/* =============================================================================
   verify_bi.sql
   Post-load checks for the star schema. Run after script_creacion_BI.sql.
   Facts must reconcile with the transactional model (nothing lost or counted
   twice), and key results are compared with values profiled from the source.
   ============================================================================= */
USE GD2C2024;
GO

SET NOCOUNT ON;

DECLARE @checks TABLE (
    check_name  NVARCHAR(100)  NOT NULL,
    expected    DECIMAL(18, 2) NOT NULL,
    actual      DECIMAL(18, 2) NULL
);

/* ---- Dimensions ---- */
INSERT INTO @checks (check_name, expected, actual)
VALUES (N'BI_DimTime months (2025-01 .. 2027-01)', 25,    (SELECT COUNT(*) FROM CHIRIPIORCA.BI_DimTime)),
       (N'BI_DimLocation rows = City rows',        16918, (SELECT COUNT(*) FROM CHIRIPIORCA.BI_DimLocation)),
       (N'BI_DimSubcategory rows',                 815,   (SELECT COUNT(*) FROM CHIRIPIORCA.BI_DimSubcategory)),
       (N'BI_DimAgeRange rows',                    4,     (SELECT COUNT(*) FROM CHIRIPIORCA.BI_DimAgeRange)),
       (N'BI_DimTimeRange rows',                   4,     (SELECT COUNT(*) FROM CHIRIPIORCA.BI_DimTimeRange));

/* ---- Facts reconcile with the transactional model ---- */
INSERT INTO @checks (check_name, expected, actual)
SELECT N'FactListing listing_count = Listing rows',
       (SELECT COUNT(*) FROM CHIRIPIORCA.Listing),
       (SELECT SUM(listing_count) FROM CHIRIPIORCA.BI_FactListing)
UNION ALL
-- SUM(DECIMAL(18,0)) is DECIMAL(38,0). UNION ALL with the DECIMAL(38,2) money
-- sums below would need precision 40, so SQL Server would cut the scale to 0
-- and round every money check. The cast keeps the union at DECIMAL(38,2).
SELECT N'FactListing initial stock (profiled 380,236)', 380236,
       CAST((SELECT SUM(total_initial_stock) FROM CHIRIPIORCA.BI_FactListing) AS DECIMAL(18, 2))
UNION ALL
SELECT N'FactListing active days (profiled 190,407)', 190407,
       (SELECT SUM(total_active_days) FROM CHIRIPIORCA.BI_FactListing)
UNION ALL
SELECT N'FactSale sale_count = Sale rows',
       (SELECT COUNT(*) FROM CHIRIPIORCA.Sale),
       (SELECT SUM(sale_count) FROM CHIRIPIORCA.BI_FactSale)
UNION ALL
SELECT N'FactSale sales_amount = SaleDetail subtotal',
       (SELECT SUM(subtotal) FROM CHIRIPIORCA.SaleDetail),
       (SELECT SUM(sales_amount) FROM CHIRIPIORCA.BI_FactSale)
UNION ALL
SELECT N'FactSale age 25-35 (profiled)', 12832,
       (SELECT SUM(sale_count) FROM CHIRIPIORCA.BI_FactSale WHERE age_range_key = 2)
UNION ALL
SELECT N'FactSale age 35-50 (profiled)', 34741,
       (SELECT SUM(sale_count) FROM CHIRIPIORCA.BI_FactSale WHERE age_range_key = 3)
UNION ALL
SELECT N'FactSale age > 50 (profiled)', 56019,
       (SELECT SUM(sale_count) FROM CHIRIPIORCA.BI_FactSale WHERE age_range_key = 4)
UNION ALL
SELECT N'FactPayment total = Payment amount',
       (SELECT SUM(amount) FROM CHIRIPIORCA.Payment),
       (SELECT SUM(total_amount) FROM CHIRIPIORCA.BI_FactPayment)
UNION ALL
SELECT N'FactShipment shipment_count = Shipment rows',
       (SELECT COUNT(*) FROM CHIRIPIORCA.Shipment),
       (SELECT SUM(shipment_count) FROM CHIRIPIORCA.BI_FactShipment)
UNION ALL
SELECT N'FactShipment on time (profiled 34,589)', 34589,
       (SELECT SUM(on_time_count) FROM CHIRIPIORCA.BI_FactShipment)
UNION ALL
SELECT N'FactShipment cost = Shipment cost',
       (SELECT SUM(shipping_cost) FROM CHIRIPIORCA.Shipment),
       (SELECT SUM(total_shipping_cost) FROM CHIRIPIORCA.BI_FactShipment)
UNION ALL
SELECT N'FactInvoice amount = InvoiceDetail subtotal',
       (SELECT SUM(subtotal) FROM CHIRIPIORCA.InvoiceDetail),
       (SELECT SUM(invoiced_amount) FROM CHIRIPIORCA.BI_FactInvoice);

/* ---- Views return what they promise ---- */
INSERT INTO @checks (check_name, expected, actual)
SELECT N'View 9: concept shares add up to ~100% per month', 0,
       (SELECT COUNT(*)
        FROM (SELECT calendar_year, calendar_month, SUM(invoiced_percentage) AS total_pct
              FROM CHIRIPIORCA.BI_vw_InvoicedPercentageByConcept
              GROUP BY calendar_year, calendar_month) AS p
        WHERE ABS(p.total_pct - 100) > 0.05)
UNION ALL
SELECT N'View 8 returns 5 cities', 5,
       (SELECT COUNT(*) FROM CHIRIPIORCA.BI_vw_TopCitiesByShippingCost)
UNION ALL
SELECT N'View 4 never exceeds 5 categories per group', 0,
       (SELECT COUNT(*) FROM CHIRIPIORCA.BI_vw_TopCategoriesByCityAndAgeRange WHERE category_rank > 5)
UNION ALL
SELECT N'View 6 never exceeds 3 cities per group', 0,
       (SELECT COUNT(*) FROM CHIRIPIORCA.BI_vw_TopInstallmentCitiesByPaymentType WHERE city_rank > 3)
UNION ALL
SELECT N'Last BI load succeeded', 1,
       (SELECT TOP (1) CASE WHEN status = 'SUCCEEDED' THEN 1 ELSE 0 END
        FROM CHIRIPIORCA.ExecutionLog
        WHERE process_name = N'BI_usp_RunLoad'
        ORDER BY execution_id DESC);

SELECT check_name, expected, actual,
       CASE WHEN actual = expected THEN 'PASS' ELSE 'FAIL' END AS result
FROM @checks
ORDER BY result, check_name;

IF EXISTS (SELECT 1 FROM @checks WHERE actual IS NULL OR actual <> expected)
    THROW 50011, N'verify_bi: one or more checks failed (see result set).', 1;
ELSE
    PRINT N'verify_bi: all checks passed.';
GO
