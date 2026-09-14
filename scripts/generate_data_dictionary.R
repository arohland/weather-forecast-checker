#!/usr/bin/env Rscript
# Generates docs/data-dictionary.md from inst/schemas/*.yml.
#
#   Rscript scripts/generate_data_dictionary.R          # (re)write the file
#   Rscript scripts/generate_data_dictionary.R --check  # exit 1 if it is stale
#
# The --check mode runs in CI, so a schema change without a regenerated
# dictionary fails the build. Uses the installed wxpipe package but reads the
# schema files from this checkout.

if (!file.exists("DESCRIPTION")) {
  stop("Run this script from the repository root.", call. = FALSE)
}

schema_dir <- file.path("inst", "schemas")
output <- file.path("docs", "data-dictionary.md")

schemas <- lapply(
  wxpipe::list_table_schemas(schema_dir),
  wxpipe::read_table_schema,
  dir = schema_dir
)
lines <- wxpipe::render_data_dictionary(schemas)

if ("--check" %in% commandArgs(trailingOnly = TRUE)) {
  current <- if (file.exists(output)) readLines(output, encoding = "UTF-8") else character()
  if (!identical(current, lines)) {
    message(
      output, " is out of date. Regenerate it with:\n",
      "  Rscript scripts/generate_data_dictionary.R"
    )
    quit(status = 1L)
  }
  message(output, " is up to date.")
} else {
  dir.create(dirname(output), showWarnings = FALSE, recursive = TRUE)
  # Write LF line endings explicitly so the output is identical on every OS.
  connection <- file(output, open = "wb")
  writeLines(enc2utf8(lines), connection, sep = "\n", useBytes = TRUE)
  close(connection)
  message("Wrote ", output)
}
