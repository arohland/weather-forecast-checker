# Shared HTTP plumbing for every API client: identification, rate limiting,
# retries with backoff, and errors that say what went wrong. A client builds
# a plain httr2 request, passes it through req_wxpipe_policies() and performs
# it with perform_request().

wxpipe_user_agent <- function() {
  paste0(
    "wxpipe/", utils::packageVersion("wxpipe"),
    " (+https://github.com/arohland/weather-forecast-checker)"
  )
}

#' Apply rate limiting, retries and error reporting to a request
#'
#' Throttling uses a token bucket per `realm` inside this R process. That is
#' sufficient because a Cloud Run Job execution is a single process running
#' requests sequentially; it would not coordinate parallel executions.
#'
#' @param req An httr2 request.
#' @param realm Throttle pool name, one per API.
#' @param capacity,fill_time_s Numeric vectors of equal length: allow
#'   `capacity[i]` requests per `fill_time_s[i]` seconds, all limits at once
#'   (e.g. `c(5, 240)` per `c(1, 3600)` for 5/s and 240/h).
#' @param max_tries Total attempts, including the first.
#' @param backoff Function of the attempt number returning seconds to wait,
#'   used when the response carries no usable wait hint. Injectable so tests
#'   do not sleep.
#' @param timeout_s Per-attempt timeout in seconds.
#' @noRd
req_wxpipe_policies <- function(req, realm, capacity, fill_time_s,
                                max_tries = 5L, backoff = default_backoff,
                                timeout_s = 120) {
  req |>
    httr2::req_user_agent(wxpipe_user_agent()) |>
    httr2::req_timeout(timeout_s) |>
    httr2::req_throttle(capacity = capacity, fill_time_s = fill_time_s, realm = realm) |>
    httr2::req_retry(
      max_tries = max_tries,
      retry_on_failure = TRUE,
      is_transient = is_transient_response,
      backoff = backoff,
      after = retry_after
    ) |>
    httr2::req_error(body = api_error_detail)
}

# 408 and 5xx gateway/availability errors are usually momentary; 429 means
# "slow down", which the retry wait handles. Every other 4xx is a bug in our
# request (bad parameter, too large, unknown station) and retrying it would
# only burn rate-limit quota.
is_transient_response <- function(resp) {
  httr2::resp_status(resp) %in% c(408L, 429L, 500L, 502L, 503L, 504L)
}

# How long the server asked us to wait, in seconds, or NA to fall back to
# exponential backoff.
# * `Retry-After` (RFC 9110) is honoured on any transient response when given
#   in seconds. The HTTP-date form is rare for APIs and falls back to backoff.
# * `RateLimit-Reset` is documented by GeoSphere as "seconds until the rate
#   limit is reset". It is sent on every response, so it is only meaningful
#   when we were actually rate limited (429).
retry_after <- function(resp) {
  seconds <- function(header) {
    value <- httr2::resp_header(resp, header)
    if (is.null(value) || !grepl("^\\s*[0-9]+(\\.[0-9]+)?\\s*$", value)) {
      return(NA_real_)
    }
    as.numeric(value)
  }
  wait <- seconds("Retry-After")
  if (is.na(wait) && httr2::resp_status(resp) == 429L) {
    wait <- seconds("RateLimit-Reset")
  }
  wait
}

# Exponential backoff (2, 4, 8, ... seconds) capped at one minute, plus up to a
# second of random jitter so that retries from separate runs do not align.
default_backoff <- function(attempt) {
  min(60, 2^attempt) + stats::runif(1)
}

# Surface the API's own explanation in the R error. GeoSphere returns
# {"detail": "..."}; Open-Meteo returns {"error": true, "reason": "..."}.
api_error_detail <- function(resp) {
  body <- tryCatch(httr2::resp_body_string(resp, encoding = "UTF-8"), error = function(e) "")
  parsed <- tryCatch(jsonlite::parse_json(body), error = function(e) NULL)
  detail <- if (is.list(parsed)) parsed$detail %||% parsed$reason
  if (rlang::is_string(detail)) {
    return(paste("API response:", detail))
  }
  if (nzchar(body)) {
    return(paste("Response body (truncated):", substr(body, 1L, 300L)))
  }
  character()
}

# Performs a request and converts any httr2 failure into a classed wxpipe
# error that names the API, keeping the original error as the parent.
perform_request <- function(req, api_name) {
  withCallingHandlers(
    httr2::req_perform(req),
    httr2_error = function(cnd) {
      cli::cli_abort(
        c("Request to {api_name} failed.", "i" = "URL: {.url {req$url}}"),
        parent = cnd,
        class = "wxpipe_error_http",
        call = NULL
      )
    }
  )
}

# The unit handed on to raw landing and parsing: exactly what came back,
# plus when and where it was fetched from.
response_record <- function(resp, api_name) {
  body_raw <- httr2::resp_body_raw(resp)
  body <- rawToChar(body_raw)
  Encoding(body) <- "UTF-8"
  if (!validUTF8(body)) {
    cli::cli_abort(
      "Response from {api_name} is not valid UTF-8.",
      class = "wxpipe_error_http"
    )
  }
  list(
    api = api_name,
    url = httr2::resp_url(resp),
    status = httr2::resp_status(resp),
    fetched_at = structure(Sys.time(), tzone = "UTC"),
    body_raw = body_raw,
    body = body
  )
}
