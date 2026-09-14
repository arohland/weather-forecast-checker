resource "google_artifact_registry_repository" "images" {
  repository_id = "wxpipe"
  location      = var.region
  format        = "DOCKER"
  description   = "Container images of the wxpipe ingestion job."

  # Images are tagged with the commit they were built from. The ten most
  # recent versions are always kept; untagged images are deleted after a week
  # and tagged ones after 90 days.
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "7d"
    }
  }
  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      tag_state  = "TAGGED"
      older_than = "90d"
    }
  }

  depends_on = [google_project_service.services]
}
