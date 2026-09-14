# Structured logging ------------------------------------------------------------------
#
# Cloud Run forwards every line a container writes to stdout or stderr to Cloud
# Logging. A line that is a single JSON object becomes a structured entry
# (jsonPayload), and these special fields are interpreted
# (https://cloud.google.com/logging/docs/structured-logging, read 2026-09-14):
#
#   - "severity" sets the entry's severity;
#   - "message" is the line shown in the Logs Explorer;
#   - "time" sets the entry's timestamp;
#   - "logging.googleapis.com/labels" sets its labels (string values);
#   - "logging.googleapis.com/operation" groups all entries of one run.
#
# Everything else stays queryable as jsonPayload.<field>.

log_severities <- c("DEBUG", "INFO", "NOTICE", "WARNING", "ERROR", "CRITICAL")

# Labels and operation shared by every entry of a run (set by run_cli()).
log_state <- new.env(parent = emptyenv())

#' Format one structured log entry
#'
#' Pure function producing a single line of JSON in the shape Cloud Logging
#' understands.
#'
#' @param severity One of `DEBUG`, `INFO`, `NOTICE`, `WARNING`, `ERROR`,
#'   `CRITICAL`.
#' @param message The human-readable message.
#' @param fields A named list of additional fields. Dates and date-times are
#'   written as ISO 8601 strings (UTC).
#' @param labels A named list of single values, stored as string labels.
#' @param operation_id Optional id grouping entries of one run.
#' @param time Time of the event.
#'
#' @return A single string without line breaks.
#' @export
#' @examples
#' format_log_entry("INFO", "Loaded rows", fields = list(rows = 140L))
format_log_entry <- function(severity, message, fields = list(), labels = list(),
                             operation_id = NULL, time = Sys.time()) {
  if (!rlang::is_string(severity) || !severity %in% log_severities) {
    cli::cli_abort(
      "{.arg severity} must be one of {.val {log_severities}}.",
      class = "wxpipe_error_input"
    )
  }
  if (!rlang::is_string(message)) {
    cli::cli_abort("{.arg message} must be a single string.", class = "wxpipe_error_input")
  }
  named_fields <- length(fields) == 0L || (is.list(fields) && !is.null(names(fields)))
  reserved <- intersect(names(fields), c("severity", "message", "time"))
  if (!named_fields || length(reserved) > 0L) {
    cli::cli_abort(
      "{.arg fields} must be a named list without severity, message or time.",
      class = "wxpipe_error_input"
    )
  }
  label_values <- vapply(labels, function(value) {
    if (rlang::is_scalar_atomic(value) && !is.na(value)) as.character(value) else NA_character_
  }, character(1))
  if (anyNA(label_values)) {
    cli::cli_abort(
      "{.arg labels} must be single, non-missing values.",
      class = "wxpipe_error_input"
    )
  }

  entry <- c(
    list(
      severity = severity,
      message = message,
      time = format(time, "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
    ),
    lapply(fields, json_friendly)
  )
  if (length(labels) > 0L) {
    entry[["logging.googleapis.com/labels"]] <- as.list(label_values)
  }
  if (!is.null(operation_id)) {
    entry[["logging.googleapis.com/operation"]] <- list(id = operation_id, producer = "wxpipe")
  }
  as.character(jsonlite::toJSON(entry, auto_unbox = TRUE, null = "null", na = "null", digits = NA))
}

#' Write a structured log entry
#'
#' Writes one line of JSON (see [format_log_entry()]) to standard output, or to
#' standard error for `ERROR` and `CRITICAL`, with the labels set by
#' [set_log_context()].
#'
#' @inheritParams format_log_entry
#' @param ... Additional named fields.
#'
#' @return The written line, invisibly.
#' @export
log_event <- function(severity, message, ...) {
  line <- format_log_entry(
    severity, message,
    fields = list(...),
    labels = log_state$labels %||% list(),
    operation_id = log_state$operation_id
  )
  connection <- if (severity %in% c("ERROR", "CRITICAL")) stderr() else stdout()
  cat(line, "\n", sep = "", file = connection)
  invisible(line)
}

#' Set the labels attached to every log entry
#'
#' @param labels A named list of single values, e.g. the run id.
#' @param operation_id Optional id grouping the entries of one run.
#'
#' @return `NULL`, invisibly. Call without arguments to clear the context.
#' @export
set_log_context <- function(labels = list(), operation_id = NULL) {
  log_state$labels <- labels
  log_state$operation_id <- operation_id
  invisible(NULL)
}

# A condition's message, including parent errors, as plain text for logs.
condition_summary <- function(cnd) {
  cli::ansi_strip(paste(conditionMessage(cnd), collapse = "\n"))
}
