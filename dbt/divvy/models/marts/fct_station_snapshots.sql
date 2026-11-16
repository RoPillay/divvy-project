select
    md5(station_id || '|' || to_varchar(valid_from))             as snapshot_id,
    station_id,
    hour_utc,
    valid_from,
    valid_to,
    duration_min,
    bikes_available,
    ebikes_available,
    bikes_disabled,
    docks_available,
    docks_disabled,
    capacity,
    station_state,
    is_stale,
    is_current,
    is_rack_or_corral
from {{ ref('int_station_status_intervals') }}