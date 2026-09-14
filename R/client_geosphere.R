#' Fetch daily station data from the GeoSphere Austria Data Hub
#'
#' Performs one or more `GET /v1/station/historical/{resource_id}` requests
#' covering `start_date`..`end_date` (both inclusive, as in the API). Every
#' parameter is requested together with its `_flag` quality code. Ranges that
#' exceed the per-request size limit are split with [plan_geosphere_chunks()].
#'
#' Requests are throttled to the documented rate limits, and transient
#' failures (429, 5xx, timeouts) are retried with backoff. Other client errors
#' fail immediately with the API's explanation:
#' * 400: range too large, or end before start;
#' * 403: unknown station or parameter.
#'
#' This function only fetches. It does not parse or store anything, so the
#' unmodified bodies can be landed in GCS before parsing.
#'
#' @param source_config The `sources$geosphere` element of
#'   [read_sources_config()].
#' @param station_ids Integer station ids.
#' @param start_date,end_date Single `Date`s.
#' @param parameters Value parameters to request, without `_flag` suffixes.
#'   Defaults to the configured list.
#' @param max_tries,backoff Retry settings; `backoff` is a function of the
#'   attempt number returning seconds.
#'
#' @return A list with one element per request, each a list with `api`, `url`,
#'   `status`, `fetched_at` (UTC), `body_raw` (raw vector), `body` (string),
#'   `start_date` and `end_date`.
#' @export
fetch_geosphere_station <- function(source_config, station_ids, start_date, end_date,
                                    parameters = source_config$parameters,
                                    max_tries = 5L, backoff = default_backoff) {
  id_is_whole <- vapply(as.list(station_ids), is_whole_number, logical(1))
  if (length(station_ids) == 0L || !all(id_is_whole) || anyDuplicated(station_ids)) {
    cli::cli_abort(
      "{.arg station_ids} must be unique whole numbers.",
      class = "wxpipe_error_input"
    )
  }
  limits <- source_config$limits
  chunks <- plan_geosphere_chunks(
    start_date, end_date,
    n_series = length(geosphere_series(parameters)),
    n_stations = length(station_ids),
    max_values = limits$max_values_per_request
  )

  lapply(seq_len(nrow(chunks)), function(i) {
    req <- geosphere_request(
      source_config, station_ids, parameters,
      chunks$start_date[i], chunks$end_date[i]
    ) |>
      req_wxpipe_policies(
        realm = "geosphere",
        capacity = c(limits$requests_per_second, limits$requests_per_hour),
        fill_time_s = c(1, 3600),
        max_tries = max_tries,
        backoff = backoff
      )
    resp <- perform_request(req, api_name = "GeoSphere")
    record <- response_record(resp, api_name = "geosphere")
    record$start_date <- chunks$start_date[i]
    record$end_date <- chunks$end_date[i]
    record
  })
}

# Builds (but does not perform) the request. Array query parameters are sent
# as repeated keys (`parameters=a&parameters=b`), the form the OpenAPI spec
# describes; comma-separated values were also observed to work.
geosphere_request <- function(source_config, station_ids, parameters, start_date, end_date) {
  httr2::request(source_config$base_url) |>
    httr2::req_url_path_append(source_config$endpoint, source_config$resource_id) |>
    httr2::req_url_query(
      parameters = geosphere_series(parameters),
      station_ids = as.character(as.integer(station_ids)),
      start = format(start_date, "%Y-%m-%d"),
      end = format(end_date, "%Y-%m-%d"),
      output_format = "geojson",
      .multi = "explode"
    )
}

# Interleaves each parameter with its quality-flag companion, so rr and sh
# become rr, rr_flag, sh and sh_flag.
geosphere_series <- function(parameters) {
  as.vector(rbind(parameters, paste0(parameters, "_flag")))
}

# Request chunking -----------------------------------------------------------
#
# GeoSphere rejects any request whose size exceeds a fixed number of values,
# where size = series x time steps x stations. The size is computed before the
# query runs, so missing values count too. Behaviour verified live on
# 2026-09-14 against klima-v2-1d: 20 series x 50,000 days = 1,000,000 -> 200 OK;
# 20 series x 50,001 days = 1,000,020 -> 400 "data slice ... too large". The
# limit is therefore inclusive.

#' Size of a GeoSphere daily station request in data values
#'
#' @param start_date,end_date `Date`s; both ends are inclusive, as in the API.
#' @param n_series Number of requested series, counting `_flag` companions.
#' @param n_stations Number of requested stations.
#'
#' @return A single number: series x days x stations.
#' @noRd
geosphere_request_size <- function(start_date, end_date, n_series, n_stations = 1L) {
  n_days <- as.numeric(end_date - start_date) + 1
  n_series * n_days * n_stations
}

#' Split a date range into requests that respect the GeoSphere size limit
#'
#' Pure function. Returns contiguous, non-overlapping, inclusive date ranges
#' that together cover `start_date`..`end_date` exactly, each no larger than
#' `max_values`. A daily run is a single chunk; a multi-decade backfill with
#' many parameters is split.
#'
#' @param start_date,end_date Single `Date`s, `start_date <= end_date`.
#' @param n_series Number of requested series, counting `_flag` companions.
#' @param n_stations Number of stations per request.
#' @param max_values The API's per-request limit (inclusive).
#'
#' @return A data frame with `Date` columns `start_date` and `end_date`, one
#'   row per request.
#' @export
#' @examples
#' plan_geosphere_chunks(
#'   as.Date("1939-01-01"), as.Date("2026-09-13"),
#'   n_series = 20, max_values = 1e6
#' )
plan_geosphere_chunks <- function(start_date, end_date, n_series, n_stations = 1L, max_values) {
  check_single_date(start_date, "start_date")
  check_single_date(end_date, "end_date")
  if (start_date > end_date) {
    cli::cli_abort(
      "{.arg start_date} ({start_date}) must not be after {.arg end_date} ({end_date}).",
      class = "wxpipe_error_input"
    )
  }
  counts <- list(n_series = n_series, n_stations = n_stations, max_values = max_values)
  for (arg in names(counts)) {
    value <- counts[[arg]]
    if (!is_whole_number(value) || value < 1) {
      cli::cli_abort(
        "{.arg {arg}} must be a single whole number >= 1.",
        class = "wxpipe_error_input"
      )
    }
  }

  days_per_chunk <- floor(max_values / (n_series * n_stations))
  if (days_per_chunk < 1) {
    cli::cli_abort(
      c(
        "A single day exceeds the GeoSphere request limit.",
        "x" = "{n_series} series x {n_stations} station{?s} > {max_values} values.",
        "i" = "Request fewer parameters or stations per call."
      ),
      class = "wxpipe_error_input"
    )
  }

  starts <- seq(start_date, end_date, by = days_per_chunk)
  ends <- pmin(starts + (days_per_chunk - 1), end_date)
  data.frame(start_date = starts, end_date = ends)
}

check_single_date <- function(x, arg) {
  if (!inherits(x, "Date") || length(x) != 1L || is.na(x)) {
    cli::cli_abort(
      "{.arg {arg}} must be a single non-missing Date, not {.obj_type_friendly {x}}.",
      class = "wxpipe_error_input",
      call = rlang::caller_env()
    )
  }
  invisible(x)
}
