with info as (

    select * from {{ ref('stg_station_information') }}

),

status_only as (

    -- stations reporting status but never seen in the station_information feed
    select distinct station_id
    from {{ ref('stg_station_status') }}
    where station_id not in (select station_id from info)

),

all_stations as (

    select
        station_id, short_name, station_name, lat, lon, capacity, region_id,
        is_rack_or_corral, first_seen_at, last_seen_at,
        true                                       as is_in_station_feed
    from info

    union all

    select
        station_id,
        null                                       as short_name,
        'Unknown (not in station feed)'            as station_name,
        null, null, null, null,
        false                                      as is_rack_or_corral,
        null, null,
        false                                      as is_in_station_feed
    from status_only

)
select
    a.station_id,
    a.short_name,
    a.station_name,
    a.lat,
    a.lon,
    a.capacity,
    a.region_id,
    a.is_rack_or_corral,
    a.is_in_station_feed,
    d.nearest_l_stop_id,
    d.nearest_l_station_name,
    d.distance_to_l_km,
    coalesce(d.distance_to_l_km <= {{ var('near_l_km') }}, false)   as is_near_l,
    a.first_seen_at,
    a.last_seen_at
from all_stations a
left join {{ ref('int_station_distance_to_l') }} d
    on a.station_id = d.station_id