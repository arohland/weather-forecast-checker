#' Read and validate the source configuration
#'
#' Loads `inst/config/sources.yml` (or another file with the same structure)
#' and validates every field before anything else runs. A typo in the config
#' should stop the pipeline at start-up with a message naming the field, not
#' surface later as a confusing HTTP or BigQuery error.
#'
#' @param path Path to a sources YAML file. Defaults to the copy installed
#'   with the package.
#'
#' @return The configuration as a nested list with elements
#'   `config_version`, `locations` and `sources`.
#' @export
#' @examples
#' config <- read_sources_config()
#' names(config$locations)
read_sources_config <- function(
  path = system.file("config", "sources.yml", package = "wxpipe")
) {
  if (!rlang::is_string(path) || !nzchar(path) || !file.exists(path)) {
    cli::cli_abort(
      "Config file {.path {path}} does not exist.",
      class = "wxpipe_error_config"
    )
  }
  config <- yaml::read_yaml(path, eval.expr = FALSE)
  validate_sources_config(config, path = path)
}

#' Look up one configured location
#'
#' @param config A configuration list as returned by [read_sources_config()].
#' @param location_id Location id, e.g. `"salzburg-airport"`.
#'
#' @return The location's configuration list, with its id added as `id`.
#' @export
#' @examples
#' get_location(read_sources_config(), "salzburg-airport")$timezone
get_location <- function(config, location_id) {
  if (!rlang::is_string(location_id)) {
    cli::cli_abort(
      "{.arg location_id} must be a single string, not {.obj_type_friendly {location_id}}.",
      class = "wxpipe_error_config"
    )
  }
  location <- config$locations[[location_id]]
  if (is.null(location)) {
    cli::cli_abort(
      c(
        "Unknown location {.val {location_id}}.",
        "i" = "Configured locations: {.val {names(config$locations)}}."
      ),
      class = "wxpipe_error_config"
    )
  }
  location$id <- location_id
  location
}

# Validation ---------------------------------------------------------------
#
# Written out field by field rather than with a schema library: the rules are
# few, the error messages matter, and it keeps the dependency set small.

validate_sources_config <- function(config, path = "<in-memory config>") {
  if (!is.list(config) || is.null(names(config))) {
    abort_config("must be a YAML mapping", config, "<root>", path)
  }
  check_config_keys(config, c("config_version", "locations", "sources"), "<root>", path)

  if (!identical(config$config_version, 1L)) {
    abort_config("must be 1", config$config_version, "config_version", path)
  }

  locations <- config$locations
  if (!is.list(locations) || length(locations) == 0L || is.null(names(locations))) {
    abort_config("must be a non-empty mapping of location ids", locations, "locations", path)
  }
  for (id in names(locations)) {
    if (!grepl("^[a-z0-9]+(-[a-z0-9]+)*$", id)) {
      abort_config("keys must be lower-case kebab-case ids", id, "locations", path)
    }
    validate_location(locations[[id]], paste0("locations.", id), path)
  }

  sources <- config$sources
  if (!is.list(sources) || is.null(names(sources))) {
    abort_config("must be a mapping of source names", sources, "sources", path)
  }
  check_config_keys(sources, c("geosphere", "openmeteo"), "sources", path)
  validate_geosphere_source(sources$geosphere, "sources.geosphere", path)
  validate_openmeteo_source(sources$openmeteo, "sources.openmeteo", path)

  config
}

validate_location <- function(location, field, path) {
  if (!is.list(location) || is.null(names(location))) {
    abort_config("must be a mapping", location, field, path)
  }
  check_config_keys(
    location,
    c("name", "latitude", "longitude", "elevation_m", "timezone", "geosphere"),
    field, path
  )
  check_config_string(location$name, paste0(field, ".name"), path)
  check_config_number(location$latitude, paste0(field, ".latitude"), path, -90, 90)
  check_config_number(location$longitude, paste0(field, ".longitude"), path, -180, 180)
  check_config_number(location$elevation_m, paste0(field, ".elevation_m"), path, -500, 9000)

  tz_field <- paste0(field, ".timezone")
  check_config_string(location$timezone, tz_field, path)
  if (!location$timezone %in% OlsonNames()) {
    abort_config("must be an IANA time zone name", location$timezone, tz_field, path)
  }

  # A location without a GeoSphere station is valid (e.g. forecast-only).
  if (!is.null(location$geosphere)) {
    geo_field <- paste0(field, ".geosphere")
    if (!is.list(location$geosphere)) {
      abort_config("must be a mapping", location$geosphere, geo_field, path)
    }
    check_config_keys(location$geosphere, "station_id", geo_field, path)
    check_config_whole(location$geosphere$station_id, paste0(geo_field, ".station_id"), path, 1)
  }
  invisible(location)
}

validate_geosphere_source <- function(source, field, path) {
  if (!is.list(source) || is.null(names(source))) {
    abort_config("must be a mapping", source, field, path)
  }
  check_config_keys(
    source,
    c("base_url", "resource_id", "endpoint", "limits", "revision_window_days", "parameters"),
    field, path
  )

  check_config_https_url(source$base_url, paste0(field, ".base_url"), path)
  check_config_string(source$resource_id, paste0(field, ".resource_id"), path)
  check_config_string(source$endpoint, paste0(field, ".endpoint"), path)

  limits <- source$limits
  limits_field <- paste0(field, ".limits")
  if (!is.list(limits) || is.null(names(limits))) {
    abort_config("must be a mapping", limits, limits_field, path)
  }
  check_config_keys(
    limits,
    c("max_values_per_request", "requests_per_second", "requests_per_hour"),
    limits_field, path
  )
  check_config_whole(
    limits$max_values_per_request, paste0(limits_field, ".max_values_per_request"), path, 1
  )
  check_config_number(
    limits$requests_per_second, paste0(limits_field, ".requests_per_second"), path, 0.001, Inf
  )
  check_config_whole(limits$requests_per_hour, paste0(limits_field, ".requests_per_hour"), path, 1)

  check_config_whole(source$revision_window_days, paste0(field, ".revision_window_days"), path, 0)

  params <- source$parameters
  params_field <- paste0(field, ".parameters")
  check_config_names(params, params_field, path)
  if (any(endsWith(params, "_flag"))) {
    abort_config(
      "must not list *_flag parameters (flags are fetched automatically)",
      params[endsWith(params, "_flag")], params_field, path
    )
  }
  invisible(source)
}

validate_openmeteo_source <- function(source, field, path) {
  sub_field <- function(...) paste(c(field, ...), collapse = ".")
  check_config_mapping(source, field, path)
  check_config_keys(
    source,
    c("model", "hourly_variables", "limits", "forecast", "previous_runs", "single_runs"),
    field, path
  )
  check_config_string(source$model, sub_field("model"), path)
  check_config_names(source$hourly_variables, sub_field("hourly_variables"), path)

  limit_keys <- c("requests_per_minute", "daily_call_budget", "variables_per_call", "days_per_call")
  check_config_mapping(source$limits, sub_field("limits"), path)
  check_config_keys(source$limits, limit_keys, sub_field("limits"), path)
  for (key in limit_keys) {
    check_config_whole(source$limits[[key]], sub_field("limits", key), path, 1)
  }

  api_keys <- list(
    forecast = c("base_url", "forecast_days"),
    previous_runs = c("base_url", "lead_days", "archive_start", "chunk_days"),
    single_runs = c("base_url", "run_hours_utc", "archive_start", "forecast_days")
  )
  for (api in names(api_keys)) {
    check_config_mapping(source[[api]], sub_field(api), path)
    check_config_keys(source[[api]], api_keys[[api]], sub_field(api), path)
    check_config_https_url(source[[api]]$base_url, sub_field(api, "base_url"), path)
  }

  forecast <- source$forecast
  previous <- source$previous_runs
  single <- source$single_runs
  # 16 days is the Open-Meteo maximum; 7 is the longest Previous Runs offset.
  check_config_whole_range(
    forecast$forecast_days, sub_field("forecast", "forecast_days"), path, 1, 16
  )
  check_config_whole_set(previous$lead_days, sub_field("previous_runs", "lead_days"), path, 1, 7)
  check_config_date(previous$archive_start, sub_field("previous_runs", "archive_start"), path)
  check_config_whole(previous$chunk_days, sub_field("previous_runs", "chunk_days"), path, 1)
  check_config_whole_set(
    single$run_hours_utc, sub_field("single_runs", "run_hours_utc"), path, 0, 23
  )
  check_config_date(single$archive_start, sub_field("single_runs", "archive_start"), path)
  check_config_whole_range(
    single$forecast_days, sub_field("single_runs", "forecast_days"), path, 1, 16
  )
  invisible(source)
}

# Small checkers -------------------------------------------------------------

check_config_mapping <- function(x, field, path) {
  if (!is.list(x) || is.null(names(x))) {
    abort_config("must be a mapping", x, field, path)
  }
  invisible(x)
}

check_config_https_url <- function(x, field, path) {
  check_config_string(x, field, path)
  if (!grepl("^https://[^ ]+[^/]$", x)) {
    abort_config("must be an https URL without a trailing slash", x, field, path)
  }
  invisible(x)
}

check_config_names <- function(x, field, path) {
  if (!is.character(x) || length(x) == 0L || anyNA(x)) {
    abort_config("must be a non-empty list of names", x, field, path)
  }
  if (anyDuplicated(x)) {
    abort_config("must not contain duplicates", x[duplicated(x)], field, path)
  }
  if (!all(grepl("^[a-z0-9_]+$", x))) {
    abort_config("must be lower-case names", x, field, path)
  }
  invisible(x)
}

check_config_whole_range <- function(x, field, path, min, max) {
  check_config_whole(x, field, path, min)
  if (x > max) {
    abort_config(paste0("must be at most ", max), x, field, path)
  }
  invisible(x)
}

check_config_whole_set <- function(x, field, path, min, max) {
  all_whole <- is.numeric(x) && length(x) > 0L && all(vapply(x, is_whole_number, logical(1)))
  if (!all_whole || anyDuplicated(x) || any(x < min) || any(x > max)) {
    abort_config(
      paste0("must be unique whole numbers between ", min, " and ", max),
      x, field, path
    )
  }
  invisible(x)
}

check_config_date <- function(x, field, path) {
  is_date <- rlang::is_string(x) && grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x)
  if (!is_date || is.na(as.Date(x, optional = TRUE))) {
    abort_config("must be a date string in YYYY-MM-DD format", x, field, path)
  }
  invisible(x)
}

check_config_keys <- function(x, allowed, field, path) {
  unknown <- setdiff(names(x), allowed)
  if (length(unknown) > 0L) {
    abort_config(
      paste0("has unknown keys (allowed: ", paste(allowed, collapse = ", "), ")"),
      unknown, field, path
    )
  }
  invisible(x)
}

check_config_string <- function(x, field, path) {
  if (!rlang::is_string(x) || !nzchar(x)) {
    abort_config("must be a non-empty string", x, field, path)
  }
  invisible(x)
}

check_config_number <- function(x, field, path, min, max) {
  if (!is.numeric(x) || length(x) != 1L || is.na(x) || x < min || x > max) {
    abort_config(paste0("must be a number between ", min, " and ", max), x, field, path)
  }
  invisible(x)
}

check_config_whole <- function(x, field, path, min) {
  if (!is.numeric(x) || length(x) != 1L || is.na(x) || x != round(x) || x < min) {
    abort_config(paste0("must be a whole number >= ", min), x, field, path)
  }
  invisible(x)
}

abort_config <- function(problem, value, field, path) {
  # `found` is used inside the cli message template below, which codetools
  # (and so lintr's object_usage_linter) cannot see into.
  found <- if (is.atomic(value) && length(value) %in% 1:10) { # nolint: object_usage_linter.
    cli::format_inline("{.val {value}}")
  } else {
    cli::format_inline("{.obj_type_friendly {value}}")
  }
  cli::cli_abort(
    c(
      "Invalid configuration: {.field {field}} {problem}.",
      "x" = "Found {found}.",
      "i" = "Config file: {.path {path}}"
    ),
    class = "wxpipe_error_config",
    call = NULL
  )
}
