run_now <- as.POSIXct("2026-09-15 06:00:00", tz = "UTC")

daily_options <- function(...) {
  utils::modifyList(
    list(
      sources = c("geosphere", "openmeteo"), mode = "daily", start_date = as.Date(NA),
      end_date = as.Date(NA), locations = "salzburg-airport", dry_run = FALSE
    ),
    list(...)
  )
}

# Planning ------------------------------------------------------------------------------

test_that("a daily run re-fetches the revision window and yesterday's forecasts", {
  plan <- plan_ingestion(daily_options(), read_sources_config(), today = as.Date("2026-09-15"))

  window <- function(start, end) list(start_date = as.Date(start), end_date = as.Date(end))
  expect_identical(plan$geosphere, window("2026-09-01", "2026-09-14"))
  expect_true(plan$forecast)
  expect_identical(plan$previous_runs, window("2026-09-14", "2026-09-14"))
  cycles <- paste("2026-09-14", c("00:00", "06:00", "12:00", "18:00"))
  expect_equal(plan$single_runs, as.POSIXct(cycles, tz = "UTC"))
})

test_that("a backfill uses the requested range and skips the current forecast", {
  options <- daily_options(
    mode = "backfill", start_date = as.Date("2026-09-01"), end_date = as.Date("2026-09-02")
  )
  plan <- plan_ingestion(options, read_sources_config(), today = as.Date("2026-09-15"))

  expect_identical(plan$geosphere$start_date, as.Date("2026-09-01"))
  expect_false(plan$forecast)
  expect_length(plan$single_runs, 8L)
})

test_that("a backfill starting before an Open-Meteo archive is refused, not shortened", {
  config <- read_sources_config()
  early <- daily_options(
    mode = "backfill", start_date = as.Date("2026-03-01"), end_date = as.Date("2026-03-02")
  )
  expect_error(plan_ingestion(early, config, as.Date("2026-09-15")), class = "wxpipe_error_usage")

  geosphere_only <- utils::modifyList(early, list(sources = "geosphere"))
  plan <- plan_ingestion(geosphere_only, config, as.Date("2026-09-15"))
  expect_length(plan$single_runs, 0L)
  expect_null(plan$previous_runs)
})

# Running ----------------------------------------------------------------------------------

run_daily <- function(bq, gcs_uploads, run_id = "run-1", fail = character(), dry_run = FALSE) {
  config <- read_sources_config()
  options <- daily_options(dry_run = dry_run)
  plan <- plan_ingestion(options, config, as.Date(run_now, tz = "UTC"))
  upload <- function(path, bucket, object_name) {
    gcs_uploads$add(object_name)
    invisible(TRUE)
  }
  capture_logs(run_ingestion(
    plan, options, config, run_id, run_now,
    backend = bq, bucket = "wx-raw-test", upload = upload,
    fetchers = fake_fetchers(run_now, fail = fail)
  ))
}

upload_log <- function() {
  names <- character()
  list(add = function(name) names <<- c(names, name), names = function() names)
}

test_that("a daily run lands one raw file per source and loads every table", {
  bq <- fake_bigquery()
  uploads <- upload_log()
  result <- run_daily(bq, uploads)$value

  expect_identical(result$status, c("ok", "ok"))
  expect_identical(result$requests, c(1L, 6L))
  expect_identical(
    uploads$names(),
    c(
      "raw/source=geosphere/dt=2026-09-15/run-1.json.gz",
      "raw/source=openmeteo/dt=2026-09-15/run-1.json.gz"
    )
  )
  # 14 revision-window days x 10 parameters.
  expect_identical(bq$count_rows("geosphere_observations"), 140L)
  # Snapshot 8 x 3 h + previous runs 8 variables x 7 leads x 24 h + 4 runs x 8 x 3 h.
  expect_identical(bq$count_rows("openmeteo_forecasts"), 24L + 1344L + 96L)
})

test_that("re-running the same daily ingestion leaves every table's row count unchanged", {
  bq <- fake_bigquery()
  run_daily(bq, upload_log(), run_id = "run-1")
  run_daily(bq, upload_log(), run_id = "run-2")

  expect_identical(bq$count_rows("geosphere_observations"), 140L)
  expect_identical(bq$count_rows("openmeteo_forecasts"), 1464L)
})

test_that("a dry run fetches, parses and validates but writes nothing", {
  uploads <- upload_log()
  result <- run_daily(bq = NULL, uploads, dry_run = TRUE)$value

  expect_identical(result$status, c("ok", "ok"))
  expect_identical(result$rows, c(140L, 1464L))
  expect_length(uploads$names(), 0L)
})

test_that("a failing source is reported and the other source still runs", {
  bq <- fake_bigquery()
  run <- run_daily(bq, upload_log(), fail = "geosphere")

  expect_identical(run$value$status, c("failed", "ok"))
  expect_match(run$value$message[1], "simulated geosphere outage")
  expect_identical(bq$count_rows("openmeteo_forecasts"), 1464L)
  expect_true(any(grepl('"severity":"ERROR"', run$stderr, fixed = TRUE)))
})

# The command line ------------------------------------------------------------------------

test_that("run_cli() exits 0 on success, 1 when a source fails and 2 on invalid usage", {
  bq <- fake_bigquery()
  dependencies <- function(fail = character()) {
    list(
      fetchers = fake_fetchers(run_now, fail = fail),
      authenticate = function() invisible(TRUE),
      backend = function(project, dataset) bq,
      upload = function(...) invisible(TRUE)
    )
  }
  cli <- function(args = character(), getenv = gcp_env(), fail = character()) {
    capture_logs(run_cli(args, run_now, getenv, dependencies(fail)))
  }

  expect_identical(cli()$value, 0L)
  expect_identical(cli(fail = "single_runs")$value, 1L)
  expect_identical(cli("--mode=weekly")$value, 2L)
  expect_identical(cli(getenv = fake_getenv())$value, 2L)
  expect_identical(cli(c("--dry-run"), getenv = fake_getenv())$value, 0L)
})

test_that("run_cli() exits 1 without touching sources when Google Cloud is unreachable", {
  all_fetchers <- c("geosphere", "forecast", "previous_runs", "single_runs")
  fetchers <- fake_fetchers(run_now, fail = all_fetchers)
  dependencies <- list(
    fetchers = fetchers,
    authenticate = function() stop("no credentials"),
    backend = function(...) stop("unreachable"),
    upload = function(...) stop("unreachable")
  )
  run <- capture_logs(run_cli(character(), run_now, gcp_env(), dependencies))

  expect_identical(run$value, 1L)
  expect_true(any(grepl("Could not connect to Google Cloud", run$stderr, fixed = TRUE)))
})

test_that("every log line of a run is structured JSON carrying the run id", {
  run <- capture_logs(run_cli(
    "--dry-run", run_now, fake_getenv(CLOUD_RUN_EXECUTION = "wx-ingest-x1"),
    list(fetchers = fake_fetchers(run_now))
  ))
  lines <- c(run$stdout, run$stderr)
  expect_gt(length(lines), 3L)
  for (line in lines) {
    entry <- jsonlite::parse_json(line)
    expect_identical(entry[["logging.googleapis.com/labels"]]$run_id, "wx-ingest-x1-attempt0")
  }
})
