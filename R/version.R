#' Pipeline version stamped onto every ingested row
#'
#' Every row written by the pipeline carries a `_pipeline_version` column so
#' that a data problem can be traced back to the exact code that produced it.
#' The package version alone is not precise enough during development (many
#' commits share `0.0.0.9000`), so the git commit the container image was
#' built from is appended as semver build metadata.
#'
#' @param git_sha Git commit SHA. Defaults to the `WXPIPE_GIT_SHA`
#'   environment variable, which the Docker build bakes into the image.
#'   An empty string means "unknown" (e.g. a local, uncommitted run).
#'
#' @return A length-one character vector such as `"0.1.0+0123abc"`, or just
#'   the package version when no SHA is available.
#' @export
#' @examples
#' pipeline_version(git_sha = "")
#' pipeline_version(git_sha = "0123abcdef")
pipeline_version <- function(git_sha = Sys.getenv("WXPIPE_GIT_SHA")) {
  if (!rlang::is_string(git_sha)) {
    cli::cli_abort(c(
      "{.arg git_sha} must be a single non-missing string.",
      "x" = "You supplied {.obj_type_friendly {git_sha}}."
    ))
  }

  version <- as.character(utils::packageVersion("wxpipe"))
  if (!nzchar(git_sha)) {
    return(version)
  }
  paste0(version, "+", substr(git_sha, 1L, 7L))
}
