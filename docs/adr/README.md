# Architecture decision records

Short records of decisions that shape this project and are not obvious from
the code: what was decided, why, which alternatives were rejected, and what
follows from it. Format after Michael Nygard: context, decision,
consequences. A decision that changes gets a new record that supersedes the
old one; records are not rewritten.

| # | Decision | Status |
|---|---|---|
| [0001](0001-r-package-layout.md) | Structure the pipeline as an R package | Accepted |
| [0002](0002-append-only-forecast-grain.md) | Store forecasts as append-only hourly statements | Accepted |
| [0003](0003-raw-landing-in-gcs.md) | Land raw API responses in Cloud Storage before parsing | Accepted |
| [0004](0004-utc-storage.md) | Store all timestamps in UTC | Accepted |
| [0005](0005-cloud-run-job.md) | Run ingestion as a Cloud Run Job | Accepted |
| [0006](0006-idempotent-staged-loads.md) | Make loads idempotent with staged, scoped replaces | Accepted |
| [0007](0007-sources-and-models.md) | Choose GeoSphere klima-v2-1d station 6300 and Open-Meteo's GeoSphere seamless model | Accepted |
