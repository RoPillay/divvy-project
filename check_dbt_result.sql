USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;

-- Rows, stations, and date range
SELECT COUNT(*)                     AS rows_kept,
       COUNT(DISTINCT station_id)   AS stations,
       MIN(polled_at)               AS first_poll,
       MAX(polled_at)               AS latest_poll
FROM DIVVY.DEV_STAGING.STG_STATION_STATUS;

-- How much the deduplication shrank the data
SELECT
  (SELECT COUNT(*)
     FROM DIVVY.RAW.STATION_STATUS_RAW r,
          LATERAL FLATTEN(input => r.RAW:data:stations))            AS raw_station_rows,
  (SELECT COUNT(*) FROM DIVVY.DEV_STAGING.STG_STATION_STATUS)   AS staged_rows;

-- A quick look at one busy station over time
SELECT station_id, last_reported_at, bikes_available, docks_available, is_renting
FROM DIVVY.DEV_STAGING.STG_STATION_STATUS
WHERE station_id = (SELECT station_id FROM DIVVY.DEV_STAGING.STG_STATION_STATUS LIMIT 1)
ORDER BY last_reported_at
LIMIT 50;