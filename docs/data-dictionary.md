# Data dictionary

<!-- GENERATED from inst/schemas/*.yml by scripts/generate_data_dictionary.R. Do not edit by hand; CI fails if this file is out of date. -->

Conventions that apply to every table:

- All `TIMESTAMP` columns are UTC. Local calendar dates are separate `DATE`
  columns derived with the location's time zone (`Europe/Vienna` for Salzburg).
- Columns starting with `_` are ingestion metadata, identical in meaning
  across tables.
- `NULL` means the source delivered no value. Rows are never dropped because
  a value is missing, and values are stored as delivered (no unit
  conversion, no decoding of sentinel values).

## Tables

- [`raw.geosphere_observations`](#rawgeosphere_observations)
- [`raw.openmeteo_forecasts`](#rawopenmeteo_forecasts)

## `raw.geosphere_observations`

Daily station observations from the GeoSphere Austria Data Hub dataset klima-v2-1d, in long format: one row per location, station, parameter and day. Values, units and quality flags are stored exactly as the API delivers them. IMPORTANT: GeoSphere's "day" is not the local calendar day, and it differs per parameter (e.g. temperature extremes run 18:10 UTC to 18:00 UTC, precipitation 06:01 UTC to 06:00 UTC of the following day). The window of each parameter is documented in the value catalogue below. Compare with forecasts only after aggregating the forecast over the same window.

**Grain (one row per):** `location_id`, `station_id`, `parameter`, `reference_time`

**Load strategy:** Idempotent replace. For each fetched location, station and date range, the loader deletes the existing rows in that range and inserts the new rows in one transaction, so re-running a range never duplicates rows. The daily run re-fetches the trailing `revision_window_days` (see inst/config/sources.yml), which picks up values GeoSphere revises after first publication (quality flags move from automatically to manually checked).

### Partitioning and clustering

- **Partitioned** by `reference_time` (MONTH): About ten rows per station per day, but the station record reaches back to 1939. Daily partitions would be tiny, and a full backfill would exceed BigQuery's limit of 10,000 partitions per table. Google recommends monthly or yearly partitioning when a table has little data per day over a wide date range, combined with clustering on the partitioning column. A revision-window reload still touches only one or two monthly partitions.
- **Clustered** by `location_id`, `parameter`, `reference_time`: Analyses and reloads filter by location and parameter; clustering on reference_time as well orders rows within each monthly partition, as recommended for coarse partitioning.

### Columns

| Column | Type | Nullable | Unit | Source | Description |
|---|---|---|---|---|---|
| `location_id` | STRING | no |  | Configuration: key under `locations` in inst/config/sources.yml. | Pipeline identifier of the location (e.g. salzburg-airport). Joins observations to forecasts for the same place. |
| `station_id` | INT64 | no |  | API: `features[].properties.station`. | GeoSphere climate station id (6300 = Salzburg Flughafen, the physical station; GeoSphere also publishes a homogenised composite as id 131, which is not used). |
| `resource_id` | STRING | no |  | Configuration: `sources.geosphere.resource_id`; the API path segment. | GeoSphere dataset the values come from (klima-v2-1d). |
| `parameter` | STRING | no |  | API: key of `features[].properties.parameters`. | GeoSphere parameter name. Each parameter has its own unit and daily aggregation window; see "Values of parameter" below. |
| `reference_time` | TIMESTAMP | no |  | API: `timestamps[]` (e.g. 2026-09-08T00:00+00:00). | The timestamp GeoSphere attaches to the daily value: always 00:00 UTC of the day label. It is a label, not the measurement period, which depends on the parameter. |
| `reference_date_local` | DATE | no |  | Derived: calendar date of reference_time in the location's time zone (Europe/Vienna). | Local calendar date of the label. Because labels are 00:00 UTC (01:00 or 02:00 in Vienna), this equals the UTC date; it does NOT mean the value covers that local day. |
| `value` | FLOAT64 | yes | see unit column | API: `features[].properties.parameters.<parameter>.data[]`. | Value as delivered, including documented sentinel codes (e.g. rr = -1 means no precipitation, sh = -1 means no snow). NULL when GeoSphere has no value yet (typically the current day) or none at all. |
| `quality_flag` | INT64 | yes |  | API: `features[].properties.parameters.<parameter>_flag.data[]` (code list q21). | GeoSphere quality code: 0 unchecked; 10 automatically checked; 11 automatically checked, changed; 12 automatically checked, original; 20 manually checked, unknown; 21 manually checked, changed; 22 manually checked, original. NULL means undefined. |
| `unit` | STRING | no |  | API: `features[].properties.parameters.<parameter>.unit`. | Unit of value, as reported by the API for this parameter. |
| `_ingested_at` | TIMESTAMP | no |  | Pipeline: time the load started. | When this row was written to BigQuery. |
| `_source_url` | STRING | no |  | Pipeline: the exact request URL. | API request that returned this row's payload. |
| `_payload_sha256` | STRING | no |  | Pipeline: SHA-256 of the unmodified response body. | Hex SHA-256 of the raw response landed in GCS before parsing; identifies the exact payload a row was parsed from, for replay and auditing. |
| `_pipeline_run_id` | STRING | no |  | Pipeline: identifier of the ingestion run. | Execution that loaded the row; also the file name of the raw payload in GCS (`raw/source=<source>/dt=<date>/<run_id>.json.gz`). |
| `_pipeline_version` | STRING | no |  | Pipeline: wxpipe package version plus git commit. | Code version that produced the row (e.g. 0.1.0+0123abc). |

### Values of `parameter`

| Value | Unit | Description | Source documentation |
|---|---|---|---|
| `tlmax` | °C | Daily maximum air temperature at 2 m: maximum of 10-minute values from 18:10 UTC on the previous day to 18:00 UTC on the labelled day. | Lufttemperatur in 2m Höhe, Maximum der Zehnminutenwerte (tlmax) von 18:10 UTC Vortag - 18:00 UTC aktueller Tag |
| `tlmin` | °C | Daily minimum air temperature at 2 m: minimum of 10-minute values from 18:10 UTC on the previous day to 18:00 UTC on the labelled day. | Lufttemperatur in 2m Höhe, Minimum der Zehnminutenwerte (tlmin) von 18:10 UTC Vortag - 18:00 UTC aktueller Tag |
| `tl_mittel` | °C | Daily mean air temperature at 2 m, defined as (tlmax + tlmin) / 2, not as the mean of all readings. | Lufttemperatur in 2m Höhe, Mittelwert berechnet aus (tlmax + tlmin)/2 |
| `rr` | mm | 24-hour precipitation total of 1-minute values from 06:01 UTC on the labelled day to 06:00 UTC on the following day. Sentinels: -1 = no precipitation, 0 = less than 0.1 mm. | Niederschlag, 24-Stundensumme der Einminutenwerte von 06:01 UTC bis 06:00 UTC des Folgetags, -1=kein Niederschlag, 0=weniger als 1/10 mm |
| `so_h` | h | Sunshine duration: sum of hourly values over 0-24 h mean local time (MOZ), which GeoSphere states as 23:00 UTC on the previous day to 23:00 UTC on the labelled day. | Sonnenscheindauer, Summe aus den Stundenwerten 0-24 Uhr MOZ (23 Vortag - 23 Tag UTC) |
| `ffx` | m/s | Peak gust: daily maximum wind speed from hourly values over 0-24 h mean local time (MOZ), i.e. 23:00 UTC on the previous day to 23:00 UTC on the labelled day. | Windgeschwindigkeit, Tagesmaximum aus den Stundenwerten 0-24 Uhr MOZ (23 Vortag - 23 Tag UTC) |
| `vv_mittel` | m/s | Daily mean wind speed: mean of the three observation terms at 06, 13 and 18 UTC. | Windgeschwindigkeit, Tagesmittel aus den Beobachtungsterminen I,II,III (06,13,18 UTC) |
| `p_mittel` | hPa | Daily mean air pressure: mean of the observation terms at 06, 13 and 18 UTC. The metadata does not state whether this is station-level or reduced pressure. | Luftdruck, Tagesmittel aus den Beobachtungsterminen I,II,III (06,13,18 UTC) |
| `rf_mittel` | % | Daily mean relative humidity: mean of the observation terms at 06, 13 and 18 UTC. | Relative Feuchte, Tagesmittel aus den Beobachtungsterminen I,II,III (06,13,18 UTC) |
| `sh` | cm | Total snow depth from the automatic snow gauge (offset-corrected) at the 06 UTC observation term. Sentinel: -1 = no snow. | Gesamtschneehöhe, aus automatischer Schneepegelmessung, Offset korrigiert, zum Beobachtungstermin I (06 UTC), -1=kein Schnee |

## `raw.openmeteo_forecasts`

Hourly numerical weather forecasts from Open-Meteo for each configured location, in long format: one row per forecast statement, variable and valid hour. A forecast is a statement made at a time about a time, so the same valid hour appears many times: once per daily snapshot, per model run and per lead time. Three sources are stored side by side and distinguished by forecast_source. "forecast" is the current, continuously stitched forecast (no run time published). "previous_runs" holds values archived at fixed lead times of 1-7 days. "single_runs" holds the full output of one model run. Only single_runs report when the forecast was issued; issued_at is NULL for the other sources rather than estimated.

**Grain (one row per):** `location_id`, `model`, `forecast_source`, `issued_at`, `lead_time_days`, `retrieved_at`, `valid_time`, `variable`

**Load strategy:** Append-only: stored forecasts are never updated or overwritten by valid time, because the history of statements about the same hour is exactly what a skill-versus-lead-time analysis needs. Reloads are idempotent through a scoped delete-and-insert in one transaction that replaces only rows of the same statements. For "forecast", that is the same location, model and UTC retrieval date (one snapshot per day). For "previous_runs", the same location and model within the fetched valid-time range (archived values do not change). For "single_runs", the same location, model and issued_at (one run).

### Partitioning and clustering

- **Partitioned** by `valid_time` (MONTH): Roughly 17,000 rows per location per day (a 16-day snapshot, four 16-day runs, seven previous-run offsets): megabytes per month, far below the roughly 10 GB per partition from which Google suggests partitioning pays off. The data spans more than 500 dates (from February 2024 plus 16 days ahead), the case for which Google recommends monthly partitioning with clustering on the partitioning column. valid_time is the dimension every skill analysis and observation join filters on; a reload's rows span at most two monthly partitions.
- **Clustered** by `location_id`, `forecast_source`, `variable`, `valid_time`: Analyses and reloads filter by location, source and variable. Clustering on valid_time as well orders rows within each monthly partition, as recommended for coarse partitioning. Four is BigQuery's maximum.

### Columns

| Column | Type | Nullable | Unit | Source | Description |
|---|---|---|---|---|---|
| `location_id` | STRING | no |  | Configuration: key under `locations` in inst/config/sources.yml. | Pipeline identifier of the location (e.g. salzburg-airport); the request uses the location's latitude and longitude. |
| `model` | STRING | no |  | Configuration: `sources.openmeteo.model`; sent as the `models` request parameter. | Open-Meteo model id. geosphere_seamless is GeoSphere AROME Austria (2.5 km, about 2.5 days) continued with ECMWF IFS. |
| `forecast_source` | STRING | no |  | Pipeline: which Open-Meteo API returned the row. | forecast = Forecast API (current stitched forecast); previous_runs = Previous Runs API (fixed lead-time offsets); single_runs = Single Runs API (one complete model run). |
| `issued_at` | TIMESTAMP | yes |  | Request: the `run` parameter of the Single Runs API. | Model initialisation time, i.e. when the forecast statement was made. Only known for single_runs; NULL for the other sources, whose APIs do not report it. |
| `lead_time_days` | INT64 | yes |  | API: N in the response column `<variable>_previous_dayN`. | Previous Runs offset: the value was predicted N x 24 hours before valid_time. NULL for the other sources. |
| `lead_time_hours` | INT64 | yes |  | Derived: valid_time minus issued_at, in hours. | Exact lead time of a single_runs value (0 = the run's first hour). NULL for the other sources, where issued_at is unknown. |
| `retrieved_at` | TIMESTAMP | no |  | Pipeline: time the API response was received. | When the pipeline fetched the statement. For forecast rows this is the best available indication of when the forecast was current. |
| `valid_time` | TIMESTAMP | no |  | API: `hourly.time[]` (Unix seconds, requested with timeformat=unixtime). | Hour the value is valid for. For instantaneous variables it is the moment itself; for aggregated variables it is the end of the preceding hour the value covers (see "Values of variable"). |
| `valid_date_local` | DATE | no |  | Derived: calendar date of valid_time in the location's time zone (Europe/Vienna). | Local calendar date of valid_time. Aggregating to GeoSphere's daily windows must use valid_time, not this column, because those windows do not follow local days. |
| `variable` | STRING | no |  | API: response column name, without any `_previous_dayN` suffix. | Open-Meteo hourly variable; see "Values of variable" below. |
| `value` | FLOAT64 | yes | see unit column | API: `hourly.<column>[]`. | Forecast value as delivered. NULL where the API has none; for example, the Previous Runs archive has no lead-time values for snow_depth and gusts only at lead day 1. |
| `unit` | STRING | no |  | API: `hourly_units.<column>`. | Unit of value, as reported by the API. |
| `_ingested_at` | TIMESTAMP | no |  | Pipeline: time the load started. | When this row was written to BigQuery. |
| `_source_url` | STRING | no |  | Pipeline: the exact request URL. | API request that returned this row's payload. |
| `_payload_sha256` | STRING | no |  | Pipeline: SHA-256 of the unmodified response body. | Hex SHA-256 of the raw response landed in GCS before parsing; identifies the exact payload a row was parsed from, for replay and auditing. |
| `_pipeline_run_id` | STRING | no |  | Pipeline: identifier of the ingestion run. | Execution that loaded the row; also the file name of the raw payload in GCS (`raw/source=<source>/dt=<date>/<run_id>.json.gz`). |
| `_pipeline_version` | STRING | no |  | Pipeline: wxpipe package version plus git commit. | Code version that produced the row (e.g. 0.1.0+0123abc). |

### Values of `variable`

| Value | Unit | Description | Source documentation |
|---|---|---|---|
| `temperature_2m` | °C | Air temperature at 2 m above ground; instantaneous value at valid_time. | Open-Meteo hourly docs: valid time Instant. |
| `precipitation` | mm | Total precipitation (rain, showers, snow) summed over the hour ending at valid_time. | Open-Meteo hourly docs: valid time Preceding hour sum. |
| `sunshine_duration` | s | Seconds of sunshine (WMO definition: direct normal irradiance above 120 W/m²). NOT CONFIRMED: the hourly documentation table does not list this variable; by analogy with its 15-minutely definition (sum over the preceding 15 minutes) the hourly value is taken to cover the hour ending at valid_time. Verify before aggregating to GeoSphere's so_h window. | Open-Meteo docs: 15-minutely table Preceding 15 minutes sum; daily table gives the WMO definition. Not in the hourly table. |
| `wind_gusts_10m` | m/s | Maximum wind gust at 10 m during the hour ending at valid_time (requested in m/s). | Open-Meteo hourly docs: valid time Preceding hour max. |
| `wind_speed_10m` | m/s | Wind speed at 10 m; instantaneous value (requested in m/s). | Open-Meteo hourly docs: valid time Instant. |
| `surface_pressure` | hPa | Atmospheric pressure at the model surface (not reduced to sea level); instantaneous value. | Open-Meteo hourly docs: valid time Instant. |
| `relative_humidity_2m` | % | Relative humidity at 2 m above ground; instantaneous value. | Open-Meteo hourly docs: valid time Instant. |
| `snow_depth` | m | Snow depth on the ground in metres (GeoSphere's sh is in centimetres); instantaneous value. | Open-Meteo hourly docs: valid time Instant, unit meters. |
