/*
===============================================================================
Stored Procedure: Load Gold Layer (Silver -> Gold)
===============================================================================
PURPOSE:
    Builds the star schema from silver. Idempotent: all gold tables are emptied and reloaded.
    Runs in a single transaction: any failure rolls back the whole layer, so Power BI never
    sees a partial load. Table loads are logged in etl.table_load_log (rolled back with the
    data on failure); the run and the failure are logged in etl.batch_log.

LOAD ORDER:
    1. delete facts, then dimensions (foreign keys)ç
    2. dimensions: calendar, order status, payment method, customer, seller, productç
    3. #order_keys: dimension keys of every order, shared by the four factsç
    4. facts: sales, delivery, reviews, payments.

CITIES:
    Customer and seller cities get the official IBGE name and state from silver.city_map
    (filled by src/build_city_map.py); unmapped cities keep the source spelling in title case.

KEYS:
    Surrogate keys are ROW_NUMBER() in natural-key order (deterministic: the same data always
    gets the same keys). Date keys are yyyymmdd integers.

USAGE:
    EXEC gold.load_gold;
===============================================================================
*/
USE OlistDW;
GO

CREATE OR ALTER PROCEDURE gold.load_gold
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @batch_id      INT,
        @table_name    VARCHAR(100),
        @start_time    DATETIME2(3),
        @rows_loaded   INT,
        @start_date    DATE,
        @end_date      DATE,
        @error_message NVARCHAR(4000);

    DECLARE @regions TABLE (uf CHAR(2) NOT NULL PRIMARY KEY, region VARCHAR(15) NOT NULL);
    INSERT INTO @regions (uf, region)
    VALUES
        ('AC', 'North'), ('AM', 'North'), ('AP', 'North'), ('PA', 'North'),
        ('RO', 'North'), ('RR', 'North'), ('TO', 'North'),
        ('AL', 'Northeast'), ('BA', 'Northeast'), ('CE', 'Northeast'), ('MA', 'Northeast'),
        ('PB', 'Northeast'), ('PE', 'Northeast'), ('PI', 'Northeast'), ('RN', 'Northeast'),
        ('SE', 'Northeast'),
        ('DF', 'Central-West'), ('GO', 'Central-West'), ('MS', 'Central-West'), ('MT', 'Central-West'),
        ('ES', 'Southeast'), ('MG', 'Southeast'), ('RJ', 'Southeast'), ('SP', 'Southeast'),
        ('PR', 'South'), ('RS', 'South'), ('SC', 'South');

    EXEC etl.start_batch @process_name = 'load_gold', @layer_name = 'gold',
                         @batch_id = @batch_id OUTPUT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- =====================================================================
        -- 1. Empty the layer: facts first, then dimensions
        -- =====================================================================
        DELETE FROM gold.fact_sales;
        DELETE FROM gold.fact_delivery;
        DELETE FROM gold.fact_reviews;
        DELETE FROM gold.fact_payments;
        DELETE FROM gold.dim_calendar;
        DELETE FROM gold.dim_customer;
        DELETE FROM gold.dim_seller;
        DELETE FROM gold.dim_product;
        DELETE FROM gold.dim_order_status;
        DELETE FROM gold.dim_payment_method;

        -- =====================================================================
        -- 2.1 dim_calendar: full years covering the order and review event dates
        -- =====================================================================
        SET @table_name = 'dim_calendar';
        SET @start_time = SYSDATETIME();

        WITH used_dates AS (
            SELECT CAST(o.order_purchase_timestamp AS DATE) AS d FROM silver.olist_orders_ds AS o
            UNION ALL SELECT CAST(o.order_approved_at AS DATE) FROM silver.olist_orders_ds AS o
            UNION ALL SELECT CAST(o.order_delivered_carrier_date AS DATE) FROM silver.olist_orders_ds AS o
            UNION ALL SELECT CAST(o.order_delivered_customer_date AS DATE) FROM silver.olist_orders_ds AS o
            UNION ALL SELECT CAST(o.order_estimated_delivery_date AS DATE) FROM silver.olist_orders_ds AS o
            UNION ALL SELECT CAST(r.review_creation_date AS DATE) FROM silver.olist_order_reviews_ds AS r
            UNION ALL SELECT CAST(r.review_answer_timestamp AS DATE) FROM silver.olist_order_reviews_ds AS r
        )
        SELECT
            @start_date = DATEFROMPARTS(YEAR(MIN(u.d)), 1, 1),
            @end_date   = DATEFROMPARTS(YEAR(MAX(u.d)), 12, 31)
        FROM used_dates AS u
        WHERE u.d IS NOT NULL;

        WITH days AS (
            SELECT DATEADD(DAY, gs.value, @start_date) AS d
            FROM GENERATE_SERIES(0, DATEDIFF(DAY, @start_date, @end_date)) AS gs
        )
        INSERT INTO gold.dim_calendar (
            date_key, [date], [year], [quarter], year_quarter, [month], month_name, month_short, 
            month_start, year_month, [day], day_of_week, day_name)
        SELECT
            YEAR(x.d) * 10000 + MONTH(x.d) * 100 + DAY(x.d),
            x.d,
            YEAR(x.d),
            DATEPART(QUARTER, x.d),
            CONCAT('Q', DATEPART(QUARTER, x.d), '-', YEAR(x.d)),
            MONTH(x.d),
            FORMAT(x.d, 'MMMM', 'en-US'),
            FORMAT(x.d, 'MMM', 'en-US'),
            DATEFROMPARTS(YEAR(x.d), MONTH(x.d), 1),  
            FORMAT(x.d, 'yyyy-MM'),
            DAY(x.d),
            (DATEPART(WEEKDAY, x.d) + @@DATEFIRST - 2) % 7 + 1, 
            FORMAT(x.d, 'dddd', 'en-US')
        FROM days AS x;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'gold', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- 2.2 dim_order_status: lifecycle order
        -- =====================================================================
        SET @table_name = 'dim_order_status';
        SET @start_time = SYSDATETIME();

        INSERT INTO gold.dim_order_status (order_status_key, order_status_code, order_status)
        VALUES
            (1, 'created',     'Created'),
            (2, 'approved',    'Approved'),
            (3, 'invoiced',    'Invoiced'),
            (4, 'processing',  'Processing'),
            (5, 'shipped',     'Shipped'),
            (6, 'delivered',   'Delivered'),
            (7, 'unavailable', 'Unavailable'),
            (8, 'canceled',    'Canceled');

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'gold', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- 2.3 dim_payment_method: every payment type in silver, with its display name
        -- =====================================================================
        SET @table_name = 'dim_payment_method';
        SET @start_time = SYSDATETIME();

        WITH types AS (
            SELECT DISTINCT p.payment_type AS code FROM silver.olist_order_payments_ds AS p
        )
        INSERT INTO gold.dim_payment_method (payment_method_key, payment_type_code, payment_type)
        SELECT
            ROW_NUMBER() OVER (ORDER BY t.code),
            t.code,
            CASE t.code
                WHEN 'credit_card' THEN 'Credit Card'
                WHEN 'debit_card'  THEN 'Debit Card'
                WHEN 'boleto'      THEN 'Bank Slip'
                WHEN 'voucher'     THEN 'Voucher'
                WHEN 'not_defined' THEN 'Not Defined'
                ELSE gold.fn_title_case(REPLACE(t.code, '_', ' '))
            END
        FROM types AS t;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'gold', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- 2.4 dim_customer: one row per person, address of the latest order (SCD1)
        -- =====================================================================
        SET @table_name = 'dim_customer';
        SET @start_time = SYSDATETIME();

        WITH latest AS (
            SELECT
                c.customer_unique_id,
                c.customer_zip_code_prefix,
                c.customer_city,
                c.customer_state,
                ROW_NUMBER() OVER (
                    PARTITION BY c.customer_unique_id
                    ORDER BY o.order_purchase_timestamp DESC, c.customer_id DESC
                ) AS rn
            FROM silver.olist_customers_ds AS c
            LEFT JOIN silver.olist_orders_ds AS o
                ON o.customer_id = c.customer_id
        )
        INSERT INTO gold.dim_customer (
            customer_key, customer_unique_id, customer_city, customer_state, customer_region,
            customer_latitude, customer_longitude)
        SELECT
            ROW_NUMBER() OVER (ORDER BY l.customer_unique_id),
            l.customer_unique_id,
            COALESCE(i.municipality_name, gold.fn_title_case(l.customer_city)),
            COALESCE(i.uf, l.customer_state),
            r.region,
            z.latitude,
            z.longitude
        FROM latest AS l
        LEFT JOIN silver.city_map AS m
            ON  m.city_raw = l.customer_city
            AND m.state_raw = l.customer_state
            AND m.zip_code_prefix = l.customer_zip_code_prefix
        LEFT JOIN silver.ibge_municipality AS i
            ON i.ibge_code = m.ibge_code
        INNER JOIN @regions AS r
            ON r.uf = COALESCE(i.uf, l.customer_state)
        LEFT JOIN silver.zip_location AS z
            ON z.zip_code_prefix = l.customer_zip_code_prefix
        WHERE l.rn = 1;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'gold', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- 2.5 dim_seller
        -- =====================================================================
        SET @table_name = 'dim_seller';
        SET @start_time = SYSDATETIME();

        INSERT INTO gold.dim_seller (
            seller_key, seller_id, seller_city, seller_state, seller_region,
            seller_latitude, seller_longitude)
        SELECT
            ROW_NUMBER() OVER (ORDER BY s.seller_id),
            s.seller_id,
            COALESCE(i.municipality_name, gold.fn_title_case(s.seller_city)),
            COALESCE(i.uf, s.seller_state),
            r.region,
            z.latitude,
            z.longitude
        FROM silver.olist_sellers_ds AS s
        LEFT JOIN silver.city_map AS m
            ON  m.city_raw = s.seller_city
            AND m.state_raw = s.seller_state
            AND m.zip_code_prefix = s.seller_zip_code_prefix
        LEFT JOIN silver.ibge_municipality AS i
            ON i.ibge_code = m.ibge_code
        INNER JOIN @regions AS r
            ON r.uf = COALESCE(i.uf, s.seller_state)
        LEFT JOIN silver.zip_location AS z
            ON z.zip_code_prefix = s.seller_zip_code_prefix;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'gold', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- 2.6 dim_product
        -- =====================================================================
        SET @table_name = 'dim_product';
        SET @start_time = SYSDATETIME();

        INSERT INTO gold.dim_product (
            product_key, product_id, product_category_name, product_category_name_english)
        SELECT
            ROW_NUMBER() OVER (ORDER BY p.product_id),
            p.product_id,
            cat.name,
            gold.fn_title_case(REPLACE(t.product_category_name_english, N'_', N' '))
        FROM silver.olist_products_ds AS p
        CROSS APPLY (SELECT COALESCE(p.product_category_name, N'sem_categoria') AS name) AS cat
        INNER JOIN silver.product_category_name_translation AS t
            ON t.product_category_name = cat.name;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'gold', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- 3. Dimension keys and order_key of every order, shared by the four facts
        --    (order_key is numbered once over all orders, so it matches across facts)
        -- =====================================================================
        DROP TABLE IF EXISTS #order_keys;

        SELECT
            o.order_id,
            ROW_NUMBER() OVER (ORDER BY o.order_id) AS order_key, 
            dc.customer_key,
            st.order_status_key,
            YEAR(o.order_purchase_timestamp) * 10000 + MONTH(o.order_purchase_timestamp) * 100
                + DAY(o.order_purchase_timestamp) AS order_date_key
        INTO #order_keys
        FROM silver.olist_orders_ds AS o
        INNER JOIN silver.olist_customers_ds AS c
            ON c.customer_id = o.customer_id
        INNER JOIN gold.dim_customer AS dc
            ON dc.customer_unique_id = c.customer_unique_id
        INNER JOIN gold.dim_order_status AS st
            ON st.order_status_code = o.order_status;

        ALTER TABLE #order_keys ADD PRIMARY KEY (order_id);

        -- =====================================================================
        -- 4.1 fact_sales
        -- =====================================================================
        SET @table_name = 'fact_sales';
        SET @start_time = SYSDATETIME();

        INSERT INTO gold.fact_sales (
            order_id, order_key, order_item_id, customer_key, product_key, seller_key,
            order_status_key, order_date_key, shipping_limit_date, price, freight_value,
            is_shipped_late)
        SELECT
            i.order_id,
            k.order_key,
            i.order_item_id,
            k.customer_key,
            dp.product_key,
            ds.seller_key,
            k.order_status_key,
            k.order_date_key,
            CAST(i.shipping_limit_date AS DATE),
            i.price,
            i.freight_value,
            CASE WHEN o.order_delivered_carrier_date IS NULL THEN NULL
                 WHEN o.order_delivered_carrier_date > i.shipping_limit_date THEN 'Yes'
                 ELSE 'No'
            END
        FROM silver.olist_order_items_ds AS i
        INNER JOIN #order_keys AS k
            ON k.order_id = i.order_id
        INNER JOIN silver.olist_orders_ds AS o
            ON o.order_id = i.order_id
        INNER JOIN gold.dim_product AS dp
            ON dp.product_id = i.product_id
        INNER JOIN gold.dim_seller AS ds
            ON ds.seller_id = i.seller_id;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'gold', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- 4.2 fact_delivery
        -- =====================================================================
        SET @table_name = 'fact_delivery';
        SET @start_time = SYSDATETIME();

        INSERT INTO gold.fact_delivery (
            order_id, customer_key, order_status_key, order_date_key, approved_date_key,
            delivered_carrier_date_key, delivered_date_key, estimated_delivery_date_key,
            order_purchase_time, order_purchase_hour, delivery_days, estimated_delivery_days,
            approval_hours, seller_handling_days, carrier_transit_days, delivery_delay_days, is_late)
        SELECT
            o.order_id,
            k.customer_key,
            k.order_status_key,
            k.order_date_key,
            YEAR(o.order_approved_at) * 10000 + MONTH(o.order_approved_at) * 100
                + DAY(o.order_approved_at),
            YEAR(o.order_delivered_carrier_date) * 10000 + MONTH(o.order_delivered_carrier_date) * 100
                + DAY(o.order_delivered_carrier_date),
            YEAR(o.order_delivered_customer_date) * 10000 + MONTH(o.order_delivered_customer_date) * 100
                + DAY(o.order_delivered_customer_date),
            YEAR(o.order_estimated_delivery_date) * 10000 + MONTH(o.order_estimated_delivery_date) * 100
                + DAY(o.order_estimated_delivery_date),
            CAST(o.order_purchase_timestamp AS TIME(0)),
            DATEPART(HOUR, o.order_purchase_timestamp),
            o.delivery_days,
            DATEDIFF(DAY, CAST(o.order_purchase_timestamp AS DATE),
                          CAST(o.order_estimated_delivery_date AS DATE)),
            o.approval_hours,
            o.seller_handling_days,
            o.carrier_transit_days,
            o.delivery_delay_days,
            CASE o.late_delivery_flag WHEN 1 THEN 'Yes' WHEN 0 THEN 'No' END
        FROM silver.olist_orders_ds AS o
        INNER JOIN #order_keys AS k
            ON k.order_id = o.order_id;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'gold', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- 4.3 fact_reviews
        -- =====================================================================
        SET @table_name = 'fact_reviews';
        SET @start_time = SYSDATETIME();

        INSERT INTO gold.fact_reviews (
            review_id, order_id, order_key, customer_key, order_status_key, order_date_key,
            review_date_key, review_score, review_sentiment, has_comment, review_answer_hours,
            is_review_before_delivery)
        SELECT
            r.review_id,
            r.order_id,
            k.order_key,
            k.customer_key,
            k.order_status_key,
            k.order_date_key,
            YEAR(r.review_creation_date) * 10000 + MONTH(r.review_creation_date) * 100
                + DAY(r.review_creation_date),
            r.review_score,
            r.review_sentiment,
            CASE WHEN r.review_comment_message IS NOT NULL THEN 'Yes' ELSE 'No' END,
            r.review_answer_hours,
            CASE WHEN o.order_delivered_customer_date IS NULL
                   OR CAST(r.review_creation_date AS DATE) < CAST(o.order_delivered_customer_date AS DATE)
                 THEN 'Yes' ELSE 'No'
            END
        FROM silver.olist_order_reviews_ds AS r
        INNER JOIN #order_keys AS k
            ON k.order_id = r.order_id
        INNER JOIN silver.olist_orders_ds AS o
            ON o.order_id = r.order_id;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'gold', @table_name, @start_time, @rows_loaded;

        -- =====================================================================
        -- 4.4 fact_payments
        -- =====================================================================
        SET @table_name = 'fact_payments';
        SET @start_time = SYSDATETIME();

        INSERT INTO gold.fact_payments (
            order_id, order_key, payment_sequential, customer_key, order_status_key,
            order_date_key, payment_method_key, payment_installments, payment_value)
        SELECT
            p.order_id,
            k.order_key,
            p.payment_sequential,
            k.customer_key,
            k.order_status_key,
            k.order_date_key,
            pm.payment_method_key,
            p.payment_installments,
            p.payment_value
        FROM silver.olist_order_payments_ds AS p
        INNER JOIN #order_keys AS k
            ON k.order_id = p.order_id
        INNER JOIN gold.dim_payment_method AS pm
            ON pm.payment_type_code = p.payment_type;

        SET @rows_loaded = @@ROWCOUNT;
        EXEC etl.log_table_load @batch_id, 'gold', @table_name, @start_time, @rows_loaded;

        DROP TABLE IF EXISTS #order_keys;

        COMMIT TRANSACTION;
        EXEC etl.end_batch @batch_id = @batch_id, @status = 'SUCCESS';
    END TRY
    BEGIN CATCH
        SET @error_message = ERROR_MESSAGE();
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        SET @start_time = COALESCE(@start_time, SYSDATETIME());
        EXEC etl.log_table_load @batch_id = @batch_id, @schema_name = 'gold',
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
PRINT '  Stored Procedure: gold.load_gold';
PRINT '  Status          : SUCCESS';
PRINT '============================================================';
GO
