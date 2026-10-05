/*
===============================================================================
DDL Script: Power BI views (dw)
===============================================================================
PURPOSE:
    One view per Power BI table, over gold. Only the columns the report uses;
    renames for display. No business logic here (it lives in gold).
VIEWS:
    Dimensions: dim_calendar, dim_customer, dim_seller, dim_product, ...
    Facts:      fact_sales, fact_delivery, fact_reviews, fact_payments
USAGE:
    Run after gold/ddl_gold_tables.sql. Idempotent (CREATE OR ALTER).
===============================================================================
*/

USE OlistDW;
GO

IF SCHEMA_ID(N'dw') IS NULL EXEC (N'CREATE SCHEMA dw');
GO

-- ============================================================================
-- 1. Dimensions
-- ============================================================================
CREATE OR ALTER VIEW dw.dim_product AS
SELECT
	dp.product_key,
	dp.product_category_name_english AS category
FROM gold.dim_product dp;
GO

CREATE OR ALTER VIEW dw.dim_customer AS
SELECT
	dc.customer_key,
	dc.customer_city,
	dc.customer_state,
	dc.customer_region
FROM gold.dim_customer dc;
GO

CREATE OR ALTER VIEW dw.dim_order_status AS
SELECT
	dos.order_status_key,
	dos.order_status
FROM gold.dim_order_status dos;
GO

CREATE OR ALTER VIEW dw.dim_payment_method AS
SELECT 
	dpm.payment_method_key,
	dpm.payment_type
FROM gold.dim_payment_method dpm;
GO

CREATE OR ALTER VIEW dw.dim_seller AS
SELECT
	ds.seller_key,
	ds.seller_city,
	ds.seller_state,
	ds.seller_region
FROM gold.dim_seller ds;
GO

CREATE OR ALTER VIEW dw.dim_calendar AS
SELECT
	dc.date_key,
	dc.date,
	dc.year,
	dc.quarter,
	dc.year_quarter,
	dc.month,
	dc.month_short,
	dc.month_start,
	dc.year_month,
	dc.day,
	dc.day_of_week,
	dc.day_name
FROM gold.dim_calendar dc;
GO

-- ============================================================================
-- 2. Facts
-- ============================================================================
CREATE OR ALTER VIEW dw.fact_payments AS
SELECT 
	fp.order_key,
	fp.customer_key,
	fp.order_status_key,
	fp.order_date_key,
	fp.payment_method_key,
	fp.payment_sequential,
	fp.payment_installments,
	fp.payment_value
FROM gold.fact_payments fp;
GO

CREATE OR ALTER VIEW dw.fact_delivery AS
SELECT 
	fd.customer_key,
	fd.order_status_key,
	fd.order_date_key,
	fd.delivered_date_key,
	fd.order_purchase_hour,
	fd.delivery_days,
	fd.estimated_delivery_days,
	fd.approval_hours,
	fd.seller_handling_days,
	fd.carrier_transit_days,
	fd.delivery_delay_days,
	fd.is_late
FROM gold.fact_delivery fd;
GO

CREATE OR ALTER VIEW dw.fact_reviews AS
SELECT 
	fr.order_key,
	fr.order_date_key,
	fr.order_status_key,
	fr.customer_key,
	fr.review_date_key,
	fr.review_score,
	fr.has_comment,
	fr.review_answer_hours,
	fr.is_review_before_delivery
FROM gold.fact_reviews fr;
GO
	
CREATE OR ALTER VIEW dw.fact_sales AS
SELECT 
	fs.order_key,
	fs.order_date_key,
	fs.customer_key,
	fs.product_key,
	fs.seller_key,
	fs.order_status_key,
	fs.price,
	fs.freight_value,
	fs.is_shipped_late
FROM gold.fact_sales fs;
GO


