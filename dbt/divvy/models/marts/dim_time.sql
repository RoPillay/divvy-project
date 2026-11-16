with spine as (

    select
        dateadd('hour', row_number() over (order by seq4()) - 1,
                '2020-01-01 00:00:00'::timestamp_ntz)            as hour_utc
    from table(generator(rowcount => 70128))   -- ~8 years of hours

),

local as (

    select
        hour_utc,
        convert_timezone('UTC', 'America/Chicago', hour_utc)     as hour_chicago
    from spine
    where hour_utc <= dateadd('day', 7, convert_timezone('UTC', current_timestamp())::timestamp_ntz)

),

parts as (

    select
        hour_utc,
        hour_chicago,
        to_date(hour_chicago)                                    as date_chicago,
        hour(hour_chicago)                                       as hour_of_day,
        dayofweekiso(hour_chicago)                               as day_of_week_iso,
        dayname(hour_chicago)                                    as day_name,
        month(hour_chicago)                                      as month_num,
        year(hour_chicago)                                       as year_num
    from local

)

select
    *,
    day_of_week_iso in (6, 7)                                    as is_weekend,
    case
        when day_of_week_iso <= 5 and hour_of_day between 7 and 9   then 'am_commute'
        when day_of_week_iso <= 5 and hour_of_day between 16 and 18 then 'pm_commute'
        else 'other'
    end                                                          as commute_period,
    case
        when month_num in (12, 1, 2) then 'winter'
        when month_num in (3, 4, 5)  then 'spring'
        when month_num in (6, 7, 8)  then 'summer'
        else 'fall'
    end                                                          as season
from parts