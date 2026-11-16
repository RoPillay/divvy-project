select
    s.station_id,
    s.short_name,
    s.station_name,
    s.lat,
    s.lon,
    s.capacity,
    s.region_id,
    s.is_rack_or_corral,
    d.nearest_l_stop_id,
    d.nearest_l_station_name,
    d.distance_to_l_km,
    coalesce(d.distance_to_l_km <= {{ var('near_l_km') }}, false)   as is_near_l,
    s.first_seen_at,
    s.last_seen_at
from {{ ref('stg_station_information') }} s
left join {{ ref('int_station_distance_to_l') }} d
    on s.station_id = d.station_id