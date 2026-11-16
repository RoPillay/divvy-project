with trip_ends as (

    select start_station_id as trip_station_id, start_station_name as trip_station_name
    from {{ ref('stg_trips') }}
    where start_station_id is not null

    union all

    select end_station_id, end_station_name
    from {{ ref('stg_trips') }}
    where end_station_id is not null

),

trip_stations as (

    -- one row per trip station ID, with its most common name and total endpoints
    select
        trip_station_id,
        trip_station_name,
        sum(count(*)) over (partition by trip_station_id)  as endpoint_count
    from trip_ends
    group by trip_station_id, trip_station_name
    qualify row_number() over (partition by trip_station_id order by count(*) desc) = 1

),

live as (

    select
        station_id,
        short_name,
        lower(trim(station_name))                         as name_key
    from {{ ref('stg_station_information') }}

)

select
    t.trip_station_id,
    t.trip_station_name,
    t.endpoint_count,
    coalesce(by_short.station_id, by_name.station_id)     as station_id,
    case
        when by_short.station_id is not null then 'short_name'
        when by_name.station_id  is not null then 'name'
        else 'unmatched'
    end                                                   as match_method
from trip_stations t
left join live by_short on t.trip_station_id = by_short.short_name
left join live by_name  on lower(trim(t.trip_station_name)) = by_name.name_key
qualify row_number() over (
    partition by t.trip_station_id
    order by (by_short.station_id is null), by_name.station_id
) = 1