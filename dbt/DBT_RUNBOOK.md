# dbt on Snowflake Runbook

This guide sets up the team's dbt project so it runs inside Snowflake, using **dbt Projects on Snowflake** in your Git-connected Workspace. It then builds the first staging model, `stg_station_status`.

**What dbt does in this project:** dbt doesn't store or process data itself. It's a way to write each transformation as a SQL `SELECT` statement, in files kept in Git. dbt turns those into tables and views in Snowflake, runs them in the right order, and tests the results.

```
RAW (loaded by COPY INTO)  →  STAGING (clean, one row per thing)  →  INTERMEDIATE (logic)  →  MARTS (star schema)
```

**Why run dbt inside Snowflake:**
- No installs on anyone's machine. Everyone works in the browser.
- No passwords in config files. dbt runs as whoever is signed in to Snowflake.
- Your Workspace is already connected to GitHub, so the dbt files are version-controlled automatically.
- It still counts as dbt, the same tool and the same files. It just runs on Snowflake's compute.

**Where to work:** Snowsight → **Projects → Workspaces** → your Git-connected workspace for `RoPillay/divvy-project`.

| Setting | Value |
|---|---|
| dbt project folder in repo | `dbt/divvy/` |
| Role | `DIVVY_ENGINEER` |
| Warehouse | `DIVVY_WH` |
| Database | `DIVVY` |
| Raw source schema | `DIVVY.RAW` |

---

## How schemas work (read once)

Each person builds into **their own development schema**, so teammates don't overwrite each other's work while experimenting. The final shared version builds into `PROD`.

dbt adds a layer name to the base schema for each person or target:

| Target | Staging models land in | Marts land in |
|---|---|---|
| `dev_sona` | `DIVVY.DEV_SONA_STAGING` | `DIVVY.DEV_SONA_MARTS` |
| `dev_<teammate>` | `DIVVY.DEV_<TEAMMATE>_STAGING` | `DIVVY.DEV_<TEAMMATE>_MARTS` |
| `prod` | `DIVVY.PROD_STAGING` | `DIVVY.PROD_MARTS` |

This is dbt's default behavior: the target's schema, then an underscore, then the layer's schema. You don't need to create these schemas. dbt creates them on the first run, which `DIVVY_ENGINEER` is allowed to do.

---

## Step 1: Create the project folders

**What it does:** sets up dbt's standard layout inside the repo.

In the Workspace file tree, create these folders. Use the **+** next to a folder name → **Folder**:

```
dbt/
└── divvy/
    ├── models/
    │   ├── staging/
    │   ├── intermediate/
    │   └── marts/
    ├── tests/
    └── macros/
```

> Workspaces are per-person. Each teammate creates their own Git-connected Workspace for the same repo. Everyone works on the same files through Git: **Pull** before starting work, and **Push** when done.

---

## Step 2: `dbt_project.yml`

**What it does:** the project's main settings: its name, which profile to use, where the models are, and how each layer is built.

**Why these choices:**
- **Staging as views:** cheap to keep around, and always reflect the latest raw data.
- **Intermediate and marts as tables:** these do the heavy logic, like stockout episodes and joins. Saving them as tables makes the dashboard and MCP queries fast.
- `stg_station_status` is the exception. It's set to a table in its own file (Step 5), because it flattens millions of rows, and rerunning that work in every downstream query would waste credits.

Create `dbt/divvy/dbt_project.yml`:

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

---

## Step 3: `profiles.yml`

**What it does:** tells dbt which role, warehouse, database, and schema to use. Each *target* is one setup you can pick from the Workspace's **Profile** dropdown.

**Why `account` and `user` say "not needed":** inside Snowflake, dbt runs as the signed-in user, so it doesn't need real values. dbt still expects the keys to exist, so they're filled with placeholders. **No passwords go in this file**, which makes it safe to commit.

Create `dbt/divvy/profiles.yml`, adding one `dev_` target per teammate:

```yaml
divvy:
  target: dev_sona
  outputs:
    dev_sona:
      type: snowflake
      account: 'not needed'
      user: 'not needed'
      role: DIVVY_ENGINEER
      database: DIVVY
      warehouse: DIVVY_WH
      schema: DEV_SONA
      threads: 8

    dev_teammate2:
      type: snowflake
      account: 'not needed'
      user: 'not needed'
      role: DIVVY_ENGINEER
      database: DIVVY
      warehouse: DIVVY_WH
      schema: DEV_TEAMMATE2
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

> If you also want to run dbt from your Mac or Cloud Shell later, those runs need a separate profile with a real account, user, and login method. Keep that in `~/.dbt/` on your machine, never in the repo.

---

## Step 4: Declare the raw sources

**What it does:** lists the raw tables dbt reads from. Models then use `{{ source('raw', 'station_status_raw') }}` instead of a hard-coded table name. This also lets dbt draw the lineage graph from raw to marts, and test the raw data.

Create `dbt/divvy/models/staging/_sources.yml`:

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
        description: Open-Meteo hourly archive, one row per yearly file.
      - name: cta_stops_raw
        description: CTA GTFS stops.txt; L stations are LOCATION_TYPE = 1 with stop IDs 40000-49999.
```

---

## Step 5: The first model, `stg_station_status`

**What it does:**
1. **Flattens** each poller file into one row per station per snapshot. This is the same `LATERAL FLATTEN` used in the Snowflake runbook's checks.
2. **Renames and types** every field: integers, booleans, and real timestamps instead of Unix seconds.
3. **Removes repeated readings.** A quiet station reports the same `last_reported` time for many minutes in a row. This keeps the first time each distinct report was seen, which shrinks the table a lot without losing any changes.

**Why it's a table:** flattening tens of thousands of files into tens of millions of rows takes real compute. Doing it once per dbt run, instead of in every downstream query, saves credits. It can become an incremental model later, when the data is bigger.

Create `dbt/divvy/models/staging/stg_station_status.sql`:

```sql
{{ config(materialized='table') }}

with snapshots as (

    select
        r.file_name,
        r.file_last_modified                              as polled_at,
        to_timestamp(r.raw:last_updated::int)             as feed_updated_at,
        s.value                                           as st
    from {{ source('raw', 'station_status_raw') }} r,
         lateral flatten(input => r.raw:data:stations) s

),

parsed as (

    select
        st:station_id::string                             as station_id,
        to_timestamp(st:last_reported::int)               as last_reported_at,
        feed_updated_at,
        polled_at,
        file_name,

        st:num_bikes_available::int                       as bikes_available,
        st:num_ebikes_available::int                      as ebikes_available,
        st:num_bikes_disabled::int                        as bikes_disabled,
        st:num_docks_available::int                       as docks_available,
        st:num_docks_disabled::int                        as docks_disabled,

        st:is_installed::int = 1                          as is_installed,
        st:is_renting::int   = 1                          as is_renting,
        st:is_returning::int = 1                          as is_returning

    from snapshots

)

select *
from parsed
-- keep the first poll that saw each distinct station report
qualify row_number() over (
    partition by station_id, last_reported_at
    order by polled_at
) = 1
```

**Notes for the team:**
- `bikes_available` already includes e-bikes. Don't add `ebikes_available` on top of it. Agree on the exact definitions of "empty" and "full" at the November 11 meeting. A proposal: *empty* = `bikes_available = 0`, *full* = `docks_available = 0`, both counted only when `is_renting` and `is_returning` are true.
- `polled_at` is when your poller saw the reading. `last_reported_at` is when the station itself last reported. A large gap between them means the station has gone quiet or offline. That's worth flagging in a later model, since a quiet station isn't necessarily empty.
- If `feed_updated_at` comes back null, the top-level `last_updated` field sits somewhere else in the JSON. `polled_at` works as the snapshot time instead.

### Add tests for it

Create `dbt/divvy/models/staging/_staging.yml`:

```yaml
version: 2

models:
  - name: stg_station_status
    description: One row per station per distinct report, flattened from the live GBFS feed.
    columns:
      - name: station_id
        tests:
          - not_null
      - name: last_reported_at
        tests:
          - not_null
      - name: bikes_available
        tests:
          - not_null
      - name: docks_available
        tests:
          - not_null
```

These use dbt's built-in tests, so no extra packages are needed. A uniqueness test on the station and report-time pair, plus checks that counts are never negative, come next in Step 8.

---

## Step 6: Run it in the Workspace

**What it does:** compiles and runs the project inside Snowflake.

1. In the Workspace toolbar, choose:
   - **Project:** `dbt/divvy`
   - **Profile:** your own target, for example `dev_sona`
2. Choose **Compile** and click the run button. This checks that everything parses and draws the lineage graph. Fix any errors it reports before continuing.
3. Choose **Run** and run it. This builds `stg_station_status` as a table in `DIVVY.DEV_SONA_STAGING`.
4. Choose **Test** and run it. All four tests should pass.

The **Output** tab shows the result once each command finishes. It doesn't stream while the command runs, so a long run looks stalled until it's done.

> **No `dbt deps` needed yet.** That command downloads extra packages like `dbt_utils`, which needs a network setup in Snowflake. The built-in tests are enough for now. If you add `packages.yml` later, an admin creates the network access once. See Snowflake's docs on external access integrations for dbt deps.

---

## Step 7: Check the result

In a SQL file in the Workspace:

```sql
USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;

-- Rows, stations, and date range
SELECT COUNT(*)                     AS rows_kept,
       COUNT(DISTINCT station_id)   AS stations,
       MIN(polled_at)               AS first_poll,
       MAX(polled_at)               AS latest_poll
FROM DIVVY.DEV_SONA_STAGING.STG_STATION_STATUS;

-- How much the deduplication shrank the data
SELECT
  (SELECT COUNT(*)
     FROM DIVVY.RAW.STATION_STATUS_RAW r,
          LATERAL FLATTEN(input => r.RAW:data:stations))            AS raw_station_rows,
  (SELECT COUNT(*) FROM DIVVY.DEV_SONA_STAGING.STG_STATION_STATUS)   AS staged_rows;

-- A quick look at one busy station over time
SELECT station_id, last_reported_at, bikes_available, docks_available, is_renting
FROM DIVVY.DEV_SONA_STAGING.STG_STATION_STATUS
WHERE station_id = (SELECT station_id FROM DIVVY.DEV_SONA_STAGING.STG_STATION_STATUS LIMIT 1)
ORDER BY last_reported_at
LIMIT 50;
```

What to expect:
- **Stations:** about 2,000.
- **Staged rows:** noticeably fewer than raw station rows. The difference is the repeated readings that were removed. Record both numbers, since they're good figures for the check-in deck.

---

## Step 8: Commit and push

In the Workspace, go to **Changes**, write a commit message like `Add dbt project skeleton and stg_station_status`, and click **Push**.

Teammates then **Pull** in their own Workspace, add their `dev_` target to `profiles.yml` if it isn't there, and run with their own profile.

> **Don't commit `target/` or `logs/`.** These are generated by every run. If they show up under Changes, add a `.gitignore` in `dbt/divvy/` containing:
> ```
> target/
> dbt_packages/
> logs/
> ```

---

## Next models (in suggested order)

| Model | Layer | What it does |
|---|---|---|
| `stg_station_information` | staging | Latest station details: name, `short_name`, lat/lon, capacity. Flags racks and corrals |
| `stg_trips` | staging | Casts trip text columns to types; flags trips with no station; checks that each file's dates match the month in its name |
| `stg_weather` | staging | Lines up Open-Meteo's parallel lists into one row per hour (the query in the Snowflake runbook, Step 10b) |
| `stg_cta_l_stations` | staging | Filters CTA stops to the L stations |
| `int_station_crosswalk` | intermediate | Trip station ID → live `station_id`, matched on `short_name` first, then name, recording the method |
| `int_station_status_flags` | intermediate | Adds `is_empty`, `is_full`, and `is_stale` (the station hasn't reported recently) to each staged row |
| `fct_stockout_events` | marts | Gaps-and-islands: one row per empty or full episode, with start, end, and duration |
| `fct_station_snapshots` | marts | Cleaned snapshots joined to the station, time, and weather keys |
| `dim_station`, `dim_time`, `dim_weather` | marts | Star schema dimensions, including each station's distance to the nearest L stop |

Write tests as you go:
- `unique` on each dimension's key
- `relationships` from each fact table to its dimensions
- a custom test that counts are never negative
- a custom test that each trip file only contains its own month

---

## Running on a schedule (later)

Once the models are stable, **deploy** the project as a dbt project object. Use **Connect → Deploy dbt project** in the Workspace, or `snow dbt deploy` from the CLI. Then schedule it.

**Option 1: a Snowflake task.** Note that dbt projects need a regular warehouse, not a serverless task:

```sql
CREATE OR REPLACE TASK DIVVY.RAW.RUN_DBT_HOURLY
  WAREHOUSE = DIVVY_WH
  SCHEDULE = 'USING CRON 20 * * * * UTC'   -- after the :05 COPY INTO
AS
  EXECUTE DBT PROJECT DIVVY.RAW.DIVVY_DBT ARGS = 'build --target prod';
```

**Option 2: Airflow,** which calls `EXECUTE DBT PROJECT` after the loads finish. This option also covers the class's Airflow requirement, and it can run the weather refresh in the same DAG.

Only one `EXECUTE DBT PROJECT` can run at a time on the same project object, so don't schedule overlapping runs.

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| Project or Profile doesn't appear in the dropdowns | The Workspace can't find `dbt_project.yml` or `profiles.yml` | Both must be directly inside `dbt/divvy/`. Check the spelling, then Pull or refresh |
| `Insufficient privileges` creating a schema | Wrong role in the profile | Set `role: DIVVY_ENGINEER`, and confirm the role has `ALL` on the `DIVVY` database (Snowflake runbook, Step 2) |
| `Object 'DIVVY.RAW.STATION_STATUS_RAW' does not exist` | Source name or schema mismatch | Compare `_sources.yml` with `SHOW TABLES IN SCHEMA DIVVY.RAW;`. Snowflake names are uppercase, and dbt matches them case-insensitively |
| Run is slow and uses credits | Flattening all raw files every run | Expected at first. Make `stg_station_status` incremental once the logic is settled |
| Tests fail on `not_null` | Some stations missing fields in some snapshots | Query the failing rows (the Output tab shows the test SQL) and decide whether to filter them or fill a default |
| Push rejected in Workspace | A teammate pushed first | Click **Pull**, resolve any conflicts in the editor, then Push |
