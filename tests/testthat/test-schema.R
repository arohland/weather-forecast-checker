# Shipped schemas ----------------------------------------------------------------

test_that("every shipped schema is valid and named after its file", {
  tables <- list_table_schemas()
  expect_true(all(c("geosphere_observations", "openmeteo_forecasts") %in% tables))
  for (table in tables) {
    expect_identical(read_table_schema(table)$table, table)
  }
})

test_that("every configured parameter and variable is described in a schema", {
  config <- read_sources_config()
  catalog_values <- function(table, column) {
    catalog <- read_table_schema(table)$value_catalogs[[column]]
    vapply(catalog, function(entry) entry$value, character(1))
  }
  expect_true(all(
    config$sources$geosphere$parameters %in% catalog_values("geosphere_observations", "parameter")
  ))
  expect_true(all(
    config$sources$openmeteo$hourly_variables %in% catalog_values("openmeteo_forecasts", "variable")
  ))
})

# validate_table() -------------------------------------------------------------------

valid_observations <- function() {
  data.frame(
    location_id = "salzburg-airport",
    station_id = 6300L,
    resource_id = "klima-v2-1d",
    parameter = "rr",
    reference_time = as.POSIXct(c("2026-09-08", "2026-09-09"), tz = "UTC"),
    reference_date_local = as.Date(c("2026-09-08", "2026-09-09")),
    value = c(0.2, -1),
    quality_flag = c(10L, NA),
    unit = "mm",
    `_ingested_at` = as.POSIXct("2026-09-14 06:00:00", tz = "UTC"),
    `_source_url` = "https://dataset.api.hub.geosphere.at/v1/station/historical/klima-v2-1d",
    `_payload_sha256` = strrep("ab", 32),
    `_pipeline_run_id` = "run-1",
    `_pipeline_version` = "0.0.0.9000",
    check.names = FALSE
  )
}

expect_schema_error <- function(data, regexp = NULL) {
  testthat::expect_error(
    validate_table(data, read_table_schema("geosphere_observations")),
    regexp = regexp,
    class = "wxpipe_error_schema"
  )
}

test_that("validate_table() accepts data that matches the schema", {
  data <- valid_observations()
  expect_identical(validate_table(data, read_table_schema("geosphere_observations")), data)
})

test_that("validate_table() rejects missing and unexpected columns", {
  expect_schema_error(valid_observations()[-1], regexp = "location_id")
  expect_schema_error(cbind(valid_observations(), extra = 1), regexp = "extra")
})

test_that("validate_table() rejects wrong types instead of coercing", {
  data <- valid_observations()
  data$station_id <- 6300
  expect_schema_error(data, regexp = "station_id")

  data <- valid_observations()
  data$reference_time <- as.POSIXct(c("2026-09-08", "2026-09-09"), tz = "Europe/Vienna")
  expect_schema_error(data, regexp = "UTC")

  data <- valid_observations()
  data$reference_date_local <- c("2026-09-08", "2026-09-09")
  expect_schema_error(data, regexp = "reference_date_local")
})

test_that("validate_table() rejects missing values in REQUIRED columns only", {
  data <- valid_observations()
  data$unit[2] <- NA
  expect_schema_error(data, regexp = "REQUIRED")

  data <- valid_observations()
  data$value <- NA_real_
  expect_silent(validate_table(data, read_table_schema("geosphere_observations")))
})

test_that("validate_table() enforces value catalogues and patterns", {
  data <- valid_observations()
  data$parameter <- "rain"
  expect_schema_error(data, regexp = "rain")

  data <- valid_observations()
  data$`_payload_sha256` <- "not-a-hash"
  expect_schema_error(data, regexp = "_payload_sha256")
})

test_that("validate_table() rejects rows that duplicate the grain", {
  data <- valid_observations()
  expect_schema_error(rbind(data, data[1, ]), regexp = "duplicate")
})

# Schema definitions -----------------------------------------------------------------

minimal_schema <- function() {
  list(
    table = "things",
    dataset = "raw",
    description = "Test table.",
    grain = "id",
    load_strategy = "Append.",
    partitioning = list(column = "day", granularity = "MONTH", rationale = "Test."),
    clustering = list(columns = "id", rationale = "Test."),
    columns = list(
      list(
        name = "id", type = "STRING", mode = "REQUIRED", source = "Test.",
        description = "Identifier.", allowed_values = c("a", "b")
      ),
      list(name = "day", type = "DATE", mode = "REQUIRED", source = "Test.", description = "Day.")
    )
  )
}

write_schema <- function(schema, file = schema$table, env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  yaml::write_yaml(schema, file.path(dir, paste0(file, ".yml")))
  dir
}

test_that("a minimal schema is valid and allowed_values are enforced", {
  schema <- read_table_schema("things", write_schema(minimal_schema()))
  ok <- data.frame(id = c("a", "b"), day = as.Date("2026-09-14"))
  expect_identical(validate_table(ok, schema), ok)
  expect_error(
    validate_table(data.frame(id = "c", day = as.Date("2026-09-14")), schema),
    class = "wxpipe_error_schema"
  )
})

test_that("invalid schema definitions are rejected", {
  modify <- function(f) {
    schema <- minimal_schema()
    f(schema)
  }
  broken <- list(
    unknown_type = modify(function(s) {
      s$columns[[1]]$type <- "INTEGER"
      s
    }),
    duplicate_column = modify(function(s) `[[<-`(s, "columns", c(s$columns, s$columns[1]))),
    partition_on_string = modify(function(s) {
      s$partitioning$column <- "id"
      s
    }),
    hourly_partitions = modify(function(s) {
      s$partitioning$granularity <- "HOUR"
      s
    }),
    five_cluster_columns = modify(function(s) {
      s$clustering$columns <- rep("id", 5)
      s
    }),
    unknown_grain = modify(function(s) `[[<-`(s, "grain", "nope")),
    catalogue_for_unknown_column = modify(function(s) {
      s$value_catalogs <- list(nope = list(list(value = "a", description = "x")))
      s
    }),
    column_without_description = modify(function(s) {
      s$columns[[2]]$description <- NULL
      s
    }),
    unknown_top_level_key = modify(function(s) `[[<-`(s, "owner", "me"))
  )
  for (case in names(broken)) {
    expect_error(
      read_table_schema("things", write_schema(broken[[case]])),
      class = "wxpipe_error_schema",
      info = case
    )
  }
})

test_that("a schema file must declare the table it is named after", {
  dir <- write_schema(minimal_schema(), file = "other")
  expect_error(read_table_schema("other", dir), class = "wxpipe_error_schema")
  expect_error(read_table_schema("missing", dir), class = "wxpipe_error_schema")
})

# Data dictionary ----------------------------------------------------------------------

test_that("the data dictionary documents every table and column", {
  lines <- render_data_dictionary()
  expect_match(lines[3], "GENERATED")
  for (table in list_table_schemas()) {
    schema <- read_table_schema(table)
    expect_true(any(lines == sprintf("## `raw.%s`", table)), info = table)
    for (column in schema$columns) {
      expect_true(
        any(startsWith(lines, sprintf("| `%s` |", column$name))),
        info = paste(table, column$name)
      )
    }
  }
})

test_that("Markdown cells are single-line with escaped pipes", {
  expect_identical(wxpipe:::md_cell("a | b\n  c "), "a \\| b c")
})

test_that("docs/data-dictionary.md is up to date with the schemas", {
  path <- testthat::test_path("..", "..", "docs", "data-dictionary.md")
  skip_if_not(file.exists(path), "Not running from a source checkout.")
  expect_identical(readLines(path, encoding = "UTF-8"), render_data_dictionary())
})
