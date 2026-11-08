USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;
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