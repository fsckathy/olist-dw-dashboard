/*
===============================================================================
SCRIPT: Create ETL Monitoring Tables and Logging Procedures
===============================================================================
PURPOSE:
    Observability for every pipeline run: which layer ran, when, how long, how many
    rows each table received or rejected, and the error message of any failure.

TABLES:
    etl.batch_log        - one row per layer execution (bronze, silver or gold)
    etl.table_load_log   - one row per table loaded within a batch

PROCEDURES (used by the load procedures, keep the logging code in one place):
    etl.start_batch      - opens a batch (status RUNNING) and returns its batch_id
    etl.end_batch        - closes a batch as SUCCESS or FAILED
    etl.log_table_load   - records one table load and prints a short summary

Idempotent: tables are created only if missing, so the log history survives redeploys.
USAGE:
    Run after 01_create_database_schemas.sql.
===============================================================================
*/
USE OlistDW;
GO

-- ----------------------------------------------------------------------------
-- 1.0 TABLE: etl.batch_log
-- ----------------------------------------------------------------------------
IF OBJECT_ID('etl.batch_log', 'U') IS NULL
BEGIN
    CREATE TABLE etl.batch_log (
        batch_id         INT IDENTITY(1, 1) NOT NULL,
        process_name     VARCHAR(50)        NOT NULL,  -- e.g. load_silver
        layer_name       VARCHAR(10)        NOT NULL,
        start_time       DATETIME2(3)       NOT NULL,
        end_time         DATETIME2(3)       NULL,
        duration_seconds DECIMAL(10, 3)     NULL,
        status           VARCHAR(10)        NOT NULL,
        error_message    NVARCHAR(4000)     NULL,      -- external text (SQL Server errors)
        executed_by      NVARCHAR(128)      NOT NULL
            CONSTRAINT df_batch_log_executed_by DEFAULT SUSER_SNAME(),

        CONSTRAINT pk_batch_log PRIMARY KEY (batch_id),
        CONSTRAINT ck_batch_log_status CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
        CONSTRAINT ck_batch_log_layer CHECK (layer_name IN ('bronze', 'silver', 'gold'))
    );

    CREATE INDEX ix_batch_log_start_time ON etl.batch_log (start_time DESC);
END;
GO

-- ----------------------------------------------------------------------------
-- 2.0 TABLE: etl.table_load_log
-- ----------------------------------------------------------------------------
IF OBJECT_ID('etl.table_load_log', 'U') IS NULL
BEGIN
    CREATE TABLE etl.table_load_log (
        log_id           INT IDENTITY(1, 1) NOT NULL,
        batch_id         INT                NOT NULL,
        schema_name      VARCHAR(10)        NOT NULL,
        table_name       VARCHAR(100)       NOT NULL,
        full_table_name  AS (schema_name + '.' + table_name),
        start_time       DATETIME2(3)       NOT NULL,
        end_time         DATETIME2(3)       NOT NULL,
        duration_seconds DECIMAL(10, 3)     NOT NULL,
        rows_loaded      INT                NOT NULL,
        rows_rejected    INT                NOT NULL,  -- rows read from the source but not loaded
        status           VARCHAR(10)        NOT NULL,
        error_message    NVARCHAR(4000)     NULL,

        CONSTRAINT pk_table_load_log PRIMARY KEY (log_id),
        CONSTRAINT fk_table_load_log_batch FOREIGN KEY (batch_id)
            REFERENCES etl.batch_log (batch_id) ON DELETE CASCADE,
        CONSTRAINT ck_table_load_log_status CHECK (status IN ('SUCCESS', 'FAILED'))
    );

    CREATE INDEX ix_table_load_log_batch ON etl.table_load_log (batch_id);
    CREATE INDEX ix_table_load_log_table ON etl.table_load_log (table_name, start_time DESC);
END;
GO

-- ----------------------------------------------------------------------------
-- 3.0 PROCEDURE: etl.start_batch
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.start_batch
    @process_name VARCHAR(50),
    @layer_name   VARCHAR(10),
    @batch_id     INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO etl.batch_log (process_name, layer_name, start_time, status)
    VALUES (@process_name, @layer_name, SYSDATETIME(), 'RUNNING');

    SET @batch_id = SCOPE_IDENTITY();

    PRINT '================================================';
    PRINT 'Loading ' + UPPER(@layer_name) + ' layer | batch_id: ' + CAST(@batch_id AS VARCHAR(10));
    PRINT '================================================';
END;
GO

-- ----------------------------------------------------------------------------
-- 4.0 PROCEDURE: etl.end_batch
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.end_batch
    @batch_id      INT,
    @status        VARCHAR(10),
    @error_message NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @end_time DATETIME2(3) = SYSDATETIME();

    UPDATE etl.batch_log
    SET end_time         = @end_time,
        duration_seconds = DATEDIFF_BIG(MILLISECOND, start_time, @end_time) / 1000.0,
        status           = @status,
        error_message    = @error_message
    WHERE batch_id = @batch_id;

    DECLARE @tables INT, @rows INT, @duration DECIMAL(10, 3);
    SELECT @tables = COUNT(*), @rows = COALESCE(SUM(t.rows_loaded), 0)
    FROM etl.table_load_log AS t
    WHERE t.batch_id = @batch_id AND t.status = 'SUCCESS';
    SELECT @duration = b.duration_seconds FROM etl.batch_log AS b WHERE b.batch_id = @batch_id;

    PRINT '================================================';
    PRINT 'Batch ' + CAST(@batch_id AS VARCHAR(10)) + ' ' + @status
        + ' | tables: ' + CAST(@tables AS VARCHAR(10))
        + ' | rows: ' + CAST(@rows AS VARCHAR(20))
        + ' | ' + CAST(@duration AS VARCHAR(20)) + ' s';
    IF @error_message IS NOT NULL PRINT 'Error: ' + @error_message;
    PRINT '================================================';
END;
GO

-- ----------------------------------------------------------------------------
-- 5.0 PROCEDURE: etl.log_table_load
-- ----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.log_table_load
    @batch_id      INT,
    @schema_name   VARCHAR(10),
    @table_name    VARCHAR(100),
    @start_time    DATETIME2(3),
    @rows_loaded   INT,
    @rows_rejected INT            = 0,
    @status        VARCHAR(10)    = 'SUCCESS',
    @error_message NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @end_time DATETIME2(3) = SYSDATETIME();
    DECLARE @duration DECIMAL(10, 3) = DATEDIFF_BIG(MILLISECOND, @start_time, @end_time) / 1000.0;

    INSERT INTO etl.table_load_log (
        batch_id, schema_name, table_name, start_time, end_time, duration_seconds,
        rows_loaded, rows_rejected, status, error_message)
    VALUES (
        @batch_id, @schema_name, @table_name, @start_time, @end_time, @duration,
        @rows_loaded, @rows_rejected, @status, @error_message);

    PRINT '>> ' + @schema_name + '.' + @table_name + ' | ' + @status
        + ' | loaded: ' + CAST(@rows_loaded AS VARCHAR(20))
        + CASE WHEN @rows_rejected > 0
               THEN ' | rejected: ' + CAST(@rows_rejected AS VARCHAR(20)) ELSE '' END
        + ' | ' + CAST(@duration AS VARCHAR(20)) + ' s';
END;
GO

-- ----------------------------------------------------------------------------
-- 6.0 Deployment Summary
-- ----------------------------------------------------------------------------
PRINT '============================================================';
PRINT 'DEPLOYMENT SUMMARY:';
PRINT '  Tables     : etl.batch_log, etl.table_load_log';
PRINT '  Procedures : etl.start_batch, etl.end_batch, etl.log_table_load';
PRINT '  Status     : SUCCESS';
PRINT '============================================================';
GO
