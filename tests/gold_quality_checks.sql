/*
===============================================================================
Quality Checks: Gold Layer
===============================================================================
PURPOSE:
    Checks the star schema before Power BI: grain preserved from silver, totals reconciled,
    calendar coverage and dimension completeness (including official IBGE city names, see
    src/build_city_map.py). Foreign keys already guarantee that every
    fact key exists in its dimension. One row per check; issue_count should be 0 for ERROR.
USAGE:
    Run after EXEC gold.load_gold.
===============================================================================
*/
USE OlistDW;
GO

WITH checks AS (
    -- Grain: every silver row reaches its fact
    SELECT 'row count differences silver vs gold facts' AS check_name, 'ERROR' AS severity,
           ABS((SELECT COUNT(*) FROM silver.olist_order_items_ds)    - (SELECT COUNT(*) FROM gold.fact_sales))
         + ABS((SELECT COUNT(*) FROM silver.olist_orders_ds)         - (SELECT COUNT(*) FROM gold.fact_delivery))
         + ABS((SELECT COUNT(*) FROM silver.olist_order_reviews_ds)  - (SELECT COUNT(*) FROM gold.fact_reviews))
         + ABS((SELECT COUNT(*) FROM silver.olist_order_payments_ds) - (SELECT COUNT(*) FROM gold.fact_payments))
           AS issue_count
    UNION ALL SELECT 'dim_customer rows <> distinct customer_unique_id', 'ERROR',
           ABS((SELECT COUNT(*) FROM gold.dim_customer)
             - (SELECT COUNT(DISTINCT customer_unique_id) FROM silver.olist_customers_ds))
    UNION ALL SELECT 'dim_product rows <> silver products', 'ERROR',
           ABS((SELECT COUNT(*) FROM gold.dim_product) - (SELECT COUNT(*) FROM silver.olist_products_ds))
    UNION ALL SELECT 'dim_seller rows <> silver sellers', 'ERROR',
           ABS((SELECT COUNT(*) FROM gold.dim_seller) - (SELECT COUNT(*) FROM silver.olist_sellers_ds))

    -- Reconciliation (cents)
    UNION ALL SELECT 'price total differs from silver (cents)', 'ERROR',
           CAST(ABS((SELECT SUM(price) FROM gold.fact_sales)
                  - (SELECT SUM(price) FROM silver.olist_order_items_ds)) * 100 AS INT)
    UNION ALL SELECT 'payment total differs from silver (cents)', 'ERROR',
           CAST(ABS((SELECT SUM(payment_value) FROM gold.fact_payments)
                  - (SELECT SUM(payment_value) FROM silver.olist_order_payments_ds)) * 100 AS INT)

    -- Calendar
    UNION ALL SELECT 'calendar gaps (missing days)', 'ERROR',
           (SELECT DATEDIFF(DAY, MIN([date]), MAX([date])) + 1 - COUNT(*) FROM gold.dim_calendar)
    UNION ALL SELECT 'month_start not first day of month', 'ERROR',
           (SELECT COUNT(*) FROM gold.dim_calendar
            WHERE month_start <> DATEFROMPARTS([year], [month], 1))
    UNION ALL SELECT 'shipping limit dates outside calendar', 'WARNING',
           (SELECT COUNT(*) FROM gold.fact_sales AS f
            WHERE NOT EXISTS (SELECT 1 FROM gold.dim_calendar AS d WHERE d.[date] = f.shipping_limit_date))

    -- order_key: one number per order, the same in fact_sales, fact_reviews and fact_payments
    UNION ALL SELECT 'order_key not 1:1 with order_id', 'ERROR',
           (SELECT COUNT(*) FROM (
                SELECT order_id FROM (
                    SELECT order_id, order_key FROM gold.fact_sales
                    UNION
                    SELECT order_id, order_key FROM gold.fact_reviews
                    UNION
                    SELECT order_id, order_key FROM gold.fact_payments) AS x
                GROUP BY order_id HAVING COUNT(*) > 1) AS d)
         + (SELECT COUNT(*) FROM (
                SELECT order_key FROM (
                    SELECT order_id, order_key FROM gold.fact_sales
                    UNION
                    SELECT order_id, order_key FROM gold.fact_reviews
                    UNION
                    SELECT order_id, order_key FROM gold.fact_payments) AS x
                GROUP BY order_key HAVING COUNT(*) > 1) AS k)

    -- Delivery stages: approval + seller handling + carrier transit = delivery_days (calendar days)
    UNION ALL SELECT 'delivery stages do not add up to delivery_days', 'ERROR',
           (SELECT COUNT(*) FROM gold.fact_delivery AS f
            INNER JOIN gold.dim_calendar AS po ON po.date_key = f.order_date_key
            INNER JOIN gold.dim_calendar AS ap ON ap.date_key = f.approved_date_key
            WHERE f.seller_handling_days IS NOT NULL AND f.carrier_transit_days IS NOT NULL
              AND DATEDIFF(DAY, po.[date], ap.[date]) + f.seller_handling_days
                + f.carrier_transit_days <> f.delivery_days)
    UNION ALL SELECT 'is_late disagrees with delivery_delay_days', 'ERROR',
           (SELECT COUNT(*) FROM gold.fact_delivery
            WHERE (is_late = 'Yes' AND NOT delivery_delay_days > 0)
               OR (is_late = 'No' AND NOT delivery_delay_days <= 0)
               OR (is_late IS NULL AND delivery_delay_days IS NOT NULL)
               OR (is_late IS NOT NULL AND delivery_delay_days IS NULL))
    UNION ALL SELECT 'purchase hour outside 0-23', 'ERROR',
           (SELECT COUNT(*) FROM gold.fact_delivery WHERE order_purchase_hour > 23)

    -- Dimension completeness
    UNION ALL SELECT 'products without English category', 'ERROR',
           (SELECT COUNT(*) FROM gold.dim_product WHERE product_category_name_english IS NULL)
    UNION ALL SELECT 'customers without coordinates', 'WARNING',
           (SELECT COUNT(*) FROM gold.dim_customer WHERE customer_latitude IS NULL)
    UNION ALL SELECT 'sellers without coordinates', 'WARNING',
           (SELECT COUNT(*) FROM gold.dim_seller WHERE seller_latitude IS NULL)
    UNION ALL SELECT 'customer cities not an IBGE municipality of their state', 'WARNING',
           (SELECT COUNT(*) FROM gold.dim_customer AS d
            WHERE NOT EXISTS (SELECT 1 FROM silver.ibge_municipality AS i
                              WHERE i.municipality_name = d.customer_city AND i.uf = d.customer_state))
    UNION ALL SELECT 'seller cities not an IBGE municipality of their state', 'WARNING',
           (SELECT COUNT(*) FROM gold.dim_seller AS d
            WHERE NOT EXISTS (SELECT 1 FROM silver.ibge_municipality AS i
                              WHERE i.municipality_name = d.seller_city AND i.uf = d.seller_state))
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
