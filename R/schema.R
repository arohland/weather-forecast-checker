# Table schemas ----------------------------------------------------------------
#
# inst/schemas/<table>.yml is the single source of truth for every raw table:
# column names, BigQuery types, nullability, units, lineage, partitioning and
# clustering. Pre-load validation, BigQuery table definitions and
# docs/data-dictionary.md are all derived from these files, so documentation
# cannot drift from what is actually loaded.

schema_types <- c("STRING", "INT64", "FLOAT64", "BOOL", "DATE", "TIMESTAMP")
schema_modes <- c("REQUIRED", "NULLABLE")

#' List the available table schemas
#'
#' @param dir Directory containing `<table>.yml` schema files. Defaults to the
#'   schemas installed with the package.
#'
#' @return A sorted character vector of table names.
#' @export
#' @examples
#' list_table_schemas()
list_table_schemas <- function(dir = system.file("schemas", package = "wxpipe")) {
  sort(sub("\\.yml$", "", list.files(dir, pattern = "\\.yml$")))
}

#' Read and validate a table schema
#'
#' @param table Table name, e.g. `"geosphere_observations"`.
#' @inheritParams list_table_schemas
#'
#' @return The schema as a validated list.
#' @export
#' @examples
#' schema <- read_table_schema("geosphere_observations")
#' vapply(schema$columns, function(column) column$name, character(1))
read_table_schema <- function(table, dir = system.file("schemas", package = "wxpipe")) {
  path <- if (rlang::is_string(table)) file.path(dir, paste0(table, ".yml")) else ""
  if (!nzchar(path) || !file.exists(path)) {
    cli::cli_abort(
      c(
        "No schema file for table {.val {table}}.",
        "i" = "Available tables: {.val {list_table_schemas(dir)}}."
      ),
      class = "wxpipe_error_schema"
    )
  }
  schema <- validate_schema_definition(yaml::read_yaml(path, eval.expr = FALSE), path)
  if (!identical(schema$table, table)) {
    cli::cli_abort(
      "Schema file {.path {path}} declares table {.val {schema$table}}; expected {.val {table}}.",
      class = "wxpipe_error_schema"
    )
  }
  schema
}

#' Validate a data frame against a table schema before loading
#'
#' Nothing is loaded into BigQuery without passing this check. It verifies,
#' and never repairs:
#' * the column set matches the schema exactly (no missing, no extra columns);
#' * each column has the R type corresponding to its BigQuery type
#'   (`TIMESTAMP` must be `POSIXct` in UTC);
#' * `REQUIRED` columns contain no missing values;
#' * values are within the column's allowed values or value catalogue, and
#'   match its pattern, where the schema defines one;
#' * no two rows share the same grain (the table's natural key).
#'
#' @param data A data frame.
#' @param schema A schema from [read_table_schema()].
#'
#' @return `data`, invisibly. Fails with a `wxpipe_error_schema` error
#'   otherwise.
#' @export
validate_table <- function(data, schema) {
  if (!is.data.frame(data)) {
    cli::cli_abort(
      "Data for {.val {schema$table}} must be a data frame, not {.obj_type_friendly {data}}.",
      class = "wxpipe_error_schema"
    )
  }

  expected <- schema_column_names(schema)
  missing <- setdiff(expected, names(data))
  extra <- setdiff(names(data), expected)
  if (length(missing) > 0L || length(extra) > 0L) {
    cli::cli_abort(
      c(
        "Columns of the data do not match the {.val {schema$table}} schema.",
        "x" = if (length(missing) > 0L) "Missing: {.field {missing}}.",
        "x" = if (length(extra) > 0L) "Not in schema: {.field {extra}}."
      ),
      class = "wxpipe_error_schema"
    )
  }

  for (column in schema$columns) {
    validate_column(data[[column$name]], column, schema)
  }

  keys <- data[schema$grain]
  duplicates <- keys[duplicated(keys), , drop = FALSE]
  if (nrow(duplicates) > 0L) {
    cli::cli_abort(
      c(
        "{nrow(duplicates)} row{?s} duplicate the grain of {.val {schema$table}}.",
        "i" = "Grain: {.field {schema$grain}}.",
        "x" = "First duplicate: {format_key(duplicates[1, , drop = FALSE])}."
      ),
      class = "wxpipe_error_schema"
    )
  }
  invisible(data)
}

#' Render the data dictionary from table schemas
#'
#' Pure function producing the Markdown for `docs/data-dictionary.md`. The
#' file is written (and checked for drift in CI) by
#' `scripts/generate_data_dictionary.R`.
#'
#' @param schemas A list of schemas from [read_table_schema()].
#'
#' @return A character vector of Markdown lines.
#' @export
render_data_dictionary <- function(
  schemas = lapply(list_table_schemas(), read_table_schema)
) {
  toc <- vapply(schemas, function(schema) {
    anchor <- gsub("[^a-z0-9_-]", "", paste0(schema$dataset, schema$table))
    sprintf("- [`%s.%s`](#%s)", schema$dataset, schema$table, anchor)
  }, character(1))

  c(
    "# Data dictionary",
    "",
    paste(
      "<!-- GENERATED from inst/schemas/*.yml by scripts/generate_data_dictionary.R.",
      "Do not edit by hand; CI fails if this file is out of date. -->"
    ),
    "",
    "Conventions that apply to every table:",
    "",
    "- All `TIMESTAMP` columns are UTC. Local calendar dates are separate `DATE`",
    "  columns derived with the location's time zone (`Europe/Vienna` for Salzburg).",
    "- Columns starting with `_` are ingestion metadata, identical in meaning",
    "  across tables.",
    "- `NULL` means the source delivered no value. Rows are never dropped because",
    "  a value is missing, and values are stored as delivered (no unit",
    "  conversion, no decoding of sentinel values).",
    "",
    "## Tables",
    "",
    toc,
    unlist(lapply(schemas, render_table_section))
  )
}

# Schema definition validation -----------------------------------------------------

validate_schema_definition <- function(schema, path) {
  # Formats `message` where it was written (it may reference that function's
  # variables), then adds the schema file path known in this scope. Passed on
  # to the column and catalogue validators so all errors name the file.
  abort_schema <- function(message, env = parent.frame()) {
    detail <- cli_escape(cli::format_inline(message, .envir = env))
    cli::cli_abort(
      c(detail, "i" = "Schema file: {.path {path}}"),
      class = "wxpipe_error_schema",
      call = NULL
    )
  }
  allowed_keys <- c(
    "table", "dataset", "description", "grain", "load_strategy",
    "partitioning", "clustering", "columns", "value_catalogs"
  )
  if (!is.list(schema) || is.null(names(schema))) {
    abort_schema("A schema must be a YAML mapping.")
  }
  unknown <- setdiff(names(schema), allowed_keys)
  if (length(unknown) > 0L) {
    abort_schema("Unknown top-level key{?s}: {.field {unknown}}.")
  }
  for (key in c("table", "dataset", "description", "load_strategy")) {
    if (!rlang::is_string(schema[[key]]) || !nzchar(schema[[key]])) {
      abort_schema("{.field {key}} must be a non-empty string.")
    }
  }

  columns <- schema$columns
  if (!is.list(columns) || length(columns) == 0L) {
    abort_schema("{.field columns} must be a non-empty list.")
  }
  for (column in columns) {
    validate_column_definition(column, abort_schema)
  }
  names <- schema_column_names(schema)
  if (anyDuplicated(names)) {
    abort_schema("Duplicate column name{?s}: {.field {names[duplicated(names)]}}.")
  }
  types <- stats::setNames(vapply(columns, function(x) x$type, character(1)), names)

  unknown_grain <- setdiff(schema$grain, names)
  if (!is.character(schema$grain) || length(schema$grain) == 0L || length(unknown_grain) > 0L) {
    abort_schema("{.field grain} must list existing columns.")
  }

  partitioning <- schema$partitioning
  partition_types <- c("DATE", "TIMESTAMP")
  if (!is.list(partitioning) || !isTRUE(types[partitioning$column] %in% partition_types)) {
    abort_schema("{.field partitioning.column} must be an existing DATE or TIMESTAMP column.")
  }
  if (!isTRUE(partitioning$granularity %in% c("DAY", "MONTH", "YEAR"))) {
    abort_schema("{.field partitioning.granularity} must be DAY, MONTH or YEAR.")
  }
  if (!rlang::is_string(partitioning$rationale)) {
    abort_schema("{.field partitioning.rationale} must explain the choice.")
  }

  clustering <- schema$clustering
  clustering_ok <- is.list(clustering) && is.character(clustering$columns) &&
    length(clustering$columns) %in% 1:4
  if (!clustering_ok || length(setdiff(clustering$columns, names)) > 0L) {
    abort_schema("{.field clustering.columns} must list 1 to 4 existing columns.")
  }
  if (!rlang::is_string(clustering$rationale)) {
    abort_schema("{.field clustering.rationale} must explain the choice.")
  }

  catalogs <- schema$value_catalogs %||% list()
  unknown_catalogs <- setdiff(names(catalogs), names)
  if (length(unknown_catalogs) > 0L) {
    abort_schema("Value catalogue for unknown column{?s} {.field {unknown_catalogs}}.")
  }
  for (catalog_column in names(catalogs)) {
    validate_catalog_definition(catalogs[[catalog_column]], catalog_column, abort_schema)
  }
  schema
}

validate_column_definition <- function(column, abort_schema) {
  allowed_keys <- c(
    "name", "type", "mode", "unit", "source", "description", "allowed_values", "pattern"
  )
  if (!is.list(column) || !rlang::is_string(column$name)) {
    abort_schema("Every column needs a {.field name}.")
  }
  name <- column$name
  unknown <- setdiff(names(column), allowed_keys)
  if (length(unknown) > 0L) {
    abort_schema("Column {.field {name}} has unknown key{?s} {.field {unknown}}.")
  }
  if (!grepl("^_?[a-z][a-z0-9_]*$", name)) {
    abort_schema("Column name {.val {name}} must be lower snake_case.")
  }
  if (!isTRUE(column$type %in% schema_types)) {
    abort_schema("Column {.field {name}}: type must be one of {.val {schema_types}}.")
  }
  if (!isTRUE(column$mode %in% schema_modes)) {
    abort_schema("Column {.field {name}}: mode must be one of {.val {schema_modes}}.")
  }
  for (key in c("source", "description")) {
    if (!rlang::is_string(column[[key]]) || !nzchar(column[[key]])) {
      abort_schema("Column {.field {name}} needs a non-empty {.field {key}}.")
    }
  }
  if (!is.null(column$unit) && !rlang::is_string(column$unit)) {
    abort_schema("Column {.field {name}}: unit must be a string.")
  }
  if (!is.null(column$allowed_values) && !is_unique_names(column$allowed_values)) {
    abort_schema("Column {.field {name}}: allowed_values must be unique strings.")
  }
  if (!is.null(column$pattern)) {
    valid_regex <- rlang::is_string(column$pattern) &&
      !inherits(try(grepl(column$pattern, ""), silent = TRUE), "try-error")
    if (!valid_regex) {
      abort_schema("Column {.field {name}}: pattern must be a valid regular expression.")
    }
  }
  invisible(column)
}

validate_catalog_definition <- function(catalog, column, abort_schema) {
  if (!is.list(catalog) || length(catalog) == 0L) {
    abort_schema("Value catalogue for {.field {column}} must be a non-empty list.")
  }
  for (entry in catalog) {
    unknown <- setdiff(names(entry), c("value", "unit", "description", "source_text"))
    if (!rlang::is_string(entry$value) || !rlang::is_string(entry$description)) {
      abort_schema("Every catalogue entry for {.field {column}} needs a value and description.")
    }
    if (length(unknown) > 0L) {
      abort_schema("Catalogue entry {.val {entry$value}} has unknown key{?s} {.field {unknown}}.")
    }
  }
  values <- vapply(catalog, function(entry) entry$value, character(1))
  duplicates <- values[duplicated(values)]
  if (length(duplicates) > 0L) {
    abort_schema("Duplicate catalogue value{?s} for {.field {column}}: {.val {duplicates}}.")
  }
  invisible(catalog)
}

# Data validation ------------------------------------------------------------------

validate_column <- function(values, column, schema) {
  # Formats `problem` where it was written, then prefixes column and table.
  abort_column <- function(problem, env = parent.frame()) {
    detail <- cli_escape(cli::format_inline(problem, .envir = env))
    cli::cli_abort(
      paste0("Column {.field {column$name}} of {.val {schema$table}} ", detail, "."),
      class = "wxpipe_error_schema",
      call = NULL
    )
  }

  type_ok <- switch(column$type,
    STRING = is.character(values),
    INT64 = is.integer(values),
    FLOAT64 = is.double(values) && !inherits(values, c("POSIXct", "Date")),
    BOOL = is.logical(values),
    DATE = inherits(values, "Date"),
    TIMESTAMP = inherits(values, "POSIXct") && identical(attr(values, "tzone"), "UTC")
  )
  if (!type_ok) {
    abort_column(paste0(
      "must be ", r_type_label(column$type), " for BigQuery ", column$type,
      ", not ", paste(class(values), collapse = "/")
    ))
  }

  n_missing <- sum(is.na(values))
  if (column$mode == "REQUIRED" && n_missing > 0L) {
    abort_column("is REQUIRED but has {n_missing} missing value{?s}")
  }

  allowed <- column_allowed_values(column, schema)
  present <- values[!is.na(values)]
  if (!is.null(allowed)) {
    unexpected <- unique(present[!present %in% allowed])
    if (length(unexpected) > 0L) {
      abort_column("has value{?s} outside the schema: {.val {utils::head(unexpected, 5)}}")
    }
  }
  if (!is.null(column$pattern)) {
    mismatched <- unique(present[!grepl(column$pattern, present)])
    if (length(mismatched) > 0L) {
      abort_column("has value{?s} not matching its pattern: {.val {utils::head(mismatched, 3)}}")
    }
  }
  invisible(values)
}

column_allowed_values <- function(column, schema) {
  catalog <- schema$value_catalogs[[column$name]]
  if (!is.null(catalog)) {
    return(vapply(catalog, function(entry) entry$value, character(1)))
  }
  column$allowed_values
}

r_type_label <- function(type) {
  switch(type,
    STRING = "character",
    INT64 = "integer",
    FLOAT64 = "double",
    BOOL = "logical",
    DATE = "Date",
    TIMESTAMP = "POSIXct in UTC"
  )
}

schema_column_names <- function(schema) {
  vapply(schema$columns, function(column) column$name, character(1))
}

format_key <- function(row) {
  values <- vapply(row, function(x) format(x[[1]]), character(1))
  paste(paste0(names(row), " = ", values), collapse = ", ")
}

# Markdown rendering ---------------------------------------------------------------

render_table_section <- function(schema) {
  column_rows <- vapply(schema$columns, function(column) {
    sprintf(
      "| `%s` | %s | %s | %s | %s | %s |",
      column$name, column$type,
      if (column$mode == "REQUIRED") "no" else "yes",
      md_cell(column$unit %||% ""),
      md_cell(column$source),
      md_cell(column$description)
    )
  }, character(1))

  catalogs <- unlist(lapply(names(schema$value_catalogs), function(column) {
    rows <- vapply(schema$value_catalogs[[column]], function(entry) {
      sprintf(
        "| `%s` | %s | %s | %s |",
        entry$value, md_cell(entry$unit %||% ""), md_cell(entry$description),
        md_cell(entry$source_text %||% "")
      )
    }, character(1))
    c(
      "", sprintf("### Values of `%s`", column), "",
      "| Value | Unit | Description | Source documentation |",
      "|---|---|---|---|",
      rows
    )
  }))

  c(
    "",
    sprintf("## `%s.%s`", schema$dataset, schema$table),
    "",
    md_paragraph(schema$description),
    "",
    sprintf("**Grain (one row per):** %s", paste0("`", schema$grain, "`", collapse = ", ")),
    "",
    sprintf("**Load strategy:** %s", md_paragraph(schema$load_strategy)),
    "",
    "### Partitioning and clustering",
    "",
    sprintf(
      "- **Partitioned** by `%s` (%s): %s",
      schema$partitioning$column, schema$partitioning$granularity,
      md_paragraph(schema$partitioning$rationale)
    ),
    sprintf(
      "- **Clustered** by %s: %s",
      paste0("`", schema$clustering$columns, "`", collapse = ", "),
      md_paragraph(schema$clustering$rationale)
    ),
    "",
    "### Columns",
    "",
    "| Column | Type | Nullable | Unit | Source | Description |",
    "|---|---|---|---|---|---|",
    column_rows,
    catalogs
  )
}

# YAML folded scalars carry line breaks and trailing newlines; Markdown table
# cells must be single-line and must not contain unescaped pipes.
md_paragraph <- function(text) {
  trimws(gsub("\\s+", " ", text))
}

md_cell <- function(text) {
  gsub("|", "\\|", md_paragraph(text), fixed = TRUE)
}
