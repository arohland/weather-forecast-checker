utc <- function(x) as.POSIXct(x, tz = "UTC")

test_that("parse_utc_timestamp() reads the GeoSphere format as UTC", {
  parsed <- parse_utc_timestamp(c("2026-09-08T00:00+00:00", "2026-09-09T00:00+00:00"))
  expect_s3_class(parsed, "POSIXct")
  expect_identical(attr(parsed, "tzone"), "UTC")
  expect_equal(parsed, utc(c("2026-09-08 00:00:00", "2026-09-09 00:00:00")))
})

test_that("parse_utc_timestamp() applies non-zero offsets", {
  with_offsets <- c("2026-09-10T02:00+02:00", "2026-01-10T01:30+0100", "2026-09-10T00:00:30Z")
  expect_equal(
    parse_utc_timestamp(with_offsets),
    utc(c("2026-09-10 00:00:00", "2026-01-10 00:30:00", "2026-09-10 00:00:30"))
  )
})

test_that("parse_utc_timestamp() rejects timestamps without an explicit offset", {
  expect_error(parse_utc_timestamp("2026-09-10T00:00"), class = "wxpipe_error_parse")
  expect_error(parse_utc_timestamp("2026-09-10"), class = "wxpipe_error_parse")
  expect_error(parse_utc_timestamp(c("2026-09-10T00:00Z", NA)), class = "wxpipe_error_parse")
  expect_error(parse_utc_timestamp("2026-13-45T00:00Z"), class = "wxpipe_error_parse")
  expect_error(parse_utc_timestamp(20260910), class = "wxpipe_error_parse")
})

test_that("parse_utc_timestamp() handles an empty vector", {
  expect_length(parse_utc_timestamp(character()), 0L)
})

test_that("derive_local_date() rolls over to the next day in summer (UTC+2)", {
  x <- utc(c("2026-09-10 21:59:59", "2026-09-10 22:00:00"))
  expect_equal(derive_local_date(x, "Europe/Vienna"), as.Date(c("2026-09-10", "2026-09-11")))
})

test_that("derive_local_date() rolls over to the next day in winter (UTC+1)", {
  x <- utc(c("2026-01-10 22:30:00", "2026-01-10 23:00:00"))
  expect_equal(derive_local_date(x, "Europe/Vienna"), as.Date(c("2026-01-10", "2026-01-11")))
})

test_that("derive_local_date() is correct across the DST transitions", {
  # Spring forward on 2026-03-29 at 01:00 UTC, fall back on 2026-10-25 at 01:00 UTC.
  x <- utc(c(
    "2026-03-28 22:59:59", "2026-03-28 23:00:00", # CET: 23:59:59 / 00:00 local
    "2026-10-24 21:59:59", "2026-10-24 22:00:00" # CEST: 23:59:59 / 00:00 local
  ))
  expect_equal(
    derive_local_date(x, "Europe/Vienna"),
    as.Date(c("2026-03-28", "2026-03-29", "2026-10-24", "2026-10-25"))
  )
})

test_that("derive_local_date() keeps GeoSphere 00:00 UTC day stamps on the same date", {
  x <- parse_utc_timestamp(c("2026-01-15T00:00+00:00", "2026-07-15T00:00+00:00"))
  expect_equal(derive_local_date(x, "Europe/Vienna"), as.Date(c("2026-01-15", "2026-07-15")))
})

test_that("derive_local_date() validates its inputs", {
  expect_error(derive_local_date("2026-09-10", "Europe/Vienna"), class = "wxpipe_error_parse")
  expect_error(
    derive_local_date(utc("2026-09-10"), "Mars/Olympus_Mons"),
    class = "wxpipe_error_parse"
  )
})
