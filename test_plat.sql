USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;

SELECT COUNT(*) AS station_hours, COUNT(DISTINCT station_id) AS stations,
       MIN(hour_utc) AS first_hour, MAX(hour_utc) AS last_hour,
       ROUND(AVG(minutes_observed), 1) AS avg_minutes_observed
FROM DIVVY.DEV_SERVING.SRV_STATION_HOUR;


SELECT
  COUNT(*)                                        AS intervals,
  COUNT_IF(duration_min > 30)                     AS over_30_min,
  ROUND(100 * COUNT_IF(duration_min > 30) / COUNT(*), 1) AS pct_over_30_min,
  ROUND(100 * SUM(IFF(duration_min > 30, duration_min, 0)) / SUM(duration_min), 1) AS pct_of_time_over_30_min
FROM DIVVY.DEV_INTERMEDIATE.INT_STATION_STATUS_INTERVALS;


-- How many station-hours fall before collection started?
SELECT hour_utc < '2026-10-27 01:00:00' AS before_collection,
       COUNT(*) AS station_hours,
       COUNT(DISTINCT station_id) AS stations,
       MIN(hour_utc) AS earliest_hour
FROM DIVVY.DEV_SERVING.SRV_STATION_HOUR
GROUP BY 1;


SELECT s.station_name,
       COUNT_IF(i.is_stale)                                              AS stale_intervals,
       ROUND(SUM(IFF(i.is_stale, i.duration_min, 0)) / 60)               AS stale_hours,
       ROUND(100 * SUM(IFF(i.is_stale, i.duration_min, 0)) / SUM(i.duration_min), 1) AS pct_time_stale,
       MAX(IFF(i.is_stale, i.station_state, NULL))                       AS state_while_silent
FROM DIVVY.DEV_INTERMEDIATE.INT_STATION_STATUS_INTERVALS i
JOIN DIVVY.DEV_MARTS.DIM_STATION s ON i.station_id = s.station_id
GROUP BY s.station_name
HAVING stale_hours > 0
ORDER BY stale_hours DESC
LIMIT 25;

SELECT COUNT(*) AS stations_mostly_silent
FROM (
  SELECT station_id, SUM(IFF(is_stale, duration_min, 0)) / SUM(duration_min) AS pct_stale
  FROM DIVVY.DEV_INTERMEDIATE.INT_STATION_STATUS_INTERVALS
  GROUP BY station_id
)
WHERE pct_stale > 0.5;


SELECT
  ROUND(100 * SUM(IFF(is_stale, duration_min, 0)) / SUM(duration_min), 1) AS pct_time_stale_docked_stations
FROM DIVVY.DEV_INTERMEDIATE.INT_STATION_STATUS_INTERVALS
WHERE NOT is_rack_or_corral;



-- Which intervals start before collection, and how long are they?
SELECT station_id, valid_from, valid_to, ROUND(duration_min / 60) AS hours, station_state
FROM DIVVY.DEV_INTERMEDIATE.INT_STATION_STATUS_INTERVALS
WHERE valid_from < '2026-10-27 01:00:00'
ORDER BY valid_from
LIMIT 20;




USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;

-- Should be ~1M rows, first hour Oct 27, avg minutes near 60, and no before-collection hours
SELECT COUNT(*) AS station_hours, COUNT(DISTINCT station_id) AS stations,
       MIN(hour_utc) AS first_hour, MAX(hour_utc) AS last_hour,
       ROUND(AVG(minutes_observed), 1) AS avg_minutes_observed,
       COUNT_IF(hour_utc < '2026-10-27 01:00:00') AS before_collection_hours
FROM DIVVY.PROD_SERVING.SRV_STATION_HOUR;

-- Station types: most should be normal
SELECT station_type, COUNT(*) AS stations
FROM DIVVY.PROD_SERVING.SRV_STATION_PROFILE
GROUP BY station_type
ORDER BY stations DESC;