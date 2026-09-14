# Small helpers shared across modules. Named checks keep multi-part
# conditions readable and on one line.

is_whole_number <- function(x) {
  is.numeric(x) && length(x) == 1L && is.finite(x) && x == round(x)
}

is_unique_names <- function(x) {
  is.character(x) && length(x) > 0L && !anyNA(x) && !anyDuplicated(x)
}

check_single_date <- function(x, arg, call = rlang::caller_env()) {
  if (!inherits(x, "Date") || length(x) != 1L || is.na(x)) {
    cli::cli_abort(
      "{.arg {arg}} must be a single non-missing Date, not {.obj_type_friendly {x}}.",
      class = "wxpipe_error_input",
      call = call
    )
  }
  invisible(x)
}

check_date_range <- function(start_date, end_date, call = rlang::caller_env()) {
  check_single_date(start_date, "start_date", call = call)
  check_single_date(end_date, "end_date", call = call)
  if (start_date > end_date) {
    cli::cli_abort(
      "{.arg start_date} ({start_date}) must not be after {.arg end_date} ({end_date}).",
      class = "wxpipe_error_input",
      call = call
    )
  }
  invisible(TRUE)
}

# Splits an inclusive date range into consecutive, non-overlapping inclusive
# chunks of at most `days_per_chunk` days.
split_date_range <- function(start_date, end_date, days_per_chunk) {
  starts <- seq(start_date, end_date, by = days_per_chunk)
  ends <- pmin(starts + (days_per_chunk - 1), end_date)
  data.frame(start_date = starts, end_date = ends)
}

# Converts a JSON array (parsed with simplifyVector = FALSE) of numbers and
# nulls into a double vector, failing on anything else instead of coercing.
json_number_series <- function(data, name, n) {
  if (!is.list(data) || length(data) != n) {
    cli::cli_abort(
      c(
        "Series {.field {name}} does not line up with the timestamps.",
        "x" = "It has {length(data)} value{?s}; there are {n} timestamp{?s}."
      ),
      class = "wxpipe_error_parse",
      call = NULL
    )
  }
  ok <- vapply(data, function(v) is.null(v) || (is.numeric(v) && length(v) == 1L), logical(1))
  if (!all(ok)) {
    cli::cli_abort(
      c(
        "Series {.field {name}} has a non-numeric value.",
        "x" = "First offending position: {which(!ok)[1]}."
      ),
      class = "wxpipe_error_parse",
      call = NULL
    )
  }
  vapply(data, function(v) if (is.null(v)) NA_real_ else as.double(v), double(1))
}
