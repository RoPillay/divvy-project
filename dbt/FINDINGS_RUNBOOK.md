# Findings Runbook (Nov 19–25)

This week turns the early counts into findings you can defend. It has two parts:

1. **Build two serving (platinum) models in dbt**, which the dashboard, forecast, and MCP server will all read from:
   - `srv_station_profile`: one row per station, classifying it as chronic or inactive, repeat-stockout, or normal
   - `srv_station_hour`: one row per station per hour, with the minutes and share of time spent empty and full
2. **Run analysis queries** on those tables for the four findings: station types, the commute tide as rates, weather as rates, and rebalancing.

| What | Where |
|---|---|
| New dbt models | `dbt/divvy/models/serving/` |
| Output schemas | `DIVVY.DEV_SERVING` and `DIVVY.PROD_SERVING` |
| Analysis queries | `snowflake/analysis/findings.sql` (run in a SQL file, not in dbt) |

---

## Why rates instead of counts

The check-in results counted stockout *episodes*. Counts mislead in two ways:

- **Group size.** More stations or more hours in a group means more episodes, even if each station is no worse. For example, "other hours" covers far more of the week than the two commute windows.
- **Length.** One 20-day episode counts the same as a 5-minute one.

A **rate** fixes both: *minutes empty ÷ minutes in service*, added up over the station-hours in each group. That's the share of time riders would find a station empty. Every comparison below uses it.

---

## Part 1: The serving models

### Step 1: Update `dbt_project.yml`

Add three variables under `vars:`, and add a `serving` block under `models: divvy:`. The new parts are marked with comments:

```yaml
vars:
  stockout_min_minutes: 5
  stale_minutes: 30
  near_l_km: 0.4
  rebalance_min_jump: 5
  rebalance_max_minutes: 10
  wet_precip_mm: 0.1
  inactive_max_changes: 10      # new: fewer bike-count changes than this over the window = likely inactive
  chronic_empty_pct: 0.5        # new: empty more than half of in-service time = chronically empty
  repeat_min_episodes: 10       # new: this many separate stockouts = repeat-stockout station

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
    serving:                    # new
      +materialized: table
      +schema: serving
```

In the Workspace, create the folder `dbt/divvy/models/serving/`.

### Step 2: `models/serving/srv_station_profile.sql`

**What it does:** one row per station across the whole live window. For each station it computes how much of its in-service time it spent empty or full, how many separate stockouts it had, and how often its bike count actually changed. Then it assigns a **station type**:

| `station_type` | Rule | What it means |
|---|---|---|
| `rack_or_corral` | Public rack, corral, or no docks | Can't really be "full"; leave it out of most findings |
| `chronic_or_inactive` | Bike count changed fewer than 10 times, **or** empty more than half the time | The far South Side pattern from the check-in. The data can't tell "inactive" apart from "never restocked," so the name covers both |
| `repeat_stockout` | 10 or more separate stockouts | Busy stations that keep running out. This is where crews can act |
| `normal` | Everything else | |

```sql
with intervals as (

    select * from {{ ref('int_station_status_intervals') }}

),

lagged as (

    select
        station_id,
        valid_from,
        duration_min,
        station_state,
        is_stale,
        bikes_available,
        lag(bikes_available) over (partition by station_id order by valid_from) as prev_bikes
    from intervals

),

activity as (

    select
        station_id,
        count(*)                                                              as n_reports,
        sum(iff(prev_bikes is not null and bikes_available <> prev_bikes, 1, 0)) as n_bike_changes,
        sum(iff(station_state <> 'out_of_service' and not is_stale, duration_min, 0)) as in_service_min,
        sum(iff(station_state = 'empty' and not is_stale, duration_min, 0))   as empty_min,
        sum(iff(station_state = 'full'  and not is_stale, duration_min, 0))   as full_min,
        min(valid_from)                                                       as first_report_at,
        max(valid_from)                                                       as last_report_at
    from lagged
    group by station_id

),

episodes as (

    select
        station_id,
        count_if(stockout_type = 'empty')                                     as empty_episodes,
        count_if(stockout_type = 'full')                                      as full_episodes,
        max(iff(stockout_type = 'empty', duration_min, null))                 as longest_empty_min
    from {{ ref('fct_stockout_events') }}
    group by station_id

)

select
    s.station_id,
    s.station_name,
    s.lat,
    s.lon,
    s.capacity,
    s.is_rack_or_corral,
    s.is_near_l,
    s.distance_to_l_km,
    s.nearest_l_station_name,
    a.n_reports,
    a.n_bike_changes,
    a.in_service_min,
    a.empty_min,
    a.full_min,
    a.empty_min / nullif(a.in_service_min, 0)                                 as pct_time_empty,
    a.full_min  / nullif(a.in_service_min, 0)                                 as pct_time_full,
    coalesce(e.empty_episodes, 0)                                             as empty_episodes,
    coalesce(e.full_episodes, 0)                                              as full_episodes,
    e.longest_empty_min,
    a.first_report_at,
    a.last_report_at,
    case
        when s.is_rack_or_corral                                              then 'rack_or_corral'
        when coalesce(a.n_bike_changes, 0) < {{ var('inactive_max_changes') }}
          or a.empty_min / nullif(a.in_service_min, 0) > {{ var('chronic_empty_pct') }}
                                                                              then 'chronic_or_inactive'
        when coalesce(e.empty_episodes, 0) + coalesce(e.full_episodes, 0)
             >= {{ var('repeat_min_episodes') }}                              then 'repeat_stockout'
        else 'normal'
    end                                                                       as station_type
from {{ ref('dim_station') }} s
left join activity a on s.station_id = a.station_id
left join episodes e on s.station_id = e.station_id
```

### Step 3: `models/serving/srv_station_hour.sql`

**What it does:** one row per station per hour, with how many minutes of that hour the station spent empty, full, out of service, or stale. It's joined to time, weather, and station details, so the dashboard and forecast can read it without extra joins.

**How it splits time into hours:** each interval from `int_station_status_intervals` can run across several hours. For example, a station empty from 7:40 to 9:10 has 20 minutes in the 7 o'clock hour, 60 in the 8 o'clock hour, and 10 in the 9 o'clock hour. `ARRAY_GENERATE_RANGE` lists the hours each interval touches, and the minutes are clipped to each hour. This avoids a range join, which would be very slow on 17 million rows.

```sql
with intervals as (

    select station_id, valid_from, valid_to, station_state, is_stale, bikes_available
    from {{ ref('int_station_status_intervals') }}
    where valid_to > valid_from

),

split as (

    select
        i.station_id,
        dateadd('hour', h.value::int, date_trunc('hour', i.valid_from))        as hour_utc,
        datediff(
            'second',
            greatest(i.valid_from, dateadd('hour', h.value::int, date_trunc('hour', i.valid_from))),
            least(i.valid_to,      dateadd('hour', h.value::int + 1, date_trunc('hour', i.valid_from)))
        ) / 60.0                                                               as minutes,
        i.station_state,
        i.is_stale,
        i.bikes_available
    from intervals i,
         lateral flatten(input => array_generate_range(
             0, datediff('hour', date_trunc('hour', i.valid_from), i.valid_to) + 1)) h

),

agg as (

    select
        station_id,
        hour_utc,
        sum(minutes)                                                           as minutes_observed,
        sum(iff(not is_stale and station_state <> 'out_of_service', minutes, 0)) as minutes_in_service,
        sum(iff(not is_stale and station_state = 'empty', minutes, 0))         as minutes_empty,
        sum(iff(not is_stale and station_state = 'full',  minutes, 0))         as minutes_full,
        sum(iff(station_state = 'out_of_service', minutes, 0))                 as minutes_out_of_service,
        sum(iff(is_stale, minutes, 0))                                         as minutes_stale,
        sum(bikes_available * minutes) / nullif(sum(minutes), 0)               as avg_bikes,
        min(bikes_available)                                                   as min_bikes,
        max(bikes_available)                                                   as max_bikes
    from split
    where minutes > 0
    group by station_id, hour_utc

)

select
    md5(a.station_id || '|' || to_varchar(a.hour_utc))                         as station_hour_id,
    a.station_id,
    a.hour_utc,
    a.minutes_observed,
    a.minutes_in_service,
    a.minutes_empty,
    a.minutes_full,
    a.minutes_out_of_service,
    a.minutes_stale,
    a.minutes_empty / nullif(a.minutes_in_service, 0)                          as pct_empty,
    a.minutes_full  / nullif(a.minutes_in_service, 0)                          as pct_full,
    a.avg_bikes,
    a.min_bikes,
    a.max_bikes,

    t.date_chicago,
    t.hour_of_day,
    t.day_name,
    t.is_weekend,
    t.commute_period,

    w.temp_c,
    w.precip_mm,
    w.is_wet,
    w.is_snow,
    w.temp_band,
    w.wind_band,
    w.is_lake_wind,

    p.station_name,
    p.station_type,
    p.is_near_l,
    p.distance_to_l_km,
    p.capacity,
    p.lat,
    p.lon
from agg a
join {{ ref('dim_time') }} t            on a.hour_utc = t.hour_utc
left join {{ ref('dim_weather') }} w    on a.hour_utc = w.hour_utc
join {{ ref('srv_station_profile') }} p on a.station_id = p.station_id
```

`is_wet` and the other weather columns are null for hours the weather download doesn't cover yet. The weather queries below filter those out.

### Step 4: `models/serving/_serving.yml`

```yaml
version: 2

models:
  - name: srv_station_profile
    description: One row per station over the live window, with time empty or full, stockout counts, and station_type.
    columns:
      - name: station_id
        tests: [unique, not_null]
      - name: station_type
        tests:
          - accepted_values:
              values: ['rack_or_corral', 'chronic_or_inactive', 'repeat_stockout', 'normal']

  - name: srv_station_hour
    description: One row per station per UTC hour, with minutes empty, full, and in service, joined to time, weather, and station.
    columns:
      - name: station_hour_id
        tests: [unique, not_null]
      - name: station_id
        tests:
          - relationships:
              to: ref('dim_station')
              field: station_id
```

Add a custom test so no hour ever has more than 60 minutes. That would mean the hour-splitting is wrong. Create `tests/assert_station_hour_max_60_min.sql`:

```sql
select *
from {{ ref('srv_station_hour') }}
where minutes_observed > 60.01
```

### Step 5: Build and check

1. In the Workspace toolbar, pick Project `dbt/divvy`, Profile **`dev`**, and command **Build**. To build just the new models and their tests, add `--select serving+` in the arguments field. Then run it.
2. Check the result:

```sql
USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;

SELECT COUNT(*) AS station_hours, COUNT(DISTINCT station_id) AS stations,
       MIN(hour_utc) AS first_hour, MAX(hour_utc) AS last_hour,
       ROUND(AVG(minutes_observed), 1) AS avg_minutes_observed
FROM DIVVY.DEV_SERVING.SRV_STATION_HOUR;
```

What to expect:
- **Station-hours:** about 2,000 stations × about 480 hours, so roughly 1 million rows.
- **`avg_minutes_observed`:** close to 60. The first and last hours are partial, so they pull it slightly below.

3. When dev looks right, run the same Build with Profile **`prod`**. The queries below read from `PROD_SERVING`.
4. Commit and push from **Changes**. Uncheck `target/` and `logs/` if they show up.

---

## Part 2: The findings queries

Create `snowflake/analysis/findings.sql` in the Workspace and paste these in. Run each one on its own and export the results as CSV, the same way you did for the check-in, so they can be charted.

Start every session with:

```sql
USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;
USE SCHEMA DIVVY.PROD_SERVING;
```

### Finding A: The two kinds of empty stations

**A1. How many stations of each type, and how much of the empty time each type accounts for.** This shows whether a few chronic stations dominate the raw "hours empty" totals.

```sql
SELECT station_type,
       COUNT(*)                                        AS stations,
       ROUND(100 * AVG(pct_time_empty), 1)             AS avg_pct_time_empty,
       SUM(empty_episodes)                             AS empty_episodes,
       ROUND(SUM(empty_min) / 60)                      AS empty_hours,
       ROUND(100 * SUM(empty_min) / SUM(SUM(empty_min)) OVER (), 1) AS pct_of_all_empty_hours
FROM SRV_STATION_PROFILE
GROUP BY station_type
ORDER BY stations DESC;
```

**A2. Check the far South Side stations from the check-in.** If `n_bike_changes` is near zero, call them inactive. If the bike count moves around but keeps returning to zero, call them unserved.

```sql
SELECT station_name, station_type, n_reports, n_bike_changes,
       ROUND(100 * pct_time_empty, 1) AS pct_time_empty,
       empty_episodes, ROUND(longest_empty_min / 60) AS longest_empty_hours
FROM SRV_STATION_PROFILE
WHERE station_name IN ('Kostner & 87th', 'Michigan Ave & 108th St', 'Parnell Ave & 127th St',
                       'Woodlawn Ave & 103rd St', 'Aberdeen St & 106th St', 'New England Ave & North Ave')
ORDER BY pct_time_empty DESC;
```

**A3. The stations crews should care about: repeat stockouts, ranked.**

```sql
SELECT station_name, is_near_l,
       empty_episodes, full_episodes,
       ROUND(100 * pct_time_empty, 1) AS pct_time_empty,
       ROUND(100 * pct_time_full, 1)  AS pct_time_full,
       capacity
FROM SRV_STATION_PROFILE
WHERE station_type = 'repeat_stockout'
ORDER BY empty_episodes + full_episodes DESC
LIMIT 15;
```

Every finding from here on keeps **only `normal` and `repeat_stockout` stations**. Chronic or inactive stations and racks are reported separately (Finding A), so they don't distort the comparisons.

### Finding B: The commute tide, as rates

**B1. The share of time empty and full, by commute period and nearness to the L.** This is the rate version of the check-in's Result 2.

```sql
SELECT commute_period, is_near_l,
       COUNT(*)                                                   AS station_hours,
       ROUND(100 * SUM(minutes_empty) / SUM(minutes_in_service), 2) AS pct_time_empty,
       ROUND(100 * SUM(minutes_full)  / SUM(minutes_in_service), 2) AS pct_time_full
FROM SRV_STATION_HOUR
WHERE station_type IN ('normal', 'repeat_stockout')
  AND minutes_in_service > 0
GROUP BY commute_period, is_near_l
ORDER BY commute_period, is_near_l;
```

**How to read it:** the tide holds up if, near the L, `pct_time_full` is highest in `am_commute` and `pct_time_empty` is highest in `pm_commute`, with the reverse (or a weaker version) farther out.

**B2. The full weekday curve, hour by hour**, for a line chart on the dashboard and in the final deck:

```sql
SELECT hour_of_day, is_near_l,
       ROUND(100 * SUM(minutes_empty) / SUM(minutes_in_service), 2) AS pct_time_empty,
       ROUND(100 * SUM(minutes_full)  / SUM(minutes_in_service), 2) AS pct_time_full
FROM SRV_STATION_HOUR
WHERE station_type IN ('normal', 'repeat_stockout')
  AND NOT is_weekend
  AND minutes_in_service > 0
GROUP BY hour_of_day, is_near_l
ORDER BY is_near_l, hour_of_day;
```

### Finding C: Weather, as rates

Rainy hours don't fall evenly across the day. If more rain fell during the evening commute, for example, a simple wet-vs-dry average would mix up "rain" with "evening." **C2 compares wet and dry hours at the same hour of the day**, which removes that mix-up.

**C1. How much wet weather the data has.** Check this first. If there are only a few dozen wet hours, say so on the slide.

```sql
SELECT is_wet, COUNT(DISTINCT hour_utc) AS hours, MIN(hour_utc), MAX(hour_utc)
FROM SRV_STATION_HOUR
WHERE is_wet IS NOT NULL
GROUP BY is_wet;
```

**C2. Wet vs. dry at the same hour of the day:**

```sql
WITH by_hour AS (
    SELECT hour_of_day, is_wet,
           SUM(minutes_empty) / SUM(minutes_in_service) AS pct_empty,
           SUM(minutes_full)  / SUM(minutes_in_service) AS pct_full,
           COUNT(*)                                     AS station_hours
    FROM SRV_STATION_HOUR
    WHERE station_type IN ('normal', 'repeat_stockout')
      AND is_wet IS NOT NULL
      AND minutes_in_service > 0
    GROUP BY hour_of_day, is_wet
),
both_kinds AS (
    SELECT hour_of_day FROM by_hour GROUP BY hour_of_day HAVING COUNT(DISTINCT is_wet) = 2
)
SELECT is_wet,
       ROUND(100 * AVG(pct_empty), 2) AS avg_pct_time_empty,
       ROUND(100 * AVG(pct_full), 2)  AS avg_pct_time_full,
       SUM(station_hours)             AS station_hours
FROM by_hour
WHERE hour_of_day IN (SELECT hour_of_day FROM both_kinds)
GROUP BY is_wet;
```

**C3. By temperature band**, the same way:

```sql
SELECT temp_band,
       COUNT(DISTINCT hour_utc)                                     AS hours,
       ROUND(100 * SUM(minutes_empty) / SUM(minutes_in_service), 2) AS pct_time_empty,
       ROUND(100 * SUM(minutes_full)  / SUM(minutes_in_service), 2) AS pct_time_full
FROM SRV_STATION_HOUR
WHERE station_type IN ('normal', 'repeat_stockout')
  AND temp_band IS NOT NULL
  AND minutes_in_service > 0
GROUP BY temp_band
ORDER BY pct_time_empty DESC;
```

Late October to mid-November covers mostly cold and mild hours, so expect little range here. If the effect is small, report it as "no clear effect in late fall." That's a real result, and it tells you what more data would answer.

### Finding D: Rebalancing

These run against the marts schema, so switch schemas first:

```sql
USE SCHEMA DIVVY.PROD_MARTS;
```

**D1. When it happens:** likely rebalancing events by Chicago hour of day and type.

```sql
SELECT t.hour_of_day, r.event_type, COUNT(*) AS events
FROM FCT_REBALANCING_EVENTS r
JOIN DIM_TIME t ON r.hour_utc = t.hour_utc
GROUP BY t.hour_of_day, r.event_type
ORDER BY t.hour_of_day, r.event_type;
```

**D2. Where it happens:** the stations with the most events.

```sql
SELECT s.station_name, s.is_near_l,
       COUNT(*)                                   AS events,
       COUNT_IF(r.event_type = 'drop_off')        AS drop_offs,
       COUNT_IF(r.event_type = 'pick_up')         AS pick_ups,
       ROUND(AVG(ABS(r.bike_change)), 1)          AS avg_bikes_moved
FROM FCT_REBALANCING_EVENTS r
JOIN DIM_STATION s ON r.station_id = s.station_id
GROUP BY s.station_name, s.is_near_l
ORDER BY events DESC
LIMIT 15;
```

**D3. Does rebalancing end stockouts?** For each likely drop-off, this checks whether the station had an **empty** stockout that ended within 10 minutes of the drop-off. For each pick-up, it checks for a **full** stockout. It also measures how long the stockout lasted before the fix, which is a rough crew response time.

```sql
WITH matched AS (
    SELECT r.rebalancing_event_id,
           r.event_type,
           e.stockout_event_id,
           DATEDIFF('minute', e.started_at, r.window_end) AS minutes_from_stockout_start
    FROM FCT_REBALANCING_EVENTS r
    LEFT JOIN FCT_STOCKOUT_EVENTS e
      ON  e.station_id = r.station_id
      AND e.stockout_type = IFF(r.event_type = 'drop_off', 'empty', 'full')
      AND e.ended_at BETWEEN DATEADD('minute', -10, r.window_start)
                         AND DATEADD('minute',  10, r.window_end)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY r.rebalancing_event_id ORDER BY e.ended_at DESC NULLS LAST) = 1
)
SELECT event_type,
       COUNT(*)                                              AS events,
       COUNT(stockout_event_id)                              AS ended_a_stockout,
       ROUND(100 * COUNT(stockout_event_id) / COUNT(*), 1)   AS pct_ended_a_stockout,
       MEDIAN(minutes_from_stockout_start)                   AS median_stockout_minutes_before_fix
FROM matched
GROUP BY event_type;
```

**How to read it:**
- **A high `pct_ended_a_stockout`** means crews often arrive *after* a station runs out. That's reactive rebalancing, which is exactly what a one-hour forecast could improve.
- **A low share** means most moves happen before a stockout (proactive), or that some of these jumps aren't trucks. Either way, say so on the slide.

**D4. Stockouts that never got a fix:** the share of repeat-stockout stations' empty episodes that ended on their own (a rider returned a bike) rather than after a likely drop-off. This is useful for "where should crews go?"

```sql
WITH fixed AS (
    SELECT DISTINCT e.stockout_event_id
    FROM FCT_STOCKOUT_EVENTS e
    JOIN FCT_REBALANCING_EVENTS r
      ON  r.station_id = e.station_id
      AND r.event_type = 'drop_off'
      AND e.stockout_type = 'empty'
      AND e.ended_at BETWEEN DATEADD('minute', -10, r.window_start) AND DATEADD('minute', 10, r.window_end)
)
SELECT p.station_name,
       COUNT(*)                                          AS empty_episodes,
       COUNT(f.stockout_event_id)                        AS ended_by_drop_off,
       ROUND(100 * COUNT(f.stockout_event_id) / COUNT(*), 1) AS pct_ended_by_drop_off,
       ROUND(AVG(e.duration_min))                        AS avg_minutes_empty
FROM FCT_STOCKOUT_EVENTS e
JOIN DIVVY.PROD_SERVING.SRV_STATION_PROFILE p ON e.station_id = p.station_id
LEFT JOIN fixed f ON e.stockout_event_id = f.stockout_event_id
WHERE e.stockout_type = 'empty'
  AND p.station_type = 'repeat_stockout'
GROUP BY p.station_name
ORDER BY empty_episodes DESC
LIMIT 15;
```

---

## What to bring back

Export these results as CSVs. With them, the findings slides and dashboard charts can be built from real numbers.

| Query | Becomes |
|---|---|
| A1, A2, A3 | "Two kinds of empty stations," now with station counts and an inactive check |
| B1, B2 | The commute tide as rates, plus a weekday hour-by-hour curve |
| C1, C2, C3 | The weather finding, with how many wet hours it's based on |
| D1–D4 | When and where crews rebalance, and whether they arrive after stockouts |

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| `Unknown function ARRAY_GENERATE_RANGE` | Very unlikely on current Snowflake | Ask and I'll send a version that uses a numbers table instead |
| `srv_station_hour` takes a long time | Splitting about 17M intervals into hours on an X-Small warehouse | Expected on the first build, a few minutes. Only rebuild prod when needed |
| `assert_station_hour_max_60_min` fails | Overlapping intervals for a station | Query the failing rows; check `stg_station_status` for duplicate reports at the same timestamp |
| `station_type` is mostly `chronic_or_inactive` | Thresholds too strict for this data | Look at A1's numbers, then adjust `inactive_max_changes` or `chronic_empty_pct` in `dbt_project.yml` and rebuild `serving+` |
| Weather queries return nothing | Weather not downloaded for the live weeks | Refresh the weather (dbt runbook, "Before you start," item 3), then rebuild |
| Rates look tiny (under 1%) | Most station-hours are fine, so averages are small | Expected. Compare groups against each other, and use A3 or D4 to show the stations that matter |
