select
    file_name,
    file_month,
    count(*)                                                        as trips,
    sum(iff(date_trunc('month', started_at_local) <> file_month, 1, 0)) as off_month_trips
from {{ ref('stg_trips') }}
group by file_name, file_month
having sum(iff(date_trunc('month', started_at_local) <> file_month, 1, 0)) > 0.01 * count(*)