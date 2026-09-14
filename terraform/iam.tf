# Identities and least-privilege access. Every grant is on the narrowest
# resource that works, and each identity can do exactly one job.

# --- Cloud Run Job (runtime) ------------------------------------------------

resource "google_service_account" "job" {
  account_id   = "wxpipe-job"
  display_name = "wxpipe ingestion job"
}

# Run load and query jobs. BigQuery jobs are a project-level resource; this
# role grants no access to data by itself.
resource "google_project_iam_member" "job_bigquery_jobs" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.job.email}"
}

# Read and write tables, including the short-lived staging tables, in the raw
# dataset only.
resource "google_bigquery_dataset_iam_member" "job_raw_editor" {
  dataset_id = google_bigquery_dataset.raw.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.job.email}"
}

# Create raw payload objects. The job cannot read, overwrite or delete them.
resource "google_storage_bucket_iam_member" "job_raw_writer" {
  bucket = google_storage_bucket.raw.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.job.email}"
}

# --- Cloud Scheduler (trigger) ----------------------------------------------

# Only allowed to start the ingestion job (granted on the job, cloud_run.tf).
resource "google_service_account" "scheduler" {
  account_id   = "wxpipe-scheduler"
  display_name = "wxpipe daily trigger"
}

# --- GitHub Actions (CI) ----------------------------------------------------

# Workload Identity Federation: GitHub's OIDC tokens are exchanged for
# short-lived Google credentials, so no service account key exists anywhere.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.services]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-actions"
  display_name                       = "GitHub Actions OIDC"

  # Tokens from any other repository are rejected outright.
  attribute_condition = "assertion.repository == \"${var.github_repository}\""
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

locals {
  github_principals = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}"
}

# Pushes images from the main branch.
resource "google_service_account" "ci_images" {
  account_id   = "wxpipe-ci-images"
  display_name = "GitHub Actions: push images"
}

resource "google_artifact_registry_repository_iam_member" "ci_images_writer" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.ci_images.email}"
}

resource "google_service_account_iam_member" "ci_images_federation" {
  service_account_id = google_service_account.ci_images.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.github_principals}/attribute.ref/refs/heads/main"
}

# Runs `terraform plan` on pull requests: read-only, and plans run with
# -lock=false so the state bucket is only read.
resource "google_service_account" "ci_plan" {
  account_id   = "wxpipe-ci-plan"
  display_name = "GitHub Actions: terraform plan (read-only)"
}

resource "google_project_iam_member" "ci_plan_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.ci_plan.email}"
}

resource "google_storage_bucket_iam_member" "ci_plan_state_reader" {
  bucket = var.state_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.ci_plan.email}"
}

resource "google_service_account_iam_member" "ci_plan_federation" {
  service_account_id = google_service_account.ci_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.github_principals}/attribute.repository/${var.github_repository}"
}
