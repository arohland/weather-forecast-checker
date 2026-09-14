# Builds small, hand-controlled Open-Meteo hourly response bodies for testing
# parser failure modes. Happy-path parsing is tested against real recorded
# responses in fixtures/; these synthetic bodies exist only to break one thing
# at a time. 1788220800 is 2026-09-01T00:00:00Z.
openmeteo_body <- function(
  time = c(1788220800, 1788224400),
  hourly = list(temperature_2m = list(14.2, NULL)),
  units = list(temperature_2m = "°C"),
  utc_offset_seconds = 0,
  time_unit = "unixtime"
) {
  body <- list(
    latitude = 47.78,
    longitude = 13.0,
    generationtime_ms = 0.5,
    utc_offset_seconds = utc_offset_seconds,
    timezone = "GMT",
    timezone_abbreviation = "GMT",
    elevation = 429,
    hourly_units = c(list(time = time_unit), units),
    hourly = c(list(time = as.list(time)), hourly)
  )
  as.character(jsonlite::toJSON(body, auto_unbox = TRUE, null = "null", digits = NA))
}
