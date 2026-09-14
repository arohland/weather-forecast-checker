# Raw API payloads, landed before parsing so that a parsing bug can be fixed
# and the data replayed without calling the APIs again.
resource "google_storage_bucket" "raw" {
  name     = "${var.project_id}-wxpipe-raw"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Payloads are only needed for replays; they are deleted after the
  # retention period to keep storage bounded.
  lifecycle_rule {
    condition {
      age = var.raw_retention_days
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.services]
}
