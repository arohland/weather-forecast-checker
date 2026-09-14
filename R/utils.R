# Small predicates shared across modules. Named checks keep multi-part
# conditions readable and on one line.

is_whole_number <- function(x) {
  is.numeric(x) && length(x) == 1L && is.finite(x) && x == round(x)
}

is_unique_names <- function(x) {
  is.character(x) && length(x) > 0L && !anyNA(x) && !anyDuplicated(x)
}
