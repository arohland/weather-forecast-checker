#' Parse ISO 8601 timestamps with an explicit UTC offset
#'
#' All timestamps are stored as UTC. This parser therefore accepts only
#' timestamps that carry an explicit offset (`Z`, `+00:00`, `+0200`, ...):
#' a timestamp without one is ambiguous, and guessing its zone is exactly
#' the kind of silent coercion the pipeline must not do.
#'
#' Accepted shapes are `YYYY-MM-DDTHH:MM[:SS]` followed by `Z`, `+HH:MM` or
#' `+HHMM`, which covers what the GeoSphere API returns
#' (e.g. `"2026-09-10T00:00+00:00"`).
#'
#' @param x Character vector of timestamps.
#'
#' @return A `POSIXct` vector in UTC, the same length as `x`.
#' @export
#' @examples
#' parse_utc_timestamp(c("2026-09-10T00:00+00:00", "2026-09-10T02:00+02:00"))
parse_utc_timestamp <- function(x) {
  if (!is.character(x)) {
    cli::cli_abort(
      "{.arg x} must be a character vector, not {.obj_type_friendly {x}}.",
      class = "wxpipe_error_parse"
    )
  }
  pattern <- "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(:\\d{2})?(Z|[+-]\\d{2}:?\\d{2})$"
  bad <- is.na(x) | !grepl(pattern, x, perl = TRUE)
  if (any(bad)) {
    cli::cli_abort(
      c(
        "Timestamps must be ISO 8601 with an explicit UTC offset.",
        "x" = "Invalid value{?s}: {.val {utils::head(x[bad], 3)}}."
      ),
      class = "wxpipe_error_parse"
    )
  }

  # Normalise to "YYYY-MM-DDTHH:MM:SS+HHMM", the form strptime's %z reads.
  normalised <- sub("Z$", "+0000", x)
  normalised <- sub("([+-]\\d{2}):(\\d{2})$", "\\1\\2", normalised, perl = TRUE)
  no_seconds <- grepl("T\\d{2}:\\d{2}[+-]", normalised, perl = TRUE)
  normalised[no_seconds] <- sub("(T\\d{2}:\\d{2})", "\\1:00", normalised[no_seconds], perl = TRUE)

  parsed <- as.POSIXct(normalised, format = "%Y-%m-%dT%H:%M:%S%z", tz = "UTC")
  if (anyNA(parsed)) {
    cli::cli_abort(
      c(
        "Timestamps matched the expected shape but are not valid date-times.",
        "x" = "Invalid value{?s}: {.val {utils::head(x[is.na(parsed)], 3)}}."
      ),
      class = "wxpipe_error_parse"
    )
  }
  parsed
}

#' Derive the local calendar date of UTC instants
#'
#' Storage is UTC, but people (and most analysis) think in local days. This
#' converts each instant to the wall-clock date in `tz`, correctly across
#' daylight-saving transitions.
#'
#' @param x A `POSIXct` vector.
#' @param tz An IANA time zone name, e.g. `"Europe/Vienna"`.
#'
#' @return A `Date` vector the same length as `x`.
#' @export
#' @examples
#' derive_local_date(as.POSIXct("2026-09-10 22:30", tz = "UTC"), "Europe/Vienna")
derive_local_date <- function(x, tz) {
  if (!inherits(x, "POSIXct")) {
    cli::cli_abort(
      "{.arg x} must be a POSIXct vector, not {.obj_type_friendly {x}}.",
      class = "wxpipe_error_parse"
    )
  }
  if (!rlang::is_string(tz) || !tz %in% OlsonNames()) {
    cli::cli_abort(
      "{.arg tz} must be an IANA time zone name, not {.val {tz}}.",
      class = "wxpipe_error_parse"
    )
  }
  as.Date(x, tz = tz)
}
