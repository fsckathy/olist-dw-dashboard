/*
===============================================================================
Quality Checks: Bronze Layer
===============================================================================
PURPOSE:
    Checks the raw data before silver: completeness, key uniqueness and whether the values
    can be converted to the silver types. One row per check; issue_count should be 0 for
    ERROR checks, WARNING checks document known source issues.
USAGE:
    Run after EXEC bronze.load_bronze.
===============================================================================
*/
USE OlistDW;
GO

WITH checks AS (
    -- Completeness: row counts of the source files (Kaggle olistbr/brazilian-ecommerce)
    SELECT 'customers row count <> 99441' AS check_name, 'ERROR' AS severity,
           ABS((SELECT COUNT(*) FROM bronze.olist_customers_ds) - 99441) AS issue_count
    UNION ALL SELECT 'orders row count <> 99441', 'ERROR',
           ABS((SELECT COUNT(*) FROM bronze.olist_orders_ds) - 99441)
    UNION ALL SELECT 'order items row count <> 112650', 'ERROR',
           ABS((SELECT COUNT(*) FROM bronze.olist_order_items_ds) - 112650)
    UNION ALL SELECT 'payments row count <> 103886', 'ERROR',
           ABS((SELECT COUNT(*) FROM bronze.olist_order_payments_ds) - 103886)
    UNION ALL SELECT 'reviews row count <> 99224', 'ERROR',
           ABS((SELECT COUNT(*) FROM bronze.olist_order_reviews_ds) - 99224)
    UNION ALL SELECT 'geolocation row count <> 1000163', 'ERROR',
           ABS((SELECT COUNT(*) FROM bronze.olist_geolocation_ds) - 1000163)
    UNION ALL SELECT 'products row count <> 32951', 'ERROR',
           ABS((SELECT COUNT(*) FROM bronze.olist_products_ds) - 32951)
    UNION ALL SELECT 'sellers row count <> 3095', 'ERROR',
           ABS((SELECT COUNT(*) FROM bronze.olist_sellers_ds) - 3095)
    UNION ALL SELECT 'category translations row count <> 71', 'ERROR',
           ABS((SELECT COUNT(*) FROM bronze.product_category_name_translation) - 71)

    -- Missing keys: primary and foreign keys of every table
    UNION ALL SELECT 'customers with blank customer_id or customer_unique_id', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_customers_ds
            WHERE NULLIF(TRIM(customer_id), '') IS NULL OR NULLIF(TRIM(customer_unique_id), '') IS NULL)
    UNION ALL SELECT 'orders with blank order_id or customer_id', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_orders_ds
            WHERE NULLIF(TRIM(order_id), '') IS NULL OR NULLIF(TRIM(customer_id), '') IS NULL)
    UNION ALL SELECT 'order items with a blank key', 'ERROR', 
           (SELECT COUNT(*) FROM bronze.olist_order_items_ds
            WHERE NULLIF(TRIM(order_id), '') IS NULL OR NULLIF(TRIM(order_item_id), '') IS NULL
               OR NULLIF(TRIM(product_id), '') IS NULL OR NULLIF(TRIM(seller_id), '') IS NULL)
    UNION ALL SELECT 'payments with blank order_id', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_order_payments_ds WHERE NULLIF(TRIM(order_id), '') IS NULL)
    UNION ALL SELECT 'reviews with blank review_id or order_id', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_order_reviews_ds
            WHERE NULLIF(TRIM(review_id), '') IS NULL OR NULLIF(TRIM(order_id), '') IS NULL)
    UNION ALL SELECT 'products with blank product_id', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_products_ds WHERE NULLIF(TRIM(product_id), '') IS NULL)
    UNION ALL SELECT 'sellers with blank seller_id', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_sellers_ds WHERE NULLIF(TRIM(seller_id), '') IS NULL)
    UNION ALL SELECT 'geolocation with blank zip prefix', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_geolocation_ds
            WHERE NULLIF(TRIM(geolocation_zip_code_prefix), '') IS NULL)
    UNION ALL SELECT 'category translations with a blank name', 'ERROR',
           (SELECT COUNT(*) FROM bronze.product_category_name_translation
            WHERE NULLIF(TRIM(product_category_name), '') IS NULL
               OR NULLIF(TRIM(product_category_name_english), '') IS NULL)

    -- Key uniqueness
    UNION ALL SELECT 'duplicated customer_id', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT customer_id) FROM bronze.olist_customers_ds)
    UNION ALL SELECT 'duplicated order_id', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM bronze.olist_orders_ds)
    UNION ALL SELECT 'duplicated (order_id, order_item_id)', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT CONCAT(order_id, '|', order_item_id)) FROM bronze.olist_order_items_ds)
    UNION ALL SELECT 'duplicated (order_id, payment_sequential)', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT CONCAT(order_id, '|', payment_sequential)) FROM bronze.olist_order_payments_ds)
    UNION ALL SELECT 'duplicated (review_id, order_id)', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT CONCAT(review_id, '|', order_id)) FROM bronze.olist_order_reviews_ds)
    UNION ALL SELECT 'duplicated product_id', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT product_id) FROM bronze.olist_products_ds)
    UNION ALL SELECT 'duplicated seller_id', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT seller_id) FROM bronze.olist_sellers_ds)
    UNION ALL SELECT 'duplicated category in translations', 'ERROR',
           (SELECT COUNT(*) - COUNT(DISTINCT product_category_name) FROM bronze.product_category_name_translation)
    UNION ALL SELECT 'duplicated review_id (known: same review for several orders)', 'WARNING',
           (SELECT COUNT(*) - COUNT(DISTINCT review_id) FROM bronze.olist_order_reviews_ds)

    -- Convertibility to the silver types (columns that silver converts with CONVERT,
    -- which fails the whole load on a bad value)
    UNION ALL SELECT 'purchase timestamps not convertible', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_orders_ds
            WHERE TRY_CONVERT(DATETIME2(0), order_purchase_timestamp, 120) IS NULL)
    UNION ALL SELECT 'estimated delivery dates not convertible', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_orders_ds
            WHERE TRY_CONVERT(DATETIME2(0), order_estimated_delivery_date, 120) IS NULL)
    UNION ALL SELECT 'order item ids not convertible', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_order_items_ds
            WHERE TRY_CONVERT(SMALLINT, order_item_id) IS NULL)
    UNION ALL SELECT 'shipping limit dates not convertible', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_order_items_ds
            WHERE TRY_CONVERT(DATETIME2(0), shipping_limit_date, 120) IS NULL)
    UNION ALL SELECT 'prices not convertible or negative', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_order_items_ds
            WHERE COALESCE(TRY_CONVERT(DECIMAL(10, 2), price), -1) < 0)
    UNION ALL SELECT 'freight values not convertible or negative', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_order_items_ds
            WHERE COALESCE(TRY_CONVERT(DECIMAL(10, 2), freight_value), -1) < 0)
    UNION ALL SELECT 'payment sequentials or installments not convertible', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_order_payments_ds
            WHERE TRY_CONVERT(SMALLINT, payment_sequential) IS NULL
               OR TRY_CONVERT(SMALLINT, payment_installments) IS NULL)
    UNION ALL SELECT 'payment values not convertible or negative', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_order_payments_ds
            WHERE COALESCE(TRY_CONVERT(DECIMAL(10, 2), payment_value), -1) < 0)
    UNION ALL SELECT 'review dates not convertible', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_order_reviews_ds
            WHERE TRY_CONVERT(DATETIME2(0), review_creation_date, 120) IS NULL
               OR TRY_CONVERT(DATETIME2(0), review_answer_timestamp, 120) IS NULL)
    UNION ALL SELECT 'review scores outside 1-5', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_order_reviews_ds
            WHERE COALESCE(TRY_CONVERT(TINYINT, review_score), 0) NOT BETWEEN 1 AND 5)
    UNION ALL SELECT 'zip prefixes not 5 digits', 'ERROR',
           (SELECT COUNT(*) FROM bronze.olist_customers_ds
            WHERE customer_zip_code_prefix NOT LIKE '[0-9][0-9][0-9][0-9][0-9]')

    -- Known source issues (documented, handled in silver)
    UNION ALL SELECT 'geolocation points outside Brazil', 'WARNING',
           (SELECT COUNT(*) FROM bronze.olist_geolocation_ds
            WHERE TRY_CONVERT(FLOAT, geolocation_lat) NOT BETWEEN -33.751111 AND 5.271944 --official source: IBGE
               OR TRY_CONVERT(FLOAT, geolocation_lng) NOT BETWEEN -73.990556 AND -28.835833) --official source: IBGE
    UNION ALL SELECT 'products without category', 'WARNING',
           (SELECT COUNT(*) FROM bronze.olist_products_ds WHERE NULLIF(TRIM(product_category_name), '') IS NULL)
)
SELECT
    c.check_name,
    c.severity,
    c.issue_count,
    CASE WHEN c.issue_count = 0 THEN 'PASS'
         WHEN c.severity = 'WARNING' THEN 'WARN'
         ELSE 'FAIL' END AS status
FROM checks AS c
ORDER BY CASE WHEN c.issue_count = 0 THEN 2 WHEN c.severity = 'WARNING' THEN 1 ELSE 0 END,
         c.check_name;
GO
