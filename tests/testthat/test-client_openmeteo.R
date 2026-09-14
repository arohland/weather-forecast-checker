openmeteo_config <- function() read_sources_config()$sources$openmeteo
salzburg <- function() get_location(read_sources_config(), "salzburg-airport")
no_requests <- function(env = parent.frame()) {
  httr2::local_mocked_responses(function(req) stop("no request expected"), env = env)
}

# Pure pieces --------------------------------------------------------------------

test_that("openmeteo_call_cost() reproduces the documented pricing examples", {
  limits <- list(variables_per_call = 10, days_per_call = 14)
  expect_equal(openmeteo_call_cost(15, 14, limits), 1.5)
  expect_equal(openmeteo_call_cost(15, 28, limits), 3)
  expect_equal(openmeteo_call_cost(8, 7, limits), 1)
  expect_equal(openmeteo_call_cost(56, 14, limits), 5.6)
})

test_that("requests ask for UTC Unix times, m/s and the configured model", {
  config <- openmeteo_config()
  req <- wxpipe:::openmeteo_request(
    config$forecast$base_url, salzburg(), c("temperature_2m", "precipitation"),
    config$model,
    forecast_days = 16
  )
  url <- httr2::url_parse(req$url)

  expect_identical(url$hostname, "api.open-meteo.com")
  expect_identical(url$query$hourly, "temperature_2m,precipitation")
  expect_identical(url$query$models, "geosphere_seamless")
  expect_identical(url$query$timezone, "GMT")
  expect_identical(url$query$timeformat, "unixtime")
  expect_identical(url$query$wind_speed_unit, "ms")
  expect_identical(url$query$latitude, "47.78944")
  expect_identical(url$query$forecast_days, "16")
})

test_that("fetches abort before any request when the call budget would be exceeded", {
  config <- openmeteo_config()
  config$limits$daily_call_budget <- 5L
  no_requests()

  expect_error(
    fetch_openmeteo_previous_runs(config, salzburg(), as.Date("2024-03-01"), as.Date("2024-03-31")),
    regexp = "budget",
    class = "wxpipe_error_input"
  )
})

test_that("previous runs reject ranges outside the archive or in the wrong order", {
  config <- openmeteo_config()
  no_requests()
  fetch <- function(start, end) {
    fetch_openmeteo_previous_runs(config, salzburg(), as.Date(start), as.Date(end))
  }
  expect_error(fetch("2024-01-01", "2024-01-07"), class = "wxpipe_error_input")
  expect_error(fetch("2026-09-07", "2026-09-01"), class = "wxpipe_error_input")
})

test_that("single runs must be on a configured cycle and inside the archive", {
  config <- openmeteo_config()
  no_requests()
  fetch <- function(run_times) fetch_openmeteo_single_runs(config, salzburg(), run_times)

  expect_error(fetch(utc_time("2026-09-10 03:00:00")), class = "wxpipe_error_input")
  expect_error(fetch(utc_time("2026-09-10 00:30:00")), class = "wxpipe_error_input")
  expect_error(fetch(utc_time("2026-04-01 18:00:00")), class = "wxpipe_error_input")
  expect_error(fetch(utc_time(rep("2026-09-10 00:00:00", 2))), class = "wxpipe_error_input")
  expect_error(fetch("2026-09-10T00:00"), class = "wxpipe_error_input")
})

# Recorded responses ------------------------------------------------------------
# Recorded from the live APIs on 2026-09-14 (see helper-fixtures.R).

test_that("the current forecast is fetched and parsed from a recorded response", {
  config <- openmeteo_config()
  with_fixtures("fixtures/om-forecast", {
    records <- fetch_openmeteo_forecast(config, salzburg())
  })

  expect_length(records, 1L)
  record <- records[[1]]
  rows <- parse_openmeteo_hourly(
    record$body, record$variables, record$forecast_source, record$model
  )

  expect_identical(nrow(rows), length(config$hourly_variables) * 16L * 24L)
  expect_setequal(unique(rows$variable), config$hourly_variables)
  expect_true(all(is.na(rows$issued_at)))
  expect_true(all(diff(as.numeric(sort(unique(rows$valid_time)))) == 3600))
  expect_identical(unique(rows$unit[rows$variable == "wind_speed_10m"]), "m/s")
  expect_identical(unique(rows$unit[rows$variable == "snow_depth"]), "m")
})

test_that("previous runs are fetched in chunks and mapped to lead times", {
  config <- openmeteo_config()
  config$previous_runs$chunk_days <- 2L
  with_fixtures("fixtures/om-previous", {
    records <- fetch_openmeteo_previous_runs(
      config, salzburg(), as.Date("2026-09-01"), as.Date("2026-09-04")
    )
  })

  expect_length(records, 2L)
  rows <- do.call(rbind, lapply(records, function(record) {
    parse_openmeteo_hourly(
      record$body, record$variables, record$forecast_source, record$model,
      lead_days = record$lead_days
    )
  }))

  expect_identical(nrow(rows), 8L * 7L * 4L * 24L)
  expect_setequal(unique(rows$lead_time_days), 1:7)
  expect_false(anyDuplicated(rows[c("variable", "lead_time_days", "valid_time")]) > 0L)
  expect_false(anyNA(rows$value[rows$variable == "temperature_2m"]))
  # Archive gaps observed on 2026-09-14: snow depth has no lead-time archive,
  # gusts only at lead day 1. The rows are kept, with NA values.
  expect_true(all(is.na(rows$value[rows$variable == "snow_depth"])))
  gusts <- rows[rows$variable == "wind_gusts_10m", ]
  expect_false(anyNA(gusts$value[gusts$lead_time_days == 1L]))
  expect_true(all(is.na(gusts$value[gusts$lead_time_days > 1L])))
})

test_that("a single run carries its initialisation time and exact lead hours", {
  config <- openmeteo_config()
  run <- utc_time("2026-09-10 00:00:00")
  with_fixtures("fixtures/om-single", {
    records <- fetch_openmeteo_single_runs(config, salzburg(), run)
  })

  record <- records[[1]]
  expect_match(record$url, "run=2026-09-10T00(:|%3A)00")
  rows <- parse_openmeteo_hourly(
    record$body, record$variables, record$forecast_source, record$model,
    issued_at = record$issued_at
  )

  expect_identical(nrow(rows), 8L * 16L * 24L)
  expect_true(all(rows$issued_at == run))
  expect_identical(range(rows$lead_time_hours), c(0L, 383L))
  expect_true(all(is.na(rows$lead_time_days)))
})
