# 0007. Choose GeoSphere klima-v2-1d station 6300 and Open-Meteo's GeoSphere seamless model

- Status: Accepted
- Date: 2026-09-14

## Context

The identifiers of the data are not guessed; they were discovered from the
APIs on 2026-09-14 and then reviewed.

**Observations.** GeoSphere's dataset list offers two daily climate datasets.
`klima-v1-1d` ends on 2024-09-01; `klima-v2-1d` is maintained. Its station
metadata lists Salzburg Airport twice: id `6300` (type INDIVIDUAL, the
physical station, from 1939) and id `131` (type COMBINED, a composite series
from 1874). Their recent values are identical.

**Forecasts.** Open-Meteo offers GeoSphere's AROME Austria model (2.5 km,
about 2.5 days ahead) and `geosphere_seamless`, which its documentation
describes as "GeoSphere Seamless (with ECMWF)". Live probes showed:

- Previous Runs archive: AROME fills only lead day 1; the seamless model
  fills lead days 1 to 7.
- Forecast API: AROME covers 2 of 7 days; the seamless model all 7.
- Archives: Previous Runs data for the seamless model starts on 2024-02-04
  (later for some variables); Single Runs start on 2026-04-02.

## Decision

- Observations come from `klima-v2-1d`, station `6300`.
- Forecasts are stored for one model, `geosphere_seamless`, only. A separate
  AROME series and Open-Meteo's generic `best_match` blend are not stored.
- Forecasts are requested for the station's own coordinates.
- A backfill that starts before the Previous Runs archive is refused. Model
  runs before the Single Runs archive are left out of the plan and reported
  as a warning, so that a Previous Runs history can still be backfilled.

All identifiers, limits and archive dates live in `inst/config/sources.yml`,
each with a comment on when and how it was determined.

## Consequences

- Lead times 1 to 7 days can be analysed from February 2024 onwards, and
  complete model runs from April 2026 onwards.
- The seamless model blends AROME with ECMWF, so skill at short lead times
  reflects AROME and at longer lead times ECMWF; the pure AROME series is not
  available for comparison.
- Some variables have gaps in the Previous Runs archive (no lead-time
  archive for `snow_depth`, gusts only at lead day 1); they appear as `NULL`.
- Two comparability questions remain open and are marked in the data
  dictionary: the aggregation period of Open-Meteo's hourly
  `sunshine_duration`, and the pressure level of GeoSphere's `p_mittel`.
