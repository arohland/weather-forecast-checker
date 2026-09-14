#!/usr/bin/env Rscript
# Local mirror of the CI pipeline: lintr, styler, roxygen2, testthat and
# R CMD check. Run from the repository root:
#
#   Rscript scripts/check.R
#
# Why base `R CMD build` / `R CMD check` rather than devtools::check()?
# pkgbuild refuses to start on Windows without Rtools, even for a package
# with no compiled code. wxpipe is pure R, so base R needs no toolchain.

if (!file.exists("DESCRIPTION")) {
  stop("Run this script from the repository root.", call. = FALSE)
}

cli::cli_h1("roxygen2")
roxygen2::roxygenise()

cli::cli_h1("lintr")
# lintr's object_usage_linter resolves functions defined in other files via
# the *installed* package namespace. Without a current install it reports
# false "no visible global function" warnings, so install first (the CI lint
# job does the same via `local::.`).
utils::install.packages(".", repos = NULL, type = "source", quiet = TRUE)
lints <- lintr::lint_package()
print(lints)
if (length(lints) > 0L) {
  stop("lintr found ", length(lints), " issue(s).", call. = FALSE)
}

cli::cli_h1("styler (dry run)")
styler::style_dir(
  ".",
  exclude_dirs = c("renv", "tests/testthat/fixtures", "terraform", ".github"),
  dry = "fail"
)

cli::cli_h1("testthat")
testthat::test_local(stop_on_failure = TRUE)

cli::cli_h1("R CMD check")
r_bin <- file.path(R.home("bin"), "R")
pkg_dir <- normalizePath(".")
check_dir <- tempfile("wxpipe-check-")
dir.create(check_dir)

withr::with_dir(check_dir, {
  if (system2(r_bin, c("CMD", "build", shQuote(pkg_dir))) != 0L) {
    stop("R CMD build failed.", call. = FALSE)
  }
  tarball <- list.files(pattern = "^wxpipe_.*\\.tar\\.gz$")
  system2(r_bin, c("CMD", "check", "--no-manual", tarball))

  # R CMD check only exits non-zero on ERROR; CI treats WARNING as fatal
  # too, so parse the log to match that behaviour.
  log <- readLines(file.path("wxpipe.Rcheck", "00check.log"))
  problems <- grep("\\.\\.\\. (WARNING|ERROR)$", log, value = TRUE)
  notes <- grep("\\.\\.\\. NOTE$", log, value = TRUE)
  if (length(notes) > 0L) cli::cli_alert_info("NOTEs: {notes}")
  if (length(problems) > 0L) {
    stop("R CMD check: ", paste(problems, collapse = "; "), call. = FALSE)
  }
})

cli::cli_alert_success("All checks passed.")
