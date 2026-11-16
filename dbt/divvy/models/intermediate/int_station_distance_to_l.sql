with stations as (

    select station_id, lat, lon
    from {{ ref('stg_station_information') }}
    where lat is not null and lon is not null

),

l_stations as (

    select l_stop_id, l_station_name, lat, lon
    from {{ ref('stg_cta_l_stations') }}
    where lat is not null and lon is not null

)

select
    s.station_id,
    l.l_stop_id                                           as nearest_l_stop_id,
    l.l_station_name                                      as nearest_l_station_name,
    haversine(s.lat, s.lon, l.lat, l.lon)                 as distance_to_l_km
from stations s
cross join l_stations l
qualify row_number() over (
    partition by s.station_id
    order by haversine(s.lat, s.lon, l.lat, l.lon)
) = 1