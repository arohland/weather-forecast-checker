test_that("missing Google Cloud credentials fail loudly with guidance", {
  expect_error(
    authenticate_gcp(fetch_token = function(...) NULL),
    regexp = "application-default",
    class = "wxpipe_error_auth"
  )
})
