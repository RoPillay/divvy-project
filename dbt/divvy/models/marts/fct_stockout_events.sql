with intervals as (

    select *
    from {{ ref('int_station_status_intervals') }}
    where not is_rack_or_corral

),

marked as (

    select
        *,
        case
            when station_state = lag(station_state) over (
                     partition by station_id order by valid_from)
            then 0 else 1
        end                                                          as is_new_island
    from intervals

),

islands as (

    select
        *,
        sum(is_new_island) over (
            partition by station_id order by valid_from
            rows between unbounded preceding and current row)        as island_id
    from marked

),

episodes as (

    select
        station_id,
        island_id,
        station_state                                                as stockout_type,
        min(valid_from)                                              as started_at,
        max(valid_to)                                                as ended_at,
        boolor_agg(is_current)                                       as is_ongoing,
        boolor_agg(is_stale)                                         as includes_stale_report,
        count(*)                                                     as report_count
    from islands
    where station_state in ('empty', 'full')
    group by station_id, island_id, station_state

)

select
    md5(station_id || '|' || stockout_type || '|' || to_varchar(started_at)) as stockout_event_id,
    station_id,
    stockout_type,
    started_at,
    ended_at,
    datediff('second', started_at, ended_at) / 60.0                  as duration_min,
    date_trunc('hour', started_at)                                   as hour_utc,
    is_ongoing,
    includes_stale_report,
    report_count
from episodes
where datediff('second', started_at, ended_at) / 60.0 >= {{ var('stockout_min_minutes') }}