metadata_columns <- function(run) {
  data.frame(
    `_ingested_at` = run$ingested_at,
    `_source_url` = "https://example.test/data",
    `_payload_sha256` = strrep("ab", 32),
    `_pipeline_run_id` = run$run_id,
    `_pipeline_version` = run$pipeline_version,
    check.names = FALSE
  )
}

observation_rows <- function(dates = c("2026-09-08", "2026-09-09"), value = c(0.2, -1),
                             run_id = "20260914T060000Z-test") {
  rows <- data.frame(
    location_id = "salzburg-airport",
    station_id = 6300L,
    resource_id = "klima-v2-1d",
    parameter = "rr",
    reference_time = as.POSIXct(dates, tz = "UTC"),
    reference_date_local = as.Date(dates),
    value = value,
    quality_flag = 10L,
    unit = "mm"
  )
  cbind(rows, metadata_columns(test_run(run_id)))
}

observation_scope <- function(start = "2026-09-08", end = "2026-09-09") {
  observation_load_scope("salzburg-airport", 6300L, as.Date(start), as.Date(end))
}

forecast_rows <- function(source = "forecast", retrieved = "2026-09-13 06:00:00",
                          issued = NULL, lead = NA_integer_) {
  valid <- as.POSIXct(c("2026-09-14 00:00:00", "2026-09-14 01:00:00"), tz = "UTC")
  issued_at <- .POSIXct(c(NA_real_, NA_real_), tz = "UTC")
  lead_hours <- NA_integer_
  if (!is.null(issued)) {
    issued_at <- as.POSIXct(rep(issued, 2), tz = "UTC")
    lead_hours <- as.integer(difftime(valid, issued_at, units = "hours"))
  }
  rows <- data.frame(
    location_id = "salzburg-airport",
    model = "geosphere_seamless",
    forecast_source = source,
    issued_at = issued_at,
    lead_time_days = as.integer(lead),
    lead_time_hours = lead_hours,
    retrieved_at = as.POSIXct(retrieved, tz = "UTC"),
    valid_time = valid,
    valid_date_local = as.Date("2026-09-14"),
    variable = "temperature_2m",
    value = c(15, 14.5),
    unit = "°C"
  )
  cbind(rows, metadata_columns(test_run()))
}

seamless_scope <- function(forecast_source, ...) {
  forecast_load_scope("salzburg-airport", "geosphere_seamless", forecast_source, ...)
}

load_observations <- function(bq, rows = observation_rows(), scope = observation_scope(),
                              run_id = "run-1") {
  load_table(rows, "geosphere_observations", scope, bq, run_id)
}

load_forecasts <- function(bq, rows, scope, run_id = "run-1") {
  load_table(rows, "openmeteo_forecasts", scope, bq, run_id)
}

# Idempotency -------------------------------------------------------------------------

test_that("loading the same observations twice leaves the row count unchanged", {
  bq <- fake_bigquery()
  load_observations(bq, run_id = "run-1")
  expect_identical(bq$count_rows("geosphere_observations"), 2L)

  load_observations(bq, run_id = "run-2")
  expect_identical(bq$count_rows("geosphere_observations"), 2L)
})

test_that("a reload replaces revised observation values instead of duplicating them", {
  bq <- fake_bigquery()
  load_observations(bq, observation_rows(value = c(0.2, -1)), run_id = "run-1")
  revised <- observation_rows(value = c(0.4, 1.5), run_id = "run-2")
  load_observations(bq, revised, run_id = "run-2")

  stored <- bq$rows("geosphere_observations")
  expect_identical(nrow(stored), 2L)
  expect_setequal(stored$value, c(0.4, 1.5))
  expect_identical(unique(stored$`_pipeline_run_id`), "run-2")
})

test_that("loads of adjacent date ranges do not touch each other", {
  bq <- fake_bigquery()
  load_observations(bq)
  later <- observation_rows(dates = c("2026-09-10", "2026-09-11"))
  later_scope <- observation_scope("2026-09-10", "2026-09-11")
  load_observations(bq, later, later_scope)
  load_observations(bq, later, later_scope, run_id = "run-2")

  expect_identical(bq$count_rows("geosphere_observations"), 4L)
})

test_that("daily forecast snapshots are appended; a same-day rerun replaces only its own", {
  bq <- fake_bigquery()
  day_13 <- seamless_scope("forecast", retrieved_date = as.Date("2026-09-13"))
  day_14 <- seamless_scope("forecast", retrieved_date = as.Date("2026-09-14"))
  load_forecasts(bq, forecast_rows(retrieved = "2026-09-13 06:00:00"), day_13)
  load_forecasts(bq, forecast_rows(retrieved = "2026-09-14 06:00:00"), day_14)
  # The same valid times, stated on two different days: both statements are kept.
  expect_identical(bq$count_rows("openmeteo_forecasts"), 4L)

  load_forecasts(bq, forecast_rows(retrieved = "2026-09-14 07:30:00"), day_14, "run-2")
  expect_identical(bq$count_rows("openmeteo_forecasts"), 4L)
  expect_identical(bq$count_rows("openmeteo_forecasts", day_13), 2L)
})

test_that("single runs are replaced per run", {
  bq <- fake_bigquery()
  run <- function(issued) {
    rows <- forecast_rows("single_runs", issued = issued)
    scope <- seamless_scope("single_runs", issued_at = as.POSIXct(issued, tz = "UTC"))
    list(rows = rows, scope = scope)
  }
  run_00 <- run("2026-09-13 00:00:00")
  run_06 <- run("2026-09-13 06:00:00")
  load_forecasts(bq, run_00$rows, run_00$scope)
  load_forecasts(bq, run_06$rows, run_06$scope)
  load_forecasts(bq, run_06$rows, run_06$scope, "run-2")

  expect_identical(bq$count_rows("openmeteo_forecasts"), 4L)
})

test_that("previous runs are replaced per valid-time range", {
  bq <- fake_bigquery()
  rows <- rbind(
    forecast_rows("previous_runs", lead = 1L),
    forecast_rows("previous_runs", lead = 2L)
  )
  day <- as.Date("2026-09-14")
  scope <- seamless_scope("previous_runs", start_date = day, end_date = day)
  load_forecasts(bq, rows, scope)
  load_forecasts(bq, rows, scope, "run-2")

  expect_identical(bq$count_rows("openmeteo_forecasts"), 4L)
})

# Guards ---------------------------------------------------------------------------------

test_that("rows outside the load scope are refused before anything is written", {
  bq <- fake_bigquery()
  rows <- observation_rows(dates = c("2026-09-08", "2026-09-10"))
  expect_error(load_observations(bq, rows), class = "wxpipe_error_input")
  expect_length(bq$log(), 0L)
})

test_that("invalid rows, zero rows and mismatched scopes never reach BigQuery", {
  bq <- fake_bigquery()
  bad <- observation_rows()
  bad$parameter <- "rain"
  expect_error(load_observations(bq, bad), class = "wxpipe_error_schema")
  expect_error(load_observations(bq, observation_rows()[0, ]), class = "wxpipe_error_input")
  forecast_scope <- seamless_scope("forecast", retrieved_date = as.Date("2026-09-13"))
  expect_error(load_observations(bq, scope = forecast_scope), class = "wxpipe_error_input")
  expect_length(bq$log(), 0L)
})

test_that("the staging table is removed even when the replace fails", {
  bq <- fake_bigquery(fail_replace = TRUE)
  expect_error(load_observations(bq), regexp = "replace the scope", class = "wxpipe_error_bigquery")
  expect_false(any(startsWith(bq$tables(), "_staging_")))
  expect_identical(bq$count_rows("geosphere_observations"), 0L)
})

test_that("a target table is created once and a drifted table is refused", {
  bq <- fake_bigquery()
  schema <- read_table_schema("geosphere_observations")
  expect_identical(wxpipe:::ensure_table(bq, schema), "created")
  expect_identical(wxpipe:::ensure_table(bq, schema), "verified")

  drifted <- wxpipe:::schema_field_frame(schema)
  drifted$type[drifted$name == "station_id"] <- "STRING"
  bq$set_fields("geosphere_observations", drifted)
  expect_error(wxpipe:::ensure_table(bq, schema), class = "wxpipe_error_schema")
})

test_that("forecast scopes require exactly the window of their source", {
  day <- as.Date("2026-09-14")
  expect_error(seamless_scope("forecast"), class = "wxpipe_error_input")
  expect_error(
    seamless_scope("forecast", retrieved_date = day, start_date = day),
    class = "wxpipe_error_input"
  )
  expect_error(
    seamless_scope("single_runs", issued_at = "2026-09-14T00:00"),
    class = "wxpipe_error_input"
  )
  expect_error(seamless_scope("archive", retrieved_date = day), class = "wxpipe_error_input")
})

# SQL ---------------------------------------------------------------------------------------

test_that("scopes render to SQL predicates that agree with scope_matches()", {
  expect_identical(
    wxpipe:::render_scope_sql(observation_scope()),
    paste0(
      "`location_id` = 'salzburg-airport'\n",
      "    AND `station_id` IN (6300)\n",
      "    AND `reference_time` >= TIMESTAMP '2026-09-08 00:00:00.000000+00'",
      " AND `reference_time` < TIMESTAMP '2026-09-10 00:00:00.000000+00'"
    )
  )
  times <- as.POSIXct(
    c("2026-09-07 23:59:59", "2026-09-08 00:00:00", "2026-09-09 23:59:59", "2026-09-10 00:00:00"),
    tz = "UTC"
  )
  data <- data.frame(location_id = "salzburg-airport", station_id = 6300L, reference_time = times)
  expect_identical(wxpipe:::scope_matches(observation_scope(), data), c(FALSE, TRUE, TRUE, FALSE))

  snapshot <- seamless_scope("forecast", retrieved_date = as.Date("2026-09-14"))
  expect_match(
    wxpipe:::render_scope_sql(snapshot),
    "DATE(`retrieved_at`) = DATE '2026-09-14'",
    fixed = TRUE
  )
})

test_that("the replace deletes the scope and inserts staged rows in one transaction", {
  sql <- wxpipe:::render_replace_sql(
    "wx-project-123", "raw", "geosphere_observations", "_staging_x",
    observation_scope(), c("location_id", "value")
  )
  target <- "`wx-project-123.raw.geosphere_observations`"
  delete <- paste0("DELETE FROM ", target, "\n  WHERE `location_id` = 'salzburg-airport'")
  insert <- paste0(
    "INSERT INTO ", target, " (`location_id`, `value`)\n",
    "  SELECT `location_id`, `value` FROM `wx-project-123.raw._staging_x`;"
  )
  rollback <- "COMMIT TRANSACTION;\nEXCEPTION WHEN ERROR THEN\n  ROLLBACK TRANSACTION;"

  expect_match(sql, "^BEGIN\n  BEGIN TRANSACTION;")
  expect_match(sql, delete, fixed = TRUE)
  expect_match(sql, insert, fixed = TRUE)
  expect_match(sql, rollback, fixed = TRUE)
  expect_lt(regexpr("DELETE", sql, fixed = TRUE), regexpr("INSERT", sql, fixed = TRUE))
})

test_that("values and identifiers that are not strictly safe are refused, not escaped", {
  day <- as.Date("2026-09-08")
  injected <- observation_load_scope("x' OR TRUE --", 6300L, day, day)
  expect_error(wxpipe:::render_scope_sql(injected), class = "wxpipe_error_input")
  expect_error(
    wxpipe:::render_replace_sql("Bad Project", "raw", "t", "s", observation_scope(), "value"),
    class = "wxpipe_error_input"
  )
  expect_error(wxpipe:::sql_identifier("value; DROP TABLE x"), class = "wxpipe_error_input")
})

test_that("schema types map to BigQuery API field types and modes", {
  fields <- wxpipe:::schema_bq_fields(read_table_schema("geosphere_observations"))
  by_name <- stats::setNames(fields, vapply(fields, function(field) field$name, character(1)))
  expect_identical(by_name$station_id$type, "INTEGER")
  expect_identical(by_name$value$type, "FLOAT")
  expect_identical(by_name$reference_time$type, "TIMESTAMP")
  expect_identical(by_name$location_id$mode, "REQUIRED")
  expect_identical(by_name$quality_flag$mode, "NULLABLE")
  expect_identical(
    wxpipe:::normalize_bq_type(c("INTEGER", "FLOAT", "BOOLEAN", "DATE")),
    c("INT64", "FLOAT64", "BOOL", "DATE")
  )
})
