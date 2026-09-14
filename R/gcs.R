# Raw payload landing ------------------------------------------------------------
#
# Every API response is written to Cloud Storage, unmodified, before it is
# parsed. A parsing bug can then be fixed and the data replayed from GCS
# without calling the APIs again, and without depending on them still serving
# the same data.
#
# Layout: one gzip-compressed, newline-delimited JSON file per run and source:
#
#   gs://<bucket>/raw/source=<source>/dt=<YYYY-MM-DD>/<run_id>.json.gz
#
# A run can make several requests per source (chunks, several model runs),
# so each line is an envelope: request metadata plus the response body as an
# exact string. `payload_sha256` is the SHA-256 of the body bytes; it is also
# stored on every loaded row as `_payload_sha256`, and verified on replay.

#' Object name of a run's raw payload file in Cloud Storage
#'
#' @param source Source name, e.g. `"geosphere"` or `"openmeteo"`.
#' @param run_date The run's start date (UTC) as a `Date`.
#' @param run_id Pipeline run identifier.
#'
#' @return A single string, e.g.
#'   `"raw/source=geosphere/dt=2026-09-14/<run_id>.json.gz"`.
#' @export
#' @examples
#' raw_object_name("geosphere", as.Date("2026-09-14"), "20260914T060000Z-a1b2c3d4")
raw_object_name <- function(source, run_date, run_id) {
  if (!rlang::is_string(source) || !grepl("^[a-z0-9_]+$", source)) {
    cli::cli_abort(
      "{.arg source} must be a lower-case name, not {.val {source}}.",
      class = "wxpipe_error_input"
    )
  }
  check_single_date(run_date, "run_date")
  if (!rlang::is_string(run_id) || !grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", run_id)) {
    cli::cli_abort(
      "{.arg run_id} may only contain letters, digits, dots, dashes and underscores.",
      class = "wxpipe_error_input"
    )
  }
  sprintf("raw/source=%s/dt=%s/%s.json.gz", source, format(run_date, "%Y-%m-%d"), run_id)
}

#' Land raw API responses in Cloud Storage
#'
#' Writes all response records of one run and source to a single gzipped
#' NDJSON file and uploads it (see the layout described in `R/gcs.R`).
#' Re-running with the same `run_id` overwrites the same object.
#'
#' @param records Response records as returned by the `fetch_*()` functions.
#' @inheritParams raw_object_name
#' @param bucket Name of the raw landing bucket.
#' @param upload Function `(path, bucket, object_name)` that uploads a local
#'   file. Defaults to an upload via googleCloudStorageR; injectable for tests.
#'
#' @return A list with the object's `uri`, `object_name` and the
#'   `payload_sha256` of each record.
#' @export
land_raw_payloads <- function(records, source, run_id, run_date, bucket,
                              upload = gcs_upload_file) {
  if (!is.list(records) || length(records) == 0L) {
    cli::cli_abort("There are no response records to land.", class = "wxpipe_error_input")
  }
  if (!rlang::is_string(bucket) || !nzchar(bucket)) {
    cli::cli_abort("{.arg bucket} must be a bucket name.", class = "wxpipe_error_input")
  }
  object_name <- raw_object_name(source, run_date, run_id)

  path <- tempfile(fileext = ".json.gz")
  on.exit(unlink(path), add = TRUE)
  write_gzip_lines(raw_envelope_lines(records, source, run_id), path)
  upload(path, bucket, object_name)

  list(
    uri = sprintf("gs://%s/%s", bucket, object_name),
    object_name = object_name,
    payload_sha256 = vapply(records, function(record) payload_sha256(record$body_raw), character(1))
  )
}

#' Read landed raw payloads back for replay
#'
#' Every body is checked against its recorded SHA-256, so a replay is
#' guaranteed to parse exactly the bytes the API returned.
#'
#' @param path Local path of a downloaded `.json.gz` raw payload file.
#'
#' @return A list of records with `api`, `url`, `status`, `fetched_at`,
#'   `body_raw`, `body` and `context` (the remaining request metadata).
#' @export
read_raw_payloads <- function(path) {
  if (!rlang::is_string(path) || !file.exists(path)) {
    cli::cli_abort("Raw payload file {.path {path}} does not exist.", class = "wxpipe_error_input")
  }
  connection <- gzfile(path, open = "rb")
  on.exit(close(connection), add = TRUE)
  lines <- readLines(connection, encoding = "UTF-8", warn = FALSE)

  lapply(seq_along(lines), function(i) {
    envelope <- tryCatch(
      jsonlite::parse_json(lines[[i]], simplifyVector = TRUE),
      error = function(e) {
        cli::cli_abort(
          "Line {i} of {.path {path}} is not valid JSON.",
          parent = e, class = "wxpipe_error_parse", call = NULL
        )
      }
    )
    body_raw <- charToRaw(enc2utf8(envelope$body))
    if (!identical(payload_sha256(body_raw), envelope$payload_sha256)) {
      cli::cli_abort(
        "Payload {i} in {.path {path}} does not match its recorded SHA-256.",
        class = "wxpipe_error_parse"
      )
    }
    list(
      api = envelope$api,
      url = envelope$url,
      status = as.integer(envelope$status),
      fetched_at = as.POSIXct(envelope$fetched_at, format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC"),
      body_raw = body_raw,
      body = envelope$body,
      context = envelope$context
    )
  })
}

# Internals ----------------------------------------------------------------------

# Lower-case hex SHA-256 as a plain string. openssl returns a classed "hash"
# object, which neither JSON serialisation nor identical() comparisons expect.
sha256_hex <- function(x) {
  paste(as.character(openssl::sha256(x)), collapse = "")
}

payload_sha256 <- function(body_raw) {
  sha256_hex(body_raw)
}

raw_envelope_lines <- function(records, source, run_id) {
  core_fields <- c("api", "url", "status", "fetched_at", "body_raw", "body")
  vapply(records, function(record) {
    context <- record[setdiff(names(record), core_fields)]
    envelope <- list(
      source = source,
      run_id = run_id,
      api = record$api,
      url = record$url,
      status = record$status,
      fetched_at = format(record$fetched_at, "%Y-%m-%dT%H:%M:%OS6Z", tz = "UTC"),
      payload_sha256 = payload_sha256(record$body_raw),
      context = lapply(context, json_friendly),
      body = record$body
    )
    as.character(jsonlite::toJSON(envelope, auto_unbox = TRUE, null = "null", digits = NA))
  }, character(1))
}

json_friendly <- function(x) {
  if (inherits(x, "POSIXct")) {
    return(format(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  }
  if (inherits(x, "Date")) {
    return(format(x, "%Y-%m-%d"))
  }
  x
}

write_gzip_lines <- function(lines, path) {
  connection <- gzfile(path, open = "wb")
  on.exit(close(connection), add = TRUE)
  writeLines(enc2utf8(lines), connection, sep = "\n", useBytes = TRUE)
  invisible(path)
}

# Uniform bucket-level access is enabled on the landing bucket (Terraform),
# which requires predefinedAcl = "bucketLevel" instead of object ACLs.
gcs_upload_file <- function(path, bucket, object_name) {
  googleCloudStorageR::gcs_upload(
    file = path,
    bucket = bucket,
    name = object_name,
    type = "application/gzip",
    predefinedAcl = "bucketLevel"
  )
  invisible(TRUE)
}
