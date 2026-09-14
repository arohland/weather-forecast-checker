#' Parse an Open-Meteo hourly response into long-format forecast rows
#'
#' Pure function: JSON text in, data frame out, no I/O. Works for all three
#' Open-Meteo APIs used by the pipeline, which share a response shape. It
#' produces one row per variable, valid hour and (for Previous Runs) lead-time
#' offset.
#'
#' A forecast is a statement made *at* a time *about* a time, and the columns
#' only claim what the source actually says:
#' * `issued_at` is the model initialisation time. Only the Single Runs API
#'   reports it; for the other sources it is `NA`, never guessed.
#' * `lead_time_days` is the Previous Runs offset N: the value predicted
#'   N x 24 hours before `valid_time`. It is `NA` for the other sources.
#' * `lead_time_hours` is the exact number of hours between `issued_at` and
#'   `valid_time`, so it is only set for Single Runs.
#'
#' The parser requires the response to be in UTC with Unix timestamps (the
#' clients request `timezone=GMT&timeformat=unixtime`). It fails loudly on
#' any other time format, on missing or unrequested variables, on series that
#' do not line up with the timestamps, and on non-numeric values. JSON `null`
#' becomes `NA`; rows are never dropped.
#'
#' @param body The response body as a single JSON string.
#' @param variables The hourly variables that were requested, as base names
#'   (e.g. `"temperature_2m"`, not `"temperature_2m_previous_day1"`).
#' @param forecast_source One of `"forecast"`, `"previous_runs"` or
#'   `"single_runs"`.
#' @param model The model id that was requested.
#' @param issued_at For `"single_runs"`, the run's initialisation time as a
#'   single `POSIXct`; otherwise `NULL`.
#' @param lead_days For `"previous_runs"`, the requested lead-time offsets in
#'   days; otherwise `NULL`.
#'
#' @return A data frame with columns `forecast_source`, `model`, `issued_at`
#'   (POSIXct, UTC), `valid_time` (POSIXct, UTC), `lead_time_days` (integer),
#'   `lead_time_hours` (integer), `variable`, `value` (double) and `unit`.
#' @export
parse_openmeteo_hourly <- function(body, variables, forecast_source, model,
                                   issued_at = NULL, lead_days = NULL) {
  check_openmeteo_parse_args(body, variables, forecast_source, model, issued_at, lead_days)

  parsed <- tryCatch(
    jsonlite::parse_json(body, simplifyVector = FALSE),
    error = function(e) {
      cli::cli_abort(
        "Open-Meteo response body is not valid JSON.",
        parent = e,
        class = "wxpipe_error_parse",
        call = NULL
      )
    }
  )
  if (!is.list(parsed) || !is.list(parsed$hourly) || !is.list(parsed$hourly_units)) {
    cli::cli_abort(
      "Open-Meteo response has no {.field hourly} and {.field hourly_units} objects.",
      class = "wxpipe_error_parse"
    )
  }
  if (!isTRUE(parsed$utc_offset_seconds == 0)) {
    cli::cli_abort(
      "Open-Meteo response is not in UTC (utc_offset_seconds = {parsed$utc_offset_seconds}).",
      class = "wxpipe_error_parse"
    )
  }
  if (!identical(parsed$hourly_units$time, "unixtime")) {
    cli::cli_abort(
      "Open-Meteo response times are not Unix timestamps.",
      class = "wxpipe_error_parse"
    )
  }

  hourly <- parsed$hourly
  valid_time <- parse_unix_times(hourly$time)
  n <- length(valid_time)

  spec <- openmeteo_column_spec(variables, forecast_source, lead_days)
  present <- setdiff(names(hourly), "time")
  missing <- setdiff(spec$column, present)
  unexpected <- setdiff(present, spec$column)
  if (length(missing) > 0L) {
    cli::cli_abort(
      "Open-Meteo response is missing variable{?s} {.val {missing}}.",
      class = "wxpipe_error_parse"
    )
  }
  if (length(unexpected) > 0L) {
    cli::cli_abort(
      "Open-Meteo response has unrequested variable{?s} {.val {unexpected}}.",
      class = "wxpipe_error_parse"
    )
  }

  issued <- if (is.null(issued_at)) .POSIXct(NA_real_, tz = "UTC") else issued_at
  lead_hours <- if (is.null(issued_at)) {
    rep(NA_integer_, n)
  } else {
    as.integer(round(as.numeric(difftime(valid_time, issued_at, units = "hours"))))
  }

  rows <- lapply(seq_len(nrow(spec)), function(i) {
    column <- spec$column[i]
    unit <- parsed$hourly_units[[column]]
    if (!rlang::is_string(unit)) {
      cli::cli_abort(
        "Open-Meteo variable {.field {column}} has no unit.",
        class = "wxpipe_error_parse"
      )
    }
    data.frame(
      forecast_source = rep(forecast_source, n),
      model = rep(model, n),
      issued_at = rep(issued, n),
      valid_time = valid_time,
      lead_time_days = rep(spec$lead_time_days[i], n),
      lead_time_hours = lead_hours,
      variable = rep(spec$variable[i], n),
      value = json_number_series(hourly[[column]], column, n),
      unit = rep(unit, n)
    )
  })
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

# Response column names: plain variable names, or for Previous Runs every
# variable x offset as "<variable>_previous_day<N>".
previous_runs_columns <- function(variables, lead_days) {
  paste0(
    rep(variables, each = length(lead_days)),
    "_previous_day",
    rep(lead_days, times = length(variables))
  )
}

openmeteo_column_spec <- function(variables, forecast_source, lead_days) {
  if (forecast_source == "previous_runs") {
    return(data.frame(
      column = previous_runs_columns(variables, lead_days),
      variable = rep(variables, each = length(lead_days)),
      lead_time_days = rep(as.integer(lead_days), times = length(variables))
    ))
  }
  data.frame(column = variables, variable = variables, lead_time_days = NA_integer_)
}

parse_unix_times <- function(times) {
  is_whole <- vapply(times, is_whole_number, logical(1))
  if (!is.list(times) || !all(is_whole)) {
    cli::cli_abort(
      "Open-Meteo {.field hourly.time} must be an array of whole Unix timestamps.",
      class = "wxpipe_error_parse"
    )
  }
  valid_time <- .POSIXct(as.numeric(unlist(times)), tz = "UTC")
  if (anyDuplicated(valid_time)) {
    cli::cli_abort(
      "Open-Meteo response contains duplicate timestamps.",
      class = "wxpipe_error_parse"
    )
  }
  valid_time
}

check_openmeteo_parse_args <- function(body, variables, forecast_source, model,
                                       issued_at, lead_days, call = rlang::caller_env()) {
  abort_arg <- function(message) {
    cli::cli_abort(message, class = "wxpipe_error_parse", call = call, .envir = parent.frame())
  }
  sources <- c("forecast", "previous_runs", "single_runs")
  if (!rlang::is_string(body)) {
    abort_arg("{.arg body} must be a single string.")
  }
  if (!is_unique_names(variables)) {
    abort_arg("{.arg variables} must be unique names.")
  }
  if (!rlang::is_string(forecast_source) || !forecast_source %in% sources) {
    abort_arg("{.arg forecast_source} must be one of {.val {sources}}.")
  }
  if (!rlang::is_string(model)) {
    abort_arg("{.arg model} must be a single string.")
  }

  is_single_time <- inherits(issued_at, "POSIXct") && length(issued_at) == 1L
  if (forecast_source == "single_runs" && (!is_single_time || anyNA(issued_at))) {
    abort_arg("Single runs need {.arg issued_at} as one non-missing POSIXct.")
  }
  if (forecast_source != "single_runs" && !is.null(issued_at)) {
    abort_arg("Only single runs have a known {.arg issued_at}; use NULL.")
  }

  leads_are_whole <- is.numeric(lead_days) && all(vapply(lead_days, is_whole_number, logical(1)))
  valid_leads <- leads_are_whole && length(lead_days) > 0L && !anyDuplicated(lead_days)
  valid_leads <- valid_leads && all(lead_days >= 1)
  if (forecast_source == "previous_runs" && !valid_leads) {
    abort_arg("Previous runs need {.arg lead_days} as unique whole numbers >= 1.")
  }
  if (forecast_source != "previous_runs" && !is.null(lead_days)) {
    abort_arg("Only previous runs have {.arg lead_days}; use NULL.")
  }
  invisible(TRUE)
}
