/* =============================================================================
   05_views.sql
   The ten business indicators requested by the statement, one view each.
   Averages and percentages are computed as SUM(numerator) / SUM(denominator)
   over additive fact measures. "Top N" views rank with ROW_NUMBER() and a
   deterministic tie-breaker instead of TOP ... ORDER BY inside a view (SQL
   Server does not guarantee the order of rows returned by a view).
   ============================================================================= */
USE GD2C2024;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- 1. Average listing duration (days) per subcategory, four-month period and year.
CREATE OR ALTER VIEW CHIRIPIORCA.BI_vw_AvgListingDurationBySubcategory
AS
SELECT t.calendar_year,
       t.four_month_period,
       s.category_name,
       s.subcategory_name,
       CAST(1.0 * SUM(f.total_active_days) / SUM(f.listing_count) AS DECIMAL(18, 2)) AS avg_active_days
FROM CHIRIPIORCA.BI_FactListing AS f
JOIN CHIRIPIORCA.BI_DimTime AS t
  ON t.time_key = f.time_key
JOIN CHIRIPIORCA.BI_DimSubcategory AS s
  ON s.subcategory_key = f.subcategory_key
GROUP BY t.calendar_year, t.four_month_period, s.category_name, s.subcategory_name;
GO

-- 2. Average initial stock per brand and year.
CREATE OR ALTER VIEW CHIRIPIORCA.BI_vw_AvgInitialStockByBrand
AS
SELECT t.calendar_year,
       b.brand_name,
       CAST(1.0 * SUM(f.total_initial_stock) / SUM(f.listing_count) AS DECIMAL(18, 2)) AS avg_initial_stock
FROM CHIRIPIORCA.BI_FactListing AS f
JOIN CHIRIPIORCA.BI_DimTime AS t
  ON t.time_key = f.time_key
JOIN CHIRIPIORCA.BI_DimBrand AS b
  ON b.brand_key = f.brand_key
GROUP BY t.calendar_year, b.brand_name;
GO

-- 3. Average sale amount per warehouse province, month and year.
CREATE OR ALTER VIEW CHIRIPIORCA.BI_vw_AvgMonthlySaleByWarehouseProvince
AS
SELECT t.calendar_year,
       t.calendar_month,
       l.province_name AS warehouse_province,
       CAST(SUM(f.sales_amount) / SUM(f.sale_count) AS DECIMAL(18, 2)) AS avg_sale_amount
FROM CHIRIPIORCA.BI_FactSale AS f
JOIN CHIRIPIORCA.BI_DimTime AS t
  ON t.time_key = f.time_key
JOIN CHIRIPIORCA.BI_DimLocation AS l
  ON l.location_key = f.warehouse_location_key
GROUP BY t.calendar_year, t.calendar_month, l.province_name;
GO

-- 4. Top 5 categories by sales amount per four-month period, year, customer city and age range.
CREATE OR ALTER VIEW CHIRIPIORCA.BI_vw_TopCategoriesByCityAndAgeRange
AS
WITH category_sales AS (
    SELECT t.calendar_year,
           t.four_month_period,
           l.province_name,
           l.city_name,
           f.customer_location_key,
           ar.range_label AS age_range,
           s.category_name,
           SUM(f.sales_amount) AS sales_amount
    FROM CHIRIPIORCA.BI_FactSale AS f
    JOIN CHIRIPIORCA.BI_DimTime AS t
      ON t.time_key = f.time_key
    JOIN CHIRIPIORCA.BI_DimLocation AS l
      ON l.location_key = f.customer_location_key
    JOIN CHIRIPIORCA.BI_DimAgeRange AS ar
      ON ar.age_range_key = f.age_range_key
    JOIN CHIRIPIORCA.BI_DimSubcategory AS s
      ON s.subcategory_key = f.subcategory_key
    GROUP BY t.calendar_year, t.four_month_period, l.province_name, l.city_name,
             f.customer_location_key, ar.range_label, s.category_name
),
ranked AS (
    SELECT cs.*,
           ROW_NUMBER() OVER (PARTITION BY cs.calendar_year, cs.four_month_period,
                                           cs.customer_location_key, cs.age_range
                              ORDER BY cs.sales_amount DESC, cs.category_name) AS category_rank
    FROM category_sales AS cs
)
SELECT calendar_year, four_month_period, province_name, city_name, age_range,
       category_rank, category_name, sales_amount
FROM ranked
WHERE category_rank <= 5;
GO

-- 5. Number of sales per time-of-day range, month and year.
CREATE OR ALTER VIEW CHIRIPIORCA.BI_vw_SalesVolumeByTimeRange
AS
SELECT t.calendar_year,
       t.calendar_month,
       tr.range_label AS time_range,
       SUM(f.sale_count) AS sale_count
FROM CHIRIPIORCA.BI_FactSale AS f
JOIN CHIRIPIORCA.BI_DimTime AS t
  ON t.time_key = f.time_key
JOIN CHIRIPIORCA.BI_DimTimeRange AS tr
  ON tr.time_range_key = f.time_range_key
GROUP BY t.calendar_year, t.calendar_month, tr.range_label;
GO

-- 6. Top 3 customer cities by amount paid in installments, per payment type, month and year.
CREATE OR ALTER VIEW CHIRIPIORCA.BI_vw_TopInstallmentCitiesByPaymentType
AS
WITH city_installments AS (
    SELECT t.calendar_year,
           t.calendar_month,
           pt.type_name AS payment_type,
           l.province_name,
           l.city_name,
           SUM(f.installment_amount) AS installment_amount
    FROM CHIRIPIORCA.BI_FactPayment AS f
    JOIN CHIRIPIORCA.BI_DimTime AS t
      ON t.time_key = f.time_key
    JOIN CHIRIPIORCA.BI_DimPaymentType AS pt
      ON pt.payment_type_key = f.payment_type_key
    JOIN CHIRIPIORCA.BI_DimLocation AS l
      ON l.location_key = f.customer_location_key
    WHERE f.installment_amount > 0
    GROUP BY t.calendar_year, t.calendar_month, pt.type_name, l.province_name, l.city_name
),
ranked AS (
    SELECT ci.*,
           ROW_NUMBER() OVER (PARTITION BY ci.calendar_year, ci.calendar_month, ci.payment_type
                              ORDER BY ci.installment_amount DESC, ci.province_name, ci.city_name) AS city_rank
    FROM city_installments AS ci
)
SELECT calendar_year, calendar_month, payment_type, city_rank, province_name, city_name, installment_amount
FROM ranked
WHERE city_rank <= 3;
GO

-- 7. Percentage of shipments delivered on time per warehouse province, month and year.
CREATE OR ALTER VIEW CHIRIPIORCA.BI_vw_ShipmentOnTimeRateByWarehouseProvince
AS
SELECT t.calendar_year,
       t.calendar_month,
       l.province_name AS warehouse_province,
       SUM(f.shipment_count) AS shipment_count,
       SUM(f.on_time_count)  AS on_time_count,
       CAST(100.0 * SUM(f.on_time_count) / SUM(f.shipment_count) AS DECIMAL(5, 2)) AS on_time_percentage
FROM CHIRIPIORCA.BI_FactShipment AS f
JOIN CHIRIPIORCA.BI_DimTime AS t
  ON t.time_key = f.time_key
JOIN CHIRIPIORCA.BI_DimLocation AS l
  ON l.location_key = f.warehouse_location_key
GROUP BY t.calendar_year, t.calendar_month, l.province_name;
GO

-- 8. Top 5 customer cities by total shipping cost paid.
CREATE OR ALTER VIEW CHIRIPIORCA.BI_vw_TopCitiesByShippingCost
AS
WITH city_cost AS (
    SELECT l.province_name,
           l.city_name,
           SUM(f.total_shipping_cost) AS total_shipping_cost,
           SUM(f.shipment_count)      AS shipment_count
    FROM CHIRIPIORCA.BI_FactShipment AS f
    JOIN CHIRIPIORCA.BI_DimLocation AS l
      ON l.location_key = f.customer_location_key
    GROUP BY l.province_name, l.city_name
),
ranked AS (
    SELECT cc.*,
           ROW_NUMBER() OVER (ORDER BY cc.total_shipping_cost DESC, cc.province_name, cc.city_name) AS city_rank
    FROM city_cost AS cc
)
SELECT city_rank, province_name, city_name, total_shipping_cost, shipment_count
FROM ranked
WHERE city_rank <= 5;
GO

-- 9. Share of each invoice concept in the amount invoiced per month and year.
--    The period total comes from a window function over the already grouped
--    rows, instead of a correlated subquery re-scanning the fact per group.
CREATE OR ALTER VIEW CHIRIPIORCA.BI_vw_InvoicedPercentageByConcept
AS
WITH concept_totals AS (
    SELECT t.calendar_year,
           t.calendar_month,
           c.concept_name,
           SUM(f.invoiced_amount) AS invoiced_amount
    FROM CHIRIPIORCA.BI_FactInvoice AS f
    JOIN CHIRIPIORCA.BI_DimTime AS t
      ON t.time_key = f.time_key
    JOIN CHIRIPIORCA.BI_DimInvoiceConcept AS c
      ON c.invoice_concept_key = f.invoice_concept_key
    GROUP BY t.calendar_year, t.calendar_month, c.concept_name
)
SELECT calendar_year,
       calendar_month,
       concept_name,
       invoiced_amount,
       CAST(100.0 * invoiced_amount
            / SUM(invoiced_amount) OVER (PARTITION BY calendar_year, calendar_month) AS DECIMAL(5, 2)) AS invoiced_percentage
FROM concept_totals;
GO

-- 10. Amount invoiced per seller province, four-month period and year.
CREATE OR ALTER VIEW CHIRIPIORCA.BI_vw_InvoicedAmountBySellerProvince
AS
SELECT t.calendar_year,
       t.four_month_period,
       l.province_name AS seller_province,
       SUM(f.invoiced_amount) AS invoiced_amount
FROM CHIRIPIORCA.BI_FactInvoice AS f
JOIN CHIRIPIORCA.BI_DimTime AS t
  ON t.time_key = f.time_key
JOIN CHIRIPIORCA.BI_DimLocation AS l
  ON l.location_key = f.seller_location_key
GROUP BY t.calendar_year, t.four_month_period, l.province_name;
GO
