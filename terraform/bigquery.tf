locals {
  # Type names as used in BigQuery API table schemas.
  bigquery_api_types = {
    STRING    = "STRING"
    INT64     = "INTEGER"
    FLOAT64   = "FLOAT"
    BOOL      = "BOOLEAN"
    DATE      = "DATE"
    TIMESTAMP = "TIMESTAMP"
  }

  # Table definitions come from the same schema files the R package validates
  # rows against and generates docs/data-dictionary.md from, so the tables,
  # the loader and the documentation cannot disagree.
  raw_tables = {
    for table in ["geosphere_observations", "openmeteo_forecasts"] :
    table => yamldecode(file("${path.module}/../inst/schemas/${table}.yml"))
  }
}

resource "google_bigquery_dataset" "raw" {
  dataset_id  = "raw"
  location    = var.bigquery_location
  description = "Ingestion tables loaded by wxpipe; see docs/data-dictionary.md."

  depends_on = [google_project_service.services]
}

# Empty for now; populated by the dbt project in a later phase.
resource "google_bigquery_dataset" "staging" {
  dataset_id  = "staging"
  location    = var.bigquery_location
  description = "dbt staging models (later phase)."

  depends_on = [google_project_service.services]
}

resource "google_bigquery_dataset" "marts" {
  dataset_id  = "marts"
  location    = var.bigquery_location
  description = "dbt marts (later phase)."

  depends_on = [google_project_service.services]
}

resource "google_bigquery_table" "raw" {
  for_each = local.raw_tables

  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = each.key
  description         = trimspace(each.value.description)
  deletion_protection = var.deletion_protection
  clustering          = each.value.clustering.columns

  time_partitioning {
    type  = each.value.partitioning.granularity
    field = each.value.partitioning.column
  }

  schema = jsonencode([
    for column in each.value.columns : {
      name        = column.name
      type        = local.bigquery_api_types[column.type]
      mode        = column.mode
      description = substr(trimspace(replace(column.description, "/\\s+/", " ")), 0, 1024)
    }
  ])
}
