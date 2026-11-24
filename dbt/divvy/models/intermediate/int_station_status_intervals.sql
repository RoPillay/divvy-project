with status as (

    select * from {{ ref('stg_station_status') }}

),

info as (

    select station_id, capacity, is_rack_or_corral
    from {{ ref('stg_station_information') }}

),

latest_poll as (

    select
        max(polled_at) as max_polled_at,
        min(polled_at) as collection_start
    from status

),

ordered as (

    select
        s.station_id,
        s.last_reported_at                                            as valid_from,
        lead(s.last_reported_at) over (
            partition by s.station_id order by s.last_reported_at)    as next_report_at,
        s.bikes_available,
        s.ebikes_available,
        s.bikes_disabled,
        s.docks_available,
        s.docks_disabled,
        s.is_installed,
        s.is_renting,
        s.is_returning,
        i.capacity,
        coalesce(i.is_rack_or_corral, false)                          as is_rack_or_corral
    from status s
    left join info i on s.station_id = i.station_id

),

with_end as (

    select
        o.station_id,
        greatest(o.valid_from, lp.collection_start)                   as valid_from,
        o.valid_from < lp.collection_start                            as is_clipped,
        coalesce(o.next_report_at, lp.max_polled_at)                  as valid_to,
        o.next_report_at is null                                      as is_current,
        o.bikes_available,
        o.ebikes_available,
        o.bikes_disabled,
        o.docks_available,
        o.docks_disabled,
        o.is_installed,
        o.is_renting,
        o.is_returning,
        o.capacity,
        o.is_rack_or_corral
    from ordered o
    cross join latest_poll lp

)

select
    station_id,
    valid_from,
    valid_to,
    datediff('second', valid_from, valid_to) / 60.0                   as duration_min,
    date_trunc('hour', valid_from)                                    as hour_utc,
    bikes_available,
    ebikes_available,
    bikes_disabled,
    docks_available,
    docks_disabled,
    capacity,
    is_installed,
    is_renting,
    is_returning,
    is_rack_or_corral,
    is_current,
    is_clipped,
    datediff('second', valid_from, valid_to) / 60.0
        > {{ var('stale_minutes') }}                                  as is_stale,
    case
        when not is_installed or (not is_renting and not is_returning) then 'out_of_service'
        when bikes_available = 0 and is_renting                        then 'empty'
        when docks_available = 0 and is_returning                      then 'full'
        else 'ok'
    end                                                               as station_state
from with_end 
where valid_to > valid_from