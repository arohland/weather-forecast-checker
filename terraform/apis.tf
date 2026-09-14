locals {
  services = [
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ]
}

# Keep APIs enabled on destroy: disabling them can break unrelated resources
# in the same project.
resource "google_project_service" "services" {
  for_each = toset(local.services)

  service            = each.value
  disable_on_destroy = false
}
