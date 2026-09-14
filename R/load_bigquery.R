# BigQuery loading -----------------------------------------------------------------
#
# Loads are idempotent and atomic:
#
# 1. Validate the rows against the table schema, and check that every row falls
#    inside the load's *scope*: the slice of the table this load owns.
# 2. Upload the rows to a short-lived staging table. A load job cannot run
#    inside a BigQuery transaction, and permanent tables cannot be created in
#    one, so staging happens before the transaction.
# 3. In one multi-statement transaction, delete the scope from the target table
#    and insert the staged rows. Both happen or neither does.
#
# Re-running a load therefore replaces exactly what the same load wrote before
# and never duplicates rows. For forecasts the scope is one statement set (one
# day's snapshot, one model run, one archived valid-time range), which keeps the
# table append-only: a new forecast never replaces an older one about the same
# valid time.
#
# BigQuery access goes through a small backend object (bigquery_backend()), so
# the loading logic is tested offline against an in-memory stand-in and against
# real BigQuery only in tests/integration/.

#' Load rows into a raw table idempotently
#'
#' @param rows A data frame for `table`, e.g. from [as_observation_rows()].
#' @param table Target table name (a schema in `inst/schemas`).
#' @param scope The slice of the table this load replaces, from
#'   [observation_load_scope()] or [forecast_load_scope()].
#' @param backend A BigQuery backend from [bigquery_backend()].
#' @param run_id Pipeline run identifier, used to name the staging table.
#'
#' @return A list with `table` and `rows_loaded`.
#' @export
load_table <- function(rows, table, scope, backend, run_id) {
  schema <- read_table_schema(table)
  if (!inherits(scope, "wxpipe_load_scope") || !identical(scope$table, table)) {
    cli::cli_abort(
      "{.arg scope} must be a load scope for table {.val {table}}.",
      class = "wxpipe_error_input"
    )
  }
  validate_table(rows, schema)
  if (nrow(rows) == 0L) {
    cli::cli_abort(
      c(
        "Refusing to load zero rows into {.val {table}}.",
        "i" = "Replacing a scope with nothing would silently delete its existing rows."
      ),
      class = "wxpipe_error_input"
    )
  }
  outside <- !scope_matches(scope, rows)
  if (any(outside)) {
    cli::cli_abort(
      c(
        "{sum(outside)} row{?s} fall outside the load scope of {.val {table}}.",
        "i" = "A re-run would not replace them, so they could be duplicated."
      ),
      class = "wxpipe_error_input"
    )
  }

  columns <- schema_column_names(schema)
  staging <- staging_table_name(table, run_id, scope)
  # Describes each step with this function's variables, so BigQuery errors
  # say which table and step failed.
  step <- function(action, expr) with_bigquery_context(cli::format_inline(action), expr)

  step("check or create table {.val {table}}", ensure_table(backend, schema))
  step(
    "create staging table {.val {staging}}",
    backend$create_table(staging, schema, staging = TRUE)
  )
  on.exit(drop_staging_table(backend, staging), add = TRUE)
  step("upload to {.val {staging}}", backend$upload(staging, rows[columns], schema))
  step(
    "replace the scope in {.val {table}}",
    backend$replace(table, staging, scope, columns)
  )

  list(table = table, rows_loaded = nrow(rows))
}

#' Load scope for GeoSphere observations
#'
#' The rows of one location and set of stations whose `reference_time` falls
#' on `start_date`..`end_date` (UTC days, inclusive) -- exactly what one
#' GeoSphere request for that range returns.
#'
#' @param location_id Location id.
#' @param station_ids Station ids.
#' @param start_date,end_date Single `Date`s.
#'
#' @return A `wxpipe_load_scope` object.
#' @export
observation_load_scope <- function(location_id, station_ids, start_date, end_date) {
  check_date_range(start_date, end_date)
  ids_are_whole <- vapply(as.list(station_ids), is_whole_number, logical(1))
  if (length(station_ids) == 0L || !all(ids_are_whole)) {
    cli::cli_abort("{.arg station_ids} must be whole numbers.", class = "wxpipe_error_input")
  }
  new_load_scope("geosphere_observations", list(
    scope_filter("location_id", "equals", value = location_id),
    scope_filter("station_id", "in", value = as.integer(station_ids)),
    scope_filter(
      "reference_time", "time_range",
      from = utc_midnight(start_date), to = utc_midnight(end_date + 1)
    )
  ))
}

#' Load scope for Open-Meteo forecasts
#'
#' Each forecast source owns a different slice, so that reloads replace only
#' the same statements and the table stays append-only:
#' * `"forecast"`: the snapshot retrieved on one UTC date (`retrieved_date`);
#' * `"previous_runs"`: archived values valid on `start_date`..`end_date`
#'   (UTC days), which do not change once archived;
#' * `"single_runs"`: the runs initialised at `issued_at`.
#'
#' @param location_id Location id.
#' @param model Model id.
#' @param forecast_source One of `"forecast"`, `"previous_runs"`, `"single_runs"`.
#' @param retrieved_date For `"forecast"`: a single `Date`.
#' @param start_date,end_date For `"previous_runs"`: single `Date`s.
#' @param issued_at For `"single_runs"`: a `POSIXct` vector.
#'
#' @return A `wxpipe_load_scope` object.
#' @export
forecast_load_scope <- function(location_id, model, forecast_source, retrieved_date = NULL,
                                start_date = NULL, end_date = NULL, issued_at = NULL) {
  supplied <- c(
    retrieved_date = !is.null(retrieved_date),
    start_date = !is.null(start_date),
    end_date = !is.null(end_date),
    issued_at = !is.null(issued_at)
  )
  needed <- switch(forecast_source,
    forecast = "retrieved_date",
    previous_runs = c("start_date", "end_date"),
    single_runs = "issued_at",
    cli::cli_abort(
      "Unknown {.arg forecast_source} {.val {forecast_source}}.",
      class = "wxpipe_error_input"
    )
  )
  if (!identical(names(supplied)[supplied], needed)) {
    cli::cli_abort(
      "A {.val {forecast_source}} scope needs exactly {.arg {needed}}.",
      class = "wxpipe_error_input"
    )
  }

  window <- switch(forecast_source,
    forecast = {
      check_single_date(retrieved_date, "retrieved_date")
      scope_filter("retrieved_at", "utc_date", value = retrieved_date)
    },
    previous_runs = {
      check_date_range(start_date, end_date)
      scope_filter(
        "valid_time", "time_range",
        from = utc_midnight(start_date), to = utc_midnight(end_date + 1)
      )
    },
    single_runs = {
      if (!inherits(issued_at, "POSIXct") || length(issued_at) == 0L || anyNA(issued_at)) {
        cli::cli_abort(
          "{.arg issued_at} must be non-missing POSIXct values.",
          class = "wxpipe_error_input"
        )
      }
      scope_filter("issued_at", "in", value = issued_at)
    }
  )
  new_load_scope("openmeteo_forecasts", list(
    scope_filter("location_id", "equals", value = location_id),
    scope_filter("model", "equals", value = model),
    scope_filter("forecast_source", "equals", value = forecast_source),
    window
  ))
}

#' Connect the loader to a BigQuery dataset
#'
#' Wraps the handful of bigrquery calls the loader needs. Authenticate first
#' with [authenticate_gcp()].
#'
#' @param project Google Cloud project id (also billed for queries).
#' @param dataset Dataset holding the raw tables.
#'
#' @return A backend object: a list of functions used by [load_table()].
#' @export
bigquery_backend <- function(project, dataset) {
  sql_table(project, dataset, "validation_only")
  bq_table <- function(table) bigrquery::bq_table(project, dataset, table)

  list(
    project = project,
    dataset = dataset,
    table_exists = function(table) bigrquery::bq_table_exists(bq_table(table)),
    table_fields = function(table) {
      fields <- bigrquery::bq_table_fields(bq_table(table))
      data.frame(
        name = vapply(fields, function(field) field$name, character(1)),
        type = normalize_bq_type(vapply(fields, function(field) field$type, character(1))),
        mode = vapply(fields, function(field) field$mode %||% "NULLABLE", character(1))
      )
    },
    create_table = function(table, schema, staging = FALSE) {
      x <- bq_table(table)
      args <- list(x, fields = schema_bq_fields(schema))
      if (staging) {
        if (bigrquery::bq_table_exists(x)) bigrquery::bq_table_delete(x)
        # Expires on its own after a day even if clean-up fails.
        expires_ms <- (as.numeric(Sys.time()) + 24 * 3600) * 1000
        args$expiration_time <- format(round(expires_ms), scientific = FALSE)
      } else {
        args$description <- md_paragraph(schema$description)
        args$time_partitioning <- list(
          type = schema$partitioning$granularity,
          field = schema$partitioning$column
        )
        args$clustering <- list(fields = as.list(schema$clustering$columns))
      }
      do.call(bigrquery::bq_table_create, args)
      invisible(TRUE)
    },
    upload = function(table, data, schema) {
      job <- bigrquery::bq_perform_upload(
        bq_table(table),
        values = data,
        fields = schema_bq_fields(schema),
        source_format = "PARQUET",
        create_disposition = "CREATE_NEVER",
        write_disposition = "WRITE_TRUNCATE"
      )
      bigrquery::bq_job_wait(job, quiet = TRUE)
      invisible(TRUE)
    },
    replace = function(table, staging, scope, columns) {
      sql <- render_replace_sql(project, dataset, table, staging, scope, columns)
      bigrquery::bq_job_wait(bigrquery::bq_perform_query(sql, billing = project), quiet = TRUE)
      invisible(TRUE)
    },
    delete_table = function(table) {
      x <- bq_table(table)
      if (bigrquery::bq_table_exists(x)) bigrquery::bq_table_delete(x)
      invisible(TRUE)
    },
    count_rows = function(table, scope = NULL) {
      where <- if (is.null(scope)) "" else paste(" WHERE", render_scope_sql(scope))
      sql <- paste0("SELECT COUNT(*) AS n FROM ", sql_table(project, dataset, table), where)
      result_table <- bigrquery::bq_project_query(project, sql)
      result <- bigrquery::bq_table_download(result_table, quiet = TRUE)
      as.integer(result$n)
    }
  )
}

# Scopes ----------------------------------------------------------------------------

new_load_scope <- function(table, filters) {
  structure(list(table = table, filters = filters), class = "wxpipe_load_scope")
}

scope_filter <- function(column, op, value = NULL, from = NULL, to = NULL) {
  list(column = column, op = op, value = value, from = from, to = to)
}

utc_midnight <- function(date) {
  as.POSIXct(format(date, "%Y-%m-%d"), tz = "UTC")
}

# Which rows of `data` a scope covers. The in-memory test backend uses this to
# apply deletes, and load_table() uses it to refuse rows outside the scope, so
# it must agree exactly with render_scope_sql().
scope_matches <- function(scope, data) {
  matches <- rep(TRUE, nrow(data))
  for (filter in scope$filters) {
    values <- data[[filter$column]]
    present <- !is.na(values)
    hit <- switch(filter$op,
      equals = present & values == filter$value,
      `in` = present & values %in% filter$value,
      time_range = present & values >= filter$from & values < filter$to,
      utc_date = present & as.Date(values, tz = "UTC") == filter$value
    )
    matches <- matches & hit
  }
  matches
}

staging_table_name <- function(table, run_id, scope) {
  run <- substr(gsub("[^A-Za-z0-9]", "", run_id), 1L, 40L)
  scope_hash <- substr(sha256_hex(render_scope_sql(scope)), 1L, 12L)
  paste0("_staging_", table, "_", run, "_", scope_hash)
}

# SQL rendering ----------------------------------------------------------------------
#
# Values are rendered as literals rather than query parameters: the
# documentation does not confirm parameter support inside multi-statement
# transactions. Every literal is therefore validated against a strict
# whitelist, and anything else is refused rather than escaped.

render_scope_sql <- function(scope) {
  clauses <- vapply(scope$filters, function(filter) {
    column <- sql_identifier(filter$column)
    switch(filter$op,
      equals = paste(column, "=", sql_literal(filter$value)),
      `in` = paste0(column, " IN (", paste(sql_literals(filter$value), collapse = ", "), ")"),
      time_range = paste0(
        column, " >= ", sql_literal(filter$from), " AND ", column, " < ", sql_literal(filter$to)
      ),
      utc_date = paste0("DATE(", column, ") = ", sql_literal(filter$value))
    )
  }, character(1))
  paste(clauses, collapse = "\n    AND ")
}

render_replace_sql <- function(project, dataset, table, staging, scope, columns) {
  target <- sql_table(project, dataset, table)
  source <- sql_table(project, dataset, staging)
  column_list <- paste(vapply(columns, sql_identifier, character(1)), collapse = ", ")
  paste0(
    "BEGIN\n",
    "  BEGIN TRANSACTION;\n",
    "  DELETE FROM ", target, "\n",
    "  WHERE ", render_scope_sql(scope), ";\n",
    "  INSERT INTO ", target, " (", column_list, ")\n",
    "  SELECT ", column_list, " FROM ", source, ";\n",
    "  COMMIT TRANSACTION;\n",
    "EXCEPTION WHEN ERROR THEN\n",
    "  ROLLBACK TRANSACTION;\n",
    "  RAISE USING MESSAGE = @@error.message;\n",
    "END;\n"
  )
}

sql_table <- function(project, dataset, table) {
  # Names are checked with `+` and nchar(): R's default regex engine (TRE)
  # rejects repetition bounds above 255, so {1,1024} is not a valid pattern.
  is_name <- function(x) {
    rlang::is_string(x) && grepl("^[A-Za-z0-9_]+$", x) && nchar(x) <= 1024L
  }
  valid_project <- rlang::is_string(project) && grepl("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", project)
  if (!valid_project || !is_name(dataset) || !is_name(table)) {
    cli::cli_abort(
      "Invalid BigQuery table reference {.val {paste(project, dataset, table, sep = '.')}}.",
      class = "wxpipe_error_input"
    )
  }
  paste0("`", project, ".", dataset, ".", table, "`")
}

sql_identifier <- function(name) {
  if (!rlang::is_string(name) || !grepl("^_?[A-Za-z][A-Za-z0-9_]*$", name)) {
    cli::cli_abort("Invalid column name {.val {name}}.", class = "wxpipe_error_input")
  }
  paste0("`", name, "`")
}

sql_literals <- function(values) {
  vapply(seq_along(values), function(i) sql_literal(values[i]), character(1))
}

sql_literal <- function(value) {
  if (length(value) != 1L || is.na(value)) {
    cli::cli_abort("SQL literals must be single, non-missing values.", class = "wxpipe_error_input")
  }
  if (inherits(value, "POSIXct")) {
    return(sprintf("TIMESTAMP '%s'", format(value, "%Y-%m-%d %H:%M:%OS6+00", tz = "UTC")))
  }
  if (inherits(value, "Date")) {
    return(sprintf("DATE '%s'", format(value, "%Y-%m-%d")))
  }
  if (is.character(value) && grepl("^[A-Za-z0-9_.:-]+$", value)) {
    return(sprintf("'%s'", value))
  }
  if (is_whole_number(value)) {
    return(format(as.integer(value)))
  }
  cli::cli_abort(
    "Refusing to render {.val {value}} as a SQL literal.",
    class = "wxpipe_error_input"
  )
}

# Tables and fields ------------------------------------------------------------------

# Production tables are created by Terraform from the same schema files. This
# creates them when missing (e.g. in a sandbox) and otherwise refuses to load
# into a table whose columns differ from its schema file.
ensure_table <- function(backend, schema) {
  if (!backend$table_exists(schema$table)) {
    backend$create_table(schema$table, schema, staging = FALSE)
    return(invisible("created"))
  }
  expected <- schema_field_frame(schema)
  actual <- backend$table_fields(schema$table)
  if (!identical(actual, expected)) {
    cli::cli_abort(
      c(
        "BigQuery table {.val {schema$table}} does not match its schema file.",
        "i" = "Expected columns: {.field {expected$name}}.",
        "i" = "Update the table (Terraform) or the schema before loading."
      ),
      class = "wxpipe_error_schema"
    )
  }
  invisible("verified")
}

schema_field_frame <- function(schema) {
  data.frame(
    name = schema_column_names(schema),
    type = vapply(schema$columns, function(column) column$type, character(1)),
    mode = vapply(schema$columns, function(column) column$mode, character(1))
  )
}

schema_bq_fields <- function(schema) {
  api_types <- c(
    STRING = "STRING", INT64 = "INTEGER", FLOAT64 = "FLOAT",
    BOOL = "BOOLEAN", DATE = "DATE", TIMESTAMP = "TIMESTAMP"
  )
  bigrquery::bq_fields(lapply(schema$columns, function(column) {
    bigrquery::bq_field(
      column$name,
      type = api_types[[column$type]],
      mode = column$mode,
      description = substr(md_paragraph(column$description), 1L, 1024L)
    )
  }))
}

# The BigQuery API reports legacy type names; compare in GoogleSQL names.
normalize_bq_type <- function(types) {
  legacy <- c(INTEGER = "INT64", FLOAT = "FLOAT64", BOOLEAN = "BOOL")
  unname(ifelse(types %in% names(legacy), legacy[types], types))
}

# `action` is already-formatted text describing the step.
with_bigquery_context <- function(action, expr) {
  withCallingHandlers(
    expr,
    error = function(cnd) {
      if (any(startsWith(class(cnd), "wxpipe_error"))) {
        return()
      }
      cli::cli_abort(
        paste("BigQuery step failed:", cli_escape(action)),
        parent = cnd,
        class = "wxpipe_error_bigquery",
        call = NULL
      )
    }
  )
}

# Staging tables expire after a day anyway, so a failed clean-up must not hide
# the outcome of the load itself; it is reported as a warning.
drop_staging_table <- function(backend, staging) {
  tryCatch(
    backend$delete_table(staging),
    error = function(e) {
      cli::cli_warn(
        "Could not delete staging table {.val {staging}}; it expires within 24 hours.",
        parent = e
      )
    }
  )
}
