# Open-Meteo clients -----------------------------------------------------------
#
# Three APIs, one request shape. All requests ask for hourly values in UTC
# (`timezone=GMT`) with Unix timestamps (`timeformat=unixtime`), so no local
# time ever needs to be interpreted, and wind speeds in m/s to match GeoSphere.
#
# * Forecast API: the current, continuously stitched forecast. It exposes no
#   model initialisation time, so these rows have no `issued_at`.
# * Previous Runs API: values archived at fixed lead-time offsets
#   (`<variable>_previous_dayN` = predicted N x 24 h before valid time).
# * Single Runs API: the complete output of one run, identified by its UTC
#   initialisation time, which becomes `issued_at`.
#
# Rate limiting: the free tier allows 600 calls/min, 5,000/h and 10,000/day,
# where a request with more than 10 variables or 14 days counts as several
# (fractional) calls. Requests are throttled per minute, and every fetch
# checks its planned total cost against a configured daily budget before
# sending anything.

#' Fetch the current hourly forecast from the Open-Meteo Forecast API
#'
#' @param source_config The `sources$openmeteo` element of
#'   [read_sources_config()].
#' @param location A location from [get_location()].
#' @param max_tries,backoff Retry settings; `backoff` is a function of the
#'   attempt number returning seconds.
#'
#' @return A list with one response record (see [fetch_geosphere_station()]),
#'   with added `forecast_source` (`"forecast"`), `model`, `issued_at` (`NULL`)
#'   and `variables`.
#' @export
fetch_openmeteo_forecast <- function(source_config, location,
                                     max_tries = 5L, backoff = default_backoff) {
  api <- source_config$forecast
  variables <- source_config$hourly_variables
  check_openmeteo_budget(
    openmeteo_call_cost(length(variables), api$forecast_days, source_config$limits),
    source_config$limits
  )

  req <- openmeteo_request(
    api$base_url, location, variables, source_config$model,
    forecast_days = api$forecast_days
  )
  record <- perform_openmeteo(req, source_config, max_tries, backoff)
  list(annotate_openmeteo_record(record, "forecast", source_config, variables))
}

#' Fetch archived forecasts at fixed lead times from the Previous Runs API
#'
#' Requests every configured variable at every configured lead-time offset
#' for `start_date`..`end_date` (valid dates, UTC, inclusive), split into
#' chunks of `previous_runs.chunk_days`.
#'
#' @inheritParams fetch_openmeteo_forecast
#' @param start_date,end_date Single `Date`s. `start_date` must not be earlier
#'   than the configured archive start.
#'
#' @return A list of response records, one per chunk, with added
#'   `forecast_source` (`"previous_runs"`), `model`, `issued_at` (`NULL`),
#'   `variables`, `lead_days`, `start_date` and `end_date`.
#' @export
fetch_openmeteo_previous_runs <- function(source_config, location, start_date, end_date,
                                          max_tries = 5L, backoff = default_backoff) {
  api <- source_config$previous_runs
  check_date_range(start_date, end_date)
  archive_start <- as.Date(api$archive_start)
  if (start_date < archive_start) {
    cli::cli_abort(
      c(
        "Previous Runs data for {.val {source_config$model}} starts on {archive_start}.",
        "x" = "Requested start date: {start_date}."
      ),
      class = "wxpipe_error_input"
    )
  }

  variables <- source_config$hourly_variables
  hourly <- previous_runs_columns(variables, api$lead_days)
  chunks <- split_date_range(start_date, end_date, api$chunk_days)
  chunk_days <- as.numeric(chunks$end_date - chunks$start_date) + 1
  costs <- vapply(
    chunk_days,
    function(days) openmeteo_call_cost(length(hourly), days, source_config$limits),
    numeric(1)
  )
  check_openmeteo_budget(sum(costs), source_config$limits)

  lapply(seq_len(nrow(chunks)), function(i) {
    req <- openmeteo_request(
      api$base_url, location, hourly, source_config$model,
      start_date = format(chunks$start_date[i], "%Y-%m-%d"),
      end_date = format(chunks$end_date[i], "%Y-%m-%d")
    )
    record <- perform_openmeteo(req, source_config, max_tries, backoff)
    record <- annotate_openmeteo_record(record, "previous_runs", source_config, variables)
    record$lead_days <- api$lead_days
    record$start_date <- chunks$start_date[i]
    record$end_date <- chunks$end_date[i]
    record
  })
}

#' Fetch complete model runs from the Single Runs API
#'
#' @inheritParams fetch_openmeteo_forecast
#' @param run_times A `POSIXct` vector of model initialisation times. Each
#'   must fall on a configured cycle hour (UTC) and not precede the configured
#'   archive start.
#'
#' @return A list of response records, one per run, with added
#'   `forecast_source` (`"single_runs"`), `model`, `issued_at` (the run time)
#'   and `variables`.
#' @export
fetch_openmeteo_single_runs <- function(source_config, location, run_times,
                                        max_tries = 5L, backoff = default_backoff) {
  api <- source_config$single_runs
  check_run_times(run_times, api)
  variables <- source_config$hourly_variables
  cost <- length(run_times) *
    openmeteo_call_cost(length(variables), api$forecast_days, source_config$limits)
  check_openmeteo_budget(cost, source_config$limits)

  lapply(seq_along(run_times), function(i) {
    req <- openmeteo_request(
      api$base_url, location, variables, source_config$model,
      run = format(run_times[i], "%Y-%m-%dT%H:%M", tz = "UTC"),
      forecast_days = api$forecast_days
    )
    record <- perform_openmeteo(req, source_config, max_tries, backoff)
    record <- annotate_openmeteo_record(record, "single_runs", source_config, variables)
    record$issued_at <- run_times[i]
    record
  })
}

#' Estimate the Open-Meteo API call cost of one request
#'
#' Open-Meteo counts a request with more than `variables_per_call` variables
#' or covering more than `days_per_call` days as several calls, using
#' fractional counts: 15 variables over 14 days cost 1.5 calls, over 28 days
#' 3.0 (examples from <https://open-meteo.com/en/pricing>, read 2026-09-14).
#'
#' @param n_variables Number of requested hourly variables (for Previous Runs,
#'   each variable x lead-time offset counts separately).
#' @param n_days Number of days covered.
#' @param limits The `sources$openmeteo$limits` configuration.
#'
#' @return A single number of API calls.
#' @export
#' @examples
#' limits <- list(variables_per_call = 10, days_per_call = 14)
#' openmeteo_call_cost(15, 28, limits)
openmeteo_call_cost <- function(n_variables, n_days, limits) {
  max(1, n_variables / limits$variables_per_call) * max(1, n_days / limits$days_per_call)
}

# Internals ------------------------------------------------------------------

openmeteo_request <- function(base_url, location, hourly, model, ...) {
  httr2::request(base_url) |>
    httr2::req_url_query(
      latitude = location$latitude,
      longitude = location$longitude,
      hourly = hourly,
      models = model,
      timezone = "GMT",
      timeformat = "unixtime",
      wind_speed_unit = "ms",
      ...,
      .multi = "comma"
    )
}

perform_openmeteo <- function(req, source_config, max_tries, backoff) {
  req <- req_wxpipe_policies(
    req,
    realm = "openmeteo",
    capacity = source_config$limits$requests_per_minute,
    fill_time_s = 60,
    max_tries = max_tries,
    backoff = backoff
  )
  resp <- perform_request(req, api_name = "Open-Meteo")
  response_record(resp, api_name = "openmeteo")
}

annotate_openmeteo_record <- function(record, forecast_source, source_config, variables) {
  record$forecast_source <- forecast_source
  record$model <- source_config$model
  record$issued_at <- NULL
  record$variables <- variables
  record
}

check_openmeteo_budget <- function(cost, limits) {
  if (cost > limits$daily_call_budget) {
    cli::cli_abort(
      c(
        "Planned Open-Meteo requests would cost {round(cost, 1)} API calls.",
        "x" = "That exceeds the configured daily budget of {limits$daily_call_budget}.",
        "i" = "Split the range across days, or raise {.field daily_call_budget}."
      ),
      class = "wxpipe_error_input"
    )
  }
  invisible(cost)
}

check_run_times <- function(run_times, api, call = rlang::caller_env()) {
  valid_vector <- inherits(run_times, "POSIXct") && length(run_times) > 0L
  if (!valid_vector || anyNA(run_times) || anyDuplicated(run_times)) {
    cli::cli_abort(
      "{.arg run_times} must be unique, non-missing POSIXct values.",
      class = "wxpipe_error_input",
      call = call
    )
  }
  # Only referenced inside cli message templates, which lintr cannot see into.
  labels <- format(run_times, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC") # nolint: object_usage_linter.
  hours <- as.integer(format(run_times, "%H", tz = "UTC"))
  on_cycle <- hours %in% api$run_hours_utc & format(run_times, "%M:%S", tz = "UTC") == "00:00"
  if (!all(on_cycle)) {
    cli::cli_abort(
      c(
        "Single runs must start on a configured cycle hour (UTC): {api$run_hours_utc}.",
        "x" = "Invalid run time{?s}: {labels[!on_cycle]}."
      ),
      class = "wxpipe_error_input",
      call = call
    )
  }
  archive_start <- as.Date(api$archive_start)
  too_early <- as.Date(run_times, tz = "UTC") < archive_start
  if (any(too_early)) {
    cli::cli_abort(
      c(
        "Single runs are archived from {archive_start}.",
        "x" = "Too early: {labels[too_early]}."
      ),
      class = "wxpipe_error_input",
      call = call
    )
  }
  invisible(run_times)
}
