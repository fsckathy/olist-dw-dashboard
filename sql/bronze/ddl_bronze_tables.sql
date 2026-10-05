/*
===============================================================================
DDL Script: Create Bronze Tables
===============================================================================
PURPOSE:
    Raw landing zone: one table per Olist CSV file, same column names and order as the file.
    Every column is NVARCHAR and nullable, so any source value lands without conversion
    errors; typing, keys and validation happens in silver.
    Drops and recreates the tables (bronze holds no history: it is reloaded on every run).
USAGE:
    Run after the 00_init scripts, before bronze/load_bronze.sql.
===============================================================================
*/
USE OlistDW;
GO

-- ----------------------------------------------------------------------------
-- TABLE 1: bronze.olist_customers_ds  (olist_customers_dataset.csv)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.olist_customers_ds;
CREATE TABLE bronze.olist_customers_ds (
    customer_id              NVARCHAR(50),
    customer_unique_id       NVARCHAR(50),
    customer_zip_code_prefix NVARCHAR(10),
    customer_city            NVARCHAR(100),
    customer_state           NVARCHAR(5)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 2: bronze.olist_geolocation_ds  (olist_geolocation_dataset.csv)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.olist_geolocation_ds;
CREATE TABLE bronze.olist_geolocation_ds (
    geolocation_zip_code_prefix NVARCHAR(10),
    geolocation_lat             NVARCHAR(50),
    geolocation_lng             NVARCHAR(50),
    geolocation_city            NVARCHAR(100),
    geolocation_state           NVARCHAR(5)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 3: bronze.olist_order_items_ds  (olist_order_items_dataset.csv)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.olist_order_items_ds;
CREATE TABLE bronze.olist_order_items_ds (
    order_id            NVARCHAR(50),
    order_item_id       NVARCHAR(10),
    product_id          NVARCHAR(50),
    seller_id           NVARCHAR(50),
    shipping_limit_date NVARCHAR(30),
    price               NVARCHAR(30),
    freight_value       NVARCHAR(30)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 4: bronze.olist_order_payments_ds  (olist_order_payments_dataset.csv)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.olist_order_payments_ds;
CREATE TABLE bronze.olist_order_payments_ds (
    order_id             NVARCHAR(50),
    payment_sequential   NVARCHAR(10),
    payment_type         NVARCHAR(30),
    payment_installments NVARCHAR(10),
    payment_value        NVARCHAR(30)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 5: bronze.olist_order_reviews_ds  (olist_order_reviews_dataset.csv)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.olist_order_reviews_ds;
CREATE TABLE bronze.olist_order_reviews_ds (
    review_id               NVARCHAR(50),
    order_id                NVARCHAR(50),
    review_score            NVARCHAR(10),
    review_comment_title    NVARCHAR(MAX),
    review_comment_message  NVARCHAR(MAX),
    review_creation_date    NVARCHAR(30),
    review_answer_timestamp NVARCHAR(30)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 6: bronze.olist_orders_ds  (olist_orders_dataset.csv)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.olist_orders_ds;
CREATE TABLE bronze.olist_orders_ds (
    order_id                      NVARCHAR(50),
    customer_id                   NVARCHAR(50),
    order_status                  NVARCHAR(30),
    order_purchase_timestamp      NVARCHAR(30),
    order_approved_at             NVARCHAR(30),
    order_delivered_carrier_date  NVARCHAR(30),
    order_delivered_customer_date NVARCHAR(30),
    order_estimated_delivery_date NVARCHAR(30)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 7: bronze.olist_products_ds  (olist_products_dataset.csv)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.olist_products_ds;
CREATE TABLE bronze.olist_products_ds (
    product_id                 NVARCHAR(50),
    product_category_name      NVARCHAR(100),
    product_name_lenght        NVARCHAR(10),
    product_description_lenght NVARCHAR(10),
    product_photos_qty         NVARCHAR(10),
    product_weight_g           NVARCHAR(10),
    product_length_cm          NVARCHAR(10),
    product_height_cm          NVARCHAR(10),
    product_width_cm           NVARCHAR(10)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 8: bronze.olist_sellers_ds  (olist_sellers_dataset.csv)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.olist_sellers_ds;
CREATE TABLE bronze.olist_sellers_ds (
    seller_id              NVARCHAR(50),
    seller_zip_code_prefix NVARCHAR(10),
    seller_city            NVARCHAR(100),
    seller_state           NVARCHAR(5)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 9: bronze.product_category_name_translation  (product_category_name_translation.csv)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS bronze.product_category_name_translation;
CREATE TABLE bronze.product_category_name_translation (
    product_category_name         NVARCHAR(100),
    product_category_name_english NVARCHAR(100)
);
GO

PRINT '============================================================';
PRINT 'DEPLOYMENT SUMMARY:';
PRINT '  Schema         : bronze';
PRINT '  Tables Created : 9 (all columns NVARCHAR, raw)';
PRINT '  Status         : SUCCESS';
PRINT '============================================================';
GO
