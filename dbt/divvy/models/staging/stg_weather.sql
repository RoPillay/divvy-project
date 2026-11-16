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