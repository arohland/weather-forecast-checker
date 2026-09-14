# Integration tests against a real BigQuery sandbox dataset.
#
# Skipped unless WXPIPE_INTEGRATION_TESTS=true. Required environment:
#   WXPIPE_GCP_PROJECT         project to bill and load into
#   WXPIPE_BQ_SANDBOX_DATASET  an existing, disposable dataset whose name
#                              contains "sandbox" (a guard against pointing
#                              the test at production data)
# Credentials come from gargle's default chain (locally:
# `gcloud auth application-default login`).
#
# Run from the repository root:
#   WXPIPE_INTEGRATION_TESTS=true \
#     Rscript -e 'devtools::load_all(); testthat::test_dir("tests/integration")'

skip_unless_integration <- function() {
  testthat::skip_if_not(
    identical(Sys.getenv("WXPIPE_INTEGRATION_TESTS"), "true"),
    "Set WXPIPE_INTEGRATION_TESTS=true to run BigQuery integration tests."
  )
  project <- Sys.getenv("WXPIPE_GCP_PROJECT")
  dataset <- Sys.getenv("WXPIPE_BQ_SANDBOX_DATASET")
  if (!nzchar(project) || !grepl("sandbox", dataset, fixed = TRUE)) {
    stop(
      "Set WXPIPE_GCP_PROJECT and a WXPIPE_BQ_SANDBOX_DATASET containing 'sandbox'.",
      call. = FALSE
    )
  }
}

integration_rows <- function(dates, value, run_id) {
  data.frame(
    location_id = "integration-test",
    station_id = 6300L,
    resource_id = "klima-v2-1d",
    parameter = "rr",
    reference_time = as.POSIXct(dates, tz = "UTC"),
    reference_date_local = as.Date(dates),
    value = value,
    quality_flag = 10L,
    unit = "mm",
    `_ingested_at` = structure(Sys.time(), tzone = "UTC"),
    `_source_url` = "https://example.test/integration",
    `_payload_sha256` = strrep("0", 64),
    `_pipeline_run_id` = run_id,
    `_pipeline_version` = pipeline_version(),
    check.names = FALSE
  )
}

test_that("loading into BigQuery twice leaves the row count unchanged", {
  skip_unless_integration()
  authenticate_gcp()
  backend <- bigquery_backend(
    Sys.getenv("WXPIPE_GCP_PROJECT"),
    Sys.getenv("WXPIPE_BQ_SANDBOX_DATASET")
  )

  # A far-future range under a test-only location, so no real data is touched.
  dates <- c("2099-01-01", "2099-01-02")
  scope <- observation_load_scope(
    "integration-test", 6300L, as.Date(dates[1]), as.Date(dates[2])
  )
  run_id <- paste0("it", format(Sys.time(), "%Y%m%d%H%M%S"))
  table <- "geosphere_observations"

  load_table(integration_rows(dates, c(1, 2), run_id), table, scope, backend, run_id)
  expect_identical(backend$count_rows(table, scope), 2L)

  second_run <- paste0(run_id, "b")
  load_table(integration_rows(dates, c(3, 4), second_run), table, scope, backend, second_run)
  expect_identical(backend$count_rows(table, scope), 2L)
})
