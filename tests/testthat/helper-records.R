# Response records and runs for tests that start after fetching (landing,
# row shaping, loading), so they do not need HTTP at all.
fake_record <- function(
  body = geosphere_body(),
  api = "geosphere",
  url = "https://example.test/data?x=1",
  fetched_at = as.POSIXct("2026-09-14 06:00:00", tz = "UTC"),
  ...
) {
  c(
    list(
      api = api,
      url = url,
      status = 200L,
      fetched_at = fetched_at,
      body_raw = charToRaw(enc2utf8(body)),
      body = body
    ),
    list(...)
  )
}

test_run <- function(run_id = "20260914T060000Z-test") {
  list(
    run_id = run_id,
    ingested_at = as.POSIXct("2026-09-14 06:05:00", tz = "UTC"),
    pipeline_version = "0.0.0.9000+abc1234"
  )
}
