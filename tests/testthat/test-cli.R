today <- as.Date("2026-09-15")
parse <- function(...) parse_ingest_args(c(...), read_sources_config(), today = today)

test_that("defaults ingest every source and location daily", {
  options <- parse()
  expect_identical(options$sources, c("geosphere", "openmeteo"))
  expect_identical(options$mode, "daily")
  expect_identical(options$locations, "salzburg-airport")
  expect_false(options$dry_run)
  expect_true(is.na(options$start_date))
})

test_that("a backfill is parsed with --flag=value and --flag value syntax", {
  options <- parse(
    "--source=geosphere", "--mode=backfill", "--start-date=2026-09-01",
    "--end-date", "2026-09-07", "--location=salzburg-airport", "--dry-run"
  )
  expect_identical(options$sources, "geosphere")
  expect_identical(options$start_date, as.Date("2026-09-01"))
  expect_identical(options$end_date, as.Date("2026-09-07"))
  expect_true(options$dry_run)
})

test_that("invalid command lines are usage errors", {
  backfill <- c("--mode=backfill", "--start-date=2026-09-01", "--end-date=2026-09-07")
  invalid <- list(
    bad_source = "--source=metar",
    bad_mode = "--mode=weekly",
    malformed_date = c("--mode=backfill", "--start-date=2026-9-1", "--end-date=2026-09-07"),
    impossible_date = c("--mode=backfill", "--start-date=2026-02-30", "--end-date=2026-09-07"),
    backfill_without_end = c("--mode=backfill", "--start-date=2026-09-01"),
    daily_with_dates = "--start-date=2026-09-01",
    reversed_range = c("--mode=backfill", "--start-date=2026-09-07", "--end-date=2026-09-01"),
    future_end = c("--mode=backfill", "--start-date=2026-09-01", "--end-date=2026-09-20"),
    unknown_location = c(backfill, "--location=vienna")
  )
  for (case in names(invalid)) {
    expect_error(
      do.call(parse, as.list(invalid[[case]])),
      class = "wxpipe_error_usage",
      info = case
    )
  }
})
