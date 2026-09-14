output "raw_bucket" {
  description = "Raw payload landing bucket (WXPIPE_GCS_BUCKET)."
  value       = google_storage_bucket.raw.name
}

output "raw_dataset" {
  description = "BigQuery dataset of the raw tables (WXPIPE_BQ_DATASET)."
  value       = google_bigquery_dataset.raw.dataset_id
}

output "image_repository" {
  description = "Artifact Registry path to push images to."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/wxpipe"
}

output "job_service_account" {
  description = "Runtime service account of the Cloud Run Job."
  value       = google_service_account.job.email
}

output "job_name" {
  description = "Cloud Run Job name, once created."
  value       = local.deploy_job ? google_cloud_run_v2_job.ingest[0].name : null
}

output "github_workload_identity_provider" {
  description = "GitHub variable GCP_WORKLOAD_IDENTITY_PROVIDER."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_ci_images_service_account" {
  description = "GitHub variable GCP_CI_SERVICE_ACCOUNT (docker workflow)."
  value       = google_service_account.ci_images.email
}

output "github_ci_plan_service_account" {
  description = "GitHub variable GCP_CI_PLAN_SERVICE_ACCOUNT (terraform workflow)."
  value       = google_service_account.ci_plan.email
}
