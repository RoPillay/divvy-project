select *
from {{ ref('fct_stockout_events') }}
where ended_at <= started_at