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

),

candidates as (

    select *
    from changes
    where window_start is not null
      and abs(bike_change) >= {{ var('rebalance_min_jump') }}
      and datediff('second', window_start, window_end) / 60.0 <= {{ var('rebalance_max_minutes') }}

),

with_neighbors as (

    select
        *,
        lead(bike_change) over (partition by station_id order by window_end) as next_change,
        lead(window_end)  over (partition by station_id order by window_end) as next_end,
        lag(bike_change)  over (partition by station_id order by window_end) as prev_change,
        lag(window_end)   over (partition by station_id order by window_end) as prev_end
    from candidates

),

flagged as (

    select
        *,
        -- this move is undone by the next one, or it undoes the previous one
        (
            (next_change is not null
             and sign(next_change) <> sign(bike_change)
             and abs(bike_change + next_change) <= 1
             and datediff('minute', window_end, next_end) <= {{ var('flicker_window_minutes') }})
         or
            (prev_change is not null
             and sign(prev_change) <> sign(bike_change)
             and abs(bike_change + prev_change) <= 1
             and datediff('minute', prev_end, window_end) <= {{ var('flicker_window_minutes') }})
        )                                                                     as is_flicker
    from with_neighbors

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
from flagged
where not is_flicker