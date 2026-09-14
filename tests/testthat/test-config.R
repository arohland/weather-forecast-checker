write_config <- function(config, env = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".yml", .local_envir = env)
  yaml::write_yaml(config, path)
  path
}

valid_config <- function() {
  yaml::read_yaml(system.file("config", "sources.yml", package = "wxpipe"))
}

test_that("the shipped sources.yml is valid and has the pinned GeoSphere values", {
  config <- read_sources_config()
  location <- get_location(config, "salzburg-airport")

  expect_identical(location$id, "salzburg-airport")
  expect_identical(location$timezone, "Europe/Vienna")
  expect_identical(location$geosphere$station_id, 6300L)
  expect_identical(config$sources$geosphere$resource_id, "klima-v2-1d")
  expect_false(any(endsWith(config$sources$geosphere$parameters, "_flag")))
})

test_that("a second location is purely a config change", {
  config <- valid_config()
  config$locations[["innsbruck-airport"]] <- list(
    name = "Innsbruck Airport", latitude = 47.26, longitude = 11.36,
    elevation_m = 578, timezone = "Europe/Vienna"
  )
  config <- read_sources_config(write_config(config))
  expect_named(config$locations, c("salzburg-airport", "innsbruck-airport"))
})

test_that("read_sources_config() fails on a missing file", {
  expect_error(read_sources_config("does-not-exist.yml"), class = "wxpipe_error_config")
})

test_that("validation names the offending field", {
  config <- valid_config()
  config$locations$`salzburg-airport`$latitude <- 147.8
  expect_error(
    read_sources_config(write_config(config)),
    regexp = "locations.salzburg-airport.latitude",
    class = "wxpipe_error_config"
  )
})

test_that("validation rejects bad values", {
  cases <- list(
    function(x) `[[<-`(x, "config_version", 2L),
    function(x) {
      x$locations$`salzburg-airport`$timezone <- "Europe/Salzburg"
      x
    },
    function(x) {
      x$locations$`salzburg-airport`$geosphere$station_id <- 63.5
      x
    },
    function(x) {
      x$locations$`salzburg-airport`$lattitude <- 47
      x
    },
    function(x) {
      names(x$locations) <- "Salzburg Airport"
      x
    },
    function(x) {
      x$sources$geosphere$base_url <- "http://insecure.example/v1"
      x
    },
    function(x) {
      x$sources$geosphere$limits$max_values_per_request <- 0L
      x
    },
    function(x) {
      x$sources$geosphere$parameters <- c("rr", "rr")
      x
    },
    function(x) {
      x$sources$geosphere$parameters <- c("rr", "rr_flag")
      x
    },
    function(x) {
      x$sources$geosphere$parameters <- list()
      x
    }
  )
  for (modify in cases) {
    expect_error(
      read_sources_config(write_config(modify(valid_config()))),
      class = "wxpipe_error_config"
    )
  }
})

test_that("Open-Meteo settings are validated", {
  set_openmeteo <- function(config, api, key, value) {
    config$sources$openmeteo[[api]][[key]] <- value
    config
  }
  cases <- list(
    set_openmeteo(valid_config(), "previous_runs", "lead_days", c(1L, 8L)),
    set_openmeteo(valid_config(), "previous_runs", "archive_start", "2024-13-01"),
    set_openmeteo(valid_config(), "single_runs", "run_hours_utc", c(0L, 24L)),
    set_openmeteo(valid_config(), "single_runs", "forecast_days", 17L),
    set_openmeteo(valid_config(), "forecast", "base_url", "http://api.open-meteo.com/v1/forecast"),
    set_openmeteo(valid_config(), "limits", "daily_call_budget", NULL),
    set_openmeteo(valid_config(), "forecast", "past_days", 3L)
  )
  for (config in cases) {
    expect_error(read_sources_config(write_config(config)), class = "wxpipe_error_config")
  }
})

test_that("get_location() lists the configured ids for an unknown location", {
  config <- read_sources_config()
  expect_error(
    get_location(config, "vienna"),
    regexp = "salzburg-airport",
    class = "wxpipe_error_config"
  )
  expect_error(get_location(config, NA_character_), class = "wxpipe_error_config")
})
