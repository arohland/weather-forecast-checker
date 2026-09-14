# Package-level httptest2 redactor, applied automatically whenever responses
# are recorded or replayed while wxpipe is loaded.
#
# Nothing here is secret (both APIs are keyless); this only shortens URLs.
# httptest2 derives mock file paths from the request URL, and the full
# GeoSphere host plus path pushed fixture paths past the 100-byte limit that
# R CMD check flags as non-portable. The same substitution is applied when
# replaying, so the shortened paths are found.
function(response) {
  httptest2::gsub_response(
    response,
    "https://dataset.api.hub.geosphere.at/v1/station/historical/",
    "geosphere/",
    fixed = TRUE
  )
}
