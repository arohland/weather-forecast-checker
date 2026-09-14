ingest_sources <- c("geosphere", "openmeteo")

#' Command-line entry point of the ingestion job
#'
#' Called by `exec/ingest.R`. Parses and validates the arguments, reads the
#' runtime environment, connects to Google Cloud (unless `--dry-run`), runs
#' the ingestion and logs every step as structured JSON.
#'
#' Exit statuses, which Cloud Run Jobs use to mark an execution failed:
#' * `0`: every requested source succeeded;
#' * `1`: at least one source failed, or Google Cloud was unreachable (the
#'   other sources still ran);
#' * `2`: invalid command line or configuration; nothing was fetched.
#'
#' @param args Command-line arguments.
#' @param now Run start time.
#' @inheritParams read_runtime_env
#' @param dependencies A list overriding any of `fetchers`, `authenticate`,
#'   `backend` and `upload` (see `default_dependencies()`); for tests.
#'
#' @return The exit status as an integer.
#' @export
run_cli <- function(args = commandArgs(trailingOnly = TRUE), now = Sys.time(),
                    getenv = Sys.getenv, dependencies = list()) {
  deps <- utils::modifyList(default_dependencies(), dependencies)
  run_id <- new_run_id(now, getenv)
  set_log_context(
    labels = list(run_id = run_id, pipeline_version = pipeline_version()),
    operation_id = run_id
  )
  on.exit(set_log_context(), add = TRUE)
  today <- as.Date(now, tz = "UTC")

  setup <- tryCatch(
    {
      config <- read_sources_config()
      options <- parse_ingest_args(args, config, today = today)
      list(
        config = config,
        options = options,
        runtime = read_runtime_env(options$dry_run, getenv),
        plan = plan_ingestion(options, config, today = today)
      )
    },
    wxpipe_error_usage = identity,
    wxpipe_error_config = identity
  )
  if (inherits(setup, "condition")) {
    log_event("ERROR", condition_summary(setup), error_class = class(setup)[1])
    return(2L)
  }
  options <- setup$options
  log_event(
    "INFO", "Ingestion run started",
    mode = options$mode, sources = options$sources, locations = options$locations,
    start_date = options$start_date, end_date = options$end_date, dry_run = options$dry_run
  )

  backend <- NULL
  if (!options$dry_run) {
    backend <- tryCatch(
      {
        deps$authenticate()
        deps$backend(setup$runtime$project, setup$runtime$dataset)
      },
      error = function(e) {
        log_event("ERROR", paste("Could not connect to Google Cloud:", condition_summary(e)))
        NULL
      }
    )
    if (is.null(backend)) {
      return(1L)
    }
  }

  summary <- run_ingestion(
    setup$plan, options, setup$config, run_id, now,
    backend = backend, bucket = setup$runtime$bucket,
    upload = deps$upload, fetchers = deps$fetchers
  )
  status <- if (all(summary$status == "ok")) 0L else 1L
  log_event(
    if (status == 0L) "INFO" else "ERROR", "Ingestion run finished",
    status = status, sources = summary$source, results = summary$status, rows = summary$rows
  )
  status
}

#' Parse and validate the ingestion command line
#'
#' ```
#' Rscript exec/ingest.R --source=geosphere|openmeteo|all \
#'                       --mode=daily|backfill \
#'                       --start-date=YYYY-MM-DD --end-date=YYYY-MM-DD \
#'                       --location=salzburg-airport \
#'                       --dry-run
#' ```
#'
#' Daily runs derive their dates from the run date, so `--start-date` and
#' `--end-date` are only accepted (and then required) with `--mode=backfill`.
#' Dates are UTC days, both inclusive. Without `--location`, every configured
#' location is ingested.
#'
#' @param args Command-line arguments.
#' @param config The source configuration.
#' @param today The run date (UTC).
#'
#' @return A list with `sources`, `mode`, `start_date`, `end_date`,
#'   `locations` and `dry_run`. Invalid input raises a `wxpipe_error_usage`
#'   error.
#' @export
parse_ingest_args <- function(args = character(), config = read_sources_config(),
                              today = as.Date(Sys.time(), tz = "UTC")) {
  parsed <- tryCatch(
    optparse::parse_args(ingest_option_parser(), args = args),
    error = function(e) {
      abort_usage(paste("Could not parse the command line:", cli_escape(conditionMessage(e))))
    }
  )

  source <- parsed$source
  if (!source %in% c(ingest_sources, "all")) {
    abort_usage("{.arg --source} must be geosphere, openmeteo or all, not {.val {source}}.")
  }
  mode <- parsed$mode
  if (!mode %in% c("daily", "backfill")) {
    abort_usage("{.arg --mode} must be daily or backfill, not {.val {mode}}.")
  }

  start_date <- parse_cli_date(parsed$start_date, "--start-date")
  end_date <- parse_cli_date(parsed$end_date, "--end-date")
  given <- !is.na(c(start_date, end_date))
  if (mode == "daily" && any(given)) {
    abort_usage("Daily runs derive their dates; use {.code --mode=backfill} to choose dates.")
  }
  if (mode == "backfill" && !all(given)) {
    abort_usage("A backfill needs both {.arg --start-date} and {.arg --end-date}.")
  }
  if (mode == "backfill" && start_date > end_date) {
    abort_usage("{.arg --start-date} ({start_date}) is after {.arg --end-date} ({end_date}).")
  }
  if (mode == "backfill" && end_date > today) {
    abort_usage("{.arg --end-date} ({end_date}) is in the future.")
  }

  configured <- names(config$locations)
  locations <- if (is.na(parsed$location)) configured else parsed$location
  unknown <- setdiff(locations, configured)
  if (length(unknown) > 0L) {
    abort_usage("Unknown location {.val {unknown}}; configured: {.val {configured}}.")
  }

  list(
    sources = if (source == "all") ingest_sources else source,
    mode = mode,
    start_date = start_date,
    end_date = end_date,
    locations = locations,
    dry_run = isTRUE(parsed$dry_run)
  )
}

ingest_option_parser <- function() {
  optparse::OptionParser(
    usage = "Rscript exec/ingest.R [options]",
    description = paste(
      "Ingest weather observations (GeoSphere Austria) and forecasts (Open-Meteo)",
      "into BigQuery. Exit status: 0 success, 1 a source failed, 2 invalid usage."
    ),
    option_list = list(
      optparse::make_option(
        "--source",
        default = "all",
        help = "geosphere, openmeteo or all [default: %default]"
      ),
      optparse::make_option(
        "--mode",
        default = "daily",
        help = "daily or backfill [default: %default]"
      ),
      optparse::make_option(
        "--start-date",
        dest = "start_date", default = NA_character_,
        help = "First UTC date to backfill (YYYY-MM-DD)"
      ),
      optparse::make_option(
        "--end-date",
        dest = "end_date", default = NA_character_,
        help = "Last UTC date to backfill, inclusive (YYYY-MM-DD)"
      ),
      optparse::make_option(
        "--location",
        default = NA_character_,
        help = "Location id from inst/config/sources.yml [default: all]"
      ),
      optparse::make_option(
        "--dry-run",
        dest = "dry_run", action = "store_true", default = FALSE,
        help = "Fetch, parse and validate, but write nothing"
      )
    )
  )
}

parse_cli_date <- function(value, flag) {
  if (is.na(value)) {
    return(as.Date(NA))
  }
  is_date <- grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", value) && !is.na(as.Date(value, optional = TRUE))
  if (!is_date) {
    abort_usage("{.arg {flag}} must be a date in YYYY-MM-DD format, not {.val {value}}.")
  }
  as.Date(value)
}

abort_usage <- function(message, env = parent.frame()) {
  cli::cli_abort(message, class = "wxpipe_error_usage", call = NULL, .envir = env)
}

default_dependencies <- function() {
  list(
    fetchers = default_fetchers(),
    authenticate = authenticate_gcp,
    backend = bigquery_backend,
    upload = gcs_upload_file
  )
}
