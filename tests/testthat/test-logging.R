test_that("log entries are single-line JSON with Cloud Logging's special fields", {
  line <- format_log_entry(
    "WARNING", "Loaded\nrows",
    fields = list(rows = 3L, day = as.Date("2026-09-14")),
    labels = list(run_id = "run-1", attempt = 0L),
    operation_id = "run-1",
    time = as.POSIXct("2026-09-14 06:00:00.5", tz = "UTC")
  )

  expect_false(grepl("\n", line, fixed = TRUE))
  entry <- jsonlite::parse_json(line)
  expect_identical(entry$severity, "WARNING")
  expect_identical(entry$message, "Loaded\nrows")
  expect_identical(entry$time, "2026-09-14T06:00:00.500Z")
  expect_identical(entry$rows, 3L)
  expect_identical(entry$day, "2026-09-14")
  expect_identical(entry[["logging.googleapis.com/labels"]], list(run_id = "run-1", attempt = "0"))
  expect_identical(
    entry[["logging.googleapis.com/operation"]],
    list(id = "run-1", producer = "wxpipe")
  )
})

test_that("invalid log entries are rejected", {
  expect_error(format_log_entry("LOUD", "x"), class = "wxpipe_error_input")
  expect_error(format_log_entry("INFO", c("a", "b")), class = "wxpipe_error_input")
  reserved_field <- list(severity = "INFO")
  expect_error(format_log_entry("INFO", "x", fields = reserved_field), class = "wxpipe_error_input")
  missing_label <- list(run_id = NA)
  expect_error(format_log_entry("INFO", "x", labels = missing_label), class = "wxpipe_error_input")
})

test_that("log_event() adds the run context and routes errors to stderr", {
  set_log_context(labels = list(run_id = "run-9"), operation_id = "run-9")
  withr::defer(set_log_context())

  info <- capture_logs(log_event("INFO", "hello", source = "geosphere"))
  expect_length(info$stdout, 1L)
  expect_length(info$stderr, 0L)
  entry <- jsonlite::parse_json(info$stdout)
  expect_identical(entry$source, "geosphere")
  expect_identical(entry[["logging.googleapis.com/labels"]]$run_id, "run-9")

  error <- capture_logs(log_event("ERROR", "boom"))
  expect_length(error$stdout, 0L)
  expect_identical(jsonlite::parse_json(error$stderr)$severity, "ERROR")
})
