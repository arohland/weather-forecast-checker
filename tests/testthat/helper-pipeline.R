# Synthetic responses shaped like the real APIs for whatever a pipeline run
# requests, so orchestration can be tested for any run date without HTTP.

synthetic_geosphere_body <- function(parameters, dates) {
  n <- length(dates)
  series <- list()
  for (parameter in parameters) {
    series[[parameter]] <- list(unit = "x", data = as.list(rep(1, n)))
    series[[paste0(parameter, "_flag")]] <- list(unit = "code", data = as.list(rep(10, n)))
  }
  geosphere_body(timestamps = paste0(format(dates, "%Y-%m-%d"), "T00:00+00:00"), series = series)
}

synthetic_openmeteo_body <- function(columns, times) {
  values <- as.list(rep(1, length(times)))
  hourly <- stats::setNames(rep(list(values), length(columns)), columns)
  units <- stats::setNames(as.list(rep("x", length(columns))), columns)
  openmeteo_body(time = as.numeric(times), hourly = hourly, units = units)
}

hours_from <- function(start, n) {
  start + 3600 * seq_len(n) - 3600
}

# Fetchers with the signatures of the real ones. `fail` names fetchers that
# should raise an error, to simulate an outage.
fake_fetchers <- function(now, fail = character()) {
  check <- function(name) {
    if (name %in% fail) stop("simulated ", name, " outage")
  }
  list(
    geosphere = function(source_config, station_ids, start_date, end_date) {
      check("geosphere")
      dates <- seq(start_date, end_date, by = 1)
      body <- synthetic_geosphere_body(source_config$parameters, dates)
      list(fake_record(body, fetched_at = now, start_date = start_date, end_date = end_date))
    },
    forecast = function(source_config, location) {
      check("forecast")
      body <- synthetic_openmeteo_body(source_config$hourly_variables, hours_from(now, 3))
      list(fake_record(
        body,
        api = "openmeteo", fetched_at = now, forecast_source = "forecast",
        model = source_config$model, variables = source_config$hourly_variables
      ))
    },
    previous_runs = function(source_config, location, start_date, end_date) {
      check("previous_runs")
      lead_days <- source_config$previous_runs$lead_days
      columns <- wxpipe:::previous_runs_columns(source_config$hourly_variables, lead_days)
      n_hours <- 24 * (as.numeric(end_date - start_date) + 1)
      times <- hours_from(as.POSIXct(format(start_date), tz = "UTC"), n_hours)
      list(fake_record(
        synthetic_openmeteo_body(columns, times),
        api = "openmeteo", fetched_at = now, forecast_source = "previous_runs",
        model = source_config$model, variables = source_config$hourly_variables,
        lead_days = lead_days, start_date = start_date, end_date = end_date
      ))
    },
    single_runs = function(source_config, location, run_times) {
      check("single_runs")
      lapply(seq_along(run_times), function(i) {
        times <- hours_from(run_times[i], 3)
        body <- synthetic_openmeteo_body(source_config$hourly_variables, times)
        fake_record(
          body,
          api = "openmeteo", fetched_at = now, forecast_source = "single_runs",
          model = source_config$model, variables = source_config$hourly_variables,
          issued_at = run_times[i]
        )
      })
    }
  )
}

fake_getenv <- function(...) {
  values <- c(...)
  function(name, unset = "") {
    if (name %in% names(values)) values[[name]] else unset
  }
}

gcp_env <- function(...) {
  fake_getenv(
    WXPIPE_GCP_PROJECT = "wx-test-project",
    WXPIPE_BQ_DATASET = "raw",
    WXPIPE_GCS_BUCKET = "wx-raw-test",
    ...
  )
}

# Runs `expr` with log output captured; returns the value and the log lines.
capture_logs <- function(expr) {
  stdout_lines <- character()
  stderr_lines <- utils::capture.output(
    stdout_lines <- utils::capture.output(value <- expr, type = "output"),
    type = "message"
  )
  list(value = value, stdout = stdout_lines, stderr = stderr_lines)
}
