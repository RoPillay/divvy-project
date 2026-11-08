USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;
USE SCHEMA DIVVY.RAW;

SELECT COUNT(*)                 AS files_loaded,
       MIN(FILE_LAST_MODIFIED)  AS first_file,
       MAX(FILE_LAST_MODIFIED)  AS latest_file
FROM STATION_STATUS_RAW;


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
ORDER BY last_reported_ts DESC
LIMIT 20;


SELECT r.FILE_NAME, COUNT(*) AS stations
FROM STATION_STATUS_RAW r,
     LATERAL FLATTEN(input => r.RAW:data:stations) s
GROUP BY r.FILE_NAME
ORDER BY r.FILE_NAME DESC
LIMIT 5;