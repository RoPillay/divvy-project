with intervals as (

    select station_id, valid_from, bikes_available, hour_utc
    from {{ ref('int_station_status_intervals') }}
    where not is_rack_or_corral
      and station_state <> 'out_of_service'

),

changes as (

    select
        station_id,
        lag(valid_from) over (partition by station_id order by valid_from)      as window_start,
        valid_from                                                              as window_end,
        hour_utc,
        bikes_available
          - lag(bikes_available) over (partition by station_id order by valid_from) as bike_change
    from intervals

)

select
    md5(station_id || '|' || to_varchar(window_end))                 as rebalancing_event_id,
    station_id,
    window_start,
    window_end,
    hour_utc,
    datediff('second', window_start, window_end) / 60.0              as window_min,
    bike_change,
    iff(bike_change > 0, 'drop_off', 'pick_up')                      as event_type
from changes
where window_start is not null
  and abs(bike_change) >= {{ var('rebalance_min_jump') }}
  and datediff('second', window_start, window_end) / 60.0 <= {{ var('rebalance_max_minutes') }}