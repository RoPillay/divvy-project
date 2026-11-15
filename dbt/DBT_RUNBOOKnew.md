# dbt on Snowflake Runbook (v2: all models)

This guide builds the full dbt project for the Divvy stockout and rebalancing pipeline: every staging, intermediate, and mart model, plus tests. It runs as **dbt Projects on Snowflake**, inside the team's Git-connected Workspace.

```
BRONZE / RAW          SILVER / staging        SILVER+ / intermediate          GOLD / marts
DIVVY.RAW.*     →     stg_station_status  →   int_station_status_intervals →  fct_station_snapshots
                      stg_station_information int_station_distance_to_l       fct_stockout_events
                      stg_trips               int_station_crosswalk           fct_rebalancing_events
                      stg_weather                                             dim_station
                      stg_cta_l_stations                                      dim_time
                                                                              dim_weather
```

| Setting | Value |
|---|---|
| Workspace | Git-connected workspace for `RoPillay/divvy-project` |
| dbt project folder | `dbt/divvy/` |
| Role / warehouse / database | `DIVVY_ENGINEER` / `DIVVY_WH` / `DIVVY` |
| Dev schemas | `DIVVY.DEV_STAGING`, `DEV_INTERMEDIATE`, `DEV_MARTS` |
| Prod schemas | `DIVVY.PROD_STAGING`, `PROD_INTERMEDIATE`, `PROD_MARTS` |

---

## Before you start

**1. Remove sensitive files from the repo.** `reset pass (sona).sql` sits at the root of the Git workspace. Delete it, or move it to a private worksheet outside the Git workspace. If it was already pushed and contains a real password, change that password now. Deleting a file doesn't remove it from Git's history.

**2. Turn on secondary roles** if dbt run controls don't appear in the Workspace. Run this once per person, then sign out and back in:

```sql
SET me = CURRENT_USER();
ALTER USER IDENTIFIER($me) SET DEFAULT_SECONDARY_ROLES = ('ALL');
```

**3. Refresh the weather data for the live weeks.** The weather files currently stop at October 28, so hours after that won't have weather. Rerun the 2026 download on your Mac with a later end date, using a **new file name** so Snowflake loads it as a new file. For example:

```bash
cd ~/divvy_weather
curl -sf --max-time 120 "https://archive-api.open-meteo.com/v1/archive?latitude=41.8781&longitude=-87.6298&start_date=2026-01-01&end_date=2026-11-12&hourly=temperature_2m,precipitation,rain,snowfall,wind_speed_10m,wind_direction_10m,weather_code&timezone=UTC" -o weather_2026_thru_1112.json
gcloud storage cp weather_2026_thru_1112.json gs://divvy-raw-srv/historical/weather/ --project=divvy-project-512716
```

Then load it in Snowflake with the same `COPY INTO WEATHER_RAW` from the Snowflake runbook, Step 10b. `stg_weather` keeps the most recently loaded value for each hour, so overlapping files are fine.

**4. Agree on the definitions.** These are set as variables in `dbt_project.yml` (Step 1), so changing one later is a one-line edit:

| Variable | Default | Meaning |
|---|---|---|
| `stockout_min_minutes` | 5 | An empty or full stretch must last at least this long to count as a stockout |
| `stale_minutes` | 30 | A report lasting longer than this without an update is flagged as stale (the station may be offline) |
| `near_l_km` | 0.4 | Within 400 m of an L station counts as "near the L" |
| `rebalance_min_jump` | 5 | A change of at least this many bikes... |
| `rebalance_max_minutes` | 10 | ...within this many minutes is flagged as likely rebalancing |
| `wet_precip_mm` | 0.1 | Hourly precipitation at or above this counts as wet |

**Station states**, as used throughout:
- `out_of_service`: not installed, or neither renting nor returning
- `empty`: `bikes_available = 0` while renting
- `full`: `docks_available = 0` while returning
- `ok`: everything else

`bikes_available` already includes e-bikes and excludes disabled bikes.

---

## Final file tree

```
dbt/divvy/
├── dbt_project.yml
├── profiles.yml
├── .gitignore
├── models/
│   ├── staging/
│   │   ├── _sources.yml
│   │   ├── _staging.yml
│   │   ├── stg_station_status.sql
│   │   ├── stg_station_information.sql
│   │   ├── stg_trips.sql
│   │   ├── stg_weather.sql
│   │   └── stg_cta_l_stations.sql
│   ├── intermediate/
│   │   ├── _intermediate.yml
│   │   ├── int_station_status_intervals.sql
│   │   ├── int_station_distance_to_l.sql
│   │   └── int_station_crosswalk.sql
│   └── marts/
│       ├── _marts.yml
│       ├── dim_station.sql
│       ├── dim_time.sql
│       ├── dim_weather.sql
│       ├── fct_station_snapshots.sql
│       ├── fct_stockout_events.sql
│       └── fct_rebalancing_events.sql
└── tests/
    ├── assert_no_negative_counts.sql
    ├── assert_station_report_unique.sql
    ├── assert_trip_file_month_matches.sql
    └── assert_stockout_end_after_start.sql
```

Delete the `temp.txt` placeholders once the real files are in place.

---

## Step 1: Project settings

### `dbt_project.yml` (replace the existing one)

Adds the definition variables. Everything else is the same as before.

```yaml
name: 'divvy'
version: '1.0.0'
config-version: 2

profile: 'divvy'

model-paths: ["models"]
test-paths: ["tests"]
macro-paths: ["macros"]
target-path: "target"
clean-targets: ["target", "dbt_packages"]

vars:
  stockout_min_minutes: 5
  stale_minutes: 30
  near_l_km: 0.4
  rebalance_min_jump: 5
  rebalance_max_minutes: 10
  wet_precip_mm: 0.1

models:
  divvy:
    staging:
      +materialized: view
      +schema: staging
    intermediate:
      +materialized: table
      +schema: intermediate
    marts:
      +materialized: table
      +schema: marts
```

### `profiles.yml` (one person runs dbt, so there are two targets)

```yaml
divvy:
  target: dev
  outputs:
    dev:
      type: snowflake
      account: 'not needed'
      user: 'not needed'
      role: DIVVY_ENGINEER
      database: DIVVY
      warehouse: DIVVY_WH
      schema: DEV
      threads: 8

    prod:
      type: snowflake
      account: 'not needed'
      user: 'not needed'
      role: DIVVY_ENGINEER
      database: DIVVY
      warehouse: DIVVY_WH
      schema: PROD
      threads: 8
```

### `.gitignore`

```
target/
dbt_packages/
logs/
```

---

## Step 2: Staging models (silver)

Staging models do the same job for each source: clean it, type it, and produce one row per real-world thing. They don't contain business logic. That lives in the intermediate layer.

### `models/staging/_sources.yml`

```yaml
version: 2

sources:
  - name: raw
    database: DIVVY
    schema: RAW
    tables:
      - name: station_status_raw
        description: One row per poller file; RAW holds the full GBFS station_status snapshot (~2,000 stations).
      - name: station_information_raw
        description: One row per daily station_information snapshot.
      - name: divvy_trips_raw
        description: Divvy monthly trip files, 2020-04 onward, all columns as text.
      - name: weather_raw
        description: Open-Meteo hourly archive, one row per downloaded file.
      - name: cta_stops_raw
        description: CTA GTFS stops.txt, all columns as text.
```

### `models/staging/stg_station_status.sql`

**What it does:** flattens each poller file into one row per station per distinct report, types every field, and removes repeated readings.

**What's new: incremental.** The first run processes every file. After that, each run only processes files that arrived since the last run, and merges them in on the station and report-time pair. This keeps hourly runs cheap as the data grows. To rebuild from scratch, run with `--full-refresh`.

```sql
{{ config(
    materialized='incremental',
    unique_key=['station_id', 'last_reported_at'],
    incremental_strategy='merge'
) }}

with snapshots as (

    select
        r.file_name,
        r.file_last_modified                              as polled_at,
        s.value                                           as st
    from {{ source('raw', 'station_status_raw') }} r,
         lateral flatten(input => r.raw:data:stations) s
    {% if is_incremental() %}
    where r.file_last_modified > (select max(polled_at) from {{ this }})
    {% endif %}

),

parsed as (

    select
        st:station_id::string                             as station_id,
        to_timestamp_ntz(st:last_reported::int)           as last_reported_at,
        polled_at,
        file_name,

        st:num_bikes_available::int                       as bikes_available,
        st:num_ebikes_available::int                      as ebikes_available,
        st:num_bikes_disabled::int                        as bikes_disabled,
        st:num_docks_available::int                       as docks_available,
        st:num_docks_disabled::int                        as docks_disabled,

        coalesce(st:is_installed::int, 1) = 1             as is_installed,
        coalesce(st:is_renting::int,   1) = 1             as is_renting,
        coalesce(st:is_returning::int, 1) = 1             as is_returning

    from snapshots
    where st:station_id is not null
      and st:last_reported is not null

)

select *
from parsed
-- keep the first poll that saw each distinct station report
qualify row_number() over (
    partition by station_id, last_reported_at
    order by polled_at
) = 1
```

All timestamps are UTC, stored without a time zone. `last_reported` is in Unix seconds, which are UTC, and the GCS file times are UTC. `dim_time` converts to Chicago time.

### `models/staging/stg_station_information.sql`

**What it does:** keeps the latest details for every station ever seen: name, `short_name`, location, and capacity. It also records when each station was first and last seen, and flags racks and corrals, which have no docks.

```sql
with snaps as (

    select
        r.file_last_modified                              as snapshot_at,
        s.value                                           as st
    from {{ source('raw', 'station_information_raw') }} r,
         lateral flatten(input => r.raw:data:stations) s

),

parsed as (

    select
        st:station_id::string                             as station_id,
        st:short_name::string                             as short_name,
        trim(st:name::string)                             as station_name,
        st:lat::float                                     as lat,
        st:lon::float                                     as lon,
        st:capacity::int                                  as capacity,
        st:region_id::string                              as region_id,
        st:is_virtual_station::boolean                    as is_virtual_station,
        snapshot_at
    from snaps
    where st:station_id is not null

),

latest as (

    select
        *,
        min(snapshot_at) over (partition by station_id)   as first_seen_at,
        max(snapshot_at) over (partition by station_id)   as last_seen_at
    from parsed
    qualify row_number() over (partition by station_id order by snapshot_at desc) = 1

)

select
    station_id,
    short_name,
    station_name,
    lat,
    lon,
    capacity,
    region_id,
    first_seen_at,
    last_seen_at,
    (
        station_name ilike '%public rack%'
        or station_name ilike '%corral%'
        or coalesce(is_virtual_station, false)
        or coalesce(capacity, 0) = 0
    )                                                     as is_rack_or_corral
from latest
```

If `is_virtual_station` doesn't exist in Divvy's feed, it comes back null, and the name and capacity checks still catch racks and corrals.

### `models/staging/stg_trips.sql`

**What it does:**
- converts the text columns to real types
- converts trip times from Chicago local time to UTC, to match the live data
- flags trips that start or end away from any station
- reads each file's month from its name, used by the mislabeled-file test
- removes duplicate rides

It's a table, because it holds tens of millions of rows and several models read from it.

```sql
{{ config(materialized='table') }}

with src as (

    select * from {{ source('raw', 'divvy_trips_raw') }}

),

typed as (

    select
        ride_id,
        rideable_type,
        try_to_timestamp_ntz(started_at)                  as started_at_local,
        try_to_timestamp_ntz(ended_at)                    as ended_at_local,
        nullif(trim(start_station_id), '')                as start_station_id,
        nullif(trim(start_station_name), '')              as start_station_name,
        nullif(trim(end_station_id), '')                  as end_station_id,
        nullif(trim(end_station_name), '')                as end_station_name,
        try_to_double(start_lat)                          as start_lat,
        try_to_double(start_lng)                          as start_lng,
        try_to_double(end_lat)                            as end_lat,
        try_to_double(end_lng)                            as end_lng,
        member_casual,
        file_name,
        to_date(regexp_substr(file_name, '([0-9]{6})-divvy', 1, 1, 'e', 1), 'YYYYMM') as file_month
    from src
    where ride_id is not null

)

select
    *,
    convert_timezone('America/Chicago', 'UTC', started_at_local)   as started_at_utc,
    convert_timezone('America/Chicago', 'UTC', ended_at_local)     as ended_at_utc,
    datediff('second', started_at_local, ended_at_local)           as duration_sec,
    start_station_id is null                                       as start_off_station,
    end_station_id is null                                         as end_off_station
from typed
qualify row_number() over (partition by ride_id order by file_name) = 1
```

**Confirm the time zone assumption.** Divvy's trip files are believed to record local Chicago time. A quick check: count trips by `hour(started_at_local)`. The peak should land around 5 PM, the evening commute. If the peak lands around 10 or 11 PM instead, the files are already in UTC, and you should drop the conversion.

### `models/staging/stg_weather.sql`

**What it does:** turns Open-Meteo's parallel lists (one list of times, one of temperatures, and so on) into one row per UTC hour. Where downloaded files overlap, it keeps the most recently loaded value.

```sql
with src as (

    select raw, file_name, loaded_at
    from {{ source('raw', 'weather_raw') }}

),

hours as (

    select
        to_timestamp_ntz(t.value::string, 'YYYY-MM-DD"T"HH24:MI')  as hour_utc,
        w.raw:hourly:temperature_2m[t.index]::float                as temp_c,
        w.raw:hourly:precipitation[t.index]::float                 as precip_mm,
        w.raw:hourly:rain[t.index]::float                          as rain_mm,
        w.raw:hourly:snowfall[t.index]::float                      as snow_cm,
        w.raw:hourly:wind_speed_10m[t.index]::float                as wind_kmh,
        w.raw:hourly:wind_direction_10m[t.index]::float            as wind_dir_deg,
        w.raw:hourly:weather_code[t.index]::int                    as weather_code,
        w.loaded_at
    from src w,
         lateral flatten(input => w.raw:hourly:time) t

)

select
    hour_utc, temp_c, precip_mm, rain_mm, snow_cm, wind_kmh, wind_dir_deg, weather_code
from hours
where temp_c is not null
qualify row_number() over (partition by hour_utc order by loaded_at desc) = 1
```

### `models/staging/stg_cta_l_stations.sql`

**What it does:** keeps only the L stations. In CTA's GTFS data these are the parent stations (`location_type = 1`), with stop IDs in the 40000s.

```sql
select
    stop_id                                               as l_stop_id,
    trim(stop_name)                                       as l_station_name,
    try_to_double(stop_lat)                               as lat,
    try_to_double(stop_lon)                               as lon,
    wheelchair_boarding
from {{ source('raw', 'cta_stops_raw') }}
where location_type = '1'
  and try_to_number(stop_id) between 40000 and 49999
```

### `models/staging/_staging.yml`

```yaml
version: 2

models:
  - name: stg_station_status
    description: One row per station per distinct report, from the live GBFS feed (UTC).
    columns:
      - name: station_id
        tests: [not_null]
      - name: last_reported_at
        tests: [not_null]
      - name: polled_at
        tests: [not_null]
      - name: bikes_available
        tests: [not_null]
      - name: docks_available
        tests: [not_null]

  - name: stg_station_information
    description: Latest details for every station seen in the live feed.
    columns:
      - name: station_id
        tests: [unique, not_null]
      - name: station_name
        tests: [not_null]

  - name: stg_trips
    description: Typed Divvy trips, 2020-04 onward, with UTC timestamps.
    columns:
      - name: ride_id
        tests: [unique, not_null]
      - name: started_at_utc
        tests: [not_null]

  - name: stg_weather
    description: Hourly Chicago weather from Open-Meteo (UTC).
    columns:
      - name: hour_utc
        tests: [unique, not_null]

  - name: stg_cta_l_stations
    description: CTA L stations (parent stations) with coordinates.
    columns:
      - name: l_stop_id
        tests: [unique, not_null]
```

---

## Step 3: Intermediate models (silver enriched)

These models hold the business logic: what counts as empty or full, how long each state lasted, which stations are near the L, and how trip station IDs map to live station IDs.

### `models/intermediate/int_station_status_intervals.sql`

**What it does:** turns each report into an interval. It runs from the moment of the report until the station's next report, which says how long the station stayed in that state. It also assigns each interval a state (`empty`, `full`, `ok`, or `out_of_service`) and flags stale reports and racks.

**Why intervals:** a stockout is about *duration*. Knowing a station was empty at 8:02 isn't enough. You need to know it stayed empty until 8:31.

```sql
with status as (

    select * from {{ ref('stg_station_status') }}

),

info as (

    select station_id, capacity, is_rack_or_corral
    from {{ ref('stg_station_information') }}

),

latest_poll as (

    select max(polled_at) as max_polled_at from status

),

ordered as (

    select
        s.station_id,
        s.last_reported_at                                            as valid_from,
        lead(s.last_reported_at) over (
            partition by s.station_id order by s.last_reported_at)    as next_report_at,
        s.bikes_available,
        s.ebikes_available,
        s.bikes_disabled,
        s.docks_available,
        s.docks_disabled,
        s.is_installed,
        s.is_renting,
        s.is_returning,
        i.capacity,
        coalesce(i.is_rack_or_corral, false)                          as is_rack_or_corral
    from status s
    left join info i on s.station_id = i.station_id

),

with_end as (

    select
        o.*,
        coalesce(o.next_report_at, lp.max_polled_at)                  as valid_to,
        o.next_report_at is null                                      as is_current
    from ordered o
    cross join latest_poll lp

)

select
    station_id,
    valid_from,
    valid_to,
    datediff('second', valid_from, valid_to) / 60.0                   as duration_min,
    date_trunc('hour', valid_from)                                    as hour_utc,
    bikes_available,
    ebikes_available,
    bikes_disabled,
    docks_available,
    docks_disabled,
    capacity,
    is_installed,
    is_renting,
    is_returning,
    is_rack_or_corral,
    is_current,
    datediff('second', valid_from, valid_to) / 60.0
        > {{ var('stale_minutes') }}                                  as is_stale,
    case
        when not is_installed or (not is_renting and not is_returning) then 'out_of_service'
        when bikes_available = 0 and is_renting                        then 'empty'
        when docks_available = 0 and is_returning                      then 'full'
        else 'ok'
    end                                                               as station_state
from with_end
```

### `models/intermediate/int_station_distance_to_l.sql`

**What it does:** finds each Divvy station's nearest L station and the straight-line distance in kilometers, using Snowflake's built-in `HAVERSINE` function. There are about 2,000 stations and 145 L stations, so comparing every pair is quick.

```sql
with stations as (

    select station_id, lat, lon
    from {{ ref('stg_station_information') }}
    where lat is not null and lon is not null

),

l_stations as (

    select l_stop_id, l_station_name, lat, lon
    from {{ ref('stg_cta_l_stations') }}
    where lat is not null and lon is not null

)

select
    s.station_id,
    l.l_stop_id                                           as nearest_l_stop_id,
    l.l_station_name                                      as nearest_l_station_name,
    haversine(s.lat, s.lon, l.lat, l.lon)                 as distance_to_l_km
from stations s
cross join l_stations l
qualify row_number() over (
    partition by s.station_id
    order by haversine(s.lat, s.lon, l.lat, l.lon)
) = 1
```

### `models/intermediate/int_station_crosswalk.sql`

**What it does:** maps each trip-file station ID (for example `CHI01747`) to the live feed's `station_id`. It matches on `short_name` first and falls back to the cleaned station name. It records how each match was made and how many trip endpoints each ID has.

From your September 2026 check, expect about 96% of trip endpoints to match on `short_name` and about 99.8% after the name fallback. Older trip years will match less, because stations that have since closed aren't in the live feed.

```sql
with trip_ends as (

    select start_station_id as trip_station_id, start_station_name as trip_station_name
    from {{ ref('stg_trips') }}
    where start_station_id is not null

    union all

    select end_station_id, end_station_name
    from {{ ref('stg_trips') }}
    where end_station_id is not null

),

trip_stations as (

    -- one row per trip station ID, with its most common name and total endpoints
    select
        trip_station_id,
        trip_station_name,
        sum(count(*)) over (partition by trip_station_id)  as endpoint_count
    from trip_ends
    group by trip_station_id, trip_station_name
    qualify row_number() over (partition by trip_station_id order by count(*) desc) = 1

),

live as (

    select
        station_id,
        short_name,
        lower(trim(station_name))                         as name_key
    from {{ ref('stg_station_information') }}

)

select
    t.trip_station_id,
    t.trip_station_name,
    t.endpoint_count,
    coalesce(by_short.station_id, by_name.station_id)     as station_id,
    case
        when by_short.station_id is not null then 'short_name'
        when by_name.station_id  is not null then 'name'
        else 'unmatched'
    end                                                   as match_method
from trip_stations t
left join live by_short on t.trip_station_id = by_short.short_name
left join live by_name  on lower(trim(t.trip_station_name)) = by_name.name_key
qualify row_number() over (
    partition by t.trip_station_id
    order by (by_short.station_id is null), by_name.station_id
) = 1
```

### `models/intermediate/_intermediate.yml`

```yaml
version: 2

models:
  - name: int_station_status_intervals
    description: Each station report as an interval (valid_from to valid_to) with its station_state.
    columns:
      - name: station_id
        tests: [not_null]
      - name: station_state
        tests:
          - accepted_values:
              values: ['empty', 'full', 'ok', 'out_of_service']

  - name: int_station_distance_to_l
    description: Nearest CTA L station and distance (km) for each Divvy station.
    columns:
      - name: station_id
        tests: [unique, not_null]

  - name: int_station_crosswalk
    description: Trip-file station ID to live station_id, with match method.
    columns:
      - name: trip_station_id
        tests: [unique, not_null]
      - name: match_method
        tests:
          - accepted_values:
              values: ['short_name', 'name', 'unmatched']
```

---

## Step 4: Marts (gold, the star schema)

The **facts** record events and measurements: snapshots, stockouts, and rebalancing. The **dimensions** describe them: where (station), when (time), and conditions (weather). Every fact joins to `dim_station` on `station_id`, and to `dim_time` and `dim_weather` on `hour_utc`.

### `models/marts/dim_station.sql`

```sql
select
    s.station_id,
    s.short_name,
    s.station_name,
    s.lat,
    s.lon,
    s.capacity,
    s.region_id,
    s.is_rack_or_corral,
    d.nearest_l_stop_id,
    d.nearest_l_station_name,
    d.distance_to_l_km,
    coalesce(d.distance_to_l_km <= {{ var('near_l_km') }}, false)   as is_near_l,
    s.first_seen_at,
    s.last_seen_at
from {{ ref('stg_station_information') }} s
left join {{ ref('int_station_distance_to_l') }} d
    on s.station_id = d.station_id
```

To add neighborhoods later, join station coordinates to Chicago's community-area boundaries, which are available on the city's data portal.

### `models/marts/dim_time.sql`

**What it does:** creates one row per hour from 2020 through about a week from now, with Chicago-time attributes: hour of day, weekday or weekend, and commute period. It's built with Snowflake's `GENERATOR`, so it doesn't need a source table.

```sql
with spine as (

    select
        dateadd('hour', row_number() over (order by seq4()) - 1,
                '2020-01-01 00:00:00'::timestamp_ntz)            as hour_utc
    from table(generator(rowcount => 70128))   -- ~8 years of hours

),

local as (

    select
        hour_utc,
        convert_timezone('UTC', 'America/Chicago', hour_utc)     as hour_chicago
    from spine
    where hour_utc <= dateadd('day', 7, convert_timezone('UTC', current_timestamp())::timestamp_ntz)

),

parts as (

    select
        hour_utc,
        hour_chicago,
        to_date(hour_chicago)                                    as date_chicago,
        hour(hour_chicago)                                       as hour_of_day,
        dayofweekiso(hour_chicago)                               as day_of_week_iso,
        dayname(hour_chicago)                                    as day_name,
        month(hour_chicago)                                      as month_num,
        year(hour_chicago)                                       as year_num
    from local

)

select
    *,
    day_of_week_iso in (6, 7)                                    as is_weekend,
    case
        when day_of_week_iso <= 5 and hour_of_day between 7 and 9   then 'am_commute'
        when day_of_week_iso <= 5 and hour_of_day between 16 and 18 then 'pm_commute'
        else 'other'
    end                                                          as commute_period,
    case
        when month_num in (12, 1, 2) then 'winter'
        when month_num in (3, 4, 5)  then 'spring'
        when month_num in (6, 7, 8)  then 'summer'
        else 'fall'
    end                                                          as season
from parts
```

The commute periods are 7:00–9:59 AM and 4:00–6:59 PM on weekdays, Chicago time. Holidays aren't flagged yet. A small seed file of US holidays would cover that if the analysis needs it.

### `models/marts/dim_weather.sql`

**What it does:** the hourly weather, plus readable categories for analysis. `is_lake_wind` flags wind blowing in from Lake Michigan (from the northeast through the southeast), which tends to make lakefront stations colder and windier.

```sql
select
    hour_utc,
    temp_c,
    precip_mm,
    rain_mm,
    snow_cm,
    wind_kmh,
    wind_dir_deg,
    weather_code,
    precip_mm >= {{ var('wet_precip_mm') }}                       as is_wet,
    coalesce(snow_cm, 0) > 0                                     as is_snow,
    case
        when temp_c < 0  then 'freezing'
        when temp_c < 10 then 'cold'
        when temp_c < 20 then 'mild'
        else 'warm'
    end                                                          as temp_band,
    case when wind_kmh >= 30 then 'windy' else 'calm' end        as wind_band,
    wind_dir_deg between 22.5 and 157.5                          as is_lake_wind
from {{ ref('stg_weather') }}
```

### `models/marts/fct_station_snapshots.sql`

**Grain:** one row per station per report interval. This is the main fact table for "how often, and for how long, is each station in each state."

```sql
select
    md5(station_id || '|' || to_varchar(valid_from))             as snapshot_id,
    station_id,
    hour_utc,
    valid_from,
    valid_to,
    duration_min,
    bikes_available,
    ebikes_available,
    bikes_disabled,
    docks_available,
    docks_disabled,
    capacity,
    station_state,
    is_stale,
    is_current,
    is_rack_or_corral
from {{ ref('int_station_status_intervals') }}
```

**Typical query:** the share of time each station spends empty, weighted by duration:

```sql
select station_id,
       sum(iff(station_state = 'empty', duration_min, 0)) / sum(duration_min) as pct_time_empty
from DIVVY.DEV_MARTS.FCT_STATION_SNAPSHOTS
where not is_rack_or_corral and not is_stale
group by station_id
order by pct_time_empty desc;
```

### `models/marts/fct_stockout_events.sql`

**Grain:** one row per stockout episode, meaning a continuous stretch where a station stayed `empty` or `full` for at least `stockout_min_minutes`.

**How it works (gaps and islands):**
1. Order each station's intervals by time.
2. Mark the start of a new "island" whenever the state changes from the previous interval.
3. A running sum of those marks gives each island an ID.
4. Group each island into one episode, with its start, end, and duration.

Racks and corrals are excluded. An episode that's still underway is flagged `is_ongoing`.

```sql
with intervals as (

    select *
    from {{ ref('int_station_status_intervals') }}
    where not is_rack_or_corral

),

marked as (

    select
        *,
        case
            when station_state = lag(station_state) over (
                     partition by station_id order by valid_from)
            then 0 else 1
        end                                                          as is_new_island
    from intervals

),

islands as (

    select
        *,
        sum(is_new_island) over (
            partition by station_id order by valid_from
            rows between unbounded preceding and current row)        as island_id
    from marked

),

episodes as (

    select
        station_id,
        island_id,
        station_state                                                as stockout_type,
        min(valid_from)                                              as started_at,
        max(valid_to)                                                as ended_at,
        boolor_agg(is_current)                                       as is_ongoing,
        boolor_agg(is_stale)                                         as includes_stale_report,
        count(*)                                                     as report_count
    from islands
    where station_state in ('empty', 'full')
    group by station_id, island_id, station_state

)

select
    md5(station_id || '|' || stockout_type || '|' || to_varchar(started_at)) as stockout_event_id,
    station_id,
    stockout_type,
    started_at,
    ended_at,
    datediff('second', started_at, ended_at) / 60.0                  as duration_min,
    date_trunc('hour', started_at)                                   as hour_utc,
    is_ongoing,
    includes_stale_report,
    report_count
from episodes
where datediff('second', started_at, ended_at) / 60.0 >= {{ var('stockout_min_minutes') }}
```

### `models/marts/fct_rebalancing_events.sql`

**Grain:** one row per likely rebalancing action: a jump of at least `rebalance_min_jump` bikes between consecutive reports that are at most `rebalance_max_minutes` apart.

**Why this signal:** riders take or return bikes one at a time. A station gaining or losing 5 or more bikes within a few minutes is much more likely to be a truck or a crew.

**Known limitation:** the live data starts October 26, and Divvy's trip files lag by about a month. So for most of the live period there are no trip records to confirm that riders didn't cause a jump. Treat these as *likely* rebalancing, and say so in the write-up. Once the November trip file is published, you can check the overlap.

```sql
with intervals as (

    select station_id, valid_from, bikes_available, hour_utc
    from {{ ref('int_station_status_intervals') }}
    where not is_rack_or_corral
      and station_state <> 'out_of_service'

),

changes as (

    select
        station_id,
        lag(valid_from) over (partition by station_id order by valid_from)      as window_start,
        valid_from                                                              as window_end,
        hour_utc,
        bikes_available
          - lag(bikes_available) over (partition by station_id order by valid_from) as bike_change
    from intervals

)

select
    md5(station_id || '|' || to_varchar(window_end))                 as rebalancing_event_id,
    station_id,
    window_start,
    window_end,
    hour_utc,
    datediff('second', window_start, window_end) / 60.0              as window_min,
    bike_change,
    iff(bike_change > 0, 'drop_off', 'pick_up')                      as event_type
from changes
where window_start is not null
  and abs(bike_change) >= {{ var('rebalance_min_jump') }}
  and datediff('second', window_start, window_end) / 60.0 <= {{ var('rebalance_max_minutes') }}
```

### `models/marts/_marts.yml`

The weather relationship tests are set to `warn`, not `error`. The weather archive runs a few days behind, so the newest hours won't have weather yet. That's expected and shouldn't fail the build.

```yaml
version: 2

models:
  - name: dim_station
    description: One row per Divvy station, with capacity, rack flag, and nearest L station.
    columns:
      - name: station_id
        tests: [unique, not_null]

  - name: dim_time
    description: One row per UTC hour with Chicago-time attributes.
    columns:
      - name: hour_utc
        tests: [unique, not_null]

  - name: dim_weather
    description: One row per UTC hour of Chicago weather with analysis categories.
    columns:
      - name: hour_utc
        tests: [unique, not_null]

  - name: fct_station_snapshots
    description: One row per station report interval.
    columns:
      - name: snapshot_id
        tests: [unique, not_null]
      - name: station_id
        tests:
          - not_null
          - relationships:
              to: ref('dim_station')
              field: station_id
      - name: hour_utc
        tests:
          - relationships:
              to: ref('dim_time')
              field: hour_utc
          - relationships:
              to: ref('dim_weather')
              field: hour_utc
              config:
                severity: warn

  - name: fct_stockout_events
    description: One row per empty or full episode lasting at least stockout_min_minutes.
    columns:
      - name: stockout_event_id
        tests: [unique, not_null]
      - name: station_id
        tests:
          - relationships:
              to: ref('dim_station')
              field: station_id
      - name: stockout_type
        tests:
          - accepted_values:
              values: ['empty', 'full']

  - name: fct_rebalancing_events
    description: Likely rebalancing actions inferred from sudden jumps in bike counts.
    columns:
      - name: rebalancing_event_id
        tests: [unique, not_null]
      - name: station_id
        tests:
          - relationships:
              to: ref('dim_station')
              field: station_id
```

If dbt complains about the `config:` block under the relationship test, the runtime is on an older dbt version. Move `severity: warn` up one level, directly under `relationships:`, alongside `to` and `field`.

---

## Step 5: Custom tests

These are **singular tests**: each one is a query that returns the *bad* rows. If it returns zero rows, the test passes.

### `tests/assert_no_negative_counts.sql`

```sql
select *
from {{ ref('stg_station_status') }}
where bikes_available < 0
   or docks_available < 0
   or coalesce(ebikes_available, 0) < 0
   or coalesce(bikes_disabled, 0) < 0
   or coalesce(docks_disabled, 0) < 0
```

### `tests/assert_station_report_unique.sql`

```sql
select station_id, last_reported_at, count(*) as n
from {{ ref('stg_station_status') }}
group by station_id, last_reported_at
having count(*) > 1
```

### `tests/assert_trip_file_month_matches.sql`

Catches mislabeled source files, like the January 2026 zip that contained a file named for January 2025. It fails any file where more than 1% of trips start outside the month in its name. The 1% allows for rides that cross midnight at the end of a month.

```sql
select
    file_name,
    file_month,
    count(*)                                                        as trips,
    sum(iff(date_trunc('month', started_at_local) <> file_month, 1, 0)) as off_month_trips
from {{ ref('stg_trips') }}
group by file_name, file_month
having sum(iff(date_trunc('month', started_at_local) <> file_month, 1, 0)) > 0.01 * count(*)
```

### `tests/assert_stockout_end_after_start.sql`

```sql
select *
from {{ ref('fct_stockout_events') }}
where ended_at <= started_at
```

---

## Step 6: Run it

`dbt build` runs every model *and* its tests in dependency order. It's the one command you need.

**In the Workspace, with the dbt toolbar visible:**
1. Open any file in `dbt/divvy/`. The run controls appear in the toolbar.
2. Choose **Project** `dbt/divvy`, **Profile** `dev`, and the **Build** command, then run it.
3. Check the **Output** tab when it finishes. It doesn't stream while running, and the first build may take several minutes.

**If the toolbar doesn't appear:** open each model's `.sql` file and press its play button, or Cmd+Enter. That runs `dbt run` for that one model. Run them in this order, so each model's inputs exist first:

1. `stg_station_status`, `stg_station_information`, `stg_trips`, `stg_weather`, `stg_cta_l_stations`
2. `int_station_status_intervals`, `int_station_distance_to_l`, `int_station_crosswalk`
3. `dim_station`, `dim_time`, `dim_weather`
4. `fct_station_snapshots`, `fct_stockout_events`, `fct_rebalancing_events`

Tests won't run this way, so get the toolbar working before the check-in. The secondary-roles step at the top of this runbook is the usual fix.

**Rebuilding `stg_station_status` from scratch,** for example after changing its logic: add `--full-refresh` to the build command's arguments, using the dropdown next to the run button.

**When dev looks right, build prod:** run the same **Build** with **Profile** `prod`. The dashboard and MCP server should read from `PROD_MARTS`.

---

## Step 7: Check the results

```sql
USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;

-- Row counts across the model
SELECT 'stg_station_status' AS model, COUNT(*) AS rows FROM DIVVY.DEV_STAGING.STG_STATION_STATUS
UNION ALL SELECT 'stg_trips',              COUNT(*) FROM DIVVY.DEV_STAGING.STG_TRIPS
UNION ALL SELECT 'dim_station',            COUNT(*) FROM DIVVY.DEV_MARTS.DIM_STATION
UNION ALL SELECT 'fct_station_snapshots',  COUNT(*) FROM DIVVY.DEV_MARTS.FCT_STATION_SNAPSHOTS
UNION ALL SELECT 'fct_stockout_events',    COUNT(*) FROM DIVVY.DEV_MARTS.FCT_STOCKOUT_EVENTS
UNION ALL SELECT 'fct_rebalancing_events', COUNT(*) FROM DIVVY.DEV_MARTS.FCT_REBALANCING_EVENTS;

-- Crosswalk coverage (should be ~96% short_name by endpoints for recent years)
SELECT match_method,
       COUNT(*)                                        AS station_ids,
       SUM(endpoint_count)                             AS endpoints,
       ROUND(100 * SUM(endpoint_count) / SUM(SUM(endpoint_count)) OVER (), 1) AS pct_endpoints
FROM DIVVY.DEV_INTERMEDIATE.INT_STATION_CROSSWALK
GROUP BY match_method;

-- Top 10 stations by hours spent empty (first finding for the check-in)
SELECT d.station_name, d.is_near_l,
       ROUND(SUM(e.duration_min) / 60, 1) AS hours_empty,
       COUNT(*)                          AS episodes
FROM DIVVY.DEV_MARTS.FCT_STOCKOUT_EVENTS e
JOIN DIVVY.DEV_MARTS.DIM_STATION d USING (station_id)
WHERE e.stockout_type = 'empty'
GROUP BY 1, 2
ORDER BY hours_empty DESC
LIMIT 10;

-- Stockouts by commute period (first transit-angle cut)
SELECT t.commute_period, d.is_near_l, e.stockout_type, COUNT(*) AS episodes
FROM DIVVY.DEV_MARTS.FCT_STOCKOUT_EVENTS e
JOIN DIVVY.DEV_MARTS.DIM_STATION d USING (station_id)
JOIN DIVVY.DEV_MARTS.DIM_TIME t USING (hour_utc)
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- Wet vs. dry (first weather cut; needs weather refreshed past Oct 28)
SELECT w.is_wet, e.stockout_type, COUNT(*) AS episodes, ROUND(AVG(e.duration_min), 1) AS avg_min
FROM DIVVY.DEV_MARTS.FCT_STOCKOUT_EVENTS e
JOIN DIVVY.DEV_MARTS.DIM_WEATHER w USING (hour_utc)
GROUP BY 1, 2
ORDER BY 1, 2;
```

The last three queries are the start of your early EDA for the check-in deck. The episode comparisons are counts, not rates, so normalize them before drawing conclusions. For example, divide by the number of station-hours in each group, or the comparison will mostly reflect how many hours fell into each category.

---

## Step 8: Commit and push

In the Workspace: **Changes** → review the file list (no passwords, no `target/` or `logs/`) → write a commit message → **Push**.

---

## After the check-in

| Next piece | Built from |
|---|---|
| **Backfill (reconstructed inventory)** | `stg_trips` + `int_station_crosswalk`: replay net arrivals minus departures per station per hour, anchored to a known starting count from the live data, then measure the drift against `fct_station_snapshots` for the overlapping weeks |
| **Hourly serving table** (platinum) | `fct_station_snapshots` aggregated to station × hour: share of time empty or full, joined to time and weather. This feeds the dashboard map and the prediction model |
| **Prediction model** | The serving table: baseline = the station's typical empty rate for that hour of week; then add weather and the last hour's trend |
| **Scheduling** | Deploy the project as a dbt project object, then run `EXECUTE DBT PROJECT ... ARGS = 'build --target prod'` hourly from a task (with a warehouse; serverless isn't supported) or from Airflow, after the `:05` load |

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| No run controls in the Workspace | Secondary roles not enabled, or no dbt file open | Run the secondary-roles SQL at the top, sign out and back in, then open a file in `dbt/divvy/` |
| `Object ... does not exist` for a `ref()` | An upstream model hasn't been built yet | Use **Build** (it handles order), or run the models in the order listed in Step 6 |
| Incremental `stg_station_status` misses data after changing its logic | Old rows were built with the old logic | Rebuild once with `--full-refresh` |
| `stg_weather` returns 0 rows | Time format mismatch | Check one value: `SELECT raw:hourly:time[0] FROM DIVVY.RAW.WEATHER_RAW LIMIT 1;`. If it includes seconds, change the format to `'YYYY-MM-DD"T"HH24:MI:SS'` |
| Weather relationship test warns | The archive runs a few days behind, or the live weeks haven't been downloaded | Refresh the weather (see "Before you start," item 3). A warning doesn't block the build |
| `assert_trip_file_month_matches` fails | Another mislabeled source file | Query `stg_trips` for that `file_name`, fix the file in the bucket as you did for January 2025 and 2026, and reload it with `FORCE = TRUE` |
| Peak trip hour lands around 10 or 11 PM | Trip files are already in UTC | Remove the `convert_timezone` calls in `stg_trips` |
| Build is slow or uses many credits | Full rebuilds of the large tables | Expected on the first run. Keep `stg_station_status` incremental, and only rebuild prod when needed |
