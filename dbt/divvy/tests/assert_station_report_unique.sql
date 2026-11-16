select station_id, last_reported_at, count(*) as n
from {{ ref('stg_station_status') }}
group by station_id, last_reported_at
having count(*) > 1