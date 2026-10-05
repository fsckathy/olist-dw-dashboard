/*
===============================================================================
Master Orchestration Script: Run Full Olist ETL Pipeline
===============================================================================
PURPOSE:
    Runs the medallion pipeline in dependency order:
        1. bronze.load_bronze  (CSV -> bronze, raw)
        2. silver.load_silver  (bronze -> silver, cleaned and typed)
        3. gold.load_gold      (silver -> gold, star schema)
    Stops at the first failing layer. Each layer logs itself in etl.batch_log and
    etl.table_load_log; this script prints a summary of the run at the end.

    City names: gold reads silver.city_map, a reference built by src/build_city_map.py
    (Python, run outside this script). The dataset is static, so the map is built once and
    rebuilt only when silver or the matching rules change. With an empty map gold still
    loads, keeping the source spellings, and this script prints a warning.

ONE-TIME SETUP (deploy, in this order):
    sql/00_init/01_create_database_schemas.sql
    sql/00_init/02_create_etl_monitoring_tables.sql
    sql/bronze/ddl_bronze_tables.sql + sql/bronze/load_bronze.sql
    sql/silver/ddl_silver_tables.sql + sql/silver/load_silver.sql
    sql/silver/ddl_city_map.sql
    sql/gold/ddl_gold_tables.sql + sql/gold/load_gold.sql

FIRST RUN:
    run this script (bronze, silver, gold), then
        python -m uv run src/build_city_map.py
    then EXEC gold.load_gold (or run this script again).

USAGE:
    Set @data_path to the folder with the Olist CSV files and run this script. 
    Quality checks: the scripts in the tests folder.
===============================================================================
*/
USE OlistDW;
GO

SET NOCOUNT ON;

DECLARE @data_path NVARCHAR(260) = N'C:\Users\Pessoal\Documents\GitHub\olist-dw-dashboard\Data\';

DECLARE
    @current_step  VARCHAR(20) = 'VALIDATION',
    @run_start     DATETIME2(3) = SYSDATETIME(),
    @error_message NVARCHAR(4000);

PRINT '============================================================';
PRINT 'OLIST ETL PIPELINE - FULL EXECUTION';
PRINT 'Start time: ' + CONVERT(VARCHAR(23), @run_start, 121);
PRINT '============================================================';

BEGIN TRY
    -- Required procedures
    IF OBJECT_ID('bronze.load_bronze', 'P') IS NULL
        THROW 50001, 'Stored procedure bronze.load_bronze does not exist. Deploy it first.', 1;
    IF OBJECT_ID('silver.load_silver', 'P') IS NULL
        THROW 50002, 'Stored procedure silver.load_silver does not exist. Deploy it first.', 1;
    IF OBJECT_ID('gold.load_gold', 'P') IS NULL
        THROW 50003, 'Stored procedure gold.load_gold does not exist. Deploy it first.', 1;
    IF OBJECT_ID('silver.city_map', 'U') IS NULL
        THROW 50004, 'Table silver.city_map does not exist. Deploy sql/silver/ddl_city_map.sql first.', 1;

    SET @current_step = 'BRONZE';
    EXEC bronze.load_bronze @data_path = @data_path;

    SET @current_step = 'SILVER';
    EXEC silver.load_silver;

    IF NOT EXISTS (SELECT 1 FROM silver.city_map)
        PRINT 'WARNING: silver.city_map is empty, gold keeps the source city spellings. '
            + 'Run src/build_city_map.py, then EXEC gold.load_gold.';

    SET @current_step = 'GOLD';
    EXEC gold.load_gold;

    PRINT '';
    PRINT '============================================================';
    PRINT 'PIPELINE COMPLETED SUCCESSFULLY';
    PRINT '  Total duration: '
        + CAST(DATEDIFF_BIG(MILLISECOND, @run_start, SYSDATETIME()) / 1000.0 AS VARCHAR(20)) + ' s';
    PRINT '============================================================';
END TRY
BEGIN CATCH
    SET @error_message = ERROR_MESSAGE();

    PRINT '';
    PRINT '============================================================';
    PRINT 'PIPELINE FAILED';
    PRINT '  Failed step   : ' + @current_step;
    PRINT '  Error message : ' + @error_message;
    PRINT '  Error number  : ' + CAST(ERROR_NUMBER() AS VARCHAR(10));
    PRINT '  Duration      : '
        + CAST(DATEDIFF_BIG(MILLISECOND, @run_start, SYSDATETIME()) / 1000.0 AS VARCHAR(20)) + ' s';
    PRINT '============================================================';
    THROW;
END CATCH;

SELECT
    b.batch_id,
    b.layer_name,
    b.status,
    b.duration_seconds,
    COUNT(t.log_id)             AS tables_loaded,
    SUM(t.rows_loaded)          AS rows_loaded,
    SUM(t.rows_rejected)        AS rows_rejected
FROM etl.batch_log AS b
LEFT JOIN etl.table_load_log AS t
    ON t.batch_id = b.batch_id
WHERE b.start_time >= @run_start
GROUP BY b.batch_id, b.layer_name, b.status, b.duration_seconds
ORDER BY b.batch_id;
GO
