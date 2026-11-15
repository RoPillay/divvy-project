select
      count(*) as failures,
      count(*) != 0 as should_warn,
      count(*) != 0 as should_error
    from (
      
    
    



select last_reported_at
from DIVVY.DEV_staging.stg_station_status
where last_reported_at is null



      
    ) dbt_internal_test