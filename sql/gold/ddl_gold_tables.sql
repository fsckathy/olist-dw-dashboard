/*
===============================================================================
DDL Script: Create Gold Layer (Star Schema)
===============================================================================
PURPOSE:
    Business-ready star schema for Power BI, built from silver by gold.load_gold.
    - Dimensions have INT surrogate keys (*_key), numbered in natural-key order, so the same
      data always gets the same keys; natural keys are kept for traceability.
    - order_key (fact_sales, fact_reviews, fact_payments): integer order number, numbered in order_id order
      over all orders, to count distinct orders in Power BI without the 32-char order_id.
      Not a relationship between facts: each fact relates only to the dimensions.
    - Facts reference dimensions through foreign keys (enforced) and keep only the columns
      the report uses (Microsoft data reduction guidance); totals such as price + freight
      are DAX measures, not stored columns.
    - Display values are ready to use: English names, title case, 'Yes' / 'No' flags.
    - SCD Type 1 (no history): customer and seller attributes reflect the latest address.

TABLES:
    Dimensions (6):
        dim_calendar        one row per day (date_key yyyymmdd); mark as date table in Power BI
        dim_customer        one row per person (customer_unique_id)
        dim_seller          one row per seller
        dim_product         one row per product
        dim_order_status    one row per order status, keys follow the order lifecycle
        dim_payment_method  one row per payment type
    Facts (4):
        fact_sales          one row per order item (unit sold)
        fact_delivery       one row per order (logistics)
        fact_reviews        one row per review
        fact_payments       one row per payment

Drops and recreates the tables (facts first, because of the foreign keys).
USAGE:
    Run after the silver scripts, before gold/load_gold.sql.
===============================================================================
*/
USE OlistDW;
GO

-- ============================================================================
-- 0. Helper function: display casing for names
-- 'santa rita do sapucai' -> 'Santa Rita do Sapucai'; 'bed bath table' -> 'Bed Bath Table'.
-- Connectors (de, da, do, das, dos, e, and, of) stay lowercase unless first.
-- ============================================================================
CREATE OR ALTER FUNCTION gold.fn_title_case (@text NVARCHAR(200))
RETURNS NVARCHAR(200)
WITH SCHEMABINDING
AS
BEGIN
    IF @text IS NULL RETURN NULL;

    RETURN (
        SELECT STRING_AGG(
                   CASE
                       WHEN w.ordinal > 1
                            AND w.value IN (N'de', N'da', N'do', N'das', N'dos', N'e', N'and', N'of')
                           THEN w.value
                       ELSE UPPER(LEFT(w.value, 1)) + SUBSTRING(w.value, 2, 200)
                   END, N' ')
               WITHIN GROUP (ORDER BY w.ordinal)
        FROM STRING_SPLIT(LOWER(TRIM(@text)), N' ', 1) AS w
        WHERE w.value <> N''
    );
END;
GO

-- ============================================================================
-- 1. Drop existing tables (facts before dimensions)
-- ============================================================================
DROP TABLE IF EXISTS gold.fact_sales;
DROP TABLE IF EXISTS gold.fact_delivery;
DROP TABLE IF EXISTS gold.fact_reviews;
DROP TABLE IF EXISTS gold.fact_payments;
DROP TABLE IF EXISTS gold.dim_calendar;
DROP TABLE IF EXISTS gold.dim_customer;
DROP TABLE IF EXISTS gold.dim_seller;
DROP TABLE IF EXISTS gold.dim_product;
DROP TABLE IF EXISTS gold.dim_order_status;
DROP TABLE IF EXISTS gold.dim_payment_method;
GO

-- ============================================================================
-- 2. Dimensions
-- ============================================================================

-- ----------------------------------------------------------------------------
-- dim_calendar: one row per day, full years covering the order and review dates.
-- Sort in Power BI: month_name / month_short by [month], day_name by day_of_week.
-- ----------------------------------------------------------------------------
CREATE TABLE gold.dim_calendar (
    date_key     INT          NOT NULL,  
    [date]       DATE         NOT NULL,
    [year]       SMALLINT     NOT NULL,
    [quarter]    TINYINT      NOT NULL,
    year_quarter CHAR(7)      NOT NULL,  
    [month]      TINYINT      NOT NULL,
    month_name   VARCHAR(10)  NOT NULL,  
    month_short  CHAR(3)      NOT NULL,  
    month_start  DATE         NOT NULL, 
    year_month   CHAR(7)      NOT NULL, 
    [day]        TINYINT      NOT NULL,
    day_of_week  TINYINT      NOT NULL,  
    day_name     VARCHAR(10)  NOT NULL,  

    CONSTRAINT pk_dim_calendar PRIMARY KEY (date_key),
    CONSTRAINT uq_dim_calendar_date UNIQUE ([date])
);
GO

-- ----------------------------------------------------------------------------
-- dim_customer: one row per person. Olist creates one customer_id per order; the person is
-- customer_unique_id. SCD1: city/state/coordinates of the person's latest order.
-- ----------------------------------------------------------------------------
CREATE TABLE gold.dim_customer (
    customer_key       INT           NOT NULL,
    customer_unique_id CHAR(32)      NOT NULL,  -- natural key
    customer_city      NVARCHAR(100) NOT NULL,  -- IBGE name (silver.city_map), else title case
    customer_state     CHAR(2)       NOT NULL,
    customer_region    VARCHAR(15)   NOT NULL,  -- North, Northeast, Central-West, Southeast, South
    customer_latitude  DECIMAL(9, 6) NULL,      -- NULL when the zip has no geolocation point
    customer_longitude DECIMAL(9, 6) NULL,

    CONSTRAINT pk_dim_customer PRIMARY KEY (customer_key),
    CONSTRAINT uq_dim_customer_natural UNIQUE (customer_unique_id)
);
GO

-- ----------------------------------------------------------------------------
-- dim_seller: one row per seller.
-- ----------------------------------------------------------------------------
CREATE TABLE gold.dim_seller (
    seller_key       INT           NOT NULL,
    seller_id        CHAR(32)      NOT NULL,  -- natural key
    seller_city      NVARCHAR(100) NOT NULL,  -- IBGE name (silver.city_map), else title case
    seller_state     CHAR(2)       NOT NULL,
    seller_region    VARCHAR(15)   NOT NULL,
    seller_latitude  DECIMAL(9, 6) NULL,
    seller_longitude DECIMAL(9, 6) NULL,

    CONSTRAINT pk_dim_seller PRIMARY KEY (seller_key),
    CONSTRAINT uq_dim_seller_natural UNIQUE (seller_id)
);
GO

-- ----------------------------------------------------------------------------
-- dim_product: one row per product; category in Portuguese (source) and English (display).
-- ----------------------------------------------------------------------------
CREATE TABLE gold.dim_product (
    product_key                   INT           NOT NULL,
    product_id                    CHAR(32)      NOT NULL,  -- natural key
    product_category_name         NVARCHAR(100) NOT NULL,  -- 'sem_categoria' when blank
    product_category_name_english NVARCHAR(100) NOT NULL,  -- 'Bed Bath Table'

    CONSTRAINT pk_dim_product PRIMARY KEY (product_key),
    CONSTRAINT uq_dim_product_natural UNIQUE (product_id)
);
GO

-- ----------------------------------------------------------------------------
-- dim_order_status: keys follow the order lifecycle (also the sort column in Power BI).
-- ----------------------------------------------------------------------------
CREATE TABLE gold.dim_order_status (
    order_status_key  TINYINT     NOT NULL,
    order_status_code VARCHAR(20) NOT NULL,  -- source value, e.g. delivered
    order_status      VARCHAR(20) NOT NULL,  -- display value, e.g. Delivered

    CONSTRAINT pk_dim_order_status PRIMARY KEY (order_status_key),
    CONSTRAINT uq_dim_order_status_natural UNIQUE (order_status_code)
);
GO

-- ----------------------------------------------------------------------------
-- dim_payment_method: one row per payment type.
-- ----------------------------------------------------------------------------
CREATE TABLE gold.dim_payment_method (
    payment_method_key TINYINT     NOT NULL,
    payment_type_code  VARCHAR(20) NOT NULL,  -- source value, e.g. boleto
    payment_type       VARCHAR(20) NOT NULL,  -- display value, e.g. Bank Slip

    CONSTRAINT pk_dim_payment_method PRIMARY KEY (payment_method_key),
    CONSTRAINT uq_dim_payment_method_natural UNIQUE (payment_type_code)
);
GO

-- ============================================================================
-- 3. Facts
-- ============================================================================

-- ----------------------------------------------------------------------------
-- fact_sales: one row per order item (one unit; quantity = number of rows).
-- shipping_limit_date has no calendar FK: 4 items carry 2020 deadlines for 2017 orders
-- (source errors) that fall outside the calendar range.
-- ----------------------------------------------------------------------------
CREATE TABLE gold.fact_sales (
    order_id            CHAR(32)       NOT NULL,  -- degenerate dimension (traceability)
    order_key           INT            NOT NULL,  -- integer order number, for distinct order
                                                  -- counts in Power BI (same in fact_reviews,
                                                  -- fact_payments)
    order_item_id       SMALLINT       NOT NULL,
    customer_key        INT            NOT NULL,
    product_key         INT            NOT NULL,
    seller_key          INT            NOT NULL,
    order_status_key    TINYINT        NOT NULL,
    order_date_key      INT            NOT NULL,
    shipping_limit_date DATE           NOT NULL,
    price               DECIMAL(10, 2) NOT NULL,
    freight_value       DECIMAL(10, 2) NOT NULL,
    is_shipped_late     VARCHAR(3)     NULL,  -- 'Yes' if handed to the carrier after the item's
                                              -- shipping limit; NULL until shipped

    CONSTRAINT pk_fact_sales PRIMARY KEY (order_id, order_item_id),
    CONSTRAINT fk_fact_sales_customer FOREIGN KEY (customer_key) REFERENCES gold.dim_customer (customer_key),
    CONSTRAINT fk_fact_sales_product  FOREIGN KEY (product_key)  REFERENCES gold.dim_product (product_key),
    CONSTRAINT fk_fact_sales_seller   FOREIGN KEY (seller_key)   REFERENCES gold.dim_seller (seller_key),
    CONSTRAINT fk_fact_sales_status   FOREIGN KEY (order_status_key) REFERENCES gold.dim_order_status (order_status_key),
    CONSTRAINT fk_fact_sales_date     FOREIGN KEY (order_date_key) REFERENCES gold.dim_calendar (date_key)
);
GO

-- ----------------------------------------------------------------------------
-- fact_delivery: one row per order. order_date_key is the main date (active relationship);
-- the other date keys are for inactive relationships (USERELATIONSHIP in DAX).
-- Delivery stages in calendar days: approval + seller_handling_days + carrier_transit_days
-- = delivery_days; a stage is NULL when its source dates are out of order.
-- ----------------------------------------------------------------------------
CREATE TABLE gold.fact_delivery (
    order_id                   CHAR(32)       NOT NULL,
    customer_key               INT            NOT NULL,
    order_status_key           TINYINT        NOT NULL,
    order_date_key             INT            NOT NULL,
    approved_date_key          INT            NULL,
    delivered_carrier_date_key INT            NULL,
    delivered_date_key         INT            NULL,
    estimated_delivery_date_key INT           NOT NULL,
    order_purchase_time        TIME(0)        NOT NULL,  -- time of day (date and time split)
    order_purchase_hour        TINYINT        NOT NULL,  -- 0-23, for purchases by hour
    delivery_days              SMALLINT       NULL,      -- purchase -> delivery
    estimated_delivery_days    SMALLINT       NOT NULL,  -- purchase -> estimated delivery
    approval_hours             DECIMAL(10, 2) NULL,
    seller_handling_days       SMALLINT       NULL,      -- approval -> handed to the carrier
    carrier_transit_days       SMALLINT       NULL,      -- carrier -> delivered to the customer
    delivery_delay_days        SMALLINT       NULL,      -- estimated -> delivery (> 0 late, < 0 early)
    is_late                    VARCHAR(3)     NULL,      -- 'Yes' / 'No'; NULL until delivered

    CONSTRAINT pk_fact_delivery PRIMARY KEY (order_id),
    CONSTRAINT fk_fact_delivery_customer  FOREIGN KEY (customer_key) REFERENCES gold.dim_customer (customer_key),
    CONSTRAINT fk_fact_delivery_status    FOREIGN KEY (order_status_key) REFERENCES gold.dim_order_status (order_status_key),
    CONSTRAINT fk_fact_delivery_date      FOREIGN KEY (order_date_key) REFERENCES gold.dim_calendar (date_key),
    CONSTRAINT fk_fact_delivery_approved  FOREIGN KEY (approved_date_key) REFERENCES gold.dim_calendar (date_key),
    CONSTRAINT fk_fact_delivery_carrier   FOREIGN KEY (delivered_carrier_date_key) REFERENCES gold.dim_calendar (date_key),
    CONSTRAINT fk_fact_delivery_delivered FOREIGN KEY (delivered_date_key) REFERENCES gold.dim_calendar (date_key),
    CONSTRAINT fk_fact_delivery_estimated FOREIGN KEY (estimated_delivery_date_key) REFERENCES gold.dim_calendar (date_key)
);
GO

-- ----------------------------------------------------------------------------
-- fact_reviews: one row per review of an order.
-- ----------------------------------------------------------------------------
CREATE TABLE gold.fact_reviews (
    review_id        CHAR(32)    NOT NULL,
    order_id         CHAR(32)    NOT NULL,
    order_key        INT         NOT NULL,  -- same order number as fact_sales
    customer_key     INT         NOT NULL,
    order_status_key TINYINT     NOT NULL,
    order_date_key   INT         NOT NULL,
    review_date_key  INT         NOT NULL,  -- review creation date
    review_score     TINYINT     NOT NULL,
    review_sentiment VARCHAR(10) NOT NULL,  -- Positive / Neutral / Negative
    has_comment      VARCHAR(3)  NOT NULL,  -- 'Yes' / 'No'
    review_answer_hours       DECIMAL(10, 2) NOT NULL,  -- survey sent -> customer answer
    is_review_before_delivery VARCHAR(3)     NOT NULL,  -- 'Yes' if the survey came before the
                                                        -- delivery (or the order never arrived)

    CONSTRAINT pk_fact_reviews PRIMARY KEY (review_id, order_id),
    CONSTRAINT fk_fact_reviews_customer    FOREIGN KEY (customer_key) REFERENCES gold.dim_customer (customer_key),
    CONSTRAINT fk_fact_reviews_status      FOREIGN KEY (order_status_key) REFERENCES gold.dim_order_status (order_status_key),
    CONSTRAINT fk_fact_reviews_order_date  FOREIGN KEY (order_date_key) REFERENCES gold.dim_calendar (date_key),
    CONSTRAINT fk_fact_reviews_review_date FOREIGN KEY (review_date_key) REFERENCES gold.dim_calendar (date_key)
);
GO

-- ----------------------------------------------------------------------------
-- fact_payments: one row per payment of an order.
-- ----------------------------------------------------------------------------
CREATE TABLE gold.fact_payments (
    order_id             CHAR(32)       NOT NULL,
    order_key            INT            NOT NULL,  -- same order number as fact_sales
    payment_sequential   SMALLINT       NOT NULL,
    customer_key         INT            NOT NULL,
    order_status_key     TINYINT        NOT NULL,
    order_date_key       INT            NOT NULL,
    payment_method_key   TINYINT        NOT NULL,
    payment_installments SMALLINT       NOT NULL,  -- 2 rows have 0 in the source (kept)
    payment_value        DECIMAL(10, 2) NOT NULL,

    CONSTRAINT pk_fact_payments PRIMARY KEY (order_id, payment_sequential),
    CONSTRAINT fk_fact_payments_customer FOREIGN KEY (customer_key) REFERENCES gold.dim_customer (customer_key),
    CONSTRAINT fk_fact_payments_status   FOREIGN KEY (order_status_key) REFERENCES gold.dim_order_status (order_status_key),
    CONSTRAINT fk_fact_payments_date     FOREIGN KEY (order_date_key) REFERENCES gold.dim_calendar (date_key),
    CONSTRAINT fk_fact_payments_method   FOREIGN KEY (payment_method_key) REFERENCES gold.dim_payment_method (payment_method_key)
);
GO

-- ============================================================================
-- 4. Indexes on fact join columns
-- ============================================================================
CREATE INDEX ix_fact_sales_customer   ON gold.fact_sales (customer_key);
CREATE INDEX ix_fact_sales_product    ON gold.fact_sales (product_key);
CREATE INDEX ix_fact_sales_seller     ON gold.fact_sales (seller_key);
CREATE INDEX ix_fact_sales_date       ON gold.fact_sales (order_date_key);
CREATE INDEX ix_fact_delivery_customer ON gold.fact_delivery (customer_key);
CREATE INDEX ix_fact_delivery_date     ON gold.fact_delivery (order_date_key);
CREATE INDEX ix_fact_reviews_customer  ON gold.fact_reviews (customer_key);
CREATE INDEX ix_fact_reviews_date      ON gold.fact_reviews (review_date_key);
CREATE INDEX ix_fact_payments_customer ON gold.fact_payments (customer_key);
CREATE INDEX ix_fact_payments_date     ON gold.fact_payments (order_date_key);
GO

PRINT '============================================================';
PRINT 'DEPLOYMENT SUMMARY:';
PRINT '  Schema      : gold';
PRINT '  Dimensions  : 6 (calendar, customer, seller, product, order_status, payment_method)';
PRINT '  Facts       : 4 (sales, delivery, reviews, payments)';
PRINT '  Constraints : PRIMARY KEY, UNIQUE, FOREIGN KEY';
PRINT '  Status      : SUCCESS';
PRINT '============================================================';
GO
