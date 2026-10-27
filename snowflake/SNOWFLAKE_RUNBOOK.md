# Snowflake Setup Runbook

This guide connects Snowflake to the bucket the poller fills, loads the live Divvy files into tables, schedules new loads automatically, and loads the historical data (trips, weather, CTA stations).

**What Snowflake does in this project:** it's the data warehouse. The bucket holds raw files. Snowflake turns them into tables that can be joined and queried with SQL. dbt, the dashboard, and the MCP server all work from Snowflake.

```
Divvy feed → poller → GCS bucket (raw files) → SNOWFLAKE (raw → staging → marts) → dashboard / MCP
                                                   ↑
                          trip history, weather, CTA stations (also staged in the bucket)
```

**Where to run things:**
- **SQL** runs in Snowflake's web interface, called **Snowsight**. Open **Projects → Workspaces** (or **Worksheets**), create a new SQL file, paste a block, and run it. Run one block at a time and check the result.
- **`gcloud` commands** run in Cloud Shell, after loading the project settings:
  ```bash
  source ~/CNDE/Divvy/divvy-project/ingestion/env.sh
  cd ~/CNDE/Divvy/divvy-project
  ```

**Who runs it:** one person (Sona) does Steps 1–10, because several steps need Snowflake's `ACCOUNTADMIN` role and GCP Owner permissions. Teammates get their own Snowflake logins in Step 3.

| Setting | Value |
|---|---|
| GCP project | `divvy-project-512716` |
| Bucket | `gs://divvy-raw-srv` |
| Snowflake cloud and region | Google Cloud, US Central1 (Iowa) |
| Warehouse | `DIVVY_WH` (X-Small) |
| Database | `DIVVY` |
| Team role | `DIVVY_ENGINEER` |

---

## Read this first: the trial ends before the final deadline

Snowflake's free trial lasts **30 days** with **$400 in credits**, whichever runs out first. When it ends, the account is suspended: you can still log in, but you can't run warehouses, load data, or query.

A trial started this week ends around late November, **before the December 11 deadline**. Decide on a plan now:

1. **Ask the professor or TA** whether the course has Snowflake education accounts or a recommended setup. This is the best first step.
2. **Upgrade the trial before it expires.** Upgrading to pay-as-you-go keeps all data and worksheets, and any unused trial credits still apply. You only pay once the credits are used up. With the cost controls below, usage should stay well under $400.
3. **Time the start date.** Starting the trial later gives you more days after the check-in, but you still need it working before November 17. This only helps a little, so treat it as a last resort.

Add a calendar reminder for **5 days before the trial ends**, whatever you choose.

---

## Step 1: Create the Snowflake account

**What it does:** creates the Snowflake account the team will share.

**The choices that matter, which can't be changed later:**
- **Cloud provider: Google Cloud Platform.** Choose **Region: US Central1 (Iowa)**, the same region as the bucket. Data moving between them then stays inside Google's network, so Google charges little or nothing for it. On a different cloud or region, every load would add data transfer costs.
- **Edition:** **Standard** stretches the trial credits furthest, at about $2 per credit compared with about $3 for Enterprise. It includes everything this project needs: tasks, stages, and Streamlit. Enterprise adds longer Time Travel and governance features you don't need here.

**Steps:**
1. Go to signup.snowflake.com and sign up with your UChicago email.
2. Pick **Google Cloud Platform → US Central1 (Iowa)** and your edition.
3. Activate the account from the email and set a password. If Snowflake asks you to set up multi-factor authentication, do it.
4. Save your **account identifier**, which looks like `orgname-accountname`. You'll find it under your name in the bottom-left corner → **Connect a tool to Snowflake**, or under **Admin → Accounts**. dbt and Streamlit need it later.

Add it to `env.sh` so the team has it:

```bash
echo 'export SNOWFLAKE_ACCOUNT="orgname-accountname"' >> $REPO/ingestion/env.sh
```

---

## Step 2: Create the warehouse, database, and team role

**What it does:**
- **Warehouse:** the compute that runs queries and loads. Snowflake bills only while it's running.
- **Database:** the container for all your tables.
- **Role:** a set of permissions. Everyone on the team uses `DIVVY_ENGINEER`, so everyone can work with the same objects.

**Why these warehouse settings:** X-Small is the cheapest size and plenty for this project. `AUTO_SUSPEND = 60` shuts the warehouse off after 60 seconds idle, so it doesn't burn credits overnight. `AUTO_RESUME` restarts it automatically when someone runs a query.

Run in Snowsight as `ACCOUNTADMIN` (the role picker is at the top of the worksheet):

```sql
USE ROLE ACCOUNTADMIN;

-- Compute
CREATE WAREHOUSE IF NOT EXISTS DIVVY_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

-- Storage container
CREATE DATABASE IF NOT EXISTS DIVVY;

-- Team role
CREATE ROLE IF NOT EXISTS DIVVY_ENGINEER;
GRANT ROLE DIVVY_ENGINEER TO ROLE SYSADMIN;   -- standard practice: admins inherit it

-- What the team role can do
GRANT USAGE, OPERATE ON WAREHOUSE DIVVY_WH TO ROLE DIVVY_ENGINEER;
GRANT ALL ON DATABASE DIVVY TO ROLE DIVVY_ENGINEER;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE DIVVY_ENGINEER;  -- needed for scheduled loads (Step 9)

-- Give yourself the role
GRANT ROLE DIVVY_ENGINEER TO USER <YOUR_SNOWFLAKE_USERNAME>;
```

Replace `<YOUR_SNOWFLAKE_USERNAME>` with the username shown under your name in the bottom-left corner.

### Set a spending limit

**What it does:** a resource monitor tracks credits used by the warehouse. It sends a warning at 75% of the limit and suspends the warehouse at 100%. That way a mistake can't drain the trial, for example a task scheduled too often or a query left running.

```sql
USE ROLE ACCOUNTADMIN;

CREATE RESOURCE MONITOR IF NOT EXISTS DIVVY_RM
  WITH CREDIT_QUOTA = 100
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE DIVVY_WH SET RESOURCE_MONITOR = DIVVY_RM;
```

100 credits is roughly $200–300, depending on edition. Expected usage is far lower than that, so hitting the limit would mean something went wrong.

---

## Step 3: Add teammates

**What it does:** creates a Snowflake login for each teammate and gives them the team role.

Run once per teammate, with their details filled in:

```sql
USE ROLE ACCOUNTADMIN;

CREATE USER IF NOT EXISTS TEAMMATE_USERNAME
  PASSWORD = 'TempPassword-ChangeMe-2026'
  MUST_CHANGE_PASSWORD = TRUE
  EMAIL = 'teammate@uchicago.edu'
  DEFAULT_ROLE = DIVVY_ENGINEER
  DEFAULT_WAREHOUSE = DIVVY_WH;

GRANT ROLE DIVVY_ENGINEER TO USER TEAMMATE_USERNAME;
```

Send each teammate their username, temporary password, and the account URL privately, not through GitHub. They'll be asked to change the password at first login, and Snowflake may ask them to set up multi-factor authentication.

---

## Step 4: Create the storage integration (Snowflake side)

**What it does:** a storage integration is Snowflake's secure connection to your bucket. When you create one, Snowflake generates **its own Google service account**. In Step 5, you give that account permission to read the bucket. No keys or passwords are exchanged.

**Why it's limited to one bucket:** `STORAGE_ALLOWED_LOCATIONS` means this integration can only ever reach `divvy-raw-srv`.

```sql
USE ROLE ACCOUNTADMIN;

CREATE STORAGE INTEGRATION IF NOT EXISTS GCS_DIVVY_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'GCS'
  ENABLED = TRUE
  STORAGE_ALLOWED_LOCATIONS = ('gcs://divvy-raw-srv/');

GRANT USAGE ON INTEGRATION GCS_DIVVY_INT TO ROLE DIVVY_ENGINEER;

DESC STORAGE INTEGRATION GCS_DIVVY_INT;
```

In the `DESC` output, find the row **`STORAGE_GCP_SERVICE_ACCOUNT`** and copy its value. It looks like `abc123@gcpuscentral1-xxxx.iam.gserviceaccount.com`. You need it in Step 5.

---

## Step 5: Let Snowflake read the bucket (GCP side, in Cloud Shell)

**What it does:** gives Snowflake's service account read-only access to the bucket.

**Why a custom role:** Snowflake needs exactly three permissions to load files: see the bucket, list the files, and read them. A custom role with only those three follows the same least-access idea as the poller's write-only account. Snowflake can read but never change or delete your raw data.

Save Snowflake's service account, using the value from Step 4:

```bash
echo 'export SNOWFLAKE_SA="paste-STORAGE_GCP_SERVICE_ACCOUNT-here"' >> $REPO/ingestion/env.sh
source $REPO/ingestion/env.sh
echo $SNOWFLAKE_SA
```

Create the read-only role:

```bash
gcloud iam roles create snowflakeReader \
  --project=$PROJECT_ID \
  --title="Snowflake bucket reader" \
  --permissions=storage.buckets.get,storage.objects.get,storage.objects.list
```

Give it to Snowflake's account, on this bucket only:

```bash
gcloud storage buckets add-iam-policy-binding gs://$BUCKET \
  --member="serviceAccount:$SNOWFLAKE_SA" \
  --role="projects/$PROJECT_ID/roles/snowflakeReader"
```

> **If this fails with a message about members not belonging to a permitted domain or customer**, UChicago's organization is blocking access for accounts outside the university, and Snowflake's account is outside it. You can't fix this yourself. Send the exact error to the professor or TA, and mention that you're connecting Snowflake to a GCS bucket.

---

## Step 6: Create schemas, file formats, and the stage

**What it does:**
- **Schemas** organize the database into layers. `RAW` holds data exactly as loaded. dbt will create its own staging and mart schemas later.
- **File formats** tell Snowflake how to read files: JSON for the live feed, CSV for the trip history.
- **The stage** is Snowflake's pointer to the bucket. `@RAW.DIVVY_GCS_STAGE/station_status/` then means "the station_status folder in the bucket."

From here on, work as the **team role**, so the team owns everything it creates:

```sql
USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;
USE DATABASE DIVVY;

CREATE SCHEMA IF NOT EXISTS RAW;
USE SCHEMA RAW;

-- How to read the live feed files (one JSON object per file)
CREATE FILE FORMAT IF NOT EXISTS JSON_FF
  TYPE = JSON;

-- How to read the trip history CSVs (gzipped, with a header row)
CREATE FILE FORMAT IF NOT EXISTS TRIPS_CSV_FF
  TYPE = CSV
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  EMPTY_FIELD_AS_NULL = TRUE
  COMPRESSION = AUTO;

-- How to read CTA GTFS files (match columns by header name)
CREATE FILE FORMAT IF NOT EXISTS GTFS_CSV_FF
  TYPE = CSV
  PARSE_HEADER = TRUE
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  EMPTY_FIELD_AS_NULL = TRUE;

-- Pointer to the bucket, using the integration from Step 4
CREATE STAGE IF NOT EXISTS DIVVY_GCS_STAGE
  URL = 'gcs://divvy-raw-srv/'
  STORAGE_INTEGRATION = GCS_DIVVY_INT
  FILE_FORMAT = JSON_FF;
```

**Test the connection.** This lists files in the bucket:

```sql
LIST @DIVVY_GCS_STAGE/station_status/ PATTERN = '.*[.]json';
```

You should see the poller's files. If you get an access error, the Step 5 permission may still be taking effect. Wait two minutes and try again.

---

## Step 7: Create raw tables and do the first load

**What it does:** creates one raw table per feed and loads every file currently in the bucket. Each file becomes **one row**, holding the full snapshot of all ~2,000 stations as JSON in a `VARIANT` column. dbt splits it into one row per station later.

**Why keep the file name:** `METADATA$FILENAME` records which file each row came from. That makes it easy to trace problems, find gaps, and confirm nothing loaded twice.

```sql
USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;
USE SCHEMA DIVVY.RAW;

CREATE TABLE IF NOT EXISTS STATION_STATUS_RAW (
  RAW                 VARIANT,
  FILE_NAME           STRING,
  FILE_LAST_MODIFIED  TIMESTAMP_NTZ,
  LOADED_AT           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS STATION_INFORMATION_RAW (
  RAW                 VARIANT,
  FILE_NAME           STRING,
  FILE_LAST_MODIFIED  TIMESTAMP_NTZ,
  LOADED_AT           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);
```

Load station status:

```sql
COPY INTO STATION_STATUS_RAW (RAW, FILE_NAME, FILE_LAST_MODIFIED)
FROM (
  SELECT $1, METADATA$FILENAME, METADATA$FILE_LAST_MODIFIED
  FROM @DIVVY_GCS_STAGE/station_status/
)
PATTERN = '.*[.]json'
FILE_FORMAT = (FORMAT_NAME = 'JSON_FF');
```

Load station information:

```sql
COPY INTO STATION_INFORMATION_RAW (RAW, FILE_NAME, FILE_LAST_MODIFIED)
FROM (
  SELECT $1, METADATA$FILENAME, METADATA$FILE_LAST_MODIFIED
  FROM @DIVVY_GCS_STAGE/station_information/
)
PATTERN = '.*[.]json'
FILE_FORMAT = (FORMAT_NAME = 'JSON_FF');
```

**How `COPY INTO` avoids duplicates:** Snowflake remembers which files it has already loaded into each table, for 64 days. Running the same `COPY INTO` again only loads new files, which is what makes the scheduled loads in Step 9 safe. The project's data window is under 64 days, so this covers it.

---

## Step 8: Check the data

**What it does:** confirms the loads worked and the JSON looks right, before building anything on top of it.

How many files loaded, and the time range they cover:

```sql
SELECT COUNT(*)                 AS files_loaded,
       MIN(FILE_LAST_MODIFIED)  AS first_file,
       MAX(FILE_LAST_MODIFIED)  AS latest_file
FROM STATION_STATUS_RAW;
```

`files_loaded` should roughly match the number of minutes since collection started.

A preview of one row per station, the same splitting dbt will do:

```sql
SELECT
    TO_TIMESTAMP(r.RAW:last_updated::INT)       AS snapshot_ts,
    s.value:station_id::STRING                  AS station_id,
    s.value:num_bikes_available::INT            AS bikes_available,
    s.value:num_ebikes_available::INT           AS ebikes_available,
    s.value:num_bikes_disabled::INT             AS bikes_disabled,
    s.value:num_docks_available::INT            AS docks_available,
    s.value:num_docks_disabled::INT             AS docks_disabled,
    s.value:is_renting::INT                     AS is_renting,
    s.value:is_returning::INT                   AS is_returning,
    TO_TIMESTAMP(s.value:last_reported::INT)    AS last_reported_ts
FROM STATION_STATUS_RAW r,
     LATERAL FLATTEN(input => r.RAW:data:stations) s
LIMIT 20;
```

- `RAW:data:stations` follows the JSON path to the list of stations.
- `LATERAL FLATTEN` turns that list into one row per station.
- `TO_TIMESTAMP` converts the Unix timestamps into readable dates.

If the top-level `last_updated` comes back empty, open one file to check where the timestamp actually is. You can still use `last_reported` or the file's timestamp instead.

Stations per snapshot. This should be about 2,000:

```sql
SELECT r.FILE_NAME, COUNT(*) AS stations
FROM STATION_STATUS_RAW r,
     LATERAL FLATTEN(input => r.RAW:data:stations) s
GROUP BY r.FILE_NAME
ORDER BY r.FILE_NAME DESC
LIMIT 5;
```

---

## Step 9: Schedule loads automatically

**What it does:** creates Snowflake **tasks** that run the `COPY INTO` commands on a schedule, so new files keep loading without anyone clicking anything.

**Why hourly and not every minute:** each time the warehouse starts, Snowflake bills at least 60 seconds of compute. Loading every 15 minutes would mean 96 warehouse starts a day, enough to use a large part of the trial credits over the quarter. Hourly means 24 short runs a day, a small fraction of the credits. The raw files are safe in the bucket either way, so loading hourly loses nothing. Snowflake is just up to an hour behind.

```sql
USE ROLE DIVVY_ENGINEER;
USE SCHEMA DIVVY.RAW;

-- Station status: every hour at :05 (UTC)
CREATE OR REPLACE TASK LOAD_STATION_STATUS_HOURLY
  WAREHOUSE = DIVVY_WH
  SCHEDULE = 'USING CRON 5 * * * * UTC'
AS
  COPY INTO STATION_STATUS_RAW (RAW, FILE_NAME, FILE_LAST_MODIFIED)
  FROM (
    SELECT $1, METADATA$FILENAME, METADATA$FILE_LAST_MODIFIED
    FROM @DIVVY_GCS_STAGE/station_status/
  )
  PATTERN = '.*[.]json'
  FILE_FORMAT = (FORMAT_NAME = 'JSON_FF');

-- Station information: daily at 10:30 UTC (after the poller's 4am Chicago run)
CREATE OR REPLACE TASK LOAD_STATION_INFORMATION_DAILY
  WAREHOUSE = DIVVY_WH
  SCHEDULE = 'USING CRON 30 10 * * * UTC'
AS
  COPY INTO STATION_INFORMATION_RAW (RAW, FILE_NAME, FILE_LAST_MODIFIED)
  FROM (
    SELECT $1, METADATA$FILENAME, METADATA$FILE_LAST_MODIFIED
    FROM @DIVVY_GCS_STAGE/station_information/
  )
  PATTERN = '.*[.]json'
  FILE_FORMAT = (FORMAT_NAME = 'JSON_FF');

-- Tasks are created paused; turn them on
ALTER TASK LOAD_STATION_STATUS_HOURLY RESUME;
ALTER TASK LOAD_STATION_INFORMATION_DAILY RESUME;
```

**Check that the tasks are running** after the next hour mark:

```sql
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
FROM TABLE(DIVVY.INFORMATION_SCHEMA.TASK_HISTORY())
ORDER BY SCHEDULED_TIME DESC
LIMIT 10;
```

`STATE` should be `SUCCEEDED`.

> **Later upgrade (optional):** Snowpipe with auto-ingest loads each file within about a minute of it landing, which is closer to true streaming. On GCS it also needs Pub/Sub notifications from the bucket and a notification integration in Snowflake. Hourly tasks are enough for the check-in. Snowpipe is worth adding if you want a stronger streaming story for the final presentation.

---

## Step 10: Load the historical data

Each historical source follows the same pattern: **download in Cloud Shell → upload to the bucket under `historical/` → `COPY INTO` a raw table.** Keeping everything in the bucket means the raw files are saved permanently and Snowflake reads them all the same way.

### 10a. Divvy trip history

**What it is:** every Divvy trip, published as one zipped CSV per month. It's used to estimate past station inventory and to study demand patterns.

**Which years:** the monthly files from April 2020 onward share the same columns. Earlier files use a different layout, with different column names, so start with 2020–present. Add older years later only if the analysis needs them. Check the list of available files at `https://divvy-tripdata.s3.amazonaws.com/index.html`.

In Cloud Shell, this downloads each month, unzips it, gzips the CSV, uploads it, and deletes the local copy. That way Cloud Shell's limited disk space doesn't fill up. It takes a while, so run it and let it go:

```bash
source ~/CNDE/Divvy/divvy-project/ingestion/env.sh
mkdir -p /tmp/divvy_trips && cd /tmp/divvy_trips

d=2020-04-01
last=$(date -d "-1 month" +%Y%m)
while [ "$(date -d "$d" +%Y%m)" -le "$last" ]; do
  ym=$(date -d "$d" +%Y%m)
  zip="${ym}-divvy-tripdata.zip"
  if curl -sfO "https://divvy-tripdata.s3.amazonaws.com/${zip}"; then
    unzip -o -q "$zip" -x "__MACOSX/*"
    for f in *.csv; do gzip -f "$f"; done
    gcloud storage cp *.csv.gz gs://$BUCKET/historical/divvy_trips/ --quiet
    echo "uploaded $ym"
  else
    echo "MISSING $ym"
  fi
  rm -f *.zip *.csv *.csv.gz
  d=$(date -d "$d +1 month" +%Y-%m-%d)
done
```

Any `MISSING` month may have a different file name. Check the index page and download it by hand.

Then load the files in Snowflake. Every column is loaded as text first. dbt converts types later, so one oddly formatted row can't break the whole load:

```sql
USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;
USE SCHEMA DIVVY.RAW;

CREATE TABLE IF NOT EXISTS DIVVY_TRIPS_RAW (
  RIDE_ID             STRING,
  RIDEABLE_TYPE       STRING,
  STARTED_AT          STRING,
  ENDED_AT            STRING,
  START_STATION_NAME  STRING,
  START_STATION_ID    STRING,
  END_STATION_NAME    STRING,
  END_STATION_ID      STRING,
  START_LAT           STRING,
  START_LNG           STRING,
  END_LAT             STRING,
  END_LNG             STRING,
  MEMBER_CASUAL       STRING,
  FILE_NAME           STRING,
  LOADED_AT           TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

COPY INTO DIVVY_TRIPS_RAW (
  RIDE_ID, RIDEABLE_TYPE, STARTED_AT, ENDED_AT,
  START_STATION_NAME, START_STATION_ID, END_STATION_NAME, END_STATION_ID,
  START_LAT, START_LNG, END_LAT, END_LNG, MEMBER_CASUAL, FILE_NAME
)
FROM (
  SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, METADATA$FILENAME
  FROM @DIVVY_GCS_STAGE/historical/divvy_trips/
)
PATTERN = '.*[.]csv[.]gz'
FILE_FORMAT = (FORMAT_NAME = 'TRIPS_CSV_FF');
```

Check the row counts by file. You measured one month at about 770,000 rows. Summer months should be much higher than winter ones:

```sql
SELECT FILE_NAME, COUNT(*) AS trips
FROM DIVVY_TRIPS_RAW
GROUP BY FILE_NAME
ORDER BY FILE_NAME;

SELECT COUNT(*) AS total_trips FROM DIVVY_TRIPS_RAW;
```

Put the real total in the proposal's data sources table.

> **Station IDs don't match between sources.** Trip files use short station codes, while the live feed uses long numeric `station_id`s. The live `station_information` feed usually includes a `short_name` field that matches the trip files' station IDs. Confirm this before building the backfill. It's the join key between historical and live data.

### 10b. Weather (Open-Meteo)

**What it is:** hourly Chicago weather (temperature, precipitation, snow, wind speed and direction), free and with no API key. It's downloaded one year per file, in UTC, to match the poller's timestamps.

```bash
mkdir -p /tmp/weather && cd /tmp/weather
end_last=$(date -u -d "-6 days" +%Y-%m-%d)   # the archive runs a few days behind

for y in 2020 2021 2022 2023 2024 2025 2026; do
  start="${y}-01-01"
  end="${y}-12-31"
  [ "$y" = "2026" ] && end="$end_last"
  curl -sf "https://archive-api.open-meteo.com/v1/archive?latitude=41.8781&longitude=-87.6298&start_date=${start}&end_date=${end}&hourly=temperature_2m,precipitation,rain,snowfall,wind_speed_10m,wind_direction_10m,weather_code&timezone=UTC" \
    -o "weather_${y}.json" && echo "got $y"
done

gcloud storage cp weather_*.json gs://$BUCKET/historical/weather/
```

Load in Snowflake, one row per yearly file:

```sql
USE SCHEMA DIVVY.RAW;

CREATE TABLE IF NOT EXISTS WEATHER_RAW (
  RAW        VARIANT,
  FILE_NAME  STRING,
  LOADED_AT  TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

COPY INTO WEATHER_RAW (RAW, FILE_NAME)
FROM (SELECT $1, METADATA$FILENAME FROM @DIVVY_GCS_STAGE/historical/weather/)
PATTERN = '.*[.]json'
FILE_FORMAT = (FORMAT_NAME = 'JSON_FF');
```

Open-Meteo returns parallel lists: one list of times, one of temperatures, and so on. Line them up by position to get one row per hour:

```sql
SELECT
    t.value::TIMESTAMP_NTZ                                AS hour_utc,
    w.RAW:hourly:temperature_2m[t.index]::FLOAT           AS temp_c,
    w.RAW:hourly:precipitation[t.index]::FLOAT            AS precip_mm,
    w.RAW:hourly:snowfall[t.index]::FLOAT                 AS snow_cm,
    w.RAW:hourly:wind_speed_10m[t.index]::FLOAT           AS wind_kmh,
    w.RAW:hourly:wind_direction_10m[t.index]::FLOAT       AS wind_dir_deg
FROM WEATHER_RAW w,
     LATERAL FLATTEN(input => w.RAW:hourly:time) t
LIMIT 24;
```

This is a preview. The same logic becomes a dbt staging model.

For the live weeks, rerun the download for the current year now and then, or add a small daily job later. Make it part of the Airflow DAG.

### 10c. CTA L stations (GTFS)

**What it is:** CTA's published schedule data. You only need `stops.txt`, which has every stop's name and coordinates, to calculate each Divvy station's distance to the nearest L stop.

```bash
mkdir -p /tmp/gtfs && cd /tmp/gtfs
curl -sfL -o google_transit.zip https://www.transitchicago.com/downloads/sch_data/google_transit.zip
unzip -o -q google_transit.zip stops.txt
head -3 stops.txt
gcloud storage cp stops.txt gs://$BUCKET/historical/cta_gtfs/stops.txt
```

Check the header that `head -3` prints. The table below matches columns by name, so extra columns in the file are simply skipped.

```sql
USE SCHEMA DIVVY.RAW;

CREATE TABLE IF NOT EXISTS CTA_STOPS_RAW (
  STOP_ID         STRING,
  STOP_CODE       STRING,
  STOP_NAME       STRING,
  STOP_DESC       STRING,
  STOP_LAT        STRING,
  STOP_LON        STRING,
  LOCATION_TYPE   STRING,
  PARENT_STATION  STRING
);

COPY INTO CTA_STOPS_RAW
FROM @DIVVY_GCS_STAGE/historical/cta_gtfs/stops.txt
FILE_FORMAT = (FORMAT_NAME = 'GTFS_CSV_FF')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

**Finding the L stations:** in CTA's GTFS data, L stations are the parent stations (`LOCATION_TYPE = 1`), with stop IDs in the 40000s. Bus stops make up most of the other rows.

```sql
SELECT STOP_ID, STOP_NAME, STOP_LAT, STOP_LON
FROM CTA_STOPS_RAW
WHERE LOCATION_TYPE = '1'
  AND TRY_TO_NUMBER(STOP_ID) BETWEEN 40000 AND 49999
ORDER BY STOP_NAME;
```

This should return about 140–150 stations.

---

## Step 11: Save the SQL to GitHub

**What it does:** keeps every setup statement in the repo, so the team and the grader can see exactly how Snowflake was built, and so it can be rebuilt if needed.

Create a folder and save each step's SQL as its own file. Copy the blocks from this runbook, or download them from Snowsight:

```bash
cd $REPO
git pull
mkdir -p snowflake/setup
# e.g. snowflake/setup/01_warehouse_db_role.sql
#      snowflake/setup/02_resource_monitor.sql
#      snowflake/setup/03_users.sql            ← leave out real passwords
#      snowflake/setup/04_storage_integration.sql
#      snowflake/setup/05_raw_schema_stage.sql
#      snowflake/setup/06_raw_tables_copy.sql
#      snowflake/setup/07_tasks.sql
#      snowflake/setup/08_historical_loads.sql
```

```bash
git add snowflake/ ingestion/env.sh
git status
git commit -m "Add Snowflake setup SQL and env vars"
git push
```

**Never commit passwords.** In `03_users.sql`, replace them with a placeholder like `'<set-privately>'`.

---

## Ongoing checks

Is Snowflake keeping up with the bucket? The latest file loaded should be less than about an hour old:

```sql
SELECT MAX(FILE_LAST_MODIFIED) AS latest_loaded,
       DATEDIFF('minute', MAX(FILE_LAST_MODIFIED), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ) AS minutes_behind
FROM DIVVY.RAW.STATION_STATUS_RAW;
```

Files per day in Snowflake. Each full day should be about 1,440:

```sql
SELECT DATE(FILE_LAST_MODIFIED) AS day, COUNT(*) AS files
FROM DIVVY.RAW.STATION_STATUS_RAW
GROUP BY day
ORDER BY day DESC;
```

Credits used so far (requires `ACCOUNTADMIN`):

```sql
USE ROLE ACCOUNTADMIN;
SELECT DATE(START_TIME) AS day, SUM(CREDITS_USED) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE WAREHOUSE_NAME = 'DIVVY_WH'
GROUP BY day
ORDER BY day DESC;
```

This view can lag a few hours behind. The trial balance tile in Snowsight's left navigation is the quickest check.

To pause loading, for example once the project is done:

```sql
ALTER TASK DIVVY.RAW.LOAD_STATION_STATUS_HOURLY SUSPEND;
ALTER TASK DIVVY.RAW.LOAD_STATION_INFORMATION_DAILY SUSPEND;
```

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| `LIST @DIVVY_GCS_STAGE` gives an access or 403 error | Step 5 permission not applied yet, or applied to the wrong account | Wait 2 minutes. Check that `$SNOWFLAKE_SA` exactly matches `STORAGE_GCP_SERVICE_ACCOUNT` from `DESC STORAGE INTEGRATION` |
| Step 5 fails: member "does not belong to a permitted customer" or domain | UChicago org policy blocks outside accounts | Send the exact error to the professor or TA |
| "Insufficient privileges" in Snowsight | Using the wrong role | Check the role picker. Use `ACCOUNTADMIN` for Steps 2–4 and `DIVVY_ENGINEER` from Step 6 on |
| `COPY INTO` loads 0 files | Files were already loaded, or the pattern or path is wrong | Run `LIST` on the same path. If the files appear, they were probably loaded already, so check the table's row count |
| Task never runs | Task wasn't resumed, or the role lacks `EXECUTE TASK` | `SHOW TASKS IN SCHEMA DIVVY.RAW;` and check `state`. Rerun the `RESUME` and the Step 2 grant |
| Trip load fails on some file | An older file has a different layout | Find it with `VALIDATE`, or temporarily add `ON_ERROR = 'CONTINUE'` and check which files errored |
| Warehouse suspended unexpectedly | Resource monitor hit 100% | Find what used the credits (credit query above) before raising the limit |
| Credits dropping faster than expected | A task scheduled too often, or a large query left running | `SHOW TASKS;` and check schedules. Confirm `AUTO_SUSPEND = 60` with `SHOW WAREHOUSES;` |

---

## What comes next

Once Steps 1–10 work, the raw layer is done. Next:

1. **Connect dbt to Snowflake.** Install `dbt-snowflake`, then set up `profiles.yml` with the account identifier, the `DIVVY_ENGINEER` role, `DIVVY_WH`, and the `DIVVY` database. For automated runs (Airflow, Streamlit), create a separate service user with key-pair login instead of a personal password.
2. **Build the staging models:** flatten station status (the Step 8 query), remove repeated readings using `last_reported`, flatten weather (the Step 10b query), type-cast the trips, and filter CTA stops to L stations.
3. **Build the marts for the November 17 check-in:** the station snapshot fact table, the stockout events fact table, and the station, time, and weather dimensions.
