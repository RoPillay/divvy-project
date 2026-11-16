with snaps as (

    select
        r.file_last_modified                              as snapshot_at,
        s.value                                           as st
    from {{ source('raw', 'station_information_raw') }} r,
         lateral flatten(input => r.raw:data:stations) s

),

parsed as (

    select
        st:station_id::string                             as station_id,
        st:short_name::string                             as short_name,
        trim(st:name::string)                             as station_name,
        st:lat::float                                     as lat,
        st:lon::float                                     as lon,
        st:capacity::int                                  as capacity,
        st:region_id::string                              as region_id,
        st:is_virtual_station::boolean                    as is_virtual_station,
        snapshot_at
    from snaps
    where st:station_id is not null

),

latest as (

    select
        *,
        min(snapshot_at) over (partition by station_id)   as first_seen_at,
        max(snapshot_at) over (partition by station_id)   as last_seen_at
    from parsed
    qualify row_number() over (partition by station_id order by snapshot_at desc) = 1

)

select
    station_id,
    short_name,
    station_name,
    lat,
    lon,
    capacity,
    region_id,
    first_seen_at,
    last_seen_at,
    (
        station_name ilike '%public rack%'
        or station_name ilike '%corral%'
        or coalesce(is_virtual_station, false)
        or coalesce(capacity, 0) = 0
    )                                                     as is_rack_or_corral
from latest