/* =============================================================================
   TP Gestion de Datos 2C2024 - CHIRIPIORCA - Business intelligence model
   GENERATED FILE - do not edit. Source: src/bi/ (run build.ps1)
   ============================================================================= */

/* ---------- src/bi/00_reset_bi.sql ---------- */
/* =============================================================================
   00_reset_bi.sql
   Makes the BI script re-runnable on its own: drops only the BI_ objects of the
   group schema (the transactional model is left untouched), in dependency-safe
   order: foreign keys, views, procedures, functions, tables.
   ============================================================================= */
USE GD2C2024;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'CHIRIPIORCA.Sale', N'U') IS NULL
    THROW 50001, N'The transactional model is missing: run script_creacion_inicial.sql first.', 1;
GO

DECLARE @drop_statements NVARCHAR(MAX);

SELECT @drop_statements = STRING_AGG(
           CAST(N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
                + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) AS NVARCHAR(MAX)),
           N';' + NCHAR(10))
FROM sys.foreign_keys AS fk
JOIN sys.tables  AS t ON t.object_id = fk.parent_object_id
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE s.name = N'CHIRIPIORCA'
  AND t.name LIKE N'BI[_]%';

IF @drop_statements IS NOT NULL
    EXEC sys.sp_executesql @drop_statements;

SELECT @drop_statements = STRING_AGG(
           CAST(N'DROP ' + v.object_kind + N' ' + QUOTENAME(s.name) + N'.' + QUOTENAME(o.name)
                AS NVARCHAR(MAX)),
           N';' + NCHAR(10)) WITHIN GROUP (ORDER BY v.drop_order, o.name)
FROM sys.objects AS o
JOIN sys.schemas AS s ON s.schema_id = o.schema_id
CROSS APPLY (
    SELECT CASE o.type WHEN 'V' THEN N'VIEW'
                       WHEN 'P' THEN N'PROCEDURE'
                       WHEN 'U' THEN N'TABLE'
                       ELSE N'FUNCTION' END AS object_kind,
           CASE o.type WHEN 'V' THEN 1
                       WHEN 'P' THEN 2
                       WHEN 'U' THEN 4
                       ELSE 3 END AS drop_order
) AS v
WHERE s.name = N'CHIRIPIORCA'
  AND o.name LIKE N'BI[_]%'
  AND o.type IN ('V', 'P', 'U', 'FN', 'IF', 'TF');

IF @drop_statements IS NOT NULL
    EXEC sys.sp_executesql @drop_statements;
GO

/* ---------- src/bi/01_dimension_tables.sql ---------- */
/* =============================================================================
   01_dimension_tables.sql
   Star-schema dimensions. Every dimension has an INT surrogate key and, when it
   comes from the transactional model, the source id as a UNIQUE business key.
   Fact loads join on that INT business key instead of on names: integer
   equality is cheaper than NVARCHAR comparison and cannot be broken by two
   cities sharing a name (the original BI joined Location by city+province text).
   ============================================================================= */
USE GD2C2024;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Smart key YYYYMM: deterministic, so facts compute it from a date without a
-- lookup join (and without YEAR()/MONTH() predicates in an ON clause).
CREATE TABLE CHIRIPIORCA.BI_DimTime (
    time_key           INT      NOT NULL,
    calendar_year      SMALLINT NOT NULL,
    four_month_period  TINYINT  NOT NULL,
    calendar_month     TINYINT  NOT NULL,
    CONSTRAINT PK_BI_DimTime PRIMARY KEY CLUSTERED (time_key),
    CONSTRAINT CK_BI_DimTime_Month CHECK (calendar_month BETWEEN 1 AND 12),
    CONSTRAINT CK_BI_DimTime_Period CHECK (four_month_period BETWEEN 1 AND 3),
    CONSTRAINT CK_BI_DimTime_Key CHECK (time_key = calendar_year * 100 + calendar_month)
);
GO

CREATE TABLE CHIRIPIORCA.BI_DimLocation (
    location_key   INT IDENTITY(1, 1) NOT NULL,
    city_id        INT                NOT NULL,
    province_name  NVARCHAR(50)       NOT NULL,
    city_name      NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_BI_DimLocation PRIMARY KEY CLUSTERED (location_key),
    CONSTRAINT UQ_BI_DimLocation_City UNIQUE (city_id)
);
GO

-- Ranges are data, not code: changing a boundary is an UPDATE, not a rewrite
-- of a function full of IF/ELSE branches.
CREATE TABLE CHIRIPIORCA.BI_DimAgeRange (
    age_range_key  TINYINT      NOT NULL,
    range_label    NVARCHAR(20) NOT NULL,
    min_age        TINYINT      NOT NULL,
    max_age        TINYINT      NOT NULL,
    CONSTRAINT PK_BI_DimAgeRange PRIMARY KEY CLUSTERED (age_range_key),
    CONSTRAINT CK_BI_DimAgeRange_Bounds CHECK (min_age <= max_age)
);
GO

CREATE TABLE CHIRIPIORCA.BI_DimTimeRange (
    time_range_key  TINYINT      NOT NULL,
    range_label     NVARCHAR(20) NOT NULL,
    start_hour      TINYINT      NOT NULL,
    end_hour        TINYINT      NOT NULL,
    CONSTRAINT PK_BI_DimTimeRange PRIMARY KEY CLUSTERED (time_range_key),
    CONSTRAINT CK_BI_DimTimeRange_Bounds CHECK (start_hour <= end_hour AND end_hour <= 23)
);
GO

CREATE TABLE CHIRIPIORCA.BI_DimPaymentType (
    payment_type_key        INT IDENTITY(1, 1) NOT NULL,
    payment_method_type_id  INT                NOT NULL,
    type_name               NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_BI_DimPaymentType PRIMARY KEY CLUSTERED (payment_type_key),
    CONSTRAINT UQ_BI_DimPaymentType_Source UNIQUE (payment_method_type_id)
);
GO

CREATE TABLE CHIRIPIORCA.BI_DimShippingType (
    shipping_type_key  INT IDENTITY(1, 1) NOT NULL,
    shipping_type_id   INT                NOT NULL,
    type_name          NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_BI_DimShippingType PRIMARY KEY CLUSTERED (shipping_type_key),
    CONSTRAINT UQ_BI_DimShippingType_Source UNIQUE (shipping_type_id)
);
GO

-- Category/subcategory hierarchy flattened into one dimension (star, not snowflake).
CREATE TABLE CHIRIPIORCA.BI_DimSubcategory (
    subcategory_key   INT IDENTITY(1, 1) NOT NULL,
    subcategory_id    INT                NOT NULL,
    category_name     NVARCHAR(50)       NOT NULL,
    subcategory_name  NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_BI_DimSubcategory PRIMARY KEY CLUSTERED (subcategory_key),
    CONSTRAINT UQ_BI_DimSubcategory_Source UNIQUE (subcategory_id)
);
GO

CREATE TABLE CHIRIPIORCA.BI_DimBrand (
    brand_key   INT IDENTITY(1, 1) NOT NULL,
    brand_id    INT                NOT NULL,
    brand_name  NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_BI_DimBrand PRIMARY KEY CLUSTERED (brand_key),
    CONSTRAINT UQ_BI_DimBrand_Source UNIQUE (brand_id)
);
GO

CREATE TABLE CHIRIPIORCA.BI_DimInvoiceConcept (
    invoice_concept_key  INT IDENTITY(1, 1) NOT NULL,
    invoice_concept_id   INT                NOT NULL,
    concept_name         NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_BI_DimInvoiceConcept PRIMARY KEY CLUSTERED (invoice_concept_key),
    CONSTRAINT UQ_BI_DimInvoiceConcept_Source UNIQUE (invoice_concept_id)
);
GO

/* ---------- src/bi/02_fact_tables.sql ---------- */
/* =============================================================================
   02_fact_tables.sql
   Aggregated fact tables. Each fact stores additive measures only (counts and
   sums); averages and percentages are derived in the views as
   SUM(numerator) / SUM(denominator). Storing pre-computed averages (as the
   original BI did) is wrong: the average of averages is not the average.

   The clustered primary key is the grain of the fact (one row per combination
   of dimension keys). It enforces that grain and, leading with time_key,
   clusters the rows in the order every view filters and groups them.
   ============================================================================= */
USE GD2C2024;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Indicators 1 and 2. Grain: start month x subcategory x brand.
CREATE TABLE CHIRIPIORCA.BI_FactListing (
    time_key             INT            NOT NULL,
    subcategory_key      INT            NOT NULL,
    brand_key            INT            NOT NULL,
    listing_count        INT            NOT NULL,
    total_active_days    INT            NOT NULL,
    total_initial_stock  DECIMAL(18, 0) NOT NULL,
    CONSTRAINT PK_BI_FactListing PRIMARY KEY CLUSTERED (time_key, subcategory_key, brand_key),
    CONSTRAINT FK_BI_FactListing_Time FOREIGN KEY (time_key) REFERENCES CHIRIPIORCA.BI_DimTime (time_key),
    CONSTRAINT FK_BI_FactListing_Subcategory FOREIGN KEY (subcategory_key) REFERENCES CHIRIPIORCA.BI_DimSubcategory (subcategory_key),
    CONSTRAINT FK_BI_FactListing_Brand FOREIGN KEY (brand_key) REFERENCES CHIRIPIORCA.BI_DimBrand (brand_key)
);
GO

-- Indicators 3, 4 and 5. Grain: sale month x warehouse location x customer
-- location x age range x subcategory x time range.
CREATE TABLE CHIRIPIORCA.BI_FactSale (
    time_key                INT            NOT NULL,
    warehouse_location_key  INT            NOT NULL,
    customer_location_key   INT            NOT NULL,
    age_range_key           TINYINT        NOT NULL,
    subcategory_key         INT            NOT NULL,
    time_range_key          TINYINT        NOT NULL,
    sale_count              INT            NOT NULL,
    units_sold              DECIMAL(18, 0) NOT NULL,
    sales_amount            DECIMAL(18, 2) NOT NULL,
    CONSTRAINT PK_BI_FactSale PRIMARY KEY CLUSTERED
        (time_key, warehouse_location_key, customer_location_key, age_range_key, subcategory_key, time_range_key),
    CONSTRAINT FK_BI_FactSale_Time FOREIGN KEY (time_key) REFERENCES CHIRIPIORCA.BI_DimTime (time_key),
    CONSTRAINT FK_BI_FactSale_WarehouseLocation FOREIGN KEY (warehouse_location_key) REFERENCES CHIRIPIORCA.BI_DimLocation (location_key),
    CONSTRAINT FK_BI_FactSale_CustomerLocation FOREIGN KEY (customer_location_key) REFERENCES CHIRIPIORCA.BI_DimLocation (location_key),
    CONSTRAINT FK_BI_FactSale_AgeRange FOREIGN KEY (age_range_key) REFERENCES CHIRIPIORCA.BI_DimAgeRange (age_range_key),
    CONSTRAINT FK_BI_FactSale_Subcategory FOREIGN KEY (subcategory_key) REFERENCES CHIRIPIORCA.BI_DimSubcategory (subcategory_key),
    CONSTRAINT FK_BI_FactSale_TimeRange FOREIGN KEY (time_range_key) REFERENCES CHIRIPIORCA.BI_DimTimeRange (time_range_key)
);
GO

-- Indicator 6. Grain: payment month x customer location x payment type.
CREATE TABLE CHIRIPIORCA.BI_FactPayment (
    time_key               INT            NOT NULL,
    customer_location_key  INT            NOT NULL,
    payment_type_key       INT            NOT NULL,
    payment_count          INT            NOT NULL,
    total_amount           DECIMAL(18, 2) NOT NULL,
    installment_amount     DECIMAL(18, 2) NOT NULL,
    CONSTRAINT PK_BI_FactPayment PRIMARY KEY CLUSTERED (time_key, customer_location_key, payment_type_key),
    CONSTRAINT FK_BI_FactPayment_Time FOREIGN KEY (time_key) REFERENCES CHIRIPIORCA.BI_DimTime (time_key),
    CONSTRAINT FK_BI_FactPayment_CustomerLocation FOREIGN KEY (customer_location_key) REFERENCES CHIRIPIORCA.BI_DimLocation (location_key),
    CONSTRAINT FK_BI_FactPayment_PaymentType FOREIGN KEY (payment_type_key) REFERENCES CHIRIPIORCA.BI_DimPaymentType (payment_type_key)
);
GO

-- Indicators 7 and 8. Grain: scheduled month x warehouse location x customer
-- location x shipping type.
CREATE TABLE CHIRIPIORCA.BI_FactShipment (
    time_key                INT            NOT NULL,
    warehouse_location_key  INT            NOT NULL,
    customer_location_key   INT            NOT NULL,
    shipping_type_key       INT            NOT NULL,
    shipment_count          INT            NOT NULL,
    on_time_count           INT            NOT NULL,
    total_shipping_cost     DECIMAL(18, 2) NOT NULL,
    CONSTRAINT PK_BI_FactShipment PRIMARY KEY CLUSTERED
        (time_key, warehouse_location_key, customer_location_key, shipping_type_key),
    CONSTRAINT FK_BI_FactShipment_Time FOREIGN KEY (time_key) REFERENCES CHIRIPIORCA.BI_DimTime (time_key),
    CONSTRAINT FK_BI_FactShipment_WarehouseLocation FOREIGN KEY (warehouse_location_key) REFERENCES CHIRIPIORCA.BI_DimLocation (location_key),
    CONSTRAINT FK_BI_FactShipment_CustomerLocation FOREIGN KEY (customer_location_key) REFERENCES CHIRIPIORCA.BI_DimLocation (location_key),
    CONSTRAINT FK_BI_FactShipment_ShippingType FOREIGN KEY (shipping_type_key) REFERENCES CHIRIPIORCA.BI_DimShippingType (shipping_type_key),
    CONSTRAINT CK_BI_FactShipment_OnTime CHECK (on_time_count <= shipment_count)
);
GO

-- Indicators 9 and 10. Grain: invoice month x seller location x concept.
CREATE TABLE CHIRIPIORCA.BI_FactInvoice (
    time_key             INT            NOT NULL,
    seller_location_key  INT            NOT NULL,
    invoice_concept_key  INT            NOT NULL,
    invoice_line_count   INT            NOT NULL,
    invoiced_amount      DECIMAL(18, 2) NOT NULL,
    CONSTRAINT PK_BI_FactInvoice PRIMARY KEY CLUSTERED (time_key, seller_location_key, invoice_concept_key),
    CONSTRAINT FK_BI_FactInvoice_Time FOREIGN KEY (time_key) REFERENCES CHIRIPIORCA.BI_DimTime (time_key),
    CONSTRAINT FK_BI_FactInvoice_SellerLocation FOREIGN KEY (seller_location_key) REFERENCES CHIRIPIORCA.BI_DimLocation (location_key),
    CONSTRAINT FK_BI_FactInvoice_InvoiceConcept FOREIGN KEY (invoice_concept_key) REFERENCES CHIRIPIORCA.BI_DimInvoiceConcept (invoice_concept_key)
);
GO

/* ---------- src/bi/03_functions.sql ---------- */
/* =============================================================================
   03_functions.sql
   Inline table-valued functions (iTVF) used by the fact loads.

   Why iTVF instead of scalar UDFs (the original OBTENER_ID_RANGO_ETARIO was a
   scalar UDF with IF/ELSE branches and table reads):
   - An iTVF is a single SELECT that the optimizer expands into the calling
     query, like a parameterized view: it joins set-based and allows parallelism.
   - A multi-statement scalar UDF that reads tables runs once per row (hidden
     RBAR), cannot be inlined by SQL Server 2019's UDF inlining and forces a
     serial plan.
   - The original function also used GETDATE(), so a customer's age range
     changed depending on the day the script was run. Age is now computed at
     the date of the event, which makes the load deterministic and repeatable.
   ============================================================================= */
USE GD2C2024;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- YYYYMM key of the time dimension for a given date.
CREATE OR ALTER FUNCTION CHIRIPIORCA.BI_fn_GetTimeKey (@event_date DATE)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT YEAR(@event_date) * 100 + MONTH(@event_date) AS time_key;
GO

-- Age range of a person at a given date (full years, birthday-aware).
CREATE OR ALTER FUNCTION CHIRIPIORCA.BI_fn_GetAgeRangeKey (@birth_date DATE, @at_date DATE)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT ar.age_range_key
    FROM (
        SELECT DATEDIFF(YEAR, @birth_date, @at_date)
               - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, @birth_date, @at_date), @birth_date) > @at_date
                      THEN 1 ELSE 0 END AS age_years
    ) AS a
    JOIN CHIRIPIORCA.BI_DimAgeRange AS ar
      ON a.age_years BETWEEN ar.min_age AND ar.max_age;
GO

-- Time-of-day range for a given instant.
CREATE OR ALTER FUNCTION CHIRIPIORCA.BI_fn_GetTimeRangeKey (@event_at DATETIME)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT tr.time_range_key
    FROM CHIRIPIORCA.BI_DimTimeRange AS tr
    WHERE DATEPART(HOUR, @event_at) BETWEEN tr.start_hour AND tr.end_hour;
GO

-- City where a customer receives a sale: the shipment address when there is a
-- shipment (statement, indicator 6), otherwise the customer's first address.
CREATE OR ALTER FUNCTION CHIRIPIORCA.BI_fn_GetSaleCustomerCity (@sale_code DECIMAL(18, 0), @customer_user_id INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT COALESCE(
               (SELECT a.city_id
                FROM CHIRIPIORCA.Shipment AS sh
                JOIN CHIRIPIORCA.Address  AS a ON a.address_id = sh.address_id
                WHERE sh.sale_code = @sale_code),
               (SELECT TOP (1) a.city_id
                FROM CHIRIPIORCA.Address AS a
                WHERE a.user_id = @customer_user_id
                ORDER BY a.address_id)
           ) AS city_id;
GO

/* ---------- src/bi/04_load_procedures.sql ---------- */
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

/* ---------- src/bi/05_views.sql ---------- */
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

/* ---------- src/bi/06_run_load.sql ---------- */
/* =============================================================================
   06_run_load.sql
   Loads the star schema from the transactional model in one atomic unit and
   refreshes statistics of the freshly loaded BI tables.
   ============================================================================= */
USE GD2C2024;
GO

EXEC CHIRIPIORCA.BI_usp_RunLoad;
GO

EXEC sys.sp_executesql N'
    DECLARE @sql NVARCHAR(MAX);
    SELECT @sql = STRING_AGG(CAST(N''UPDATE STATISTICS CHIRIPIORCA.'' + QUOTENAME(t.name) + N'' WITH FULLSCAN'' AS NVARCHAR(MAX)), N'';'')
    FROM sys.tables AS t
    WHERE t.schema_id = SCHEMA_ID(N''CHIRIPIORCA'') AND t.name LIKE N''BI[_]%'';
    EXEC sys.sp_executesql @sql;';
GO
