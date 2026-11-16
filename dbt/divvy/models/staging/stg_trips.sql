{{ config(materialized='table') }}

with src as (

    select * from {{ source('raw', 'divvy_trips_raw') }}

),

typed as (

    select
        ride_id,
        rideable_type,
        try_to_timestamp_ntz(started_at)                  as started_at_local,
        try_to_timestamp_ntz(ended_at)                    as ended_at_local,
        nullif(trim(start_station_id), '')                as start_station_id,
        nullif(trim(start_station_name), '')              as start_station_name,
        nullif(trim(end_station_id), '')                  as end_station_id,
        nullif(trim(end_station_name), '')                as end_station_name,
        try_to_double(start_lat)                          as start_lat,
        try_to_double(start_lng)                          as start_lng,
        try_to_double(end_lat)                            as end_lat,
        try_to_double(end_lng)                            as end_lng,
        member_casual,
        file_name,
        to_date(regexp_substr(file_name, '([0-9]{6})-divvy', 1, 1, 'e', 1), 'YYYYMM') as file_month
    from src
    where ride_id is not null

)

select
    *,
    convert_timezone('America/Chicago', 'UTC', started_at_local)   as started_at_utc,
    convert_timezone('America/Chicago', 'UTC', ended_at_local)     as ended_at_utc,
    datediff('second', started_at_local, ended_at_local)           as duration_sec,
    start_station_id is null                                       as start_off_station,
    end_station_id is null                                         as end_off_station
from typed
qualify row_number() over (partition by ride_id order by file_name) = 1