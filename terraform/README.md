# Infrastructure

Terraform for everything the ingestion job needs on Google Cloud. Applying is
manual; CI only checks formatting, validates, and plans pull requests.

## What it creates

| Resource | Name | Notes |
|---|---|---|
| APIs | Artifact Registry, BigQuery, Cloud Resource Manager, Cloud Scheduler, IAM, IAM Credentials, Cloud Run, Cloud Storage, STS | Left enabled on destroy |
| BigQuery datasets | `raw`, `staging`, `marts` | `staging` and `marts` stay empty until the dbt phase |
| BigQuery tables | `raw.geosphere_observations`, `raw.openmeteo_forecasts` | Columns, partitioning and clustering read from `inst/schemas/*.yml` |
| Cloud Storage bucket | `<project>-wxpipe-raw` | Raw API payloads; uniform access, public access prevention, deleted after `raw_retention_days` (default 730) |
| Artifact Registry | `wxpipe` (Docker) | Keeps the 10 newest images; deletes untagged images after 7 days, tagged after 90 |
| Cloud Run Job | `wxpipe-ingest` | Created once `job_image` is set; 1 vCPU, 1 GiB, 1 h timeout, 1 retry |
| Cloud Scheduler job | `wxpipe-daily` | Created once `job_image` is set; starts the job daily at 07:30 UTC by default |
| Workload Identity Federation | pool `github`, provider `github-actions` | Accepts GitHub OIDC tokens from `github_repository` only |

## Identities and permissions

Each identity does one job and every role is granted on the narrowest
resource that works. No service account keys exist.

| Identity | Role | Granted on | Why |
|---|---|---|---|
| `wxpipe-job` (Cloud Run Job) | `roles/bigquery.jobUser` | project | Run load and query jobs (grants no data access by itself) |
| | `roles/bigquery.dataEditor` | dataset `raw` | Read and write the raw and staging tables |
| | `roles/storage.objectCreator` | raw bucket | Create raw payload files; cannot read, overwrite or delete them |
| `wxpipe-scheduler` | `roles/run.invoker` | job `wxpipe-ingest` | Start the job (includes `run.jobs.run`) |
| `wxpipe-ci-images` (GitHub Actions) | `roles/artifactregistry.writer` | repository `wxpipe` | Push images |
| | `roles/iam.workloadIdentityUser` | the service account | Only for workflows running on `refs/heads/main` |
| `wxpipe-ci-plan` (GitHub Actions) | `roles/viewer` | project | Read-only `terraform plan` on pull requests |
| | `roles/storage.objectViewer` | state bucket | Read the state (plans run with `-lock=false`) |

## Bootstrap

The job needs an image, and the image registry is created by Terraform, so
the first setup is a two-phase apply. Commands use `europe-west3` and
`YOUR_PROJECT_ID`; replace them with your values.

Prerequisites: a Google Cloud project with billing enabled and Owner access to
it, the [gcloud CLI](https://cloud.google.com/sdk/docs/install), and
Terraform 1.16 or later.

### 1. Authenticate

```bash
gcloud auth login
```

```bash
gcloud auth application-default login
```

```bash
gcloud config set project YOUR_PROJECT_ID
```

Terraform enables APIs through the Service Usage API, which must itself be on:

```bash
gcloud services enable serviceusage.googleapis.com
```

### 2. Create the state bucket

Remote state lives in a versioned bucket that Terraform does not manage
itself (it has to exist before `terraform init`).

```bash
gcloud storage buckets create gs://YOUR_PROJECT_ID-tfstate --location=europe-west3 --uniform-bucket-level-access --public-access-prevention
```

```bash
gcloud storage buckets update gs://YOUR_PROJECT_ID-tfstate --versioning
```

### 3. Configure

Copy `terraform.tfvars.example` to `terraform.tfvars` (gitignored) and fill in
the project, region and state bucket. Leave `job_image` unset for now.

### 4. First apply

```bash
terraform init -backend-config="bucket=YOUR_PROJECT_ID-tfstate"
```

```bash
terraform apply
```

This creates everything except the Cloud Run Job and its schedule.

### 5. Configure GitHub

Set these repository variables (Settings > Secrets and variables > Actions >
Variables), most of them from `terraform output`:

| Variable | Value |
|---|---|
| `GCP_PROJECT_ID` | your project id |
| `GCP_REGION` | `europe-west3` |
| `BIGQUERY_LOCATION` | `europe-west3` |
| `ARTIFACT_REGISTRY_REPOSITORY` | `wxpipe` |
| `TF_STATE_BUCKET` | `YOUR_PROJECT_ID-tfstate` |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | output `github_workload_identity_provider` |
| `GCP_CI_SERVICE_ACCOUNT` | output `github_ci_images_service_account` |
| `GCP_CI_PLAN_SERVICE_ACCOUNT` | output `github_ci_plan_service_account` |

With the GitHub CLI, for example:

```bash
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --body "$(terraform output -raw github_workload_identity_provider)"
```

### 6. Push the first image

Push to `main`: the `docker` workflow builds the image and pushes it as
`europe-west3-docker.pkg.dev/YOUR_PROJECT_ID/wxpipe/wxpipe:<git-sha>`.

### 7. Second apply

Set `job_image` in `terraform.tfvars` to that image, then:

```bash
terraform apply
```

This creates the Cloud Run Job and the daily Cloud Scheduler trigger.

### 8. Smoke test

A dry run fetches and parses everything but writes nothing:

```bash
gcloud run jobs execute wxpipe-ingest --region=europe-west3 --args=--dry-run --wait
```

Logs appear in Cloud Logging as structured entries, grouped by run id.

## Operating

Backfills run as one-off executions with overridden arguments. Open-Meteo's
Previous Runs archive starts in February 2024 and its Single Runs archive in
April 2026 (see `inst/config/sources.yml`); model runs from before their
archive are skipped with a warning. Keep each execution within the Open-Meteo
call budget (`daily_call_budget`), e.g. a few months per run:

```bash
gcloud run jobs execute wxpipe-ingest --region=europe-west3 --args=--source=openmeteo,--mode=backfill,--start-date=2024-02-04,--end-date=2024-05-31 --wait
```

```bash
gcloud run jobs execute wxpipe-ingest --region=europe-west3 --args=--source=geosphere,--mode=backfill,--start-date=2000-01-01,--end-date=2026-09-13 --wait
```

Loads are idempotent, so re-running any execution is safe.

To deploy a new image, update `job_image` and run `terraform apply`.
