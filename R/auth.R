#' Authenticate to Google Cloud using gargle's default credential chain
#'
#' No credentials are handled or stored by the pipeline itself.
#' `gargle::token_fetch()` tries, in order: a bring-your-own token, a service
#' account key, external account (workload identity federation), Application
#' Default Credentials, and the GCE metadata server. Locally, ADC come from
#' `gcloud auth application-default login`. On Cloud Run the metadata server
#' provides a token for the job's attached service account. The same token is
#' passed to bigrquery and googleCloudStorageR.
#'
#' @param scopes OAuth scopes; `cloud-platform` covers BigQuery and Cloud
#'   Storage.
#' @param fetch_token Function returning a token or `NULL`; injectable for
#'   tests.
#'
#' @return The token, invisibly.
#' @export
authenticate_gcp <- function(scopes = "https://www.googleapis.com/auth/cloud-platform",
                             fetch_token = gargle::token_fetch) {
  token <- fetch_token(scopes = scopes)
  if (is.null(token)) {
    cli::cli_abort(
      c(
        "No Google Cloud credentials found.",
        "i" = "Locally, run {.code gcloud auth application-default login}.",
        "i" = "On Cloud Run, attach a service account to the job."
      ),
      class = "wxpipe_error_auth"
    )
  }
  bigrquery::bq_auth(token = token)
  googleCloudStorageR::gcs_auth(token = token)
  invisible(token)
}
