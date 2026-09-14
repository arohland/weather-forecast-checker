# Ingestion pipeline -------------------------------------------------------------------
#
# For each source: fetch everything the plan asks for, land all raw responses
# in GCS (one file per source), and only then parse, validate and load them,
# one load per natural batch. A source that fails is logged and reported, and
# the other sources still run; the CLI exits non-zero if any source failed.

#' Plan what one ingestion run fetches
#'
#' Pure function turning the parsed command line and the run date into
#' concrete windows (all dates UTC, inclusive).
#'
#' Daily runs:
#' * GeoSphere: the last `revision_window_days` days up to yesterday, so
#'   revised observations are picked up.
#' * Open-Meteo: the current forecast snapshot, yesterday's Previous Runs
#'   values (all lead times are archived by then) and yesterday's model runs
#'   on every configured cycle.
#'
#' Backfills use `start_date`..`end_date` for every selected source (the
#' current forecast snapshot cannot be backfilled). A range starting before the
#' Previous Runs archive is refused. The Single Runs archive starts much later
#' (see `inst/config/sources.yml`), so model runs before its start are left out
#' of the plan and counted in `skipped_single_runs`, which the CLI logs as a
#' warning; this keeps a Previous Runs history backfill possible.
#'
#' @param options Output of [parse_ingest_args()].
#' @param config The source configuration.
#' @param today The run date (UTC).
#'
#' @return A list with `geosphere` and `previous_runs` (each `NULL` or a list
#'   with `start_date` and `end_date`), `forecast` (logical), `single_runs`
#'   (a `POSIXct` vector of run times, possibly empty) and
#'   `skipped_single_runs` (the number of runs before the archive start).
#' @export
plan_ingestion <- function(options, config, today) {
  check_single_date(today, "today")
  daily <- identical(options$mode, "daily")
  yesterday <- today - 1
  plan <- list(
    geosphere = NULL,
    forecast = FALSE,
    previous_runs = NULL,
    single_runs = .POSIXct(numeric(), tz = "UTC"),
    skipped_single_runs = 0L
  )

  if ("geosphere" %in% options$sources) {
    revision_days <- config$sources$geosphere$revision_window_days
    plan$geosphere <- if (daily) {
      list(start_date = today - revision_days, end_date = yesterday)
    } else {
      list(start_date = options$start_date, end_date = options$end_date)
    }
  }

  if ("openmeteo" %in% options$sources) {
    openmeteo <- config$sources$openmeteo
    start <- if (daily) yesterday else options$start_date
    end <- if (daily) yesterday else options$end_date
    check_archive_start(start, openmeteo$previous_runs$archive_start, "Previous Runs")
    plan$forecast <- daily
    plan$previous_runs <- list(start_date = start, end_date = end)

    runs <- cycle_times(start, end, openmeteo$single_runs$run_hours_utc)
    archived <- as.Date(runs, tz = "UTC") >= as.Date(openmeteo$single_runs$archive_start)
    plan$single_runs <- runs[archived]
    plan$skipped_single_runs <- sum(!archived)
  }
  plan
}

#' Run one planned ingestion
#'
#' @param plan Output of [plan_ingestion()].
#' @param options Output of [parse_ingest_args()].
#' @param config The source configuration.
#' @param run_id Pipeline run identifier.
#' @param now Run start time; becomes `_ingested_at`.
#' @param backend A BigQuery backend ([bigquery_backend()]); `NULL` in a dry run.
#' @param bucket Raw landing bucket; unused in a dry run.
#' @param upload GCS upload function (see [land_raw_payloads()]).
#' @param fetchers A list of fetch functions: `geosphere`, `forecast`,
#'   `previous_runs` and `single_runs`.
#'
#' @return A data frame with one row per source: `source`, `status`
#'   (`"ok"` or `"failed"`), `requests`, `rows` and `message`.
#' @export
run_ingestion <- function(plan, options, config, run_id, now, backend = NULL, bucket = NULL,
                          upload = gcs_upload_file, fetchers = default_fetchers()) {
  context <- list(
    plan = plan,
    config = config,
    run = list(
      run_id = run_id,
      ingested_at = structure(now, tzone = "UTC"),
      pipeline_version = pipeline_version()
    ),
    run_date = as.Date(now, tz = "UTC"),
    dry_run = isTRUE(options$dry_run),
    locations = lapply(options$locations, function(id) get_location(config, id)),
    backend = backend,
    bucket = bucket,
    upload = upload,
    fetchers = fetchers
  )

  results <- lapply(options$sources, function(source) {
    tryCatch(
      ingest_source(source, context),
      error = function(e) {
        message <- condition_summary(e)
        log_event(
          "ERROR", paste0("Source ", source, " failed: ", message),
          source = source, error_class = class(e)[1]
        )
        source_result(source, "failed", NA_integer_, NA_integer_, message)
      }
    )
  })
  do.call(rbind, results)
}

default_fetchers <- function() {
  list(
    geosphere = fetch_geosphere_station,
    forecast = fetch_openmeteo_forecast,
    previous_runs = fetch_openmeteo_previous_runs,
    single_runs = fetch_openmeteo_single_runs
  )
}

# One source ----------------------------------------------------------------------------

ingest_source <- function(source, context) {
  batches <- switch(source,
    geosphere = geosphere_batches(context),
    openmeteo = openmeteo_batches(context)
  )
  records <- unlist(lapply(batches, function(batch) batch$records), recursive = FALSE)
  log_event("INFO", "Fetched responses", source = source, responses = length(records))

  # Land every raw response before parsing anything, so a parsing bug can be
  # fixed and replayed from GCS.
  if (!context$dry_run && length(records) > 0L) {
    landed <- land_raw_payloads(
      records, source, context$run$run_id, context$run_date, context$bucket,
      upload = context$upload
    )
    log_event("INFO", "Landed raw payloads", source = source, uri = landed$uri)
  }

  rows <- 0L
  for (batch in batches) {
    loaded <- process_batch(batch, context)
    log_event(
      "INFO", if (context$dry_run) "Validated rows (dry run)" else "Loaded rows",
      source = source, table = batch$table, location = batch$location$id, rows = loaded
    )
    rows <- rows + loaded
  }
  source_result(source, "ok", length(records), rows, "")
}

geosphere_batches <- function(context) {
  window <- context$plan$geosphere
  source_config <- context$config$sources$geosphere
  batches <- list()
  for (location in context$locations) {
    if (is.null(location$geosphere)) {
      log_event("INFO", "Location has no GeoSphere station; skipped", location = location$id)
      next
    }
    station <- location$geosphere$station_id
    records <- context$fetchers$geosphere(
      source_config, station, window$start_date, window$end_date
    )
    for (record in records) {
      record$location_id <- location$id
      scope <- observation_load_scope(location$id, station, record$start_date, record$end_date)
      batch <- new_batch("geosphere_observations", location, list(record), scope)
      batches <- c(batches, list(batch))
    }
  }
  batches
}

openmeteo_batches <- function(context) {
  plan <- context$plan
  source_config <- context$config$sources$openmeteo
  model <- source_config$model
  batches <- list()
  add_batch <- function(batches, location, records, scope) {
    records <- lapply(records, function(record) `[[<-`(record, "location_id", location$id))
    c(batches, list(new_batch("openmeteo_forecasts", location, records, scope)))
  }

  for (location in context$locations) {
    if (plan$forecast) {
      for (record in context$fetchers$forecast(source_config, location)) {
        retrieved_date <- as.Date(record$fetched_at, tz = "UTC")
        scope <- forecast_load_scope(
          location$id, model, "forecast",
          retrieved_date = retrieved_date
        )
        batches <- add_batch(batches, location, list(record), scope)
      }
    }

    if (!is.null(plan$previous_runs)) {
      window <- plan$previous_runs
      records <- context$fetchers$previous_runs(
        source_config, location, window$start_date, window$end_date
      )
      for (record in records) {
        scope <- forecast_load_scope(
          location$id, model, "previous_runs",
          start_date = record$start_date, end_date = record$end_date
        )
        batches <- add_batch(batches, location, list(record), scope)
      }
    }

    # One load per day of runs rather than per run: a long backfill then needs
    # a quarter of the staging loads and transactions.
    if (length(plan$single_runs) > 0L) {
      records <- context$fetchers$single_runs(source_config, location, plan$single_runs)
      run_days <- vapply(records, function(record) {
        format(record$issued_at, "%Y-%m-%d", tz = "UTC")
      }, character(1))
      for (day in unique(run_days)) {
        day_records <- records[run_days == day]
        issued_at <- do.call(c, lapply(day_records, function(record) record$issued_at))
        scope <- forecast_load_scope(location$id, model, "single_runs", issued_at = issued_at)
        batches <- add_batch(batches, location, day_records, scope)
      }
    }
  }
  batches
}

# Batches ----------------------------------------------------------------------------------

new_batch <- function(table, location, records, scope) {
  list(table = table, location = location, records = records, scope = scope)
}

process_batch <- function(batch, context) {
  rows <- do.call(rbind, lapply(batch$records, batch_rows, batch = batch, context = context))
  if (context$dry_run) {
    validate_table(rows, read_table_schema(batch$table))
    return(nrow(rows))
  }
  load_table(rows, batch$table, batch$scope, context$backend, context$run$run_id)$rows_loaded
}

batch_rows <- function(record, batch, context) {
  metadata <- ingestion_metadata(record, context$run)
  if (batch$table == "geosphere_observations") {
    geosphere <- context$config$sources$geosphere
    parsed <- parse_geosphere_station(record$body, geosphere$parameters)
    return(as_observation_rows(parsed, batch$location, geosphere$resource_id, metadata))
  }
  parsed <- parse_openmeteo_hourly(
    record$body, record$variables, record$forecast_source, record$model,
    issued_at = record$issued_at, lead_days = record$lead_days
  )
  as_forecast_rows(parsed, batch$location, record, metadata)
}

# Helpers ----------------------------------------------------------------------------------

source_result <- function(source, status, requests, rows, message) {
  data.frame(
    source = source,
    status = status,
    requests = as.integer(requests),
    rows = as.integer(rows),
    message = message
  )
}

cycle_times <- function(start_date, end_date, hours) {
  days <- format(seq(start_date, end_date, by = 1), "%Y-%m-%d")
  grid <- expand.grid(day = days, hour = sort(hours), stringsAsFactors = FALSE)
  sort(as.POSIXct(sprintf("%s %02d:00:00", grid$day, grid$hour), tz = "UTC"))
}

check_archive_start <- function(start_date, archive_start, api) {
  archive_start <- as.Date(archive_start)
  if (start_date < archive_start) {
    abort_usage(c(
      "Open-Meteo {api} data starts on {archive_start}; the requested range starts {start_date}.",
      "i" = "Use {.code --source=geosphere} for earlier dates, or a later {.arg --start-date}."
    ))
  }
  invisible(TRUE)
}
