USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;
USE SCHEMA DIVVY.PROD_SERVING;

-- Finding A: The two kinds of empty stations

-- A1. How many stations of each type, and how much of the empty time each type accounts for. This shows whether a few chronic stations dominate the raw "hours empty" totals
SELECT station_type,
       COUNT(*)                                        AS stations,
       ROUND(100 * AVG(pct_time_empty), 1)             AS avg_pct_time_empty,
       SUM(empty_episodes)                             AS empty_episodes,
       ROUND(SUM(empty_min) / 60)                      AS empty_hours,
       ROUND(100 * SUM(empty_min) / SUM(SUM(empty_min)) OVER (), 1) AS pct_of_all_empty_hours
FROM SRV_STATION_PROFILE
GROUP BY station_type
ORDER BY stations DESC;

-- A2. Check the far South Side stations from the check-in. If n_bike_changes is near zero, call them inactive. If the bike count moves around but keeps returning to zero, call them unserved
SELECT station_name, station_type, n_reports, n_bike_changes,
       ROUND(100 * pct_time_empty, 1) AS pct_time_empty,
       empty_episodes, ROUND(longest_empty_min / 60) AS longest_empty_hours
FROM SRV_STATION_PROFILE
WHERE station_name IN ('Kostner & 87th', 'Michigan Ave & 108th St', 'Parnell Ave & 127th St',
                       'Woodlawn Ave & 103rd St', 'Aberdeen St & 106th St', 'New England Ave & North Ave')
ORDER BY pct_time_empty DESC;

-- A3. The stations crews should care about: repeat stockouts, ranked
SELECT station_name, is_near_l,
       empty_episodes, full_episodes,
       ROUND(100 * pct_time_empty, 1) AS pct_time_empty,
       ROUND(100 * pct_time_full, 1)  AS pct_time_full,
       capacity
FROM SRV_STATION_PROFILE
WHERE station_type = 'repeat_stockout'
ORDER BY empty_episodes + full_episodes DESC
LIMIT 15;


-- Finding B: The commute tide, as rates

-- B1. The share of time empty and full, by commute period and nearness to the L. This is the rate version of the check-in's Result 2
SELECT commute_period, is_near_l,
       COUNT(*)                                                   AS station_hours,
       ROUND(100 * SUM(minutes_empty) / SUM(minutes_in_service), 2) AS pct_time_empty,
       ROUND(100 * SUM(minutes_full)  / SUM(minutes_in_service), 2) AS pct_time_full
FROM SRV_STATION_HOUR
WHERE station_type IN ('normal', 'repeat_stockout')
  AND minutes_in_service > 0
GROUP BY commute_period, is_near_l
ORDER BY commute_period, is_near_l;

-- B2. The full weekday curve, hour by hour, for a line chart on the dashboard and in the final deck:
SELECT hour_of_day, is_near_l,
       ROUND(100 * SUM(minutes_empty) / SUM(minutes_in_service), 2) AS pct_time_empty,
       ROUND(100 * SUM(minutes_full)  / SUM(minutes_in_service), 2) AS pct_time_full
FROM SRV_STATION_HOUR
WHERE station_type IN ('normal', 'repeat_stockout')
  AND NOT is_weekend
  AND minutes_in_service > 0
GROUP BY hour_of_day, is_near_l
ORDER BY is_near_l, hour_of_day;


-- Finding C: Weather, as rates

-- C1. How much wet weather the data has. Check this first. If there are only a few dozen wet hours, say so on the slide
SELECT is_wet, COUNT(DISTINCT hour_utc) AS hours, MIN(hour_utc), MAX(hour_utc)
FROM SRV_STATION_HOUR
WHERE is_wet IS NOT NULL
GROUP BY is_wet;

-- C2. Wet vs. dry at the same hour of the day:
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

-- C3. By temperature band, the same way:
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


-- Finding D: Rebalancing

USE SCHEMA DIVVY.PROD_MARTS;

-- D1. When it happens: likely rebalancing events by Chicago hour of day and type
SELECT t.hour_of_day, r.event_type, COUNT(*) AS events
FROM FCT_REBALANCING_EVENTS r
JOIN DIM_TIME t ON r.hour_utc = t.hour_utc
GROUP BY t.hour_of_day, r.event_type
ORDER BY t.hour_of_day, r.event_type;

-- D2. Where it happens: the stations with the most events
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

-- D3. Does rebalancing end stockouts? For each likely drop-off, this checks whether the station had an empty stockout that ended within 10 minutes of the drop-off. For each pick-up, it checks for a full stockout. It also measures how long the stockout lasted before the fix, which is a rough crew response time.
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

-- D4. Stockouts that never got a fix: the share of repeat-stockout stations' empty episodes that ended on their own (a rider returned a bike) rather than after a likely drop-off. This is useful for "where should crews go?"
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