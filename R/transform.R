# Row shaping ----------------------------------------------------------------------
#
# Pure functions that turn parser output into rows of the raw tables: add the
# location, derived local dates and the ingestion metadata every row carries,
# in the column order of inst/schemas. The result is checked with
# validate_table() before anything is loaded.

#' Ingestion metadata for rows parsed from one response
#'
#' @param record The response record the rows were parsed from.
#' @param run The pipeline run: a list with `run_id`, `ingested_at` (POSIXct,
#'   UTC) and `pipeline_version`.
#'
#' @return A named list with the five `_`-prefixed metadata values.
#' @export
ingestion_metadata <- function(record, run) {
  if (!rlang::is_string(record$url) || !is.raw(record$body_raw)) {
    cli::cli_abort("{.arg record} must be a response record.", class = "wxpipe_error_input")
  }
  run_is_complete <- rlang::is_string(run$run_id) && rlang::is_string(run$pipeline_version)
  if (!run_is_complete || !inherits(run$ingested_at, "POSIXct")) {
    cli::cli_abort(
      "{.arg run} needs {.field run_id}, {.field ingested_at} and {.field pipeline_version}.",
      class = "wxpipe_error_input"
    )
  }
  list(
    `_ingested_at` = run$ingested_at,
    `_source_url` = record$url,
    `_payload_sha256` = payload_sha256(record$body_raw),
    `_pipeline_run_id` = run$run_id,
    `_pipeline_version` = run$pipeline_version
  )
}

#' Shape parsed GeoSphere observations into `raw.geosphere_observations` rows
#'
#' @param observations Output of [parse_geosphere_station()].
#' @param location A location from [get_location()].
#' @param resource_id GeoSphere dataset id the data was fetched from.
#' @param metadata Output of [ingestion_metadata()].
#'
#' @return A data frame with the columns of the `geosphere_observations`
#'   schema, in schema order.
#' @export
as_observation_rows <- function(observations, location, resource_id, metadata) {
  n <- nrow(observations)
  rows <- data.frame(
    location_id = rep(location$id, n),
    station_id = observations$station_id,
    resource_id = rep(resource_id, n),
    parameter = observations$parameter,
    reference_time = observations$reference_time,
    reference_date_local = derive_local_date(observations$reference_time, location$timezone),
    value = observations$value,
    quality_flag = observations$quality_flag,
    unit = observations$unit
  )
  add_ingestion_metadata(rows, metadata)
}

#' Shape parsed Open-Meteo forecasts into `raw.openmeteo_forecasts` rows
#'
#' @param forecasts Output of [parse_openmeteo_hourly()].
#' @param location A location from [get_location()].
#' @param record The response record the forecasts were parsed from; its
#'   `fetched_at` becomes `retrieved_at`.
#' @param metadata Output of [ingestion_metadata()].
#'
#' @return A data frame with the columns of the `openmeteo_forecasts` schema,
#'   in schema order.
#' @export
as_forecast_rows <- function(forecasts, location, record, metadata) {
  n <- nrow(forecasts)
  rows <- data.frame(
    location_id = rep(location$id, n),
    model = forecasts$model,
    forecast_source = forecasts$forecast_source,
    issued_at = forecasts$issued_at,
    lead_time_days = forecasts$lead_time_days,
    lead_time_hours = forecasts$lead_time_hours,
    retrieved_at = rep(record$fetched_at, n),
    valid_time = forecasts$valid_time,
    valid_date_local = derive_local_date(forecasts$valid_time, location$timezone),
    variable = forecasts$variable,
    value = forecasts$value,
    unit = forecasts$unit
  )
  add_ingestion_metadata(rows, metadata)
}

add_ingestion_metadata <- function(rows, metadata) {
  n <- nrow(rows)
  for (name in names(metadata)) {
    rows[[name]] <- rep(metadata[[name]], n)
  }
  rows
}
