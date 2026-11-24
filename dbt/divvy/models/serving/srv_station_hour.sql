with intervals as (

    select station_id, valid_from, valid_to, station_state, is_stale, bikes_available
    from {{ ref('int_station_status_intervals') }}
    where valid_to > valid_from

),

split as (

    select
        i.station_id,
        dateadd('hour', h.value::int, date_trunc('hour', i.valid_from))        as hour_utc,
        datediff(
            'second',
            greatest(i.valid_from, dateadd('hour', h.value::int, date_trunc('hour', i.valid_from))),
            least(i.valid_to,      dateadd('hour', h.value::int + 1, date_trunc('hour', i.valid_from)))
        ) / 60.0                                                               as minutes,
        i.station_state,
        i.is_stale,
        i.bikes_available
    from intervals i,
         lateral flatten(input => array_generate_range(
             0, datediff('hour', date_trunc('hour', i.valid_from), i.valid_to) + 1)) h

),

agg as (

    select
        station_id,
        hour_utc,
        sum(minutes)                                                           as minutes_observed,
        sum(iff(not is_stale and station_state <> 'out_of_service', minutes, 0)) as minutes_in_service,
        sum(iff(not is_stale and station_state = 'empty', minutes, 0))         as minutes_empty,
        sum(iff(not is_stale and station_state = 'full',  minutes, 0))         as minutes_full,
        sum(iff(station_state = 'out_of_service', minutes, 0))                 as minutes_out_of_service,
        sum(iff(is_stale, minutes, 0))                                         as minutes_stale,
        sum(bikes_available * minutes) / nullif(sum(minutes), 0)               as avg_bikes,
        min(bikes_available)                                                   as min_bikes,
        max(bikes_available)                                                   as max_bikes
    from split
    where minutes > 0
    group by station_id, hour_utc

)

select
    md5(a.station_id || '|' || to_varchar(a.hour_utc))                         as station_hour_id,
    a.station_id,
    a.hour_utc,
    a.minutes_observed,
    a.minutes_in_service,
    a.minutes_empty,
    a.minutes_full,
    a.minutes_out_of_service,
    a.minutes_stale,
    a.minutes_empty / nullif(a.minutes_in_service, 0)                          as pct_empty,
    a.minutes_full  / nullif(a.minutes_in_service, 0)                          as pct_full,
    a.avg_bikes,
    a.min_bikes,
    a.max_bikes,

    t.date_chicago,
    t.hour_of_day,
    t.day_name,
    t.is_weekend,
    t.commute_period,

    w.temp_c,
    w.precip_mm,
    w.is_wet,
    w.is_snow,
    w.temp_band,
    w.wind_band,
    w.is_lake_wind,

    p.station_name,
    p.station_type,
    p.is_near_l,
    p.distance_to_l_km,
    p.capacity,
    p.lat,
    p.lon
from agg a
join {{ ref('dim_time') }} t            on a.hour_utc = t.hour_utc
left join {{ ref('dim_weather') }} w    on a.hour_utc = w.hour_utc
join {{ ref('srv_station_profile') }} p on a.station_id = p.station_id