# An upload stand-in that keeps a copy of every uploaded file.
capturing_upload <- function(dir) {
  uploads <- list()
  list(
    upload = function(path, bucket, object_name) {
      copy <- file.path(dir, basename(object_name))
      file.copy(path, copy, overwrite = TRUE)
      entry <- list(bucket = bucket, object_name = object_name, copy = copy)
      uploads[[length(uploads) + 1L]] <<- entry
      invisible(TRUE)
    },
    uploads = function() uploads
  )
}

land <- function(records, upload, bucket = "wx-raw") {
  land_raw_payloads(records, "geosphere", "run-1", as.Date("2026-09-14"), bucket, upload = upload)
}

test_that("raw payload object names follow the landing layout", {
  day <- as.Date("2026-09-14")
  expect_identical(
    raw_object_name("geosphere", day, "20260914T060000Z-ab12"),
    "raw/source=geosphere/dt=2026-09-14/20260914T060000Z-ab12.json.gz"
  )
  expect_error(raw_object_name("geo/sphere", day, "run"), class = "wxpipe_error_input")
  expect_error(raw_object_name("geosphere", "2026-09-14", "run"), class = "wxpipe_error_input")
  expect_error(raw_object_name("geosphere", day, "../run"), class = "wxpipe_error_input")
})

test_that("payload hashes are the SHA-256 of the body bytes, as plain strings", {
  hash <- wxpipe:::payload_sha256(charToRaw("abc"))
  expect_identical(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
})

test_that("responses are landed gzipped and replay byte for byte", {
  gcs <- capturing_upload(withr::local_tempdir())
  records <- list(
    fake_record(start_date = as.Date("2026-09-01"), end_date = as.Date("2026-09-02")),
    # Non-ASCII content (the degree sign) must survive the round trip too.
    fake_record(
      body = openmeteo_body(), api = "openmeteo",
      issued_at = utc_time("2026-09-10 00:00:00")
    )
  )

  landed <- land(records, gcs$upload)

  expect_identical(landed$uri, "gs://wx-raw/raw/source=geosphere/dt=2026-09-14/run-1.json.gz")
  upload <- gcs$uploads()[[1]]
  expect_identical(upload$bucket, "wx-raw")
  expect_identical(readBin(upload$copy, "raw", 2L), as.raw(c(0x1f, 0x8b)))

  replayed <- read_raw_payloads(upload$copy)
  expect_length(replayed, 2L)
  for (i in seq_along(records)) {
    expect_identical(replayed[[i]]$body_raw, records[[i]]$body_raw)
    expect_identical(replayed[[i]]$url, records[[i]]$url)
    expect_equal(replayed[[i]]$fetched_at, records[[i]]$fetched_at)
  }
  hashes <- vapply(records, function(record) wxpipe:::payload_sha256(record$body_raw), character(1))
  expect_identical(landed$payload_sha256, hashes)
  expect_identical(replayed[[1]]$context$start_date, "2026-09-01")
  expect_identical(replayed[[2]]$context$issued_at, "2026-09-10T00:00:00Z")
})

test_that("a replayed payload that does not match its hash is rejected", {
  gcs <- capturing_upload(withr::local_tempdir())
  land(list(fake_record()), gcs$upload)
  path <- gcs$uploads()[[1]]$copy

  lines <- readLines(gzfile(path), warn = FALSE)
  connection <- gzfile(path, open = "wb")
  writeLines(sub("0.2", "0.3", lines, fixed = TRUE), connection)
  close(connection)

  expect_error(read_raw_payloads(path), class = "wxpipe_error_parse")
})

test_that("landing needs records and a bucket", {
  upload <- function(...) stop("no upload expected")
  expect_error(land(list(), upload), class = "wxpipe_error_input")
  expect_error(land(list(fake_record()), upload, bucket = ""), class = "wxpipe_error_input")
})
