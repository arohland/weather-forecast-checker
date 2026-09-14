#!/usr/bin/env Rscript
# Entrypoint of the Cloud Run Job, and of local runs:
#
#   Rscript exec/ingest.R --source=geosphere|openmeteo|all \
#                         --mode=daily|backfill \
#                         --start-date=YYYY-MM-DD --end-date=YYYY-MM-DD \
#                         --location=salzburg-airport \
#                         --dry-run
#
# All logic lives in the wxpipe package (wxpipe::run_cli()), where it is
# tested. This script only passes the arguments on and turns the result into
# the process exit status that Cloud Run uses to mark an execution failed:
# 0 success, 1 a source failed, 2 invalid usage or configuration.

status <- tryCatch(
  wxpipe::run_cli(commandArgs(trailingOnly = TRUE)),
  error = function(e) {
    # run_cli() logs its own failures as structured JSON. This only catches
    # errors raised before that was possible, e.g. the package failing to load.
    message("wxpipe failed before structured logging was available: ", conditionMessage(e))
    1L
  }
)
quit(save = "no", status = status)
