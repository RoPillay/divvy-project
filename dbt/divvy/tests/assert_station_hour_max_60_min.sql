select *
from {{ ref('srv_station_hour') }}
where minutes_observed > 60.01