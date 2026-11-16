select *
from {{ ref('stg_station_status') }}
where bikes_available < 0
   or docks_available < 0
   or coalesce(ebikes_available, 0) < 0
   or coalesce(bikes_disabled, 0) < 0
   or coalesce(docks_disabled, 0) < 0