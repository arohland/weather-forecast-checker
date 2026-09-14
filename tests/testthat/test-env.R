test_that("runtime settings come from the environment, with no defaults", {
  expect_identical(
    read_runtime_env(getenv = gcp_env()),
    list(project = "wx-test-project", dataset = "raw", bucket = "wx-raw-test")
  )
  expect_error(
    read_runtime_env(getenv = fake_getenv(WXPIPE_GCP_PROJECT = "wx-test-project")),
    regexp = "WXPIPE_BQ_DATASET",
    class = "wxpipe_error_config"
  )
})

test_that("a dry run does not need the Google Cloud settings", {
  settings <- read_runtime_env(dry_run = TRUE, getenv = fake_getenv())
  expect_identical(settings$project, "")
})

test_that("on Cloud Run the run id is the execution name plus the task attempt", {
  getenv <- fake_getenv(CLOUD_RUN_EXECUTION = "wx-ingest-abc12", CLOUD_RUN_TASK_ATTEMPT = "1")
  expect_identical(new_run_id(getenv = getenv), "wx-ingest-abc12-attempt1")
})

test_that("locally the run id is a UTC timestamp with a random suffix", {
  now <- as.POSIXct("2026-09-14 06:00:00", tz = "UTC")
  run_id <- new_run_id(now, getenv = fake_getenv())
  expect_match(run_id, "^local-20260914T060000Z-[0-9a-f]{8}$")
  expect_false(identical(run_id, new_run_id(now, getenv = fake_getenv())))
  expect_no_error(raw_object_name("geosphere", as.Date("2026-09-14"), run_id))
})
