/*
===============================================================================
DDL Script: Create Silver Tables
===============================================================================
PURPOSE:
    Cleaned, typed and keyed copy of bronze, plus derived columns and one derived table:
        - proper data types (CHAR ids, DATETIME2, DECIMAL money)
        - primary keys on every table (natural keys of the source)
        - source spelling fixed (product_name_lenght -> product_name_length)
        - derived columns: delivery_days, approval_hours, seller_handling_days,
          carrier_transit_days, delivery_delay_days, late_delivery_flag, review_sentiment,
          review_answer_hours, product_volume_cm3
        - silver.zip_location: one row per zip prefix with clean median coordinates
        - dwh_batch_id / dwh_load_date on every table: which etl batch wrote the row
    No foreign keys between silver tables (they are truncated and reloaded independently);
    referential integrity is verified by tests/silver_quality_checks.sql.
    Drops and recreates the tables.
USAGE:
    Run after the bronze scripts, before silver/load_silver.sql.
===============================================================================
*/
USE OlistDW;
GO

-- ----------------------------------------------------------------------------
-- TABLE 1: silver.olist_customers_ds
-- customer_id is created per order; customer_unique_id identifies the person.
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.olist_customers_ds;
CREATE TABLE silver.olist_customers_ds (
    customer_id              CHAR(32)      NOT NULL,
    customer_unique_id       CHAR(32)      NOT NULL,
    customer_zip_code_prefix CHAR(5)       NOT NULL,  
    customer_city            NVARCHAR(100) NOT NULL,
    customer_state           CHAR(2)       NOT NULL,
    dwh_batch_id             INT           NOT NULL,
    dwh_load_date            DATETIME2(0)  NOT NULL CONSTRAINT df_silver_customers_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_customers PRIMARY KEY (customer_id)
);
CREATE INDEX ix_silver_customers_unique_id ON silver.olist_customers_ds (customer_unique_id);
GO

-- ----------------------------------------------------------------------------
-- TABLE 2: silver.olist_geolocation_ds
-- Points inside Brazil only, rounded to 6 decimals, exact duplicates removed.
-- No primary key: many points per zip prefix.
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.olist_geolocation_ds;
CREATE TABLE silver.olist_geolocation_ds (
    geolocation_zip_code_prefix CHAR(5)       NOT NULL,
    geolocation_lat             DECIMAL(9, 6) NOT NULL,
    geolocation_lng             DECIMAL(9, 6) NOT NULL,
    geolocation_city            NVARCHAR(100) NOT NULL,
    geolocation_state           CHAR(2)       NOT NULL,
    dwh_batch_id                INT           NOT NULL,
    dwh_load_date               DATETIME2(0)  NOT NULL CONSTRAINT df_silver_geolocation_load DEFAULT SYSDATETIME()
);
CREATE CLUSTERED INDEX cix_silver_geolocation_zip
    ON silver.olist_geolocation_ds (geolocation_zip_code_prefix);
GO

-- ----------------------------------------------------------------------------
-- TABLE 3: silver.zip_location (derived from silver.olist_geolocation_ds)
-- One row per zip prefix: median coordinates after removing outlier points.
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.zip_location;
CREATE TABLE silver.zip_location (
    zip_code_prefix CHAR(5)       NOT NULL,
    latitude        DECIMAL(9, 6) NOT NULL,
    longitude       DECIMAL(9, 6) NOT NULL,
    n_points        INT           NOT NULL,  -- clean points behind the median
    dwh_batch_id    INT           NOT NULL,
    dwh_load_date   DATETIME2(0)  NOT NULL CONSTRAINT df_silver_zip_location_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_zip_location PRIMARY KEY (zip_code_prefix)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 4: silver.olist_order_items_ds
-- One row per unit sold (Olist has no quantity column).
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.olist_order_items_ds;
CREATE TABLE silver.olist_order_items_ds (
    order_id            CHAR(32)       NOT NULL,
    order_item_id       SMALLINT       NOT NULL,
    product_id          CHAR(32)       NOT NULL,
    seller_id           CHAR(32)       NOT NULL,
    shipping_limit_date DATETIME2(0)   NOT NULL,
    price               DECIMAL(10, 2) NOT NULL,
    freight_value       DECIMAL(10, 2) NOT NULL,
    dwh_batch_id        INT            NOT NULL,
    dwh_load_date       DATETIME2(0)   NOT NULL CONSTRAINT df_silver_order_items_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_order_items PRIMARY KEY (order_id, order_item_id)
);
CREATE INDEX ix_silver_order_items_product ON silver.olist_order_items_ds (product_id);
CREATE INDEX ix_silver_order_items_seller  ON silver.olist_order_items_ds (seller_id);
GO

-- ----------------------------------------------------------------------------
-- TABLE 5: silver.olist_order_payments_ds
-- One row per payment (card + voucher = 2 rows); installments are a column.
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.olist_order_payments_ds;
CREATE TABLE silver.olist_order_payments_ds (
    order_id             CHAR(32)       NOT NULL,
    payment_sequential   SMALLINT       NOT NULL,
    payment_type         VARCHAR(20)    NOT NULL,  
    payment_installments SMALLINT       NOT NULL,
    payment_value        DECIMAL(10, 2) NOT NULL,
    dwh_batch_id         INT            NOT NULL,
    dwh_load_date        DATETIME2(0)   NOT NULL CONSTRAINT df_silver_order_payments_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_order_payments PRIMARY KEY (order_id, payment_sequential)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 6: silver.olist_order_reviews_ds
-- review_id is not unique in the source (814 repeats): key is (review_id, order_id).
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.olist_order_reviews_ds;
CREATE TABLE silver.olist_order_reviews_ds (
    review_id               CHAR(32)      NOT NULL,
    order_id                CHAR(32)      NOT NULL,
    review_score            TINYINT       NOT NULL,
    review_sentiment        VARCHAR(10)   NOT NULL,  -- Positive (4-5) / Neutral (3) / Negative (1-2)
    review_comment_title    NVARCHAR(200) NULL,
    review_comment_message  NVARCHAR(MAX) NULL,
    review_creation_date    DATETIME2(0)  NOT NULL,
    review_answer_timestamp DATETIME2(0)  NOT NULL,
    review_answer_hours     DECIMAL(10, 2) NOT NULL,  -- survey sent -> customer answer
    dwh_batch_id            INT           NOT NULL,
    dwh_load_date           DATETIME2(0)  NOT NULL CONSTRAINT df_silver_order_reviews_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_order_reviews PRIMARY KEY (review_id, order_id)
);
CREATE INDEX ix_silver_order_reviews_order ON silver.olist_order_reviews_ds (order_id);
GO

-- ----------------------------------------------------------------------------
-- TABLE 7: silver.olist_orders_ds
-- Delivery measures are NULL until the order is delivered to the customer.
-- Stages in calendar days, so approval + handling + transit = delivery_days. A stage whose
-- source dates are out of order (e.g. carrier before approval) is NULL, not negative.
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.olist_orders_ds;
CREATE TABLE silver.olist_orders_ds (
    order_id                      CHAR(32)       NOT NULL,
    customer_id                   CHAR(32)       NOT NULL,
    order_status                  VARCHAR(20)    NOT NULL,
    order_purchase_timestamp      DATETIME2(0)   NOT NULL,
    order_approved_at             DATETIME2(0)   NULL,
    order_delivered_carrier_date  DATETIME2(0)   NULL,
    order_delivered_customer_date DATETIME2(0)   NULL,
    order_estimated_delivery_date DATETIME2(0)   NOT NULL,
    delivery_days                 SMALLINT       NULL,  -- purchase date -> delivery date
    approval_hours                DECIMAL(10, 2) NULL,  -- purchase -> approval
    seller_handling_days          SMALLINT       NULL,  -- approval date -> carrier date
    carrier_transit_days          SMALLINT       NULL,  -- carrier date -> delivery date
    delivery_delay_days           SMALLINT       NULL,  -- estimated -> delivery (> 0 late, < 0 early)
    late_delivery_flag            BIT            NULL,  -- delivered after the estimated date
    dwh_batch_id                  INT            NOT NULL,
    dwh_load_date                 DATETIME2(0)   NOT NULL CONSTRAINT df_silver_orders_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_orders PRIMARY KEY (order_id)
);
CREATE INDEX ix_silver_orders_customer ON silver.olist_orders_ds (customer_id);
GO

-- ----------------------------------------------------------------------------
-- TABLE 8: silver.olist_products_ds
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.olist_products_ds;
CREATE TABLE silver.olist_products_ds (
    product_id                 CHAR(32)      NOT NULL,
    product_category_name      NVARCHAR(100) NULL,      -- NULL in the source for 610 products
    product_name_length        SMALLINT      NULL,
    product_description_length SMALLINT      NULL,
    product_photos_qty         SMALLINT      NULL,
    product_weight_g           INT           NULL,
    product_length_cm          SMALLINT      NULL,
    product_height_cm          SMALLINT      NULL,
    product_width_cm           SMALLINT      NULL,
    product_volume_cm3         INT           NULL,
    dwh_batch_id               INT           NOT NULL,
    dwh_load_date              DATETIME2(0)  NOT NULL CONSTRAINT df_silver_products_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_products PRIMARY KEY (product_id)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 9: silver.olist_sellers_ds
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.olist_sellers_ds;
CREATE TABLE silver.olist_sellers_ds (
    seller_id              CHAR(32)      NOT NULL,
    seller_zip_code_prefix CHAR(5)       NOT NULL,
    seller_city            NVARCHAR(100) NOT NULL,
    seller_state           CHAR(2)       NOT NULL,
    dwh_batch_id           INT           NOT NULL,
    dwh_load_date          DATETIME2(0)  NOT NULL CONSTRAINT df_silver_sellers_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_sellers PRIMARY KEY (seller_id)
);
GO

-- ----------------------------------------------------------------------------
-- TABLE 10: silver.product_category_name_translation
-- Source file + the categories it misses (completed in load_silver).
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS silver.product_category_name_translation;
CREATE TABLE silver.product_category_name_translation (
    product_category_name         NVARCHAR(100) NOT NULL,
    product_category_name_english NVARCHAR(100) NOT NULL,
    dwh_batch_id                  INT           NOT NULL,
    dwh_load_date                 DATETIME2(0)  NOT NULL CONSTRAINT df_silver_category_translation_load DEFAULT SYSDATETIME(),

    CONSTRAINT pk_silver_category_translation PRIMARY KEY (product_category_name)
);
GO

PRINT '============================================================';
PRINT 'DEPLOYMENT SUMMARY:';
PRINT '  Schema         : silver';
PRINT '  Tables Created : 10 (9 source tables + zip_location)';
PRINT '  Primary Keys   : all tables except olist_geolocation_ds';
PRINT '  Status         : SUCCESS';
PRINT '============================================================';
GO
