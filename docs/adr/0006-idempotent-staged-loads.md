# 0006. Make loads idempotent with staged, scoped replaces

- Status: Accepted
- Date: 2026-09-14

## Context

A load can be re-run for many reasons: Cloud Run retries a failed task,
someone repeats a backfill, or the daily run re-fetches GeoSphere's revision
window. None of these may duplicate rows. At the same time, the forecast
table is append-only ([0002](0002-append-only-forecast-grain.md)), so a
reload must replace only the statements it previously wrote.

BigQuery constraints (from its documentation):

- Multi-statement transactions support `SELECT`, DML and temporary-table DDL,
  but not DDL on permanent tables, and `LOAD DATA` is not among the supported
  statements.
- Transactions that mutate the same table conflict, and one of them is
  cancelled.
- A table can receive at most 1,500 load jobs per day; DML statements do not
  count toward table modifications.

## Decision

Every load goes through `load_table()`:

1. Validate the rows against the table schema.
2. Check that every row falls inside the load's **scope**, the slice of the
   table this load owns, and refuse otherwise.
3. Upload the rows (Parquet) into a new staging table that expires after 24
   hours.
4. In one multi-statement transaction, `DELETE` the scope from the target and
   `INSERT ... SELECT` the staged rows. On error the transaction rolls back.
5. Drop the staging table.

Scopes per table and source:

| Rows | Scope |
|---|---|
| Observations | location, stations and `reference_time` within the requested days |
| Forecast snapshot | location, model, source and UTC date of `retrieved_at` |
| Previous Runs | location, model, source and `valid_time` within the requested days |
| Single Runs | location, model, source and the run times (`issued_at`), batched per day |

Values in the generated SQL are rendered as literals after strict whitelist
validation, because the documentation does not confirm that query parameters
work inside multi-statement transactions. Production tables are created by
Terraform from the schema files; the loader refuses to load into a table
whose columns differ from its schema.

Rejected alternatives:

- **`MERGE` on the grain**: the forecast grain contains nullable columns,
  which need NULL-safe matching, and a merge does not remove rows that
  disappeared from a revised response.
- **Overwriting partitions**: partitions are monthly, far coarser than a
  load's scope; overwriting one would delete other statements.
- **Streaming inserts with insert ids**: deduplication is best effort only.

## Consequences

- Re-running any load leaves row counts unchanged and applies revisions; this
  is tested offline with an in-memory BigQuery stand-in that applies the same
  scope logic, and against real BigQuery in `tests/integration/`.
- Each load costs one load job (into a fresh staging table) and one
  transaction; loads into the same table must run one after another.
- A load of zero rows is refused, because replacing a scope with nothing
  would silently delete data.
- The job's service account needs `bigquery.dataEditor` on the dataset to
  create and drop staging tables.
