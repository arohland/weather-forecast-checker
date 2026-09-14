# The ingestion job and its daily trigger. Both are created only once
# var.job_image points at a pushed image (see README.md, bootstrap step 6).

locals {
  deploy_job = var.job_image != null
}

resource "google_cloud_run_v2_job" "ingest" {
  count = local.deploy_job ? 1 : 0

  name                = "wxpipe-ingest"
  location            = var.region
  deletion_protection = var.deletion_protection

  template {
    task_count = 1

    template {
      service_account = google_service_account.job.email
      timeout         = "3600s"

      # Loads are idempotent, so one retry of a failed attempt is safe.
      max_retries = 1

      containers {
        image = var.job_image
        args  = ["--source=all", "--mode=daily"]

        env {
          name  = "WXPIPE_GCP_PROJECT"
          value = var.project_id
        }
        env {
          name  = "WXPIPE_BQ_DATASET"
          value = google_bigquery_dataset.raw.dataset_id
        }
        env {
          name  = "WXPIPE_GCS_BUCKET"
          value = google_storage_bucket.raw.name
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }
      }
    }
  }

  depends_on = [google_project_service.services]
}

# roles/run.invoker includes run.jobs.run and is documented as grantable on a
# single job, so the scheduler can start this job and nothing else.
resource "google_cloud_run_v2_job_iam_member" "scheduler_invoker" {
  count = local.deploy_job ? 1 : 0

  name     = google_cloud_run_v2_job.ingest[0].name
  location = google_cloud_run_v2_job.ingest[0].location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "daily" {
  count = local.deploy_job ? 1 : 0

  name             = "wxpipe-daily"
  description      = "Starts the wxpipe ingestion job once a day."
  schedule         = var.schedule
  time_zone        = "Etc/UTC"
  region           = var.region
  attempt_deadline = "320s"

  retry_config {
    retry_count = 1
  }

  # Calls the Cloud Run Admin API's jobs.run method, as documented for running
  # jobs on a schedule.
  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.ingest[0].name}:run"

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_invoker]
}
