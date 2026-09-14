# 0004. Store all timestamps in UTC

- Status: Accepted
- Date: 2026-09-14

## Context

The pipeline combines two sources with different time conventions for a
location that observes daylight saving time (`Europe/Vienna`: UTC+1 in
winter, UTC+2 in summer):

- GeoSphere labels each daily value with a timestamp at 00:00 UTC, but the
  period a value covers depends on the parameter: 18:10 to 18:00 UTC for
  temperature extremes, 06:01 UTC to 06:00 UTC of the next day for
  precipitation, and 23:00 to 23:00 UTC for sunshine and peak gusts.
- Open-Meteo can return times in any requested time zone, as local
  wall-clock strings without an offset.

A local wall-clock time without an offset is ambiguous once a year (the
autumn DST change repeats an hour), and a "day" means different periods to
each source.

## Decision

- Every `TIMESTAMP` column holds UTC. Open-Meteo is requested with
  `timezone=GMT&timeformat=unixtime`, so no local time is ever parsed.
- The timestamp parser accepts only ISO 8601 values with an explicit offset
  and rejects anything else instead of assuming a zone.
- Local calendar dates are separate, derived `DATE` columns
  (`reference_date_local`, `valid_date_local`), computed with the location's
  configured time zone.
- The data dictionary documents each GeoSphere parameter's aggregation window
  in the API's own words, and states that GeoSphere's daily labels are not
  local days.

## Consequences

- Stored times are unambiguous and daylight saving time cannot corrupt them;
  the conversion is tested across both DST transitions.
- Consumers convert to local time for display. The local date columns are a
  convenience, not a measurement window: comparing forecasts with
  observations must aggregate `valid_time` over each parameter's UTC window.
- Adding a location in another time zone only requires its `timezone` in the
  configuration.
