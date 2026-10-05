/*
===============================================================================
Stored Procedure: Load Silver Layer (Bronze -> Silver)
===============================================================================
PURPOSE:
    Cleans, types and keys the bronze data. Idempotent: every table is truncated first.
    Each table is logged in etl.table_load_log (rows_rejected = bronze rows not loaded);
    the run in etl.batch_log. A failure stops the run, is logged and re-raised.

RULES:
    - Required columns use strict CONVERT: a malformed row stops the load instead of being
      silently dropped. Optional columns use TRY_CONVERT on blank-safe values.
    - Text: trimmed; states uppercased; cities lowercase as in the source.
    - Geolocation: points outside Brazil dropped, coordinates rounded
      to 6 decimals, exact duplicates removed.
    - zip_location: per zip, points > 50 km AND > 10x the typical distance from the zip median
      are outliers (zips with >= 3 points); coordinates = median of the remaining points.
    - Reviews: blank or junk comments become NULL; line breaks and tabs inside
      comments become spaces.
    - Orders: delivery stages in calendar days (approval + seller handling + carrier transit
      = delivery_days); a stage with out-of-order source dates is NULL, not negative.
    - Products: weight 0 -> NULL; volume only when all three dimensions are positive.
    - Category translation: completed with the categories missing from the source file.
    
USAGE:
    EXEC silver.load_silver;
===============================================================================
*/
USE OlistDW;
GO

CREATE OR ALTER PROCEDURE silver.load_silver
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @batch_id      INT,
        @table_name    VARCHAR(100),
        @start_time    DATETIME2(3),
        @rows_loaded   INT,
        @rows_source   INT,
        @rows_rejected INT,
        @error_message NVARCHAR(4000);

    EXEC etl.start_batch @process_name = 'load_silver', @layer_name = 'silver',
                         @batch_id = @batch_id OUTPUT;

    BEGIN TRY
        -- =====================================================================
        -- TABLE 1: silver.olist_customers_ds
        -- =====================================================================
        SET @table_name = 'olist_customers_ds';
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.olist_customers_ds;

        INSERT INTO silver.olist_customers_ds WITH (TABLOCK)
            (customer_id, customer_unique_id, customer_zip_code_prefix, customer_city,
             customer_state, dwh_batch_id)
        SELECT
            TRIM(c.customer_id),
            TRIM(c.customer_unique_id),
            TRIM(c.customer_zip_code_prefix),
            TRIM(c.customer_city),
            UPPER(TRIM(c.customer_state)),
            @batch_id
        FROM bronze.olist_customers_ds AS c;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'silver', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- TABLE 2: silver.olist_geolocation_ds
        -- =====================================================================
        SET @table_name = 'olist_geolocation_ds';
        SET @start_time = SYSDATETIME();
        SELECT @rows_source = COUNT(*) FROM bronze.olist_geolocation_ds;
        TRUNCATE TABLE silver.olist_geolocation_ds;

        WITH typed AS (
            SELECT
                TRIM(g.geolocation_zip_code_prefix)                    AS zip,
                ROUND(TRY_CONVERT(FLOAT, g.geolocation_lat), 6)        AS lat,
                ROUND(TRY_CONVERT(FLOAT, g.geolocation_lng), 6)        AS lng,
                TRIM(g.geolocation_city)                               AS city,
                UPPER(TRIM(g.geolocation_state))                       AS [state]
            FROM bronze.olist_geolocation_ds AS g
        )
        INSERT INTO silver.olist_geolocation_ds WITH (TABLOCK)
            (geolocation_zip_code_prefix, geolocation_lat, geolocation_lng, geolocation_city,
             geolocation_state, dwh_batch_id)
        SELECT DISTINCT t.zip, t.lat, t.lng, t.city, t.[state], @batch_id
        FROM typed AS t
        WHERE t.lat BETWEEN -33.751111 AND 5.271944 --official source: IBGE
          AND t.lng BETWEEN -73.990556 AND -28.835833; --official source: IBGE

        SET @rows_loaded = @@ROWCOUNT;
        SET @rows_rejected = @rows_source - @rows_loaded;  
        EXEC etl.log_table_load @batch_id, 'silver', @table_name, @start_time, @rows_loaded,
                                @rows_rejected;

        -- =====================================================================
        -- TABLE 3: silver.zip_location (derived from silver.olist_geolocation_ds)
        -- =====================================================================
        SET @table_name = 'zip_location';
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.zip_location;

        WITH points AS (
            SELECT DISTINCT
                g.geolocation_zip_code_prefix AS zip,
                CAST(g.geolocation_lat AS FLOAT) AS lat,
                CAST(g.geolocation_lng AS FLOAT) AS lng
            FROM silver.olist_geolocation_ds AS g
        ),
        med AS (
            SELECT
                p.zip, p.lat, p.lng,
                PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.lat) OVER (PARTITION BY p.zip) AS lat_med,
                PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p.lng) OVER (PARTITION BY p.zip) AS lng_med,
                COUNT(*) OVER (PARTITION BY p.zip) AS zip_points
            FROM points AS p
        ),
        dist AS (
            -- Haversine distance to the zip median, in km
            SELECT
                m.*,
                2 * 6371.0 * ASIN(IIF(SQRT(h.a) > 1, 1, SQRT(h.a))) AS dist_km
            FROM med AS m
            CROSS APPLY (
                SELECT POWER(SIN(RADIANS(m.lat - m.lat_med) / 2), 2)
                     + COS(RADIANS(m.lat_med)) * COS(RADIANS(m.lat))
                     * POWER(SIN(RADIANS(m.lng - m.lng_med) / 2), 2) AS a
            ) AS h
        ),
        typical AS (
            SELECT
                d.*,
                PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d.dist_km) OVER (PARTITION BY d.zip) AS dist_med
            FROM dist AS d
        ),
        clean AS (
            SELECT t.zip, t.lat, t.lng
            FROM typical AS t
            WHERE NOT (t.zip_points >= 3 AND t.dist_km > 50 AND t.dist_km > 10 * t.dist_med)
        ),
        zip_median AS (
            SELECT DISTINCT
                c.zip,
                PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.lat) OVER (PARTITION BY c.zip) AS lat,
                PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY c.lng) OVER (PARTITION BY c.zip) AS lng,
                COUNT(*) OVER (PARTITION BY c.zip) AS n_points
            FROM clean AS c
        )
        INSERT INTO silver.zip_location WITH (TABLOCK)
            (zip_code_prefix, latitude, longitude, n_points, dwh_batch_id)
        SELECT z.zip, ROUND(z.lat, 6), ROUND(z.lng, 6), z.n_points, @batch_id
        FROM zip_median AS z;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'silver', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- TABLE 4: silver.olist_sellers_ds
        -- =====================================================================
        SET @table_name = 'olist_sellers_ds';
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.olist_sellers_ds;

        INSERT INTO silver.olist_sellers_ds WITH (TABLOCK)
            (seller_id, seller_zip_code_prefix, seller_city, seller_state, dwh_batch_id)
        SELECT
            TRIM(s.seller_id),
            TRIM(s.seller_zip_code_prefix),
            TRIM(s.seller_city),
            UPPER(TRIM(s.seller_state)),
            @batch_id
        FROM bronze.olist_sellers_ds AS s;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'silver', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- TABLE 5: silver.olist_products_ds
        -- =====================================================================
        SET @table_name = 'olist_products_ds';
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.olist_products_ds;

        WITH typed AS (
            SELECT
                TRIM(p.product_id)                                        AS product_id,
                NULLIF(TRIM(p.product_category_name), N'')                AS category,
                TRY_CONVERT(SMALLINT, NULLIF(p.product_name_lenght, N''))        AS name_length,
                TRY_CONVERT(SMALLINT, NULLIF(p.product_description_lenght, N'')) AS description_length,
                TRY_CONVERT(SMALLINT, NULLIF(p.product_photos_qty, N''))  AS photos_qty,
                NULLIF(TRY_CONVERT(INT, NULLIF(p.product_weight_g, N'')), 0) AS weight_g,
                TRY_CONVERT(SMALLINT, NULLIF(p.product_length_cm, N''))   AS length_cm,
                TRY_CONVERT(SMALLINT, NULLIF(p.product_height_cm, N''))   AS height_cm,
                TRY_CONVERT(SMALLINT, NULLIF(p.product_width_cm, N''))    AS width_cm
            FROM bronze.olist_products_ds AS p
        )
        INSERT INTO silver.olist_products_ds WITH (TABLOCK)
            (product_id, product_category_name, product_name_length, product_description_length,
             product_photos_qty, product_weight_g, product_length_cm, product_height_cm,
             product_width_cm, product_volume_cm3, dwh_batch_id)
        SELECT
            t.product_id, t.category, t.name_length, t.description_length, t.photos_qty,
            t.weight_g, t.length_cm, t.height_cm, t.width_cm,
            CASE WHEN t.length_cm > 0 AND t.height_cm > 0 AND t.width_cm > 0
                 THEN CAST(t.length_cm AS INT) * t.height_cm * t.width_cm
            END,
            @batch_id
        FROM typed AS t;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'silver', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- TABLE 6: silver.product_category_name_translation
        -- =====================================================================
        SET @table_name = 'product_category_name_translation';
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.product_category_name_translation;

        INSERT INTO silver.product_category_name_translation
            (product_category_name, product_category_name_english, dwh_batch_id)
        SELECT TRIM(t.product_category_name), TRIM(t.product_category_name_english), @batch_id
        FROM bronze.product_category_name_translation AS t;

        INSERT INTO silver.product_category_name_translation
            (product_category_name, product_category_name_english, dwh_batch_id)
        SELECT m.product_category_name, m.product_category_name_english, @batch_id
        FROM (VALUES
            (N'portateis_cozinha_e_preparadores_de_alimentos', N'portable_kitchen_appliances_and_food_preparers'),
            (N'pc_gamer',      N'pc_gamer'),
            (N'sem_categoria', N'without_category')
        ) AS m (product_category_name, product_category_name_english)
        WHERE NOT EXISTS (SELECT 1 FROM silver.product_category_name_translation AS t
                          WHERE t.product_category_name = m.product_category_name);

        SELECT @rows_loaded = COUNT(*) FROM silver.product_category_name_translation;
        EXEC etl.log_table_load @batch_id, 'silver', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- TABLE 7: silver.olist_orders_ds
        -- =====================================================================
        SET @table_name = 'olist_orders_ds';
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.olist_orders_ds;

        WITH typed AS (
            SELECT
                TRIM(o.order_id)                                                   AS order_id,
                TRIM(o.customer_id)                                                AS customer_id,
                LOWER(TRIM(o.order_status))                                        AS order_status,
                CONVERT(DATETIME2(0), o.order_purchase_timestamp, 120)             AS purchased_at,
                TRY_CONVERT(DATETIME2(0), NULLIF(o.order_approved_at, N''), 120)   AS approved_at,
                TRY_CONVERT(DATETIME2(0), NULLIF(o.order_delivered_carrier_date, N''), 120)  AS carrier_at,
                TRY_CONVERT(DATETIME2(0), NULLIF(o.order_delivered_customer_date, N''), 120) AS delivered_at,
                CONVERT(DATETIME2(0), o.order_estimated_delivery_date, 120)        AS estimated_at
            FROM bronze.olist_orders_ds AS o
        )
        INSERT INTO silver.olist_orders_ds WITH (TABLOCK)
            (order_id, customer_id, order_status, order_purchase_timestamp, order_approved_at,
             order_delivered_carrier_date, order_delivered_customer_date,
             order_estimated_delivery_date, delivery_days, approval_hours, seller_handling_days,
             carrier_transit_days, delivery_delay_days, late_delivery_flag, dwh_batch_id)
        SELECT
            t.order_id, t.customer_id, t.order_status, t.purchased_at, t.approved_at,
            t.carrier_at, t.delivered_at, t.estimated_at,
            DATEDIFF(DAY, CAST(t.purchased_at AS DATE), CAST(t.delivered_at AS DATE)),
            CAST(DATEDIFF(MINUTE, t.purchased_at, t.approved_at) / 60.0 AS DECIMAL(10, 2)),
            -- Stages in calendar days; out-of-order source dates (negative stage) become NULL
            IIF(s.handling_days >= 0, s.handling_days, NULL),
            IIF(s.transit_days >= 0, s.transit_days, NULL),
            DATEDIFF(DAY, CAST(t.estimated_at AS DATE), CAST(t.delivered_at AS DATE)),
            CASE WHEN t.delivered_at IS NULL THEN NULL
                 WHEN CAST(t.delivered_at AS DATE) > CAST(t.estimated_at AS DATE) THEN 1
                 ELSE 0
            END,
            @batch_id
        FROM typed AS t
        CROSS APPLY (
            SELECT
                DATEDIFF(DAY, CAST(t.approved_at AS DATE), CAST(t.carrier_at AS DATE))  AS handling_days,
                DATEDIFF(DAY, CAST(t.carrier_at AS DATE), CAST(t.delivered_at AS DATE)) AS transit_days
        ) AS s;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'silver', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- TABLE 8: silver.olist_order_items_ds
        -- =====================================================================
        SET @table_name = 'olist_order_items_ds';
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.olist_order_items_ds;

        INSERT INTO silver.olist_order_items_ds WITH (TABLOCK)
            (order_id, order_item_id, product_id, seller_id, shipping_limit_date, price,
             freight_value, dwh_batch_id)
        SELECT
            TRIM(i.order_id),
            CONVERT(SMALLINT, i.order_item_id),
            TRIM(i.product_id),
            TRIM(i.seller_id),
            CONVERT(DATETIME2(0), i.shipping_limit_date, 120),
            CONVERT(DECIMAL(10, 2), i.price),
            CONVERT(DECIMAL(10, 2), i.freight_value),
            @batch_id
        FROM bronze.olist_order_items_ds AS i;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'silver', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- TABLE 9: silver.olist_order_payments_ds
        -- =====================================================================
        SET @table_name = 'olist_order_payments_ds';
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.olist_order_payments_ds;

        INSERT INTO silver.olist_order_payments_ds WITH (TABLOCK)
            (order_id, payment_sequential, payment_type, payment_installments, payment_value,
             dwh_batch_id)
        SELECT
            TRIM(p.order_id),
            CONVERT(SMALLINT, p.payment_sequential),
            LOWER(TRIM(p.payment_type)),
            CONVERT(SMALLINT, p.payment_installments),  
            CONVERT(DECIMAL(10, 2), p.payment_value),
            @batch_id
        FROM bronze.olist_order_payments_ds AS p;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'silver', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- TABLE 10: silver.olist_order_reviews_ds
        -- =====================================================================
        SET @table_name = 'olist_order_reviews_ds';
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.olist_order_reviews_ds;

        WITH typed AS (
            SELECT
                TRIM(r.review_id)                                      AS review_id,
                TRIM(r.order_id)                                       AS order_id,
                CONVERT(TINYINT, r.review_score)                       AS score,
                -- Line breaks and tabs inside comments become spaces
                TRIM(REPLACE(REPLACE(REPLACE(r.review_comment_title,
                     CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' ')) AS title,
                TRIM(REPLACE(REPLACE(REPLACE(r.review_comment_message,
                     CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' ')) AS message,
                CONVERT(DATETIME2(0), r.review_creation_date, 120)     AS created_at,
                CONVERT(DATETIME2(0), r.review_answer_timestamp, 120)  AS answered_at
            FROM bronze.olist_order_reviews_ds AS r
        )
        INSERT INTO silver.olist_order_reviews_ds WITH (TABLOCK)
            (review_id, order_id, review_score, review_sentiment, review_comment_title,
             review_comment_message, review_creation_date, review_answer_timestamp,
             review_answer_hours, dwh_batch_id)
        SELECT
            t.review_id,
            t.order_id,
            t.score,
            CASE WHEN t.score >= 4 THEN 'Positive' WHEN t.score = 3 THEN 'Neutral' ELSE 'Negative' END,
            CASE WHEN t.title IN (N'', N'?', N'??', N'???', N'.', N'..', N'...') THEN NULL
                 ELSE LEFT(t.title, 200) END,
            CASE WHEN t.message IN (N'', N'?', N'??', N'???', N'.', N'..', N'...') THEN NULL
                 ELSE t.message END,
            t.created_at,
            t.answered_at,
            CAST(DATEDIFF(MINUTE, t.created_at, t.answered_at) / 60.0 AS DECIMAL(10, 2)),
            @batch_id
        FROM typed AS t;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'silver', @table_name, @start_time, @rows_loaded;

        EXEC etl.end_batch @batch_id = @batch_id, @status = 'SUCCESS';
    END TRY
    BEGIN CATCH
        SET @error_message = ERROR_MESSAGE();
        SET @start_time = COALESCE(@start_time, SYSDATETIME());
        EXEC etl.log_table_load @batch_id = @batch_id, @schema_name = 'silver',
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
PRINT '  Stored Procedure: silver.load_silver';
PRINT '  Status          : SUCCESS';
PRINT '============================================================';
GO
