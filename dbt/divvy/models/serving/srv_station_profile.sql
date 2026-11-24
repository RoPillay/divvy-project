with intervals as (

    select * from {{ ref('int_station_status_intervals') }}

),

lagged as (

    select
        station_id,
        valid_from,
        duration_min,
        station_state,
        is_stale,
        bikes_available,
        lag(bikes_available) over (partition by station_id order by valid_from) as prev_bikes
    from intervals

),

activity as (

    select
        station_id,
        count(*)                                                              as n_reports,
        sum(iff(prev_bikes is not null and bikes_available <> prev_bikes, 1, 0)) as n_bike_changes,
        sum(iff(station_state <> 'out_of_service' and not is_stale, duration_min, 0)) as in_service_min,
        sum(iff(station_state = 'empty' and not is_stale, duration_min, 0))   as empty_min,
        sum(iff(station_state = 'full'  and not is_stale, duration_min, 0))   as full_min,
        sum(iff(is_stale, duration_min, 0))                                   as stale_min,
        sum(duration_min)                                                     as total_min,
        min(valid_from)                                                       as first_report_at,
        max(valid_from)                                                       as last_report_at
    from lagged
    group by station_id

),

episodes as (

    select
        station_id,
        count_if(stockout_type = 'empty')                                     as empty_episodes,
        count_if(stockout_type = 'full')                                      as full_episodes,
        max(iff(stockout_type = 'empty', duration_min, null))                 as longest_empty_min
    from {{ ref('fct_stockout_events') }}
    group by station_id

)

select
    s.station_id,
    s.station_name,
    s.lat,
    s.lon,
    s.capacity,
    s.is_rack_or_corral,
    s.is_near_l,
    s.distance_to_l_km,
    s.nearest_l_station_name,
    a.n_reports,
    a.n_bike_changes,
    a.in_service_min,
    a.empty_min,
    a.full_min,
    a.empty_min / nullif(a.in_service_min, 0)                                 as pct_time_empty,
    a.full_min  / nullif(a.in_service_min, 0)                                 as pct_time_full,
    a.stale_min / nullif(a.total_min, 0)                                      as pct_time_stale,
    coalesce(e.empty_episodes, 0)                                             as empty_episodes,
    coalesce(e.full_episodes, 0)                                              as full_episodes,
    e.longest_empty_min,
    a.first_report_at,
    a.last_report_at,
    case
        when s.is_rack_or_corral                                              then 'rack_or_corral'
        when coalesce(a.n_bike_changes, 0) < {{ var('inactive_max_changes') }}
          or a.empty_min / nullif(a.in_service_min, 0) > {{ var('chronic_empty_pct') }}
          or a.stale_min / nullif(a.total_min, 0) > 0.5
                                                                              then 'chronic_or_inactive'
        when coalesce(e.empty_episodes, 0) + coalesce(e.full_episodes, 0)
             >= {{ var('repeat_min_episodes') }}                              then 'repeat_stockout'
        else 'normal'
    end                                                                       as station_type
from {{ ref('dim_station') }} s
left join activity a on s.station_id = a.station_id
left join episodes e on s.station_id = e.station_id