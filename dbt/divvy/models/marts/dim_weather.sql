select
    hour_utc,
    temp_c,
    precip_mm,
    rain_mm,
    snow_cm,
    wind_kmh,
    wind_dir_deg,
    weather_code,
    precip_mm >= {{ var('wet_precip_mm') }}                       as is_wet,
    coalesce(snow_cm, 0) > 0                                     as is_snow,
    case
        when temp_c < 0  then 'freezing'
        when temp_c < 10 then 'cold'
        when temp_c < 20 then 'mild'
        else 'warm'
    end                                                          as temp_band,
    case when wind_kmh >= 30 then 'windy' else 'calm' end        as wind_band,
    wind_dir_deg between 22.5 and 157.5                          as is_lake_wind
from {{ ref('stg_weather') }}