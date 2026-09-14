#' Parse a GeoSphere station response into tidy observation rows
#'
#' Pure function: JSON text in, data frame out, no I/O. It turns the GeoJSON
#' `FeatureCollection` returned by
#' `GET /v1/station/historical/{resource_id}` into one row per station,
#' parameter and timestamp (long format). Long format means adding a
#' parameter to the config never changes the table schema.
#'
#' Values are kept exactly as the API sends them. In particular, the
#' documented sentinels (e.g. `rr = -1` for "no precipitation", `sh = -1` for
#' "no snow") are not decoded here: the raw layer mirrors the source, and
#' decoding belongs in the downstream staging models, where it is visible and
#' testable. JSON `null` becomes `NA`.
#'
#' The parser fails loudly, never silently dropping or coercing, when:
#' * the body is not a GeoJSON `FeatureCollection`;
#' * a requested parameter or its `_flag` companion is missing, or an
#'   unrequested one is present;
#' * a data series length does not match the number of timestamps;
#' * a value is not a number or `null`, or a quality flag is not a whole
#'   number.
#'
#' Note that `geometry.coordinates` is returned as `[lat, lon]`, the reverse
#' of the GeoJSON standard. It is ignored here: station coordinates come from
#' the configuration.
#'
#' @param body The response body as a single JSON string.
#' @param parameters Character vector of the value parameters that were
#'   requested, without their `_flag` companions.
#'
#' @return A data frame with columns `station_id` (integer), `parameter`
#'   (character), `reference_time_utc` (POSIXct, UTC), `value` (double),
#'   `quality_flag` (integer) and `unit` (character).
#' @export
parse_geosphere_station <- function(body, parameters) {
  if (!rlang::is_string(body)) {
    cli::cli_abort(
      "{.arg body} must be a single string, not {.obj_type_friendly {body}}.",
      class = "wxpipe_error_parse"
    )
  }
  if (!is_unique_names(parameters)) {
    cli::cli_abort(
      "{.arg parameters} must be a non-empty character vector of unique names.",
      class = "wxpipe_error_parse"
    )
  }

  parsed <- tryCatch(
    jsonlite::parse_json(body, simplifyVector = FALSE),
    error = function(e) {
      cli::cli_abort(
        "GeoSphere response body is not valid JSON.",
        parent = e,
        class = "wxpipe_error_parse",
        call = NULL
      )
    }
  )
  if (!is.list(parsed) || !identical(parsed$type, "FeatureCollection")) {
    cli::cli_abort(
      "GeoSphere response is not a GeoJSON FeatureCollection.",
      class = "wxpipe_error_parse"
    )
  }

  raw_timestamps <- parsed$timestamps
  timestamp_is_string <- vapply(raw_timestamps, rlang::is_string, logical(1))
  if (!is.list(raw_timestamps) || !all(timestamp_is_string)) {
    cli::cli_abort(
      "GeoSphere response {.field timestamps} must be an array of strings.",
      class = "wxpipe_error_parse"
    )
  }
  timestamps <- parse_utc_timestamp(as.character(unlist(raw_timestamps)))
  if (anyDuplicated(timestamps)) {
    cli::cli_abort(
      "GeoSphere response contains duplicate timestamps.",
      class = "wxpipe_error_parse"
    )
  }

  features <- parsed$features
  if (!is.list(features) || length(features) == 0L) {
    cli::cli_abort(
      "GeoSphere response contains no features (stations).",
      class = "wxpipe_error_parse"
    )
  }

  rows <- lapply(
    features, parse_geosphere_feature,
    timestamps = timestamps, parameters = parameters
  )
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

parse_geosphere_feature <- function(feature, timestamps, parameters) {
  properties <- feature$properties
  station <- properties$station
  if (!is_whole_number(station)) {
    cli::cli_abort(
      "GeoSphere feature has a missing or non-integer {.field station} id.",
      class = "wxpipe_error_parse"
    )
  }
  station <- as.integer(station)

  series <- properties$parameters
  if (!is.list(series) || is.null(names(series))) {
    cli::cli_abort(
      "GeoSphere feature for station {station} has no {.field parameters} object.",
      class = "wxpipe_error_parse"
    )
  }
  expected <- c(parameters, paste0(parameters, "_flag"))
  missing <- setdiff(expected, names(series))
  unexpected <- setdiff(names(series), expected)
  if (length(missing) > 0L) {
    cli::cli_abort(
      "GeoSphere response for station {station} is missing parameter{?s} {.val {missing}}.",
      class = "wxpipe_error_parse"
    )
  }
  if (length(unexpected) > 0L) {
    cli::cli_abort(
      "GeoSphere response for station {station} has unrequested parameter{?s} {.val {unexpected}}.",
      class = "wxpipe_error_parse"
    )
  }

  n <- length(timestamps)
  per_parameter <- lapply(parameters, function(parameter) {
    values <- series_to_double(series[[parameter]], parameter, station, n)
    flag_name <- paste0(parameter, "_flag")
    flags <- series_to_double(series[[flag_name]], flag_name, station, n)
    if (any(!is.na(flags) & flags != round(flags))) {
      cli::cli_abort(
        "Quality flag {.field {flag_name}} for station {station} contains non-integer codes.",
        class = "wxpipe_error_parse"
      )
    }
    unit <- series[[parameter]]$unit
    if (!rlang::is_string(unit)) {
      cli::cli_abort(
        "Parameter {.field {parameter}} for station {station} has no {.field unit}.",
        class = "wxpipe_error_parse"
      )
    }
    data.frame(
      station_id = rep(station, n),
      parameter = rep(parameter, n),
      reference_time_utc = timestamps,
      value = values,
      quality_flag = as.integer(flags),
      unit = rep(unit, n)
    )
  })
  do.call(rbind, per_parameter)
}

series_to_double <- function(entry, name, station, n) {
  json_number_series(entry$data, paste0(name, " (station ", station, ")"), n)
}
