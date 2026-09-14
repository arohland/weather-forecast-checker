# 0003. Land raw API responses in Cloud Storage before parsing

- Status: Accepted
- Date: 2026-09-14

## Context

Parsers have bugs, and some are only noticed weeks later. If the only copy
of the data is the parsed table, fixing such a bug means calling the APIs
again, which may not be possible: GeoSphere revises observations after
publication, the Open-Meteo Forecast API only ever serves the *current*
forecast, and both APIs are rate limited.

## Decision

Before anything is parsed, every response of a run is written to Cloud
Storage, unmodified:

```
gs://<bucket>/raw/source=<source>/dt=<YYYY-MM-DD>/<run_id>.json.gz
```

- One gzip-compressed, newline-delimited JSON file per run and source. Each
  line is an envelope with the request URL, status, fetch time and request
  context, the response body as an exact string, and the body's SHA-256.
- Every loaded row carries `_payload_sha256` and `_pipeline_run_id`, so it can
  be traced to the exact payload it was parsed from.
- `read_raw_payloads()` verifies each body against its hash, so a replay
  parses exactly the bytes the API returned.
- The job's service account may only *create* objects in the bucket; it
  cannot overwrite or delete landed payloads. A lifecycle rule deletes them
  after `raw_retention_days` (730 by default).
- A dry run lands nothing.

Rejected alternatives:

- **One object per response**: a backfill can make hundreds of requests per
  run; one file per run and source keeps the layout predictable and matches
  the run id used everywhere else.
- **Store raw JSON in a BigQuery column**: mixes landing with modelling, and
  a replay would still depend on BigQuery holding the payload.
- **Parse first, land only the parsed rows**: defeats the purpose.

## Consequences

- A parsing fix can be replayed from GCS without calling the APIs, including
  forecasts that the APIs no longer serve.
- The landed file is an envelope around each response, not the bare response;
  the bytes of each body are preserved exactly and verified by hash.
- Storage cost is negligible (kilobytes to a few megabytes per run).
- The `dt=` partition is the run date, not the data date; the envelope's
  context records which dates a request covered.
