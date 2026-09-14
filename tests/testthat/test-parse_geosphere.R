# Synthetic bodies: one defect at a time -------------------------------------

test_that("a minimal body parses into typed long-format rows", {
  parsed <- parse_geosphere_station(geosphere_body(), parameters = "rr")

  expect_equal(
    parsed,
    data.frame(
      station_id = c(6300L, 6300L),
      parameter = c("rr", "rr"),
      reference_time = as.POSIXct(c("2026-09-08", "2026-09-09"), tz = "UTC"),
      value = c(0.2, -1),
      quality_flag = c(10L, NA),
      unit = c("mm", "mm")
    )
  )
})

test_that("documented sentinels such as rr = -1 are kept, not decoded", {
  parsed <- parse_geosphere_station(geosphere_body(), parameters = "rr")
  expect_identical(parsed$value[2], -1)
})

test_that("JSON null values become NA rather than being dropped", {
  body <- geosphere_body(series = list(
    rr = list(unit = "mm", data = list(NULL, NULL)),
    rr_flag = list(unit = "code", data = list(NULL, NULL))
  ))
  parsed <- parse_geosphere_station(body, parameters = "rr")
  expect_identical(nrow(parsed), 2L)
  expect_true(all(is.na(parsed$value)))
})

test_that("a missing requested parameter is an error", {
  expect_error(
    parse_geosphere_station(geosphere_body(), parameters = c("rr", "tlmax")),
    regexp = "tlmax",
    class = "wxpipe_error_parse"
  )
})

test_that("a missing _flag companion is an error", {
  body <- geosphere_body(series = list(rr = list(unit = "mm", data = list(1, 2))))
  expect_error(
    parse_geosphere_station(body, "rr"),
    regexp = "rr_flag",
    class = "wxpipe_error_parse"
  )
})

test_that("an unrequested parameter is an error", {
  body <- geosphere_body(series = list(
    rr = list(unit = "mm", data = list(1, 2)),
    rr_flag = list(unit = "code", data = list(10, 10)),
    sh = list(unit = "cm", data = list(1, 2))
  ))
  expect_error(parse_geosphere_station(body, "rr"), regexp = "sh", class = "wxpipe_error_parse")
})

test_that("a series that does not line up with the timestamps is an error", {
  body <- geosphere_body(series = list(
    rr = list(unit = "mm", data = list(1)),
    rr_flag = list(unit = "code", data = list(10, 10))
  ))
  expect_error(parse_geosphere_station(body, "rr"), class = "wxpipe_error_parse")
})

test_that("non-numeric values and non-integer flags are errors, not coerced", {
  text_value <- geosphere_body(series = list(
    rr = list(unit = "mm", data = list("5.9", 1)),
    rr_flag = list(unit = "code", data = list(10, 10))
  ))
  fractional_flag <- geosphere_body(series = list(
    rr = list(unit = "mm", data = list(5.9, 1)),
    rr_flag = list(unit = "code", data = list(10.5, 10))
  ))
  expect_error(parse_geosphere_station(text_value, "rr"), class = "wxpipe_error_parse")
  expect_error(parse_geosphere_station(fractional_flag, "rr"), class = "wxpipe_error_parse")
})

test_that("structural problems in the body are errors", {
  broken_bodies <- list(
    not_json = "{not json",
    not_a_feature_collection = geosphere_body(type = "Feature"),
    no_utc_offset = geosphere_body(timestamps = c("2026-09-08T00:00", "2026-09-09T00:00")),
    duplicate_timestamps = geosphere_body(timestamps = rep("2026-09-08T00:00+00:00", 2)),
    station_id_as_string = geosphere_body(station = "6300"),
    no_features = '{"type":"FeatureCollection","timestamps":[],"features":[]}'
  )
  for (case in names(broken_bodies)) {
    expect_error(
      parse_geosphere_station(broken_bodies[[case]], "rr"),
      class = "wxpipe_error_parse",
      info = case
    )
  }
})

test_that("parse_geosphere_station() validates its arguments", {
  body <- geosphere_body()
  expect_error(parse_geosphere_station(c(body, body), "rr"), class = "wxpipe_error_parse")
  expect_error(parse_geosphere_station(body, c("rr", "rr")), class = "wxpipe_error_parse")
  expect_error(parse_geosphere_station(body, character()), class = "wxpipe_error_parse")
})
