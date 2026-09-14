variable "project_id" {
  description = "Google Cloud project that hosts the pipeline."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run, Cloud Scheduler, Artifact Registry and the raw bucket."
  type        = string
}

variable "bigquery_location" {
  description = "Location of the BigQuery datasets, e.g. the same region."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository (owner/name) allowed to push images and run plans."
  type        = string
}

variable "state_bucket" {
  description = "Name of the Terraform state bucket created during bootstrap."
  type        = string
}

variable "job_image" {
  description = <<-EOT
    Container image of the Cloud Run Job, e.g.
    <region>-docker.pkg.dev/<project>/wxpipe/wxpipe:<git-sha>. Leave null on
    the first apply, before any image has been pushed; the job and its
    schedule are then not created yet.
  EOT
  type        = string
  default     = null
}

variable "schedule" {
  description = "Cron schedule of the daily run, in UTC."
  type        = string
  default     = "30 7 * * *"
}

variable "raw_retention_days" {
  description = "Days to keep raw API payloads in Cloud Storage before deletion."
  type        = number
  default     = 730
}

variable "deletion_protection" {
  description = "Protect the BigQuery tables and the Cloud Run Job from deletion by Terraform."
  type        = bool
  default     = true
}
