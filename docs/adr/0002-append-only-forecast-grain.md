# 0002. Store forecasts as append-only hourly statements

- Status: Accepted
- Date: 2026-09-14

## Context

The purpose of collecting forecasts is to measure how forecast skill changes
with lead time. A forecast is a statement made *at* a time *about* a time:
the forecast for next Tuesday made on Saturday and the one made on Monday are
different facts, and both are needed. Updating a stored forecast when a newer
one for the same valid time arrives would destroy exactly that signal.

The three Open-Meteo APIs used state different things:

- The **Forecast API** returns the current forecast, continuously stitched
  from the latest model runs. It does not report when those runs were
  initialised.
- The **Previous Runs API** returns archived values at fixed lead-time
  offsets: `<variable>_previous_dayN` is the value predicted N x 24 hours
  before the valid time. It does not report a run time either.
- The **Single Runs API** returns the complete output of one model run,
  identified by its initialisation time.

Observations are daily, but GeoSphere's daily windows differ per parameter
(temperature extremes 18:10 to 18:00 UTC, precipitation 06:01 UTC to
06:00 UTC of the next day) and none of them is a local calendar day.
Open-Meteo's daily aggregates are computed over local calendar days, so they
cannot be compared with the observations like for like.

## Decision

`raw.openmeteo_forecasts` stores **hourly** values in long format and is
**append-only**: rows are never updated or overwritten because of their valid
time. Daily values matching each GeoSphere window are derived downstream
(dbt) from the hourly values.

Each row records exactly what its source states, and nothing more:

- `forecast_source`: `forecast`, `previous_runs` or `single_runs`.
- `issued_at`: the model initialisation time, set only for `single_runs`;
  `NULL` otherwise rather than estimated.
- `lead_time_days`: the Previous Runs offset N; `NULL` otherwise.
- `lead_time_hours`: `valid_time - issued_at` for single runs; `NULL`
  otherwise.
- `retrieved_at`: when the pipeline received the response, the best
  available indication of when a stitched forecast was current.

The grain is `(location_id, model, forecast_source, issued_at,
lead_time_days, retrieved_at, valid_time, variable)`. Re-running a load
replaces only rows of the same statements (see [0006](0006-idempotent-staged-loads.md)).

Rejected alternatives:

- **Upsert the latest forecast per valid time**: loses the history the table
  exists for.
- **Store Open-Meteo's daily aggregates**: their local-day windows do not
  match GeoSphere's.
- **Derive an `issued_at` for every row** (fetch time for the Forecast API,
  valid time minus N days for Previous Runs): would present approximations
  as facts.

## Consequences

- The table grows by roughly 17,000 rows per location per day, which is
  megabytes per month (see the partitioning notes in the data dictionary).
- Analyses must choose a source and handle `NULL` lead times deliberately;
  the data dictionary documents what each column means per source.
- The daily comparison requires a downstream step that aggregates hourly
  values over each parameter's window. For `sunshine_duration`, Open-Meteo's
  hourly documentation does not state the aggregation period; it is recorded
  as unconfirmed.
- Archive gaps (e.g. no lead-time archive for `snow_depth`) appear as `NULL`
  values rather than missing rows.
