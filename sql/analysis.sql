/*
===============================================================================
Analysis Script: fact_sales (dw)
===============================================================================
PURPOSE:
    Exploratory analysis of the numeric measures in the dw fact views.
    Read-only: no objects are created or modified.
ANALYSES:
    1. Descriptive statistics: min, max, mean, median, stdev, percentiles.
    2. Pareto / ABC curve: concentration of a measure by dimension member.
    3. Percentiles: P10-P99 distribution, IQR (P25-P75) and tail length (P99 vs P90).
    4. Outliers: IQR rule on each numeric measure.
    5. Correlation: Pearson coefficient between pairs of measures.
NOTES:
    Check each fact's grain before aggregating (e.g. fact_sales is one row
    per order item); use COUNT(DISTINCT order_key) for order counts.
USAGE:
    Run after sql/dw/ddl_dw_views.sql.
===============================================================================
*/

-- ==========================================================
-- VIEW: dw.fact_sales
-- ==========================================================

-- Check MAX and MIN dates by year
SELECT
	dc.year AS order_year,
	MIN(dc.date) AS min_order_date,
	MAX(dc.date) AS max_order_date
FROM dw.fact_sales AS fs
LEFT JOIN dw.dim_calendar AS dc
	ON dc.date_key = fs.order_date_key
GROUP BY dc.year
ORDER BY order_year;
-- 2016 (from Sep 4) and 2018 (until Sep 3) are partial years; avoid direct YoY comparisons

/*
-------------------------------------------------------------------------------
1. Descriptive statistics: price
-------------------------------------------------------------------------------
How to read:
    - mean > median means a right-skewed distribution: few expensive items
      pull the mean up. Median is the better "typical price".
    - median means that half of the items cost at or below this; typical price
    - stdev is in R$. mean - stdev < 0 confirms the data is not normal, so
      the "68% within 1 stdev" rule does not apply; use percentiles instead.
    - CV (stdev / mean) > 1 means very high dispersion.
Result:
    Median R$ 74.99, mean R$ 120.65, stdev R$ 183.63, CV 1.52.
Takeaway:
    Sales are dominated by low-priced items: the mean is ~1.6x the median and CV 1.52 shows high dispersion. 
    Report the median as the typical price in dashboards and keep the mean only for revenue calculations.
*/

WITH percentiles AS (
	SELECT DISTINCT
		PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fs.price) OVER() AS price_median
	FROM dw.fact_sales AS fs
)
SELECT
	COUNT(*) AS items,
	MIN(fs.price) AS price_min, 
	MAX(fs.price) AS price_max,
	FORMAT(AVG(fs.price), 'N2', 'pt-BR') AS price_avg, 
	ROUND(STDEV(fs.price), 2) AS price_stdev, 
	MAX(p.price_median) AS max_price_median, 
	ROUND(STDEV(fs.price) / AVG(fs.price), 2) AS price_cv,
    ROUND(AVG(fs.price) - STDEV(fs.price), 2) AS mean_minus_stdv
FROM dw.fact_sales AS fs
CROSS JOIN percentiles AS p;

/*
-------------------------------------------------------------------------------
2. Pareto / ABC curve: revenue by seller
-------------------------------------------------------------------------------
How to read:
    - Class A: sellers that accumulate the first 80% of revenue; B: 80-95%; C: last 5%.
    - Compare seller_share with revenue_share: the bigger the gap, the more
      concentrated the revenue.
Result:
    A: ~18% of sellers, 80% of revenue.
    B: ~24% of sellers, 15% of revenue.
    C: ~58% of sellers, 5% of revenue.
    An average class A seller sells ~52x more than a class C seller.
Takeaway:
    Revenue is concentrated, close to the 80/20 rule: class A (~18% of sellers) drives 80% of revenue.
    Total revenue depends mostly on class A performance. 
    Class C is a long tail of small sellers (~58% of the base, only 5% of revenue).
*/

WITH sellers AS (
    SELECT
        fs.seller_key,
        SUM(fs.price) AS revenue
    FROM dw.fact_sales AS fs
    GROUP BY fs.seller_key
),
cumulative AS (
    SELECT
        s.seller_key,
        s.revenue,
        SUM(s.revenue) OVER (ORDER BY s.revenue DESC, s.seller_key ROWS UNBOUNDED PRECEDING)
            / SUM(s.revenue) OVER () AS cumulative_share
    FROM sellers AS s
),
classified AS (
    SELECT
        c.seller_key,
        c.revenue,
        CASE
            WHEN c.cumulative_share <= 0.80 THEN 'A'
            WHEN c.cumulative_share <= 0.95 THEN 'B'
            ELSE 'C'
        END AS abc_class
    FROM cumulative AS c
)
SELECT
    cl.abc_class,
    COUNT(*) AS sellers,
    CAST(COUNT(*) AS FLOAT) / SUM(COUNT(*)) OVER () AS seller_share,
    SUM(cl.revenue) AS revenue,
    SUM(cl.revenue) / SUM(SUM(cl.revenue)) OVER () AS revenue_share,
    AVG(cl.revenue) AS avg_revenue_per_seller
FROM classified AS cl
GROUP BY cl.abc_class
ORDER BY cl.abc_class;

/*
-------------------------------------------------------------------------------
3. Percentiles: price (P10-P99)
-------------------------------------------------------------------------------
How to read:
    - Pn: n% of the items cost at or below this value; P50 is the median.
    - IQR (P25-P75): price range of the middle 50% of items; not affected
      by extreme prices.
    - P99 / P90 ratio: the higher it is, the longer the right tail.
Result:
    50% of items cost between R$ 39.90 and R$ 134.90.
    P99 (R$ 890) is ~4x P90 (R$ 229.80): long right tail driven by a few expensive items.
Takeaway:
    The typical item costs ~R$ 40-135; 
    The mean (R$ 120.65) is close to P75, so ~70% of items cost less than the mean. 
    The top 10% spans a wide range (~R$ 230-890+), which is why the mean is well above the median.
*/

SELECT DISTINCT
    PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY fs.price) OVER () AS p10, 
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY fs.price) OVER () AS p25, 
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY fs.price) OVER () AS p50, 
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY fs.price) OVER () AS p75, 
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY fs.price) OVER () AS p90, 
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY fs.price) OVER () AS p99  
FROM dw.fact_sales AS fs;


/*
-------------------------------------------------------------------------------
4. Outliers: price (IQR rule)
-------------------------------------------------------------------------------
How to read:
    - Outlier: price > Q3 + 1.5 * IQR or price < Q1 - 1.5 * IQR.
    - lower_fence is usually negative for price, so lower_outliers = 0
      is expected, not an error.
    - outlier_revenue_share shows how much revenue depends on outliers.
Result:
    Upper fence R$ 227.40; ~7.5% of items are outliers and generate ~36% of revenue.
    Lower fence is negative, so all outliers are high-price items.
Takeaway:
    Revenue depends heavily on a few high-ticket items, so keep them in all revenue metrics. 
    Use the median as the typical price instead of removing outliers.
*/

WITH quartiles AS (
    SELECT DISTINCT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY fs.price) OVER () AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY fs.price) OVER () AS q3
    FROM dw.fact_sales AS fs
),
fences AS (
    SELECT
        q.q1,
        q.q3,
        q.q1 - 1.5 * (q.q3 - q.q1) AS lower_fence,
        q.q3 + 1.5 * (q.q3 - q.q1) AS upper_fence
    FROM quartiles AS q
)
SELECT
    f.lower_fence,
    f.upper_fence,
    COUNT(*) AS total_items,
    SUM(CASE WHEN fs.price > f.upper_fence THEN 1 ELSE 0 END) AS upper_outliers,
    SUM(CASE WHEN fs.price < f.lower_fence THEN 1 ELSE 0 END) AS lower_outliers,
    AVG(CASE WHEN fs.price > f.upper_fence OR fs.price < f.lower_fence
             THEN 1.0 ELSE 0.0 END) AS outlier_share, 
    SUM(CASE WHEN fs.price > f.upper_fence OR fs.price < f.lower_fence
             THEN fs.price ELSE 0 END) / SUM(fs.price) AS outlier_revenue_share 
FROM dw.fact_sales AS fs
CROSS JOIN fences AS f
GROUP BY f.lower_fence, f.upper_fence;

/*
-------------------------------------------------------------------------------
5. Correlation: price vs installments (Pearson)
-------------------------------------------------------------------------------
How to read:
    - Grain is the order: price is SUM(price) per order and installments is
      MAX(payment_installments) per order (an order can have several payments).
    - r ranges from -1 to 1: |r| < 0.3 weak, 0.3-0.7 moderate, > 0.7 strong.
      Positive r means more expensive orders are paid in more installments.
    - Pearson is sensitive to outliers (~7.5% of items are high-price
      outliers) and does not imply causation.
Result:
    r = ~0.31 over 98,665 orders.
Takeaway:
    Moderate positive relationship: more expensive orders tend to be paid in more installments.
    The price explains only ~10% of the variation (r² ~0.10). 
    It does not show that installments cause higher-ticket purchases.
*/

WITH order_price AS (
    SELECT
        fs.order_key,
        SUM(fs.price) AS order_price
    FROM dw.fact_sales AS fs
    GROUP BY fs.order_key
),
order_installments AS (
    SELECT
        fp.order_key,
        MAX(fp.payment_installments) AS installments
    FROM dw.fact_payments AS fp
    GROUP BY fp.order_key
),
pearson AS (
    SELECT
        COUNT(*) AS orders,
        (COUNT(*) * SUM(v.x * v.y) - SUM(v.x) * SUM(v.y))
        / NULLIF(
            SQRT(COUNT(*) * SUM(v.x * v.x) - SUM(v.x) * SUM(v.x))
            * SQRT(COUNT(*) * SUM(v.y * v.y) - SUM(v.y) * SUM(v.y)),
            0
        ) AS r
    FROM order_price AS op
    INNER JOIN order_installments AS oi
        ON oi.order_key = op.order_key
    CROSS APPLY (
        SELECT CAST(op.order_price AS FLOAT) AS x, CAST(oi.installments AS FLOAT) AS y
    ) AS v
)
SELECT
    p.orders,
    ROUND(p.r, 2) AS pearson_price_installments,
    ROUND(SQUARE(p.r), 2) AS r_squared
FROM pearson AS p;


/*
-------------------------------------------------------------------------------
1. Descriptive statistics: freight
-------------------------------------------------------------------------------
How to read:
    - mean > median means a right-skewed distribution: few expensive items
      pull the mean up. Median is the better "typical freight".
    - median means that half of the freight at or below this; typical freight
    - stdev is in R$. mean - stdev > 0 does not confirm the data is normal, so
      the "68% within 1 stdev" rule does not apply; use percentiles instead.
    - CV (stdev / mean) between 0.3 and 1 means medium dispersion.
Result:
    Median R$ 16.26, mean R$ 19.99, stdev R$ 15.81, CV 0.79.
Takeaway:
    Freight is less skewed than price: the mean is ~1.2x the median and CV 0.79 shows medium dispersion. 
    A few expensive shipments still pull the mean up, so report the median as the typical freight in dashboards.
    Keep the mean only for total freight cost calculations.
*/
WITH percentiles AS (
	SELECT DISTINCT
		PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fs.freight_value) OVER() AS freight_median
	FROM dw.fact_sales AS fs
)
SELECT
	COUNT(*) AS items,
	MIN(fs.freight_value) AS freight_min, 
	MAX(fs.freight_value) AS freight_max, 
	FORMAT(AVG(fs.freight_value), 'N2', 'pt-BR') AS freight_avg, 
	ROUND(STDEV(fs.freight_value), 2) AS freight_stdev, 
	MAX(p.freight_median) AS max_freight_median, 
	ROUND(STDEV(fs.freight_value) / AVG(fs.freight_value), 2) AS freight_cv, 
    ROUND(AVG(fs.freight_value) - STDEV(fs.freight_value), 2) AS mean_minus_stdv
FROM dw.fact_sales AS fs
CROSS JOIN percentiles AS p;

/*
-------------------------------------------------------------------------------
2. Pareto / ABC curve: freight by states
-------------------------------------------------------------------------------
How to read:
    - Class A: states that accumulate the first 80% of freight; B: 80-95%; C: last 5%.
    - Compare item_share with freight_share: if a class pays a larger share
      of freight than its share of items, its shipments are more expensive
      (distance effect).
    - avg_freight_per_item: average freight per item in each class.
Result:
    A: 8 states, ~86% of items, ~80% of freight, R$ 18.55 per item.
    B: 8 states, ~11% of items, ~15% of freight, R$ 27.22 per item.
    C: 11 states, ~3% of items, ~5% of freight, R$ 34.20 per item.
Takeaway:
    Freight is concentrated in 8 of 27 states (class A: South, Southeast and
    the largest Northeast states), driven by volume: they receive ~86% of
    items but pay only ~80% of freight, at the lowest freight per item (R$ 18.55).
    Distance raises the cost per shipment: class C states (mostly North and
    Northeast) pay ~1.8x more freight per item than class A, and class B ~1.5x more.
*/

WITH states AS (
    SELECT
        dc.customer_state,
        COUNT(*) AS items,
        SUM(fs.freight_value) AS freight
    FROM dw.fact_sales AS fs
    INNER JOIN dw.dim_customer AS dc
        ON dc.customer_key = fs.customer_key
    GROUP BY dc.customer_state
),
cumulative AS (
    SELECT
        s.customer_state,
        s.items,
        s.freight,
        SUM(s.freight) OVER (ORDER BY s.freight DESC, s.customer_state ROWS UNBOUNDED PRECEDING)
            / SUM(s.freight) OVER () AS cumulative_share
    FROM states AS s
),
classified AS (
    SELECT
        c.customer_state,
        c.items,
        c.freight,
        CASE
            WHEN c.cumulative_share <= 0.80 THEN 'A'
            WHEN c.cumulative_share <= 0.95 THEN 'B'
            ELSE 'C'
        END AS abc_class
    FROM cumulative AS c
)
SELECT
    cl.abc_class,
    COUNT(*) AS states,
    STRING_AGG(cl.customer_state, ', ') WITHIN GROUP (ORDER BY cl.freight DESC) AS state_list,
    CAST(SUM(cl.items) AS FLOAT) / SUM(SUM(cl.items)) OVER () AS item_share,
    SUM(cl.freight) / SUM(SUM(cl.freight)) OVER () AS freight_share,
    SUM(cl.freight) / SUM(cl.items) AS avg_freight_per_item
FROM classified AS cl
GROUP BY cl.abc_class
ORDER BY cl.abc_class;

/*
-------------------------------------------------------------------------------
3. Percentiles: freight (P10-P99)
-------------------------------------------------------------------------------
How to read:
    - Pn: n% of the items have freight at or below this value; P50 is the
      median.
    - IQR (P25-P75): freight range of the middle 50% of items; not affected
      by extreme freight.
    - P99 / P90 ratio: the higher it is, the longer the right tail.
Result:
    50% of items have freight between R$ 13.08 and R$ 21.15.
    P99 (R$ 84.52) is ~2.5x P90 (R$ 34.04): long right tail driven by a few
    expensive shipments.
Takeaway:
    The typical item has freight of ~R$ 13-21; 
    The mean (R$ 19.99) is close to P75, so ~70% of items pay less than the mean freight.
    The top 10% spans ~R$ 34-85+, a shorter tail than price (P99/P90 ~2.5x
    vs ~4x), which is why the mean is only slightly above the median.
*/

SELECT DISTINCT
    PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY fs.freight_value) OVER () AS p10,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY fs.freight_value) OVER () AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY fs.freight_value) OVER () AS p50,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY fs.freight_value) OVER () AS p75,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY fs.freight_value) OVER () AS p90,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY fs.freight_value) OVER () AS p99
FROM dw.fact_sales AS fs;

/*
-------------------------------------------------------------------------------
4. Outliers: freight (IQR rule)
-------------------------------------------------------------------------------
How to read:
    - Outlier: freight > Q3 + 1.5 * IQR or freight < Q1 - 1.5 * IQR.
    - lower_fence is positive for freight, so low outliers are possible:
      items with near-zero freight (likely free shipping).
    - outlier_freight_share shows how much of the total freight comes from
      outliers.
Result:
    Upper fence R$ 33.26, lower fence R$ 0.98; ~10.8% of items are outliers
    and account for ~28% of total freight.
    Most outliers are high-freight items (11,613 high vs 521 low).
Takeaway:
    A few expensive shipments account for ~28% of total
    freight, so keep them in freight cost metrics and use the median as the
    typical freight instead of removing outliers.
    Low outliers (~0.5% of items) have near-zero freight, likely free
    shipping rather than data errors.
*/

WITH quartiles AS (
    SELECT DISTINCT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY fs.freight_value) OVER () AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY fs.freight_value) OVER () AS q3
    FROM dw.fact_sales AS fs
),
fences AS (
    SELECT
        q.q1,
        q.q3,
        q.q1 - 1.5 * (q.q3 - q.q1) AS lower_fence,
        q.q3 + 1.5 * (q.q3 - q.q1) AS upper_fence
    FROM quartiles AS q
)
SELECT
    f.lower_fence,
    f.upper_fence,
    COUNT(*) AS total_items,
    SUM(CASE WHEN fs.freight_value > f.upper_fence THEN 1 ELSE 0 END) AS upper_outliers,
    SUM(CASE WHEN fs.freight_value < f.lower_fence THEN 1 ELSE 0 END) AS lower_outliers,
    AVG(CASE WHEN fs.freight_value > f.upper_fence OR fs.freight_value < f.lower_fence
             THEN 1.0 ELSE 0.0 END) AS outlier_share, 
    SUM(CASE WHEN fs.freight_value > f.upper_fence OR fs.freight_value < f.lower_fence
             THEN fs.freight_value ELSE 0 END) / SUM(fs.freight_value) AS outlier_freight_share,
    CAST(SUM(CASE WHEN fs.freight_value < f.lower_fence THEN 1 ELSE 0 END) AS FLOAT)
    / COUNT(*) AS lower_outlier_share
FROM dw.fact_sales AS fs
CROSS JOIN fences AS f
GROUP BY f.lower_fence, f.upper_fence;

/*
-------------------------------------------------------------------------------
5. Correlation: freight vs distance (Pearson)
-------------------------------------------------------------------------------
How to read:
    - Grain is the order item: freight is freight_value per item and distance
      is the straight-line (Haversine) distance in km between seller and
      customer zip codes.
    - r ranges from -1 to 1: |r| < 0.3 weak, 0.3-0.7 moderate, > 0.7 strong.
      Positive r means items shipped farther pay more freight.
    - Pearson is sensitive to outliers (~10.8% of items are freight
      outliers) and does not imply causation.
Result:
    r = ~0.39 over 112,098 items (552 items without geolocation excluded).
Takeaway:
    Moderate positive relationship: items shipped farther tend to pay more freight. 
    Distance explains ~15% of the freight variation (r² ~0.15).
    The rest likely comes from weight and volume, which are not available in the model.
*/

WITH items AS (
    SELECT
        CAST(fs.freight_value AS FLOAT) AS freight,
        -- Haversine distance in km between seller and customer
        6371 * 2 * ASIN(SQRT(
            SQUARE(SIN(RADIANS(dc.customer_latitude - ds.seller_latitude) / 2))
            + COS(RADIANS(ds.seller_latitude)) * COS(RADIANS(dc.customer_latitude))
            * SQUARE(SIN(RADIANS(dc.customer_longitude - ds.seller_longitude) / 2))
        )) AS distance_km
    FROM dw.fact_sales AS fs
    INNER JOIN dw.dim_seller AS ds
        ON ds.seller_key = fs.seller_key
    INNER JOIN dw.dim_customer AS dc
        ON dc.customer_key = fs.customer_key
    WHERE ds.seller_latitude IS NOT NULL  
      AND dc.customer_latitude IS NOT NULL
),
pearson AS (
    SELECT
        COUNT(*) AS items,
        (COUNT(*) * SUM(i.distance_km * i.freight) - SUM(i.distance_km) * SUM(i.freight))
        / NULLIF(
            SQRT(COUNT(*) * SUM(i.distance_km * i.distance_km) - SUM(i.distance_km) * SUM(i.distance_km))
            * SQRT(COUNT(*) * SUM(i.freight * i.freight) - SUM(i.freight) * SUM(i.freight)),
            0
        ) AS r
    FROM items AS i
)
SELECT
    p.items,
    ROUND(p.r, 2) AS pearson_freight_distance,
    ROUND(SQUARE(p.r), 2) AS r_squared
FROM pearson AS p;

