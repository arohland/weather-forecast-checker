# Package-level httptest2 redactor, applied automatically whenever responses
# are recorded or replayed while wxpipe is loaded.
#
# Nothing here is secret (both APIs are keyless); this only shortens URLs.
# httptest2 derives mock file paths from the request URL, and full hosts plus
# paths pushed fixture paths past the 100-byte limit that R CMD check flags as
# non-portable. The same substitutions are applied when replaying, so the
# shortened paths are found.
function(response) {
  shorten <- c(
    "https://dataset.api.hub.geosphere.at/v1/station/historical/" = "geosphere/",
    "https://api.open-meteo.com/v1/" = "om-forecast/",
    "https://previous-runs-api.open-meteo.com/v1/" = "om-previous/",
    "https://single-runs-api.open-meteo.com/v1/" = "om-single/"
  )
  for (long in names(shorten)) {
    response <- httptest2::gsub_response(response, long, shorten[[long]], fixed = TRUE)
  }
  response
}
