
  
    

        create or replace transient table DIVVY.PROD_staging.stg_station_status
         as
        (

with snapshots as (

    select
        r.file_name,
        r.file_last_modified                              as polled_at,
        s.value                                           as st
    from DIVVY.RAW.station_status_raw r,
         lateral flatten(input => r.raw:data:stations) s
    

),

parsed as (

    select
        st:station_id::string                             as station_id,
        to_timestamp_ntz(st:last_reported::int)           as last_reported_at,
        polled_at,
        file_name,

        st:num_bikes_available::int                       as bikes_available,
        st:num_ebikes_available::int                      as ebikes_available,
        st:num_bikes_disabled::int                        as bikes_disabled,
        st:num_docks_available::int                       as docks_available,
        st:num_docks_disabled::int                        as docks_disabled,

        coalesce(st:is_installed::int, 1) = 1             as is_installed,
        coalesce(st:is_renting::int,   1) = 1             as is_renting,
        coalesce(st:is_returning::int, 1) = 1             as is_returning

        from snapshots
    where st:station_id is not null
      and st:last_reported is not null
      -- some stations report a placeholder time (1970) before going live
      and to_timestamp_ntz(st:last_reported::int) >= '2020-01-01'

)

select *
from parsed
-- keep the first poll that saw each distinct station report
qualify row_number() over (
    partition by station_id, last_reported_at
    order by polled_at
) = 1
        );
      
  