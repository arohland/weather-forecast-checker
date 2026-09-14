test_that("pipeline_version() appends a 7-character sha as build metadata", {
  expect_match(
    pipeline_version(git_sha = "0123456789abcdef"),
    "^[0-9]+(\\.[0-9]+)+\\+0123456$"
  )
})

test_that("pipeline_version() is the bare version when no sha is known", {
  expect_identical(
    pipeline_version(git_sha = ""),
    as.character(utils::packageVersion("wxpipe"))
  )
})

test_that("pipeline_version() reads WXPIPE_GIT_SHA by default", {
  withr::local_envvar(WXPIPE_GIT_SHA = "fedcba9876")
  expect_match(pipeline_version(), "\\+fedcba9$")
})

test_that("pipeline_version() rejects anything that is not a single string", {
  expect_error(pipeline_version(git_sha = NA_character_), class = "rlang_error")
  expect_error(pipeline_version(git_sha = c("a", "b")), class = "rlang_error")
  expect_error(pipeline_version(git_sha = 1L), class = "rlang_error")
})
