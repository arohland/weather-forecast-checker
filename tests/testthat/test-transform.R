salzburg_location <- function() get_location(read_sources_config(), "salzburg-airport")

test_that("parsed observations become schema-valid rows with metadata", {
  schema <- read_table_schema("geosphere_observations")
  record <- fake_record()
  parsed <- parse_geosphere_station(record$body, "rr")

  rows <- as_observation_rows(
    parsed, salzburg_location(), "klima-v2-1d", ingestion_metadata(record, test_run())
  )

  expect_silent(validate_table(rows, schema))
  expect_identical(names(rows), wxpipe:::schema_column_names(schema))
  expect_identical(unique(rows$location_id), "salzburg-airport")
  expect_identical(unique(rows$`_payload_sha256`), wxpipe:::payload_sha256(record$body_raw))
  expect_identical(unique(rows$`_pipeline_run_id`), "20260914T060000Z-test")
  expect_equal(rows$reference_date_local, as.Date(c("2026-09-08", "2026-09-09")))
})

test_that("parsed forecasts become schema-valid rows with local dates", {
  schema <- read_table_schema("openmeteo_forecasts")
  # 2026-09-01 21:00 and 22:00 UTC = 23:00 and 00:00 in Vienna (CEST).
  record <- fake_record(body = openmeteo_body(time = c(1788296400, 1788300000)), api = "openmeteo")
  parsed <- parse_openmeteo_hourly(
    record$body, "temperature_2m", "single_runs", "geosphere_seamless",
    issued_at = utc_time("2026-09-01 00:00:00")
  )

  metadata <- ingestion_metadata(record, test_run())
  rows <- as_forecast_rows(parsed, salzburg_location(), record, metadata)

  expect_silent(validate_table(rows, schema))
  expect_identical(names(rows), wxpipe:::schema_column_names(schema))
  expect_equal(rows$valid_date_local, as.Date(c("2026-09-01", "2026-09-02")))
  expect_equal(rows$retrieved_at, rep(record$fetched_at, 2))
  expect_identical(rows$lead_time_hours, c(21L, 22L))
})

test_that("ingestion metadata requires a record and a complete run", {
  record <- fake_record()
  expect_error(ingestion_metadata(list(url = "x"), test_run()), class = "wxpipe_error_input")
  expect_error(ingestion_metadata(record, list(run_id = "x")), class = "wxpipe_error_input")
})

test_that("recorded responses from every source produce schema-valid rows", {
  config <- read_sources_config()
  location <- salzburg_location()
  observations_schema <- read_table_schema("geosphere_observations")
  forecasts_schema <- read_table_schema("openmeteo_forecasts")

  with_fixtures("fixtures/geosphere-recent", {
    geosphere <- fetch_geosphere_station(
      config$sources$geosphere, 6300L, as.Date("2026-08-31"), as.Date("2026-09-14")
    )
  })
  observations <- as_observation_rows(
    parse_geosphere_station(geosphere[[1]]$body, config$sources$geosphere$parameters),
    location, config$sources$geosphere$resource_id, ingestion_metadata(geosphere[[1]], test_run())
  )
  expect_silent(validate_table(observations, observations_schema))

  openmeteo <- config$sources$openmeteo
  with_fixtures("fixtures/om-forecast", {
    forecast <- fetch_openmeteo_forecast(openmeteo, location)
  })
  with_fixtures("fixtures/om-single", {
    single <- fetch_openmeteo_single_runs(openmeteo, location, utc_time("2026-09-10 00:00:00"))
  })
  openmeteo$previous_runs$chunk_days <- 2L
  with_fixtures("fixtures/om-previous", {
    previous <- fetch_openmeteo_previous_runs(
      openmeteo, location, as.Date("2026-09-01"), as.Date("2026-09-04")
    )
  })

  for (record in c(forecast, single, previous)) {
    parsed <- parse_openmeteo_hourly(
      record$body, record$variables, record$forecast_source, record$model,
      issued_at = record$issued_at, lead_days = record$lead_days
    )
    rows <- as_forecast_rows(parsed, location, record, ingestion_metadata(record, test_run()))
    expect_silent(validate_table(rows, forecasts_schema))
  }
})
