# Builds small, hand-controlled GeoSphere response bodies for testing parser
# failure modes. Happy-path parsing is tested against real recorded responses
# in fixtures/; these synthetic bodies exist only to break one thing at a time.
geosphere_body <- function(
  timestamps = c("2026-09-08T00:00+00:00", "2026-09-09T00:00+00:00"),
  series = list(
    rr = list(unit = "mm", data = list(0.2, -1)),
    rr_flag = list(unit = "code", data = list(10, NULL))
  ),
  station = 6300,
  type = "FeatureCollection"
) {
  parameters <- lapply(names(series), function(name) {
    list(name = name, unit = series[[name]]$unit, data = series[[name]]$data)
  })
  names(parameters) <- names(series)

  body <- list(
    media_type = "application/json",
    type = type,
    version = "v1",
    timestamps = as.list(timestamps),
    features = list(list(
      type = "Feature",
      geometry = list(type = "Point", coordinates = list(47.78944, 13.00861)),
      properties = list(parameters = parameters, station = station)
    ))
  )
  as.character(jsonlite::toJSON(body, auto_unbox = TRUE, null = "null", digits = NA))
}
