terraform {
  required_version = ">= 1.16.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.2"
    }
  }

  # Remote state in Cloud Storage. The state bucket is created once by hand
  # (see README.md) and passed at init time, because backend blocks cannot
  # use variables:
  #   terraform init -backend-config="bucket=<state-bucket>"
  backend "gcs" {
    prefix = "wxpipe"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
