# 0005. Run ingestion as a Cloud Run Job

- Status: Accepted
- Date: 2026-09-14

## Context

The ingestion is a batch process: it starts once a day, runs for a few
minutes, and exits. Backfills of years of data can run much longer. It needs
R, compiled R packages and their system libraries, so it is shipped as a
container image. Nothing calls it over HTTP.

Options on Google Cloud (limits from the documentation, read 2026-09-14):

- **Cloud Run functions.** Only specific language runtimes are offered (such
  as Node.js, Python, Go, Java, Ruby, PHP and .NET); R is not one of them, so
  an R pipeline would need a custom container anyway.
- **Cloud Run service.** Runs any container, but must listen for HTTP
  requests, and a request can last at most 60 minutes. A batch job would need
  a web server wrapped around it and an HTTP call to start it.
- **Compute Engine VM with cron.** Runs anything for any duration, but costs
  money while idle and needs operating system maintenance.
- **Cloud Run Job.** Runs a container to completion without a web server.
  Success is exit code 0 and failure any non-zero exit code. A task can run
  for up to 168 hours, failed tasks are retried up to a configurable maximum
  (0 to 10), and each execution can override the container arguments.

## Decision

The pipeline runs as the Cloud Run Job `wxpipe-ingest`:

- One task per execution, no parallelism.
- Timeout 1 hour and one retry. Retries are safe because loads are
  idempotent ([0006](0006-idempotent-staged-loads.md)).
- `exec/ingest.R` exits with 0 on success, 1 if a source failed, and 2 on
  invalid usage, so Cloud Run marks failed executions correctly.
- Cloud Scheduler starts the daily execution by calling the documented
  `jobs:run` endpoint; backfills are started manually with
  `gcloud run jobs execute --args=...`.
- Logs are single-line JSON on stdout and stderr, which Cloud Logging stores
  as structured entries.

## Consequences

- There is no HTTP listener in this image. The planned Plumber API is a
  separate service with its own image.
- Cost is per second of execution, and a daily run fits within the Cloud Run
  free tier (see README).
- Long backfills fit within the task timeout, but each is also bounded by
  the Open-Meteo call budget, so large ranges are split across executions.
- A deployment is a new image tag plus `terraform apply`; executions always
  use the image the job points at.
