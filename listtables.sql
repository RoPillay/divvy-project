USE ROLE DIVVY_ENGINEER;
USE WAREHOUSE DIVVY_WH;

SELECT table_schema,
       table_name,
       table_type,                              -- BASE TABLE or VIEW
       row_count,
       ROUND(bytes / 1e9, 2) AS size_gb,
       last_altered                             -- when it was last rebuilt
FROM DIVVY.INFORMATION_SCHEMA.TABLES
WHERE table_schema <> 'INFORMATION_SCHEMA'
ORDER BY table_schema, table_name;