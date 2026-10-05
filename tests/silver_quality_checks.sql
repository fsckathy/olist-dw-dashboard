/*
===============================================================================
Quality Checks: Silver Layer
===============================================================================
PURPOSE:
    Checks the cleaned data: nothing lost from bronze, referential integrity between the
    silver tables (they have no foreign keys), value domains and date consistency.
    One row per check; issue_count should be 0 for ERROR checks.
USAGE:
    Run after EXEC silver.load_silver.
===============================================================================
*/
USE OlistDW;
GO

WITH checks AS (
    -- Completeness: bronze -> silver (geolocation is filtered on purpose)
    SELECT 'row count differences bronze vs silver' AS check_name, 'ERROR' AS severity,
           ABS((SELECT COUNT(*) FROM bronze.olist_customers_ds)      - (SELECT COUNT(*) FROM silver.olist_customers_ds))
         + ABS((SELECT COUNT(*) FROM bronze.olist_orders_ds)         - (SELECT COUNT(*) FROM silver.olist_orders_ds))
         + ABS((SELECT COUNT(*) FROM bronze.olist_order_items_ds)    - (SELECT COUNT(*) FROM silver.olist_order_items_ds))
         + ABS((SELECT COUNT(*) FROM bronze.olist_order_payments_ds) - (SELECT COUNT(*) FROM silver.olist_order_payments_ds))
         + ABS((SELECT COUNT(*) FROM bronze.olist_order_reviews_ds)  - (SELECT COUNT(*) FROM silver.olist_order_reviews_ds))
         + ABS((SELECT COUNT(*) FROM bronze.olist_products_ds)       - (SELECT COUNT(*) FROM silver.olist_products_ds))
         + ABS((SELECT COUNT(*) FROM bronze.olist_sellers_ds)        - (SELECT COUNT(*) FROM silver.olist_sellers_ds))
           AS issue_count

    -- Referential integrity
    UNION ALL SELECT 'orders without customer', 'ERROR',
           (SELECT COUNT(*) FROM silver.olist_orders_ds AS o
            WHERE NOT EXISTS (SELECT 1 FROM silver.olist_customers_ds AS c WHERE c.customer_id = o.customer_id))
    UNION ALL SELECT 'items without order', 'ERROR',
           (SELECT COUNT(*) FROM silver.olist_order_items_ds AS i
            WHERE NOT EXISTS (SELECT 1 FROM silver.olist_orders_ds AS o WHERE o.order_id = i.order_id))
    UNION ALL SELECT 'items without product', 'ERROR',
           (SELECT COUNT(*) FROM silver.olist_order_items_ds AS i
            WHERE NOT EXISTS (SELECT 1 FROM silver.olist_products_ds AS p WHERE p.product_id = i.product_id))
    UNION ALL SELECT 'items without seller', 'ERROR',
           (SELECT COUNT(*) FROM silver.olist_order_items_ds AS i
            WHERE NOT EXISTS (SELECT 1 FROM silver.olist_sellers_ds AS s WHERE s.seller_id = i.seller_id))
    UNION ALL SELECT 'payments without order', 'ERROR',
           (SELECT COUNT(*) FROM silver.olist_order_payments_ds AS p
            WHERE NOT EXISTS (SELECT 1 FROM silver.olist_orders_ds AS o WHERE o.order_id = p.order_id))
    UNION ALL SELECT 'reviews without order', 'ERROR',
           (SELECT COUNT(*) FROM silver.olist_order_reviews_ds AS r
            WHERE NOT EXISTS (SELECT 1 FROM silver.olist_orders_ds AS o WHERE o.order_id = r.order_id))
    UNION ALL SELECT 'product categories without translation', 'ERROR',
           (SELECT COUNT(DISTINCT COALESCE(p.product_category_name, N'sem_categoria'))
            FROM silver.olist_products_ds AS p
            WHERE NOT EXISTS (SELECT 1 FROM silver.product_category_name_translation AS t
                              WHERE t.product_category_name = COALESCE(p.product_category_name, N'sem_categoria')))

    -- Domains and consistency
    UNION ALL SELECT 'unknown order status', 'ERROR',
           (SELECT COUNT(*) FROM silver.olist_orders_ds
            WHERE order_status NOT IN ('created', 'approved', 'invoiced', 'processing',
                                       'shipped', 'delivered', 'unavailable', 'canceled'))
    UNION ALL SELECT 'negative price or freight', 'ERROR',
           (SELECT COUNT(*) FROM silver.olist_order_items_ds WHERE price < 0 OR freight_value < 0)
    UNION ALL SELECT 'geolocation points outside Brazil', 'ERROR',
           (SELECT COUNT(*) FROM silver.olist_geolocation_ds
            WHERE geolocation_lat NOT BETWEEN -34.0 AND 5.5 OR geolocation_lng NOT BETWEEN -74.5 AND -28.5)
    UNION ALL SELECT 'delivered before purchase', 'WARNING',
           (SELECT COUNT(*) FROM silver.olist_orders_ds WHERE delivery_days < 0)
    UNION ALL SELECT 'orders without payment', 'WARNING',
           (SELECT COUNT(*) FROM silver.olist_orders_ds AS o
            WHERE NOT EXISTS (SELECT 1 FROM silver.olist_order_payments_ds AS p WHERE p.order_id = o.order_id))
    UNION ALL SELECT 'payments with 0 installments', 'WARNING',
           (SELECT COUNT(*) FROM silver.olist_order_payments_ds WHERE payment_installments = 0)

    -- Delivery stages: negative values are never stored; out-of-order source dates become NULL
    UNION ALL SELECT 'negative delivery stage or review answer time', 'ERROR',
           (SELECT COUNT(*) FROM silver.olist_orders_ds
            WHERE seller_handling_days < 0 OR carrier_transit_days < 0)
         + (SELECT COUNT(*) FROM silver.olist_order_reviews_ds WHERE review_answer_hours < 0)
    UNION ALL SELECT 'handed to carrier before approval (handling NULL)', 'WARNING',
           (SELECT COUNT(*) FROM silver.olist_orders_ds
            WHERE order_approved_at IS NOT NULL AND order_delivered_carrier_date IS NOT NULL
              AND seller_handling_days IS NULL)
    UNION ALL SELECT 'delivered before carrier handoff (transit NULL)', 'WARNING',
           (SELECT COUNT(*) FROM silver.olist_orders_ds
            WHERE order_delivered_carrier_date IS NOT NULL AND order_delivered_customer_date IS NOT NULL
              AND carrier_transit_days IS NULL)
    UNION ALL SELECT 'handed to carrier before purchase', 'WARNING',
           (SELECT COUNT(*) FROM silver.olist_orders_ds
            WHERE order_delivered_carrier_date < order_purchase_timestamp)

    -- City reference (src/build_city_map.py): every customer/seller city combination mapped
    UNION ALL SELECT 'IBGE municipalities missing (< 5570)', 'ERROR',
           IIF((SELECT COUNT(*) FROM silver.ibge_municipality) < 5570, 1, 0)
    UNION ALL SELECT 'city combinations missing from city_map (rebuild it)', 'ERROR',
           (SELECT COUNT(*) FROM (
                SELECT c.customer_city AS city, c.customer_state AS uf, c.customer_zip_code_prefix AS zip
                FROM silver.olist_customers_ds AS c
                UNION
                SELECT s.seller_city, s.seller_state, s.seller_zip_code_prefix
                FROM silver.olist_sellers_ds AS s) AS x
            WHERE NOT EXISTS (SELECT 1 FROM silver.city_map AS m
                              WHERE m.city_raw = x.city AND m.state_raw = x.uf
                                AND m.zip_code_prefix = x.zip))
    UNION ALL SELECT 'customer/seller rows with a city not matched to IBGE', 'WARNING',
           (SELECT COALESCE(SUM(m.n_rows), 0) FROM silver.city_map AS m
            WHERE m.match_method = 'unmatched')
    UNION ALL SELECT 'customer zips without coordinates', 'WARNING',
           (SELECT COUNT(DISTINCT c.customer_zip_code_prefix) FROM silver.olist_customers_ds AS c
            WHERE NOT EXISTS (SELECT 1 FROM silver.zip_location AS z WHERE z.zip_code_prefix = c.customer_zip_code_prefix))
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
