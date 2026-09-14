# An in-memory stand-in for bigquery_backend(). It keeps tables as data frames
# and applies a replace exactly like the BigQuery transaction does: delete the
# rows the scope matches (using the same scope_matches() the loader relies
# on), then append the staged rows. The generated SQL itself is tested
# separately, and against real BigQuery in tests/integration/.
fake_bigquery <- function(fail_replace = FALSE) {
  tables <- new.env(parent = emptyenv())
  fields <- new.env(parent = emptyenv())
  state <- new.env(parent = emptyenv())
  state$log <- character()
  record <- function(entry) state$log <- c(state$log, entry)

  list(
    project = "wx-fake-project",
    dataset = "raw",
    table_exists = function(table) exists(table, envir = tables, inherits = FALSE),
    table_fields = function(table) get(table, envir = fields),
    create_table = function(table, schema, staging = FALSE) {
      record(paste("create", table))
      assign(table, NULL, envir = tables)
      assign(table, wxpipe:::schema_field_frame(schema), envir = fields)
      invisible(TRUE)
    },
    upload = function(table, data, schema) {
      record(paste("upload", table))
      assign(table, data, envir = tables)
      invisible(TRUE)
    },
    replace = function(table, staging, scope, columns) {
      record(paste("replace", table))
      if (fail_replace) {
        stop("simulated BigQuery failure")
      }
      current <- get(table, envir = tables)
      staged <- get(staging, envir = tables)[columns]
      if (!is.null(current)) {
        current <- current[!wxpipe:::scope_matches(scope, current), , drop = FALSE]
      }
      combined <- rbind(current, staged)
      rownames(combined) <- NULL
      assign(table, combined, envir = tables)
      invisible(TRUE)
    },
    delete_table = function(table) {
      record(paste("delete", table))
      if (exists(table, envir = tables, inherits = FALSE)) {
        rm(list = table, envir = tables)
      }
      invisible(TRUE)
    },
    count_rows = function(table, scope = NULL) {
      data <- get(table, envir = tables)
      if (is.null(data)) {
        return(0L)
      }
      if (is.null(scope)) nrow(data) else sum(wxpipe:::scope_matches(scope, data))
    },
    # Test-only helpers.
    rows = function(table) get(table, envir = tables),
    tables = function() ls(tables, all.names = TRUE),
    log = function() state$log,
    set_fields = function(table, value) assign(table, value, envir = fields)
  )
}
