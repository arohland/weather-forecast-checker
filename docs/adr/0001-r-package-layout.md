# 0001. Structure the pipeline as an R package

- Status: Accepted
- Date: 2026-09-14

## Context

The ingestion pipeline is written in R, runs unattended in a container, and
is also a learning project, so it has to be testable, documented and easy to
reason about. The usual options for R pipelines are:

1. A folder of scripts that `source()` each other.
2. An R package, with a thin script as the entrypoint.
3. A workflow framework such as `targets`.

Scripts are quick to start with, but they have no declared dependencies, no
standard place for tests or documentation, and shared state between sourced
files is easy to create by accident. `targets` shines for analyses with
expensive, cacheable steps; an ingestion job that must run every step every
day gains little from its dependency graph and adds a framework to learn.

## Decision

The pipeline is the R package `wxpipe`:

- `R/` holds all logic as functions; parsing and transformation are pure,
  and I/O (HTTP, GCS, BigQuery, logging) is isolated in a few modules.
- `exec/ingest.R` is only an entrypoint that calls `wxpipe::run_cli()`.
- `inst/config/` and `inst/schemas/` hold configuration and table schemas,
  read with `system.file()`.
- `tests/testthat/` holds unit tests (offline); `tests/integration/` holds
  opt-in tests against real BigQuery.
- roxygen2 generates `NAMESPACE` and the reference documentation.

## Consequences

- `R CMD check`, `testthat`, `lintr`, `covr` and roxygen2 work with their
  standard conventions, and CI uses the stock `r-lib/actions`.
- Dependencies are declared in `DESCRIPTION` and pinned in `renv.lock`; every
  cross-package call is namespaced (`httr2::request()`), so there are no
  hidden `library()` side effects.
- The package version, combined with the git commit, identifies the code
  that produced each row (`_pipeline_version`).
- Some tooling expects the package to be installed: lintr resolves functions
  across files through the installed namespace, and the container installs
  the package into its library. `scripts/check.R` installs before linting.
- A package brings boilerplate (`DESCRIPTION`, `NAMESPACE`, `man/`) that a
  handful of scripts would not need.
