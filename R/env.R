#' Read the Google Cloud settings from environment variables
#'
#' The GCP project, BigQuery dataset and GCS bucket are deliberately not in
#' the repository and have no defaults: the same image runs against a sandbox
#' or production depending only on its environment. A missing variable is an
#' error, except in a dry run, which writes nothing.
#'
#' | Variable | Meaning |
#' |---|---|
#' | `WXPIPE_GCP_PROJECT` | Project that owns the dataset and is billed for queries |
#' | `WXPIPE_BQ_DATASET` | Dataset holding the raw tables (e.g. `raw`) |
#' | `WXPIPE_GCS_BUCKET` | Bucket for raw payload landing |
#'
#' @param dry_run Whether the run writes nothing.
#' @param getenv Environment lookup with the signature of [Sys.getenv()];
#'   injectable for tests.
#'
#' @return A list with `project`, `dataset` and `bucket` (empty strings for
#'   unset variables in a dry run).
#' @export
read_runtime_env <- function(dry_run = FALSE, getenv = Sys.getenv) {
  variables <- c(
    project = "WXPIPE_GCP_PROJECT",
    dataset = "WXPIPE_BQ_DATASET",
    bucket = "WXPIPE_GCS_BUCKET"
  )
  values <- vapply(variables, function(name) getenv(name, unset = ""), character(1))
  missing <- unname(variables[!nzchar(values)])
  if (!dry_run && length(missing) > 0L) {
    cli::cli_abort(
      c(
        "Missing required environment variable{?s}: {.envvar {missing}}.",
        "i" = "Set them locally (see README) or on the Cloud Run job (Terraform).",
        "i" = "Use {.code --dry-run} to fetch and parse without writing anything."
      ),
      class = "wxpipe_error_config"
    )
  }
  as.list(values)
}

#' Identifier of a pipeline run
#'
#' On Cloud Run this is the job execution name (`CLOUD_RUN_EXECUTION`) plus
#' the task attempt, so log entries, raw payload files and loaded rows can be
#' traced to an execution in the console, and a retried task gets its own id.
#' Elsewhere it is a UTC timestamp with a random suffix.
#'
#' @param now Run start time.
#' @inheritParams read_runtime_env
#'
#' @return A single string of letters, digits, dots, dashes and underscores.
#' @export
new_run_id <- function(now = Sys.time(), getenv = Sys.getenv) {
  execution <- getenv("CLOUD_RUN_EXECUTION", unset = "")
  if (nzchar(execution)) {
    attempt <- getenv("CLOUD_RUN_TASK_ATTEMPT", unset = "0")
    return(paste0(execution, "-attempt", attempt))
  }
  suffix <- paste(as.character(openssl::rand_bytes(4)), collapse = "")
  paste0("local-", format(now, "%Y%m%dT%H%M%SZ", tz = "UTC"), "-", suffix)
}
