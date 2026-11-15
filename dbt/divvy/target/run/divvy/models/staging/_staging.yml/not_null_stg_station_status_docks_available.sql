select
      count(*) as failures,
      count(*) != 0 as should_warn,
      count(*) != 0 as should_error
    from (
      
    
    



select docks_available
from DIVVY.DEV_staging.stg_station_status
where docks_available is null



      
    ) dbt_internal_test