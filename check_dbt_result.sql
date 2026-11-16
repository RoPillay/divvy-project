USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;

-- 1. Row counts across the model
SELECT 'stg_station_status' AS model, COUNT(*) AS n FROM DIVVY.PROD_STAGING.STG_STATION_STATUS
UNION ALL SELECT 'stg_trips',              COUNT(*) FROM DIVVY.PROD_STAGING.STG_TRIPS
UNION ALL SELECT 'dim_station',            COUNT(*) FROM DIVVY.PROD_MARTS.DIM_STATION
UNION ALL SELECT 'fct_station_snapshots',  COUNT(*) FROM DIVVY.PROD_MARTS.FCT_STATION_SNAPSHOTS
UNION ALL SELECT 'fct_stockout_events',    COUNT(*) FROM DIVVY.PROD_MARTS.FCT_STOCKOUT_EVENTS
UNION ALL SELECT 'fct_rebalancing_events', COUNT(*) FROM DIVVY.PROD_MARTS.FCT_REBALANCING_EVENTS;

-- 2. Crosswalk coverage (expect ~96% short_name by endpoints)
SELECT match_method,
       COUNT(*)            AS station_ids,
       SUM(endpoint_count) AS endpoints,
       ROUND(100 * SUM(endpoint_count) / SUM(SUM(endpoint_count)) OVER (), 1) AS pct_endpoints
FROM DIVVY.PROD_INTERMEDIATE.INT_STATION_CROSSWALK
GROUP BY match_method;

-- 3. Top 10 stations by hours spent empty
SELECT d.station_name, d.is_near_l,
       ROUND(SUM(e.duration_min) / 60, 1) AS hours_empty,
       COUNT(*)                           AS episodes
FROM DIVVY.PROD_MARTS.FCT_STOCKOUT_EVENTS e
JOIN DIVVY.PROD_MARTS.DIM_STATION d USING (station_id)
WHERE e.stockout_type = 'empty'
  AND NOT e.includes_stale_report
GROUP BY 1, 2
ORDER BY hours_empty DESC
LIMIT 10;

-- 4. Stockouts by commute period and nearness to the L
SELECT t.commute_period, d.is_near_l, e.stockout_type, COUNT(*) AS episodes
FROM DIVVY.PROD_MARTS.FCT_STOCKOUT_EVENTS e
JOIN DIVVY.PROD_MARTS.DIM_STATION d USING (station_id)
JOIN DIVVY.PROD_MARTS.DIM_TIME t USING (hour_utc)
WHERE NOT e.includes_stale_report
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- 5. Wet vs. dry (only covers hours through Nov 10, where weather exists)
SELECT w.is_wet, e.stockout_type, COUNT(*) AS episodes, ROUND(AVG(e.duration_min), 1) AS avg_min
FROM DIVVY.PROD_MARTS.FCT_STOCKOUT_EVENTS e
JOIN DIVVY.PROD_MARTS.DIM_WEATHER w USING (hour_utc)
WHERE NOT e.includes_stale_report
GROUP BY 1, 2
ORDER BY 1, 2;

-- 6. Busiest trip hour (should be ~17, the evening commute)
SELECT HOUR(started_at_local) AS hr, COUNT(*) AS trips
FROM DIVVY.PROD_STAGING.STG_TRIPS
GROUP BY 1 ORDER BY 2 DESC LIMIT 3;

SELECT YEAR(t.started_at_local) AS yr, c.match_method, COUNT(*) AS trip_starts,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY YEAR(t.started_at_local)), 1) AS pct
FROM DIVVY.PROD_STAGING.STG_TRIPS t
JOIN DIVVY.PROD_INTERMEDIATE.INT_STATION_CROSSWALK c ON t.start_station_id = c.trip_station_id
GROUP BY 1, 2 ORDER BY 1, 2;