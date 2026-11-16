select
    stop_id                                               as l_stop_id,
    trim(stop_name)                                       as l_station_name,
    try_to_double(stop_lat)                               as lat,
    try_to_double(stop_lon)                               as lon,
    wheelchair_boarding
from {{ source('raw', 'cta_stops_raw') }}
where location_type = '1'
  and try_to_number(stop_id) between 40000 and 49999