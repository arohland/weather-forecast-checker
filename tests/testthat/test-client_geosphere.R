# Request construction ----------------------------------------------------------

test_that("geosphere_request() builds the documented endpoint and query", {
  source_config <- read_sources_config()$sources$geosphere
  req <- wxpipe:::geosphere_request(
    source_config, 6300L, c("tlmax", "rr"),
    as.Date("2026-09-01"), as.Date("2026-09-13")
  )
  expect_identical(
    req$url,
    paste0(
      "https://dataset.api.hub.geosphere.at/v1/station/historical/klima-v2-1d",
      "?parameters=tlmax&parameters=tlmax_flag&parameters=rr&parameters=rr_flag",
      "&station_ids=6300&start=2026-09-01&end=2026-09-13&output_format=geojson"
    )
  )
})

test_that("fetch_geosphere_station() validates station ids before any request", {
  source_config <- read_sources_config()$sources$geosphere
  day <- as.Date("2026-09-13")
  httr2::local_mocked_responses(function(req) stop("no request expected"))
  for (bad_ids in list("6300", c(6300, 6300), 63.5, numeric())) {
    expect_error(
      fetch_geosphere_station(source_config, bad_ids, day, day),
      class = "wxpipe_error_input"
    )
  }
})

# Recorded responses ------------------------------------------------------------
# Recorded from the live API on 2026-09-14 (see helper-fixtures.R).

test_that("a recent daily window is fetched and parsed from recorded responses", {
  source_config <- read_sources_config()$sources$geosphere
  with_fixtures("fixtures/geosphere-recent", {
    records <- fetch_geosphere_station(
      source_config,
      station_ids = 6300L,
      start_date = as.Date("2026-08-31"),
      end_date = as.Date("2026-09-14")
    )
  })

  expect_length(records, 1L)
  expect_identical(records[[1]]$status, 200L)
  obs <- parse_geosphere_station(records[[1]]$body, source_config$parameters)

  expect_identical(nrow(obs), 10L * 15L)
  expect_setequal(unique(obs$parameter), source_config$parameters)
  expect_identical(unique(obs$station_id), 6300L)
  expect_identical(unique(obs$unit[obs$parameter == "tlmax"]), "°C")
  expect_identical(unique(obs$unit[obs$parameter == "rr"]), "mm")

  at <- function(parameter, date) {
    obs$value[obs$parameter == parameter & obs$reference_time == as.POSIXct(date, tz = "UTC")]
  }
  expect_equal(at("tlmax", "2026-09-08"), 33.5)
  expect_equal(at("rr", "2026-09-09"), 11.2)
  # Documented sentinel: -1 means "no precipitation"; kept as delivered.
  expect_equal(at("rr", "2026-09-11"), -1)
  # The current day is not published yet: its rows exist with NA values.
  today <- obs[obs$reference_time == as.POSIXct("2026-09-14", tz = "UTC"), ]
  expect_identical(nrow(today), 10L)
  expect_true(all(is.na(today$value)))
})

test_that("a winter window with snow parameters parses from recorded responses", {
  source_config <- read_sources_config()$sources$geosphere
  with_fixtures("fixtures/geosphere-winter", {
    records <- fetch_geosphere_station(
      source_config,
      station_ids = 6300L,
      start_date = as.Date("2026-01-19"),
      end_date = as.Date("2026-01-25")
    )
  })
  obs <- parse_geosphere_station(records[[1]]$body, source_config$parameters)

  expect_identical(nrow(obs), 10L * 7L)
  snow <- obs[obs$parameter == "sh", ]
  expect_identical(unique(snow$unit), "cm")
  # Snow depth is either a depth in cm or the documented -1 "no snow" sentinel.
  expect_true(all(snow$value >= -1, na.rm = TRUE))
})

test_that("a range above the size limit is fetched in contiguous chunks", {
  source_config <- read_sources_config()$sources$geosphere
  # Shrink the limit so a two-week range needs two requests:
  # 20 series (10 parameters + flags) x 7 days = 140 values per request.
  source_config$limits$max_values_per_request <- 140L

  with_fixtures("fixtures/geosphere-chunked", {
    records <- fetch_geosphere_station(
      source_config,
      station_ids = 6300L,
      start_date = as.Date("2026-08-31"),
      end_date = as.Date("2026-09-13")
    )
  })

  expect_length(records, 2L)
  expect_match(records[[1]]$url, "start=2026-08-31&end=2026-09-06", fixed = TRUE)
  expect_match(records[[2]]$url, "start=2026-09-07&end=2026-09-13", fixed = TRUE)

  obs <- do.call(rbind, lapply(records, function(r) {
    parse_geosphere_station(r$body, source_config$parameters)
  }))
  expect_identical(nrow(obs), 10L * 14L)
  expect_false(anyDuplicated(obs[c("parameter", "reference_time")]) > 0L)
})

# Chunk planning -----------------------------------------------------------------

test_that("a request exactly at the GeoSphere limit is one chunk", {
  # Mirrors the live probe: 20 series x 50,000 days = 1,000,000 values -> 200.
  chunks <- plan_geosphere_chunks(
    as.Date("1860-01-01"), as.Date("1996-11-22"),
    n_series = 20, max_values = 1e6
  )
  expect_identical(nrow(chunks), 1L)
  expect_equal(
    wxpipe:::geosphere_request_size(chunks$start_date, chunks$end_date, n_series = 20),
    1e6
  )
})

test_that("one day over the limit splits into two chunks", {
  # Mirrors the live probe: 20 series x 50,001 days = 1,000,020 values -> 400.
  chunks <- plan_geosphere_chunks(
    as.Date("1860-01-01"), as.Date("1996-11-23"),
    n_series = 20, max_values = 1e6
  )
  expect_identical(nrow(chunks), 2L)
  expect_identical(chunks$end_date[1], as.Date("1996-11-22"))
  expect_identical(chunks$start_date[2], as.Date("1996-11-23"))
  expect_identical(chunks$end_date[2], as.Date("1996-11-23"))
})

test_that("chunks are contiguous, cover the range exactly and respect the limit", {
  start <- as.Date("1939-03-01")
  end <- as.Date("2026-09-13")
  chunks <- plan_geosphere_chunks(start, end, n_series = 20, n_stations = 3, max_values = 1e6)

  expect_gt(nrow(chunks), 1L)
  expect_identical(chunks$start_date[1], start)
  expect_identical(chunks$end_date[nrow(chunks)], end)
  expect_identical(chunks$start_date[-1], chunks$end_date[-nrow(chunks)] + 1)
  sizes <- wxpipe:::geosphere_request_size(chunks$start_date, chunks$end_date, 20, 3)
  expect_true(all(sizes <= 1e6))
  expect_equal(
    sum(as.numeric(chunks$end_date - chunks$start_date) + 1),
    as.numeric(end - start) + 1
  )
})

test_that("a single-day request is one chunk", {
  day <- as.Date("2026-09-13")
  chunks <- plan_geosphere_chunks(day, day, n_series = 20, max_values = 1e6)
  expect_identical(chunks, data.frame(start_date = day, end_date = day))
})

test_that("plan_geosphere_chunks() rejects invalid input", {
  day <- as.Date("2026-09-13")
  plan <- function(start = day, end = day, n_series = 20, max_values = 1e6) {
    plan_geosphere_chunks(start, end, n_series = n_series, max_values = max_values)
  }
  expect_error(plan(start = day + 1), class = "wxpipe_error_input")
  expect_error(plan(start = "2026-09-13"), class = "wxpipe_error_input")
  expect_error(plan(end = as.Date(NA)), class = "wxpipe_error_input")
  expect_error(plan(n_series = 0), class = "wxpipe_error_input")
  expect_error(plan(n_series = 2.5), class = "wxpipe_error_input")
  expect_error(plan(max_values = 10), class = "wxpipe_error_input")
})
