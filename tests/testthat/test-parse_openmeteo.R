utc <- function(x) as.POSIXct(x, tz = "UTC")

parse <- function(body, variables = "temperature_2m", source = "forecast", ...) {
  parse_openmeteo_hourly(body, variables, source, "geosphere_seamless", ...)
}

# Synthetic bodies: one defect at a time -------------------------------------

test_that("a forecast body parses into long rows without an issue time", {
  expect_equal(
    parse(openmeteo_body()),
    data.frame(
      forecast_source = "forecast",
      model = "geosphere_seamless",
      issued_at = .POSIXct(c(NA_real_, NA_real_), tz = "UTC"),
      valid_time = utc(c("2026-09-01 00:00:00", "2026-09-01 01:00:00")),
      lead_time_days = NA_integer_,
      lead_time_hours = NA_integer_,
      variable = "temperature_2m",
      value = c(14.2, NA),
      unit = "°C"
    )
  )
})

test_that("previous-runs columns are mapped to variable and lead time", {
  body <- openmeteo_body(
    hourly = list(
      temperature_2m_previous_day1 = list(14, 15),
      temperature_2m_previous_day2 = list(13, NULL)
    ),
    units = list(
      temperature_2m_previous_day1 = "°C",
      temperature_2m_previous_day2 = "°C"
    )
  )
  parsed <- parse(body, source = "previous_runs", lead_days = 1:2)

  expect_identical(parsed$variable, rep("temperature_2m", 4))
  expect_identical(parsed$lead_time_days, c(1L, 1L, 2L, 2L))
  expect_identical(parsed$value, c(14, 15, 13, NA))
  expect_true(all(is.na(parsed$issued_at)))
  expect_true(all(is.na(parsed$lead_time_hours)))
})

test_that("single runs carry their issue time and exact lead hours", {
  issued <- utc("2026-09-01 00:00:00")
  parsed <- parse(openmeteo_body(), source = "single_runs", issued_at = issued)

  expect_equal(parsed$issued_at, rep(issued, 2))
  expect_identical(parsed$lead_time_hours, c(0L, 1L))
  expect_true(all(is.na(parsed$lead_time_days)))
})

test_that("malformed responses are errors, not coerced or dropped", {
  expect_error(parse("{not json"), class = "wxpipe_error_parse")
  expect_error(parse(openmeteo_body(utc_offset_seconds = 7200)), class = "wxpipe_error_parse")

  iso_times <- openmeteo_body(
    time = c("2026-09-01T00:00", "2026-09-01T01:00"),
    time_unit = "iso8601"
  )
  expect_error(parse(iso_times), class = "wxpipe_error_parse")
  duplicate_times <- openmeteo_body(time = c(1788220800, 1788220800))
  expect_error(parse(duplicate_times), class = "wxpipe_error_parse")

  expect_error(
    parse(openmeteo_body(), variables = c("temperature_2m", "precipitation")),
    regexp = "precipitation",
    class = "wxpipe_error_parse"
  )
  extra <- openmeteo_body(
    hourly = list(temperature_2m = list(1, 2), precipitation = list(0, 0)),
    units = list(temperature_2m = "°C", precipitation = "mm")
  )
  expect_error(parse(extra), regexp = "precipitation", class = "wxpipe_error_parse")

  short <- openmeteo_body(hourly = list(temperature_2m = list(14.2)))
  expect_error(parse(short), class = "wxpipe_error_parse")
  text_value <- openmeteo_body(hourly = list(temperature_2m = list("14.2", 15)))
  expect_error(parse(text_value), class = "wxpipe_error_parse")
  expect_error(parse(openmeteo_body(units = list())), class = "wxpipe_error_parse")
})

test_that("issue time and lead days are only accepted where the source provides them", {
  body <- openmeteo_body()
  issued <- utc("2026-09-01 00:00:00")
  expect_error(parse(body, source = "single_runs"), class = "wxpipe_error_parse")
  expect_error(parse(body, issued_at = issued), class = "wxpipe_error_parse")
  expect_error(parse(body, source = "previous_runs"), class = "wxpipe_error_parse")
  expect_error(parse(body, lead_days = 1), class = "wxpipe_error_parse")
  expect_error(parse(body, source = "archive"), class = "wxpipe_error_parse")
  expect_error(parse(body, variables = c("a", "a")), class = "wxpipe_error_parse")
})
