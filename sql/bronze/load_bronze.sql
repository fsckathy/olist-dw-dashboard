/*
===============================================================================
Stored Procedure: Load Bronze Layer (CSV -> Bronze)
===============================================================================
PURPOSE:
    Loads the 9 Olist CSV files into the bronze tables, as-is.
    Idempotent: each table is truncated before its BULK INSERT.
    Each table is logged in etl.table_load_log; the run in etl.batch_log.
    Tables are loaded one by one: a failure stops the run, is
    logged with the failing table, and the error is re-raised to the caller.

LOAD OPTIONS:
    FORMAT = 'CSV'       quoted fields with commas / line breaks
    CODEPAGE = '65001'   UTF-8, keeps Portuguese accents
    ROWTERMINATOR        reviews and category translation end lines with CRLF; others LF

PARAMETERS:
    @data_path  folder with the CSV files, as seen by the SQL Server service.

USAGE:
    EXEC bronze.load_bronze @data_path = N'C:\path\to\Data\';
===============================================================================
*/
USE OlistDW;
GO

CREATE OR ALTER PROCEDURE bronze.load_bronze
    @data_path NVARCHAR(260)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @batch_id       INT,
        @table_name     VARCHAR(100),
        @file_name      NVARCHAR(200),
        @row_terminator VARCHAR(10),
        @start_time     DATETIME2(3),
        @rows_loaded    INT,
        @sql            NVARCHAR(MAX),
        @error_message  NVARCHAR(4000);

    IF RIGHT(@data_path, 1) <> N'\' SET @data_path += N'\';

    DECLARE @files TABLE (
        seq            TINYINT       NOT NULL PRIMARY KEY,
        table_name     VARCHAR(100)  NOT NULL,
        file_name      NVARCHAR(200) NOT NULL,
        row_terminator VARCHAR(10)   NOT NULL
    );
    INSERT INTO @files (seq, table_name, file_name, row_terminator)
    VALUES
    --Some files use CRLF (0x0d0a) instead of LF (0x0a). Line endings determined using Notepad++
        (1, 'olist_customers_ds',                'olist_customers_dataset.csv',           '0x0a'),
        (2, 'olist_geolocation_ds',              'olist_geolocation_dataset.csv',         '0x0a'),
        (3, 'olist_order_items_ds',              'olist_order_items_dataset.csv',         '0x0a'),
        (4, 'olist_order_payments_ds',           'olist_order_payments_dataset.csv',      '0x0a'),
        (5, 'olist_order_reviews_ds',            'olist_order_reviews_dataset.csv',       '0x0d0a'),
        (6, 'olist_orders_ds',                   'olist_orders_dataset.csv',              '0x0a'),
        (7, 'olist_products_ds',                 'olist_products_dataset.csv',            '0x0a'),
        (8, 'olist_sellers_ds',                  'olist_sellers_dataset.csv',             '0x0a'),
        (9, 'product_category_name_translation', 'product_category_name_translation.csv', '0x0d0a');

    EXEC etl.start_batch @process_name = 'load_bronze', @layer_name = 'bronze',
                         @batch_id = @batch_id OUTPUT;

    BEGIN TRY
        DECLARE file_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT f.table_name, f.file_name, f.row_terminator FROM @files AS f ORDER BY f.seq;
        OPEN file_cursor;
        FETCH NEXT FROM file_cursor INTO @table_name, @file_name, @row_terminator;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @start_time = SYSDATETIME();

            SET @sql = N'TRUNCATE TABLE bronze.' + QUOTENAME(@table_name) + N';
BULK INSERT bronze.' + QUOTENAME(@table_name) + N'
FROM ''' + REPLACE(@data_path + @file_name, N'''', N'''''') + N'''
WITH (FORMAT = ''CSV'', FIRSTROW = 2, FIELDQUOTE = ''"'', CODEPAGE = ''65001'',
      ROWTERMINATOR = ''' + @row_terminator + N''', TABLOCK);';
            EXEC sys.sp_executesql @sql;

            SET @sql = N'SELECT @n = COUNT(*) FROM bronze.' + QUOTENAME(@table_name) + N';';
            EXEC sys.sp_executesql @sql, N'@n INT OUTPUT', @n = @rows_loaded OUTPUT;

            EXEC etl.log_table_load @batch_id = @batch_id, @schema_name = 'bronze',
                                    @table_name = @table_name, @start_time = @start_time,
                                    @rows_loaded = @rows_loaded;

            FETCH NEXT FROM file_cursor INTO @table_name, @file_name, @row_terminator;
        END;

        CLOSE file_cursor;
        DEALLOCATE file_cursor;

        EXEC etl.end_batch @batch_id = @batch_id, @status = 'SUCCESS';
    END TRY
    BEGIN CATCH
        SET @error_message = ERROR_MESSAGE();

        IF CURSOR_STATUS('local', 'file_cursor') >= 0 CLOSE file_cursor;
        IF CURSOR_STATUS('local', 'file_cursor') > -3 DEALLOCATE file_cursor;

        SET @start_time = COALESCE(@start_time, SYSDATETIME());
        EXEC etl.log_table_load @batch_id = @batch_id, @schema_name = 'bronze',
                                @table_name = @table_name, @start_time = @start_time,
                                @rows_loaded = 0, @status = 'FAILED',
                                @error_message = @error_message;
        EXEC etl.end_batch @batch_id = @batch_id, @status = 'FAILED',
                           @error_message = @error_message;
        THROW;
    END CATCH;
END;
GO

PRINT '============================================================';
PRINT 'DEPLOYMENT SUMMARY:';
PRINT '  Stored Procedure: bronze.load_bronze';
PRINT '  Status          : SUCCESS';
PRINT '============================================================';
GO
