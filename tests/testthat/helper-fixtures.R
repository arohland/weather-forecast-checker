# Replays recorded HTTP responses from tests/testthat/<dir> via httptest2.
#
# CI must never hit the live APIs. httptest2::with_mock_dir() silently starts
# *recording* when its directory is missing, so this wrapper turns a missing
# fixture directory into a hard error. Recording (which does hit the live APIs
# and replaces the directory) happens only when explicitly requested:
#
#   WXPIPE_RECORD_FIXTURES=true Rscript -e 'devtools::test(filter = "client_geosphere")'
with_fixtures <- function(dir, code) {
  path <- testthat::test_path(dir)
  recording <- identical(Sys.getenv("WXPIPE_RECORD_FIXTURES"), "true")
  if (!recording && !dir.exists(path)) {
    stop(
      "Fixture directory '", dir, "' is missing. Record it deliberately with ",
      "WXPIPE_RECORD_FIXTURES=true (this calls the live API).",
      call. = FALSE
    )
  }
  if (recording) {
    unlink(path, recursive = TRUE)
  }
  httptest2::with_mock_dir(dir, code)
}
