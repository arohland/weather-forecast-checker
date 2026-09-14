# Retry, backoff and error handling are exercised against a real local HTTP
# server (webfakes, bound to 127.0.0.1 only). httr2's built-in response
# mocking returns before req_perform()'s retry loop, so mocks cannot show
# that a request is actually retried.

fake_api <- function(station_response) {
  # Evaluate now: the app runs in a separate R process where test helpers
  # such as geosphere_body() do not exist.
  force(station_response)
  app <- webfakes::new_app()

  # Count calls per path so tests can assert how often the client tried.
  app$use(function(req, res) {
    calls <- req$app$locals$calls %||% list()
    calls[[req$path]] <- (calls[[req$path]] %||% 0L) + 1L
    req$app$locals$calls <- calls
    "next"
  })
  n_calls <- function(req) req$app$locals$calls[[req$path]]
  ok <- function(res) res$send_json(list(ok = TRUE), auto_unbox = TRUE)

  app$get("/flaky", function(req, res) {
    if (n_calls(req) < 3L) res$set_status(503L)$send("temporarily unavailable") else ok(res)
  })
  app$get("/rate-limited", function(req, res) {
    if (n_calls(req) > 1L) {
      return(ok(res))
    }
    res$set_status(429L)$set_header("Retry-After", "0")$send("slow down")
  })
  app$get("/rate-limited-no-hint", function(req, res) {
    if (n_calls(req) > 1L) ok(res) else res$set_status(429L)$send("slow down")
  })
  app$get("/down", function(req, res) {
    res$set_status(503L)$send("down")
  })
  app$get("/too-large", function(req, res) {
    # Body observed from GeoSphere on 2026-09-14 for an oversized request.
    detail <- paste(
      "The data slice you requested is too large.",
      "The limit is 1000000 data points. You requested 1838640."
    )
    res$set_status(400L)$send_json(list(detail = detail), auto_unbox = TRUE)
  })
  app$get("/forbidden", function(req, res) {
    detail <- "Violation for station_ids: '999999' not available or access denied"
    res$set_status(403L)$send_json(list(detail = detail), auto_unbox = TRUE)
  })
  app$get("/station/historical/klima-v2-1d", function(req, res) {
    if (n_calls(req) == 1L) {
      return(res$set_status(503L)$send("warming up"))
    }
    res$set_type("application/json")$send(station_response)
  })
  app$get("/calls", function(req, res) {
    res$send_json(req$app$locals$calls, auto_unbox = TRUE)
  })
  app
}

api <- webfakes::local_app_process(fake_api(geosphere_body()))

calls_to <- function(path) {
  calls <- httr2::request(api$url("/calls")) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  calls[[path]] %||% 0L
}

# Retries without sleeping: tests must be fast and deterministic.
policy_request <- function(path, max_tries = 3L, backoff = function(attempt) 0) {
  httr2::request(api$url(path)) |>
    wxpipe:::req_wxpipe_policies(
      realm = "wxpipe-tests", capacity = 1000, fill_time_s = 1,
      max_tries = max_tries, backoff = backoff
    )
}

# Retry and backoff behaviour --------------------------------------------------

test_that("transient server errors are retried until the request succeeds", {
  resp <- wxpipe:::perform_request(policy_request("/flaky", max_tries = 5L), "Test API")
  expect_identical(httr2::resp_status(resp), 200L)
  expect_identical(calls_to("/flaky"), 3L)
})

test_that("HTTP 429 is retried and its Retry-After wait is used instead of backoff", {
  backoff_must_not_run <- function(attempt) stop("backoff used despite Retry-After")
  req <- policy_request("/rate-limited", backoff = backoff_must_not_run)

  resp <- wxpipe:::perform_request(req, "Test API")
  expect_identical(httr2::resp_status(resp), 200L)
  expect_identical(calls_to("/rate-limited"), 2L)
})

test_that("HTTP 429 without a wait hint falls back to backoff", {
  backoff_calls <- 0L
  counting_backoff <- function(attempt) {
    backoff_calls <<- backoff_calls + 1L
    0
  }
  req <- policy_request("/rate-limited-no-hint", backoff = counting_backoff)

  resp <- wxpipe:::perform_request(req, "Test API")
  expect_identical(httr2::resp_status(resp), 200L)
  expect_identical(backoff_calls, 1L)
})

test_that("retries stop after max_tries with a classed error", {
  err <- expect_error(
    wxpipe:::perform_request(policy_request("/down", max_tries = 3L), "Test API"),
    class = "wxpipe_error_http"
  )
  expect_s3_class(err$parent, "httr2_http_503")
  expect_identical(calls_to("/down"), 3L)
})

test_that("400 is not retried and carries the API's explanation", {
  err <- expect_error(
    wxpipe:::perform_request(policy_request("/too-large"), "GeoSphere"),
    class = "wxpipe_error_http"
  )
  expect_identical(calls_to("/too-large"), 1L)
  expect_s3_class(err$parent, "httr2_http_400")
  expect_match(conditionMessage(err$parent), "too large")
})

test_that("403 (unknown station or parameter) is not retried", {
  expect_error(
    wxpipe:::perform_request(policy_request("/forbidden"), "GeoSphere"),
    class = "wxpipe_error_http"
  )
  expect_identical(calls_to("/forbidden"), 1L)
})

test_that("the GeoSphere client retries a transient failure end to end", {
  source_config <- read_sources_config()$sources$geosphere
  source_config$base_url <- sub("/$", "", api$url())
  day <- as.Date("2026-09-08")

  records <- fetch_geosphere_station(
    source_config, 6300L, day, day + 1,
    parameters = "rr", backoff = function(attempt) 0
  )

  expect_identical(calls_to("/station/historical/klima-v2-1d"), 2L)
  expect_length(records, 1L)
  expect_identical(records[[1]]$status, 200L)
  expect_identical(nrow(parse_geosphere_station(records[[1]]$body, "rr")), 2L)
})

# Pure helpers -----------------------------------------------------------------

fake_response <- function(status, headers = list(), body = "") {
  httr2::response(status_code = status, headers = headers, body = charToRaw(body))
}

test_that("retry_after() reads wait hints in seconds", {
  retry_after <- wxpipe:::retry_after
  expect_identical(retry_after(fake_response(429, list("Retry-After" = "7"))), 7)
  expect_identical(retry_after(fake_response(503, list("Retry-After" = "3"))), 3)
  expect_identical(retry_after(fake_response(429, list("RateLimit-Reset" = "12"))), 12)
  # RateLimit-Reset is sent on every GeoSphere response; only 429 makes it a wait.
  expect_identical(retry_after(fake_response(503, list("RateLimit-Reset" = "12"))), NA_real_)
  expect_identical(retry_after(fake_response(429)), NA_real_)
  http_date <- list("Retry-After" = "Wed, 21 Oct 2026 07:28:00 GMT")
  expect_identical(retry_after(fake_response(429, http_date)), NA_real_)
})

test_that("default_backoff() grows exponentially, is capped and jittered", {
  default_backoff <- wxpipe:::default_backoff
  expect_gte(default_backoff(1), 2)
  expect_lt(default_backoff(1), 3)
  expect_gte(default_backoff(3), 8)
  expect_lt(default_backoff(3), 9)
  expect_gte(default_backoff(20), 60)
  expect_lt(default_backoff(20), 61)
})

test_that("api_error_detail() extracts GeoSphere and Open-Meteo messages", {
  detail <- function(status, body) wxpipe:::api_error_detail(fake_response(status, body = body))
  expect_match(detail(400, '{"detail":"End date before start date"}'), "End date")
  expect_match(detail(400, '{"error":true,"reason":"Invalid model"}'), "Invalid model")
  expect_match(detail(502, "<html>Bad gateway</html>"), "Bad gateway")
  expect_identical(detail(500, ""), character())
})

test_that("requests identify the pipeline in the User-Agent", {
  req <- policy_request("/flaky")
  expect_match(req$options$useragent, "^wxpipe/[0-9.]+ \\(\\+https://github.com/")
})
