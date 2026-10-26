/* =============================================================================
   04_load_procedures.sql
   Set-based ETL from the transactional model into the star schema.
   Same contract as the migration: steps do not manage transactions,
   BI_usp_RunLoad runs all of them atomically.
   ============================================================================= */
USE GD2C2024;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------------------
   Dimensions
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.BI_usp_LoadDimensions
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Time: one row per calendar month between the first and last date found
       in any fact source, with no gaps (a month without events still exists). */
    DECLARE @first_month DATE, @last_month DATE;

    SELECT @first_month = MIN(bounds.min_date), @last_month = MAX(bounds.max_date)
    FROM (
        SELECT MIN(start_date),     MAX(end_date)                  FROM CHIRIPIORCA.Listing
        UNION ALL SELECT MIN(sale_date),      MAX(sale_date)       FROM CHIRIPIORCA.Sale
        UNION ALL SELECT MIN(scheduled_date), MAX(scheduled_date)  FROM CHIRIPIORCA.Shipment
        UNION ALL SELECT MIN(payment_date),   MAX(payment_date)    FROM CHIRIPIORCA.Payment
        UNION ALL SELECT MIN(invoice_date),   MAX(invoice_date)    FROM CHIRIPIORCA.Invoice
    ) AS bounds (min_date, max_date);

    SET @first_month = DATEFROMPARTS(YEAR(@first_month), MONTH(@first_month), 1);
    SET @last_month  = DATEFROMPARTS(YEAR(@last_month),  MONTH(@last_month),  1);

    -- Numbers 0..N-1 from a cross join of a 10-row constant (up to 10,000 months)
    -- generate the calendar in one statement, without a loop.
    WITH digits AS (
        SELECT n FROM (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)) AS d (n)
    ),
    month_offsets AS (
        SELECT TOP (DATEDIFF(MONTH, @first_month, @last_month) + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS month_offset
        FROM digits AS d1 CROSS JOIN digits AS d2 CROSS JOIN digits AS d3 CROSS JOIN digits AS d4
    )
    INSERT INTO CHIRIPIORCA.BI_DimTime (time_key, calendar_year, four_month_period, calendar_month)
    SELECT YEAR(m.month_start) * 100 + MONTH(m.month_start),
           YEAR(m.month_start),
           (MONTH(m.month_start) - 1) / 4 + 1,
           MONTH(m.month_start)
    FROM month_offsets AS mo
    CROSS APPLY (SELECT DATEADD(MONTH, mo.month_offset, @first_month) AS month_start) AS m;

    INSERT INTO CHIRIPIORCA.BI_DimLocation (city_id, province_name, city_name)
    SELECT ci.city_id, p.province_name, ci.city_name
    FROM CHIRIPIORCA.City AS ci
    JOIN CHIRIPIORCA.Province AS p
      ON p.province_id = ci.province_id;

    -- Boundaries follow the statement literally: "< 25" and "> 50" are strict,
    -- so 50 belongs to "35 - 50" and the shared 35 is assigned to "25 - 35".
    INSERT INTO CHIRIPIORCA.BI_DimAgeRange (age_range_key, range_label, min_age, max_age)
    VALUES (1, N'< 25',     0,  24),
           (2, N'25 - 35', 25,  35),
           (3, N'35 - 50', 36,  50),
           (4, N'> 50',    51, 255);

    INSERT INTO CHIRIPIORCA.BI_DimTimeRange (time_range_key, range_label, start_hour, end_hour)
    VALUES (1, N'00:00 - 06:00',  0,  5),
           (2, N'06:00 - 12:00',  6, 11),
           (3, N'12:00 - 18:00', 12, 17),
           (4, N'18:00 - 24:00', 18, 23);

    INSERT INTO CHIRIPIORCA.BI_DimPaymentType (payment_method_type_id, type_name)
    SELECT payment_method_type_id, type_name
    FROM CHIRIPIORCA.PaymentMethodType;

    INSERT INTO CHIRIPIORCA.BI_DimShippingType (shipping_type_id, type_name)
    SELECT shipping_type_id, type_name
    FROM CHIRIPIORCA.ShippingType;

    INSERT INTO CHIRIPIORCA.BI_DimSubcategory (subcategory_id, category_name, subcategory_name)
    SELECT sc.subcategory_id, c.category_name, sc.subcategory_name
    FROM CHIRIPIORCA.Subcategory AS sc
    JOIN CHIRIPIORCA.Category AS c
      ON c.category_id = sc.category_id;

    INSERT INTO CHIRIPIORCA.BI_DimBrand (brand_id, brand_name)
    SELECT brand_id, brand_name
    FROM CHIRIPIORCA.Brand;

    INSERT INTO CHIRIPIORCA.BI_DimInvoiceConcept (invoice_concept_id, concept_name)
    SELECT invoice_concept_id, concept_name
    FROM CHIRIPIORCA.InvoiceConcept;
END;
GO

/* ---------------------------------------------------------------------------
   Facts
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.BI_usp_LoadFactListing
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Listings are attributed to the month they start (statement, indicator 1).
    INSERT INTO CHIRIPIORCA.BI_FactListing WITH (TABLOCK)
           (time_key, subcategory_key, brand_key, listing_count, total_active_days, total_initial_stock)
    SELECT tk.time_key, ds.subcategory_key, db.brand_key,
           COUNT(*),
           SUM(DATEDIFF(DAY, l.start_date, l.end_date)),
           SUM(l.initial_stock)
    FROM CHIRIPIORCA.Listing AS l
    JOIN CHIRIPIORCA.Product AS pr
      ON pr.product_id = l.product_id
    JOIN CHIRIPIORCA.BI_DimSubcategory AS ds
      ON ds.subcategory_id = pr.subcategory_id
    JOIN CHIRIPIORCA.BI_DimBrand AS db
      ON db.brand_id = pr.brand_id
    CROSS APPLY CHIRIPIORCA.BI_fn_GetTimeKey(l.start_date) AS tk
    GROUP BY tk.time_key, ds.subcategory_key, db.brand_key;
END;
GO

CREATE OR ALTER PROCEDURE CHIRIPIORCA.BI_usp_LoadFactSale
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- One input row per sale line. The source stores only the sale DATE (no
    -- time of day), so every sale falls in the 00:00 - 06:00 range; the
    -- dimension is still modeled so the indicator works once times exist.
    INSERT INTO CHIRIPIORCA.BI_FactSale WITH (TABLOCK)
           (time_key, warehouse_location_key, customer_location_key, age_range_key,
            subcategory_key, time_range_key, sale_count, units_sold, sales_amount)
    SELECT tk.time_key, wl.location_key, cl.location_key, ar.age_range_key,
           ds.subcategory_key, tr.time_range_key,
           COUNT(DISTINCT s.sale_code),
           SUM(sd.quantity),
           SUM(sd.subtotal)
    FROM CHIRIPIORCA.Sale AS s
    JOIN CHIRIPIORCA.SaleDetail AS sd
      ON sd.sale_code = s.sale_code
    JOIN CHIRIPIORCA.Listing AS l
      ON l.listing_code = sd.listing_code
    JOIN CHIRIPIORCA.Product AS pr
      ON pr.product_id = l.product_id
    JOIN CHIRIPIORCA.Warehouse AS w
      ON w.warehouse_code = l.warehouse_code
    JOIN CHIRIPIORCA.Customer AS c
      ON c.customer_id = s.customer_id
    CROSS APPLY CHIRIPIORCA.BI_fn_GetSaleCustomerCity(s.sale_code, c.user_id) AS cc
    JOIN CHIRIPIORCA.BI_DimLocation AS wl
      ON wl.city_id = w.city_id
    JOIN CHIRIPIORCA.BI_DimLocation AS cl
      ON cl.city_id = cc.city_id
    JOIN CHIRIPIORCA.BI_DimSubcategory AS ds
      ON ds.subcategory_id = pr.subcategory_id
    CROSS APPLY CHIRIPIORCA.BI_fn_GetTimeKey(s.sale_date) AS tk
    CROSS APPLY CHIRIPIORCA.BI_fn_GetAgeRangeKey(c.birth_date, s.sale_date) AS ar
    CROSS APPLY CHIRIPIORCA.BI_fn_GetTimeRangeKey(CAST(s.sale_date AS DATETIME)) AS tr
    GROUP BY tk.time_key, wl.location_key, cl.location_key, ar.age_range_key,
             ds.subcategory_key, tr.time_range_key;
END;
GO

CREATE OR ALTER PROCEDURE CHIRIPIORCA.BI_usp_LoadFactPayment
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO CHIRIPIORCA.BI_FactPayment WITH (TABLOCK)
           (time_key, customer_location_key, payment_type_key, payment_count, total_amount, installment_amount)
    SELECT tk.time_key, cl.location_key, dpt.payment_type_key,
           COUNT(*),
           SUM(p.amount),
           SUM(CASE WHEN cpd.installments > 1 THEN p.amount ELSE 0 END)
    FROM CHIRIPIORCA.Payment AS p
    JOIN CHIRIPIORCA.PaymentMethod AS pm
      ON pm.payment_method_id = p.payment_method_id
    JOIN CHIRIPIORCA.BI_DimPaymentType AS dpt
      ON dpt.payment_method_type_id = pm.payment_method_type_id
    LEFT JOIN CHIRIPIORCA.CardPaymentDetail AS cpd
      ON cpd.payment_id = p.payment_id
    JOIN CHIRIPIORCA.Sale AS s
      ON s.sale_code = p.sale_code
    JOIN CHIRIPIORCA.Customer AS c
      ON c.customer_id = s.customer_id
    CROSS APPLY CHIRIPIORCA.BI_fn_GetSaleCustomerCity(s.sale_code, c.user_id) AS cc
    JOIN CHIRIPIORCA.BI_DimLocation AS cl
      ON cl.city_id = cc.city_id
    CROSS APPLY CHIRIPIORCA.BI_fn_GetTimeKey(p.payment_date) AS tk
    GROUP BY tk.time_key, cl.location_key, dpt.payment_type_key;
END;
GO

CREATE OR ALTER PROCEDURE CHIRIPIORCA.BI_usp_LoadFactShipment
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- On time = delivered on the scheduled date, inside the scheduled hour
    -- window. The warehouse is the one of the sale's first line (every sale in
    -- the data set has exactly one line).
    INSERT INTO CHIRIPIORCA.BI_FactShipment WITH (TABLOCK)
           (time_key, warehouse_location_key, customer_location_key, shipping_type_key,
            shipment_count, on_time_count, total_shipping_cost)
    SELECT tk.time_key, wl.location_key, cl.location_key, dst.shipping_type_key,
           COUNT(*),
           SUM(CASE WHEN CAST(sh.delivered_at AS DATE) = sh.scheduled_date
                     AND DATEPART(HOUR, sh.delivered_at) BETWEEN sh.window_start_hour AND sh.window_end_hour
                    THEN 1 ELSE 0 END),
           SUM(sh.shipping_cost)
    FROM CHIRIPIORCA.Shipment AS sh
    JOIN CHIRIPIORCA.Address AS a
      ON a.address_id = sh.address_id
    CROSS APPLY (
        SELECT TOP (1) w.city_id
        FROM CHIRIPIORCA.SaleDetail AS sd
        JOIN CHIRIPIORCA.Listing    AS l ON l.listing_code   = sd.listing_code
        JOIN CHIRIPIORCA.Warehouse  AS w ON w.warehouse_code = l.warehouse_code
        WHERE sd.sale_code = sh.sale_code
        ORDER BY sd.sale_detail_id
    ) AS wh
    JOIN CHIRIPIORCA.BI_DimLocation AS wl
      ON wl.city_id = wh.city_id
    JOIN CHIRIPIORCA.BI_DimLocation AS cl
      ON cl.city_id = a.city_id
    JOIN CHIRIPIORCA.BI_DimShippingType AS dst
      ON dst.shipping_type_id = sh.shipping_type_id
    CROSS APPLY CHIRIPIORCA.BI_fn_GetTimeKey(sh.scheduled_date) AS tk
    GROUP BY tk.time_key, wl.location_key, cl.location_key, dst.shipping_type_key;
END;
GO

CREATE OR ALTER PROCEDURE CHIRIPIORCA.BI_usp_LoadFactInvoice
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Location is the seller's address (statement, indicator 10: "provincia
    -- del vendedor"); the original used the warehouse of the listing.
    INSERT INTO CHIRIPIORCA.BI_FactInvoice WITH (TABLOCK)
           (time_key, seller_location_key, invoice_concept_key, invoice_line_count, invoiced_amount)
    SELECT tk.time_key, sl.location_key, dic.invoice_concept_key,
           COUNT(*),
           SUM(idt.subtotal)
    FROM CHIRIPIORCA.InvoiceDetail AS idt
    JOIN CHIRIPIORCA.Invoice AS i
      ON i.invoice_number = idt.invoice_number
    JOIN CHIRIPIORCA.Seller AS se
      ON se.seller_id = i.seller_id
    CROSS APPLY (
        SELECT TOP (1) a.city_id
        FROM CHIRIPIORCA.Address AS a
        WHERE a.user_id = se.user_id
        ORDER BY a.address_id
    ) AS sa
    JOIN CHIRIPIORCA.BI_DimLocation AS sl
      ON sl.city_id = sa.city_id
    JOIN CHIRIPIORCA.BI_DimInvoiceConcept AS dic
      ON dic.invoice_concept_id = idt.invoice_concept_id
    CROSS APPLY CHIRIPIORCA.BI_fn_GetTimeKey(i.invoice_date) AS tk
    GROUP BY tk.time_key, sl.location_key, dic.invoice_concept_key;
END;
GO

/* ---------------------------------------------------------------------------
   Orchestrator
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.BI_usp_RunLoad
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @execution_id INT;

    INSERT INTO CHIRIPIORCA.ExecutionLog (process_name, started_at, status)
    VALUES (N'BI_usp_RunLoad', SYSDATETIME(), 'RUNNING');
    SET @execution_id = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC CHIRIPIORCA.BI_usp_LoadDimensions;
        EXEC CHIRIPIORCA.BI_usp_LoadFactListing;
        EXEC CHIRIPIORCA.BI_usp_LoadFactSale;
        EXEC CHIRIPIORCA.BI_usp_LoadFactPayment;
        EXEC CHIRIPIORCA.BI_usp_LoadFactShipment;
        EXEC CHIRIPIORCA.BI_usp_LoadFactInvoice;

        COMMIT TRANSACTION;

        UPDATE CHIRIPIORCA.ExecutionLog
        SET finished_at = SYSDATETIME(), status = 'SUCCEEDED'
        WHERE execution_id = @execution_id;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        UPDATE CHIRIPIORCA.ExecutionLog
        SET finished_at   = SYSDATETIME(),
            status        = 'FAILED',
            error_number  = ERROR_NUMBER(),
            error_message = CONCAT(ERROR_PROCEDURE(), N' (line ', ERROR_LINE(), N'): ', ERROR_MESSAGE())
        WHERE execution_id = @execution_id;

        THROW;
    END CATCH;
END;
GO
