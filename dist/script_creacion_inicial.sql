/* =============================================================================
   TP Gestion de Datos 2C2024 - CHIRIPIORCA - Transactional model and migration
   GENERATED FILE - do not edit. Source: src/transactional/ (run build.ps1)
   ============================================================================= */

/* ---------- src/transactional/00_reset_schema.sql ---------- */
/* =============================================================================
   00_reset_schema.sql
   Makes the script re-runnable: drops every object owned by the group schema
   (transactional and BI) and guarantees the schema exists.

   Instead of one hand-written DROP per object (which silently goes stale when
   an object is added or renamed), the drop list is generated from the catalog
   views, in dependency-safe order:
     1. foreign keys   2. views   3. procedures   4. functions   5. tables
   ============================================================================= */
USE GD2C2024;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @drop_statements NVARCHAR(MAX);

-- 1) Foreign keys first, so tables can then be dropped in any order.
SELECT @drop_statements = STRING_AGG(
           CAST(N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
                + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) AS NVARCHAR(MAX)),
           N';' + NCHAR(10))
FROM sys.foreign_keys AS fk
JOIN sys.tables  AS t ON t.object_id = fk.parent_object_id
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE s.name = N'CHIRIPIORCA';

IF @drop_statements IS NOT NULL
    EXEC sys.sp_executesql @drop_statements;

-- 2) Remaining schema-scoped objects. Views go before functions because a view
--    may reference a function; functions go before tables for the same reason.
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
  AND o.type IN ('V', 'P', 'U', 'FN', 'IF', 'TF');

IF @drop_statements IS NOT NULL
    EXEC sys.sp_executesql @drop_statements;

-- 3) CREATE SCHEMA must be the only statement in its batch, hence dynamic SQL.
IF SCHEMA_ID(N'CHIRIPIORCA') IS NULL
    EXEC (N'CREATE SCHEMA CHIRIPIORCA AUTHORIZATION dbo;');
GO

/* ---------- src/transactional/01_tables.sql ---------- */
/* =============================================================================
   01_tables.sql
   Normalized transactional model (3NF) for the marketplace.

   Conventions
   - Surrogate keys are INT IDENTITY (4 bytes) instead of DECIMAL(18,0) (9 bytes):
     narrower keys mean narrower clustered and nonclustered indexes, more rows
     per 8 KB page and fewer reads on every join.
   - Natural codes that already identify a row in the source (sale, listing,
     invoice, warehouse, product model) are kept as primary keys with their
     source data type, so the migration needs no lookup joins to resolve them.
   - Every other column keeps the exact data type of its source column in
     gd_esquema.Maestra (course rule). Money is DECIMAL(18,2): the source has
     cents and DECIMAL(18,0) would round them away.
   - Every constraint is named (PK_, FK_, UQ_, CK_, DF_) so error messages and
     execution plans are readable and the constraint can be altered by name.
   ============================================================================= */
USE GD2C2024;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------------------
   Execution log: one row per run of a migration/load orchestrator.
   --------------------------------------------------------------------------- */
CREATE TABLE CHIRIPIORCA.ExecutionLog (
    execution_id   INT IDENTITY(1, 1) NOT NULL,
    process_name   NVARCHAR(100)      NOT NULL,
    started_at     DATETIME2(3)       NOT NULL,
    finished_at    DATETIME2(3)       NULL,
    status         VARCHAR(10)        NOT NULL,
    error_number   INT                NULL,
    error_message  NVARCHAR(4000)     NULL,
    CONSTRAINT PK_ExecutionLog PRIMARY KEY CLUSTERED (execution_id),
    CONSTRAINT CK_ExecutionLog_Status CHECK (status IN ('RUNNING', 'SUCCEEDED', 'FAILED'))
);
GO

/* ---------------------------------------------------------------------------
   Geography
   --------------------------------------------------------------------------- */
CREATE TABLE CHIRIPIORCA.Province (
    province_id    INT IDENTITY(1, 1) NOT NULL,
    province_name  NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_Province PRIMARY KEY CLUSTERED (province_id),
    CONSTRAINT UQ_Province_Name UNIQUE (province_name)
);
GO

-- A city name is only unique inside its province (1,612 names repeat across provinces).
CREATE TABLE CHIRIPIORCA.City (
    city_id        INT IDENTITY(1, 1) NOT NULL,
    province_id    INT                NOT NULL,
    city_name      NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_City PRIMARY KEY CLUSTERED (city_id),
    CONSTRAINT FK_City_Province FOREIGN KEY (province_id) REFERENCES CHIRIPIORCA.Province (province_id),
    CONSTRAINT UQ_City_Province_Name UNIQUE (province_id, city_name)
);
GO

/* ---------------------------------------------------------------------------
   Users, customers and sellers
   A user account can play the customer role, the seller role or both, and owns
   one or more addresses.
   --------------------------------------------------------------------------- */
CREATE TABLE CHIRIPIORCA.UserAccount (
    user_id        INT IDENTITY(1, 1) NOT NULL,
    username       NVARCHAR(50)       NOT NULL,
    user_password  NVARCHAR(50)       NOT NULL,
    created_on     DATE               NOT NULL,
    CONSTRAINT PK_UserAccount PRIMARY KEY CLUSTERED (user_id)
);
GO

CREATE TABLE CHIRIPIORCA.Address (
    address_id     INT IDENTITY(1, 1) NOT NULL,
    user_id        INT                NOT NULL,
    street         NVARCHAR(50)       NOT NULL,
    street_number  DECIMAL(18, 0)     NOT NULL,
    floor_number   DECIMAL(18, 0)     NULL,
    apartment      NVARCHAR(50)       NULL,
    postal_code    NVARCHAR(50)       NULL,
    city_id        INT                NOT NULL,
    CONSTRAINT PK_Address PRIMARY KEY CLUSTERED (address_id),
    CONSTRAINT FK_Address_UserAccount FOREIGN KEY (user_id) REFERENCES CHIRIPIORCA.UserAccount (user_id),
    CONSTRAINT FK_Address_City FOREIGN KEY (city_id) REFERENCES CHIRIPIORCA.City (city_id)
);
GO

-- DNI alone is not unique in the source (14 DNIs belong to two people), so the
-- business key is DNI + last name + first name.
CREATE TABLE CHIRIPIORCA.Customer (
    customer_id    INT IDENTITY(1, 1) NOT NULL,
    user_id        INT                NOT NULL,
    dni            DECIMAL(18, 0)     NOT NULL,
    first_name     NVARCHAR(50)       NOT NULL,
    last_name      NVARCHAR(50)       NOT NULL,
    birth_date     DATE               NOT NULL,
    email          NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_Customer PRIMARY KEY CLUSTERED (customer_id),
    CONSTRAINT FK_Customer_UserAccount FOREIGN KEY (user_id) REFERENCES CHIRIPIORCA.UserAccount (user_id),
    CONSTRAINT UQ_Customer_User UNIQUE (user_id),
    CONSTRAINT UQ_Customer_Identity UNIQUE (dni, last_name, first_name)
);
GO

CREATE TABLE CHIRIPIORCA.Seller (
    seller_id      INT IDENTITY(1, 1) NOT NULL,
    user_id        INT                NOT NULL,
    cuit           NVARCHAR(50)       NOT NULL,
    business_name  NVARCHAR(50)       NOT NULL,
    email          NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_Seller PRIMARY KEY CLUSTERED (seller_id),
    CONSTRAINT FK_Seller_UserAccount FOREIGN KEY (user_id) REFERENCES CHIRIPIORCA.UserAccount (user_id),
    CONSTRAINT UQ_Seller_User UNIQUE (user_id),
    CONSTRAINT UQ_Seller_Cuit UNIQUE (cuit)
);
GO

/* ---------------------------------------------------------------------------
   Product catalog
   --------------------------------------------------------------------------- */
CREATE TABLE CHIRIPIORCA.Category (
    category_id    INT IDENTITY(1, 1) NOT NULL,
    category_name  NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_Category PRIMARY KEY CLUSTERED (category_id),
    CONSTRAINT UQ_Category_Name UNIQUE (category_name)
);
GO

-- 45 subcategory names are shared by 22 categories: the pair is the business key.
CREATE TABLE CHIRIPIORCA.Subcategory (
    subcategory_id    INT IDENTITY(1, 1) NOT NULL,
    category_id       INT                NOT NULL,
    subcategory_name  NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_Subcategory PRIMARY KEY CLUSTERED (subcategory_id),
    CONSTRAINT FK_Subcategory_Category FOREIGN KEY (category_id) REFERENCES CHIRIPIORCA.Category (category_id),
    CONSTRAINT UQ_Subcategory_Category_Name UNIQUE (category_id, subcategory_name)
);
GO

CREATE TABLE CHIRIPIORCA.Brand (
    brand_id    INT IDENTITY(1, 1) NOT NULL,
    brand_name  NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_Brand PRIMARY KEY CLUSTERED (brand_id),
    CONSTRAINT UQ_Brand_Name UNIQUE (brand_name)
);
GO

CREATE TABLE CHIRIPIORCA.ProductModel (
    model_code         DECIMAL(18, 0) NOT NULL,
    model_description  NVARCHAR(50)   NOT NULL,
    CONSTRAINT PK_ProductModel PRIMARY KEY CLUSTERED (model_code)
);
GO

-- The source reuses only 10 product codes across 6,893 products; a code is
-- unique inside a subcategory (verified on the full data set).
CREATE TABLE CHIRIPIORCA.Product (
    product_id           INT IDENTITY(1, 1) NOT NULL,
    product_code         NVARCHAR(50)       NOT NULL,
    product_description  NVARCHAR(50)       NOT NULL,
    unit_price           DECIMAL(18, 2)     NOT NULL,
    subcategory_id       INT                NOT NULL,
    brand_id             INT                NOT NULL,
    model_code           DECIMAL(18, 0)     NOT NULL,
    CONSTRAINT PK_Product PRIMARY KEY CLUSTERED (product_id),
    CONSTRAINT FK_Product_Subcategory FOREIGN KEY (subcategory_id) REFERENCES CHIRIPIORCA.Subcategory (subcategory_id),
    CONSTRAINT FK_Product_Brand FOREIGN KEY (brand_id) REFERENCES CHIRIPIORCA.Brand (brand_id),
    CONSTRAINT FK_Product_ProductModel FOREIGN KEY (model_code) REFERENCES CHIRIPIORCA.ProductModel (model_code),
    CONSTRAINT UQ_Product_Code_Subcategory UNIQUE (product_code, subcategory_id),
    CONSTRAINT CK_Product_UnitPrice CHECK (unit_price >= 0)
);
GO

/* ---------------------------------------------------------------------------
   Warehouses and listings
   --------------------------------------------------------------------------- */
CREATE TABLE CHIRIPIORCA.Warehouse (
    warehouse_code  DECIMAL(18, 0) NOT NULL,
    street          NVARCHAR(50)   NOT NULL,
    street_number   DECIMAL(18, 0) NOT NULL,
    daily_cost      DECIMAL(18, 2) NOT NULL,
    city_id         INT            NOT NULL,
    CONSTRAINT PK_Warehouse PRIMARY KEY CLUSTERED (warehouse_code),
    CONSTRAINT FK_Warehouse_City FOREIGN KEY (city_id) REFERENCES CHIRIPIORCA.City (city_id),
    CONSTRAINT CK_Warehouse_DailyCost CHECK (daily_cost >= 0)
);
GO

CREATE TABLE CHIRIPIORCA.Listing (
    listing_code         DECIMAL(18, 0) NOT NULL,
    listing_description  NVARCHAR(50)   NOT NULL,
    start_date           DATE           NOT NULL,
    end_date             DATE           NOT NULL,
    initial_stock        DECIMAL(18, 0) NOT NULL,
    unit_price           DECIMAL(18, 2) NOT NULL,
    listing_cost         DECIMAL(18, 2) NOT NULL,
    sale_fee_rate        DECIMAL(18, 2) NOT NULL,
    product_id           INT            NOT NULL,
    seller_id            INT            NOT NULL,
    warehouse_code       DECIMAL(18, 0) NOT NULL,
    CONSTRAINT PK_Listing PRIMARY KEY CLUSTERED (listing_code),
    CONSTRAINT FK_Listing_Product FOREIGN KEY (product_id) REFERENCES CHIRIPIORCA.Product (product_id),
    CONSTRAINT FK_Listing_Seller FOREIGN KEY (seller_id) REFERENCES CHIRIPIORCA.Seller (seller_id),
    CONSTRAINT FK_Listing_Warehouse FOREIGN KEY (warehouse_code) REFERENCES CHIRIPIORCA.Warehouse (warehouse_code),
    CONSTRAINT CK_Listing_Dates CHECK (end_date >= start_date),
    CONSTRAINT CK_Listing_Stock CHECK (initial_stock >= 0),
    CONSTRAINT CK_Listing_SaleFeeRate CHECK (sale_fee_rate >= 0)
);
GO

/* ---------------------------------------------------------------------------
   Lookup tables
   --------------------------------------------------------------------------- */
CREATE TABLE CHIRIPIORCA.PaymentMethodType (
    payment_method_type_id  INT IDENTITY(1, 1) NOT NULL,
    type_name               NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_PaymentMethodType PRIMARY KEY CLUSTERED (payment_method_type_id),
    CONSTRAINT UQ_PaymentMethodType_Name UNIQUE (type_name)
);
GO

CREATE TABLE CHIRIPIORCA.PaymentMethod (
    payment_method_id       INT IDENTITY(1, 1) NOT NULL,
    method_name             NVARCHAR(50)       NOT NULL,
    payment_method_type_id  INT                NOT NULL,
    CONSTRAINT PK_PaymentMethod PRIMARY KEY CLUSTERED (payment_method_id),
    CONSTRAINT FK_PaymentMethod_PaymentMethodType FOREIGN KEY (payment_method_type_id)
        REFERENCES CHIRIPIORCA.PaymentMethodType (payment_method_type_id),
    CONSTRAINT UQ_PaymentMethod_Name UNIQUE (method_name)
);
GO

CREATE TABLE CHIRIPIORCA.ShippingType (
    shipping_type_id  INT IDENTITY(1, 1) NOT NULL,
    type_name         NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_ShippingType PRIMARY KEY CLUSTERED (shipping_type_id),
    CONSTRAINT UQ_ShippingType_Name UNIQUE (type_name)
);
GO

CREATE TABLE CHIRIPIORCA.InvoiceConcept (
    invoice_concept_id  INT IDENTITY(1, 1) NOT NULL,
    concept_name        NVARCHAR(50)       NOT NULL,
    CONSTRAINT PK_InvoiceConcept PRIMARY KEY CLUSTERED (invoice_concept_id),
    CONSTRAINT UQ_InvoiceConcept_Name UNIQUE (concept_name)
);
GO

/* ---------------------------------------------------------------------------
   Sales: header (Sale) 1..N lines (SaleDetail). The header does NOT point to a
   single line; the line points to its header.
   --------------------------------------------------------------------------- */
CREATE TABLE CHIRIPIORCA.Sale (
    sale_code     DECIMAL(18, 0) NOT NULL,
    customer_id   INT            NOT NULL,
    sale_date     DATE           NOT NULL,
    total_amount  DECIMAL(18, 2) NOT NULL,
    CONSTRAINT PK_Sale PRIMARY KEY CLUSTERED (sale_code),
    CONSTRAINT FK_Sale_Customer FOREIGN KEY (customer_id) REFERENCES CHIRIPIORCA.Customer (customer_id),
    CONSTRAINT CK_Sale_TotalAmount CHECK (total_amount >= 0)
);
GO

CREATE TABLE CHIRIPIORCA.SaleDetail (
    sale_detail_id  INT IDENTITY(1, 1) NOT NULL,
    sale_code       DECIMAL(18, 0)     NOT NULL,
    listing_code    DECIMAL(18, 0)     NOT NULL,
    quantity        DECIMAL(18, 0)     NOT NULL,
    unit_price      DECIMAL(18, 2)     NOT NULL,
    subtotal        DECIMAL(18, 2)     NOT NULL,
    CONSTRAINT PK_SaleDetail PRIMARY KEY CLUSTERED (sale_detail_id),
    CONSTRAINT FK_SaleDetail_Sale FOREIGN KEY (sale_code) REFERENCES CHIRIPIORCA.Sale (sale_code),
    CONSTRAINT FK_SaleDetail_Listing FOREIGN KEY (listing_code) REFERENCES CHIRIPIORCA.Listing (listing_code),
    CONSTRAINT CK_SaleDetail_Quantity CHECK (quantity > 0)
);
GO

-- One shipment per sale, delivered to one of the customer's addresses.
CREATE TABLE CHIRIPIORCA.Shipment (
    shipment_id        INT IDENTITY(1, 1) NOT NULL,
    sale_code          DECIMAL(18, 0)     NOT NULL,
    address_id         INT                NOT NULL,
    shipping_type_id   INT                NOT NULL,
    scheduled_date     DATE               NOT NULL,
    window_start_hour  DECIMAL(18, 0)     NOT NULL,
    window_end_hour    DECIMAL(18, 0)     NOT NULL,
    shipping_cost      DECIMAL(18, 2)     NOT NULL,
    delivered_at       DATETIME           NULL,
    CONSTRAINT PK_Shipment PRIMARY KEY CLUSTERED (shipment_id),
    CONSTRAINT FK_Shipment_Sale FOREIGN KEY (sale_code) REFERENCES CHIRIPIORCA.Sale (sale_code),
    CONSTRAINT FK_Shipment_Address FOREIGN KEY (address_id) REFERENCES CHIRIPIORCA.Address (address_id),
    CONSTRAINT FK_Shipment_ShippingType FOREIGN KEY (shipping_type_id) REFERENCES CHIRIPIORCA.ShippingType (shipping_type_id),
    CONSTRAINT UQ_Shipment_Sale UNIQUE (sale_code),
    CONSTRAINT CK_Shipment_Window CHECK (window_start_hour BETWEEN 0 AND 24
                                         AND window_end_hour BETWEEN 0 AND 24
                                         AND window_start_hour <= window_end_hour),
    CONSTRAINT CK_Shipment_Cost CHECK (shipping_cost >= 0)
);
GO

/* ---------------------------------------------------------------------------
   Payments: card data lives in a 1:0..1 subtype table, because only card
   payments carry it (statement, "Gestión de Pagos").
   --------------------------------------------------------------------------- */
CREATE TABLE CHIRIPIORCA.Payment (
    payment_id         INT IDENTITY(1, 1) NOT NULL,
    sale_code          DECIMAL(18, 0)     NOT NULL,
    payment_method_id  INT                NOT NULL,
    payment_date       DATE               NOT NULL,
    amount             DECIMAL(18, 2)     NOT NULL,
    CONSTRAINT PK_Payment PRIMARY KEY CLUSTERED (payment_id),
    CONSTRAINT FK_Payment_Sale FOREIGN KEY (sale_code) REFERENCES CHIRIPIORCA.Sale (sale_code),
    CONSTRAINT FK_Payment_PaymentMethod FOREIGN KEY (payment_method_id) REFERENCES CHIRIPIORCA.PaymentMethod (payment_method_id),
    CONSTRAINT CK_Payment_Amount CHECK (amount >= 0)
);
GO

CREATE TABLE CHIRIPIORCA.CardPaymentDetail (
    payment_id            INT            NOT NULL,
    card_number           NVARCHAR(50)   NOT NULL,
    card_expiration_date  DATE           NOT NULL,
    installments          DECIMAL(18, 0) NOT NULL,
    CONSTRAINT PK_CardPaymentDetail PRIMARY KEY CLUSTERED (payment_id),
    CONSTRAINT FK_CardPaymentDetail_Payment FOREIGN KEY (payment_id) REFERENCES CHIRIPIORCA.Payment (payment_id),
    CONSTRAINT CK_CardPaymentDetail_Installments CHECK (installments >= 1)
);
GO

/* ---------------------------------------------------------------------------
   Marketplace invoices to sellers: header 1..N lines, one line per concept
   (listing fee, sale commission, warehouse rental).
   --------------------------------------------------------------------------- */
CREATE TABLE CHIRIPIORCA.Invoice (
    invoice_number  DECIMAL(18, 0) NOT NULL,
    seller_id       INT            NOT NULL,
    invoice_date    DATE           NOT NULL,
    total_amount    DECIMAL(18, 2) NOT NULL,
    CONSTRAINT PK_Invoice PRIMARY KEY CLUSTERED (invoice_number),
    CONSTRAINT FK_Invoice_Seller FOREIGN KEY (seller_id) REFERENCES CHIRIPIORCA.Seller (seller_id),
    CONSTRAINT CK_Invoice_TotalAmount CHECK (total_amount >= 0)
);
GO

CREATE TABLE CHIRIPIORCA.InvoiceDetail (
    invoice_detail_id   INT IDENTITY(1, 1) NOT NULL,
    invoice_number      DECIMAL(18, 0)     NOT NULL,
    listing_code        DECIMAL(18, 0)     NOT NULL,
    invoice_concept_id  INT                NOT NULL,
    quantity            DECIMAL(18, 0)     NOT NULL,
    unit_price          DECIMAL(18, 2)     NOT NULL,
    subtotal            DECIMAL(18, 2)     NOT NULL,
    CONSTRAINT PK_InvoiceDetail PRIMARY KEY CLUSTERED (invoice_detail_id),
    CONSTRAINT FK_InvoiceDetail_Invoice FOREIGN KEY (invoice_number) REFERENCES CHIRIPIORCA.Invoice (invoice_number),
    CONSTRAINT FK_InvoiceDetail_Listing FOREIGN KEY (listing_code) REFERENCES CHIRIPIORCA.Listing (listing_code),
    CONSTRAINT FK_InvoiceDetail_InvoiceConcept FOREIGN KEY (invoice_concept_id)
        REFERENCES CHIRIPIORCA.InvoiceConcept (invoice_concept_id),
    CONSTRAINT CK_InvoiceDetail_Quantity CHECK (quantity > 0)
);
GO

/* ---------- src/transactional/02_migration_procedures.sql ---------- */
/* =============================================================================
   02_migration_procedures.sql
   One stored procedure per aggregate, all set-based (no cursors, no row-by-row
   loops, no scalar UDFs). Procedures do not manage transactions themselves:
   CHIRIPIORCA.usp_RunMigration wraps all of them in a single transaction, so
   the migration is all-or-nothing. SET XACT_ABORT ON in every procedure makes
   any run-time error doom that transaction instead of leaving it half-applied.

   Source rows in gd_esquema.Maestra come in three disjoint shapes (verified on
   the 242,108 rows of the data set):
     - listing rows  (34,629): listing + seller + product + warehouse
     - sale rows    (103,592): sale + one line + customer + shipment + payment
     - invoice rows (103,887): one invoice line + listing code
   Each procedure filters on the column that identifies its shape.
   ============================================================================= */
USE GD2C2024;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ---------------------------------------------------------------------------
   Geography
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateProvinces
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- CROSS APPLY (VALUES ...) unpivots the three province columns in a single
    -- scan of Maestra, instead of three scans glued together with UNION.
    INSERT INTO CHIRIPIORCA.Province (province_name)
    SELECT DISTINCT src.province_name
    FROM gd_esquema.Maestra AS m
    CROSS APPLY (VALUES (m.ALMACEN_PROVINCIA),
                        (m.CLI_USUARIO_DOMICILIO_PROVINCIA),
                        (m.VEN_USUARIO_DOMICILIO_PROVINCIA)) AS src (province_name)
    WHERE src.province_name IS NOT NULL;
END;
GO

CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateCities
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO CHIRIPIORCA.City (province_id, city_name)
    SELECT DISTINCT p.province_id, src.city_name
    FROM gd_esquema.Maestra AS m
    CROSS APPLY (VALUES (m.ALMACEN_Localidad,                m.ALMACEN_PROVINCIA),
                        (m.CLI_USUARIO_DOMICILIO_LOCALIDAD,  m.CLI_USUARIO_DOMICILIO_PROVINCIA),
                        (m.VEN_USUARIO_DOMICILIO_LOCALIDAD,  m.VEN_USUARIO_DOMICILIO_PROVINCIA)) AS src (city_name, province_name)
    JOIN CHIRIPIORCA.Province AS p
      ON p.province_name = src.province_name
    WHERE src.city_name IS NOT NULL;
END;
GO

/* ---------------------------------------------------------------------------
   Customers: user account + customer role + addresses
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateCustomers
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- 1) One row per distinct customer (with its user account data).
    CREATE TABLE #customer_source (
        source_row_id  INT IDENTITY(1, 1) PRIMARY KEY,
        dni            DECIMAL(18, 0) NOT NULL,
        first_name     NVARCHAR(50)   NOT NULL,
        last_name      NVARCHAR(50)   NOT NULL,
        birth_date     DATE           NOT NULL,
        email          NVARCHAR(50)   NOT NULL,
        username       NVARCHAR(50)   NOT NULL,
        user_password  NVARCHAR(50)   NOT NULL,
        created_on     DATE           NOT NULL
    );

    INSERT INTO #customer_source (dni, first_name, last_name, birth_date, email,
                                  username, user_password, created_on)
    SELECT DISTINCT m.CLIENTE_DNI, m.CLIENTE_NOMBRE, m.CLIENTE_APELLIDO, m.CLIENTE_FECHA_NAC, m.CLIENTE_MAIL,
                    m.CLI_USUARIO_NOMBRE, m.CLI_USUARIO_PASS, m.CLI_USUARIO_FECHA_CREACION
    FROM gd_esquema.Maestra AS m
    WHERE m.CLIENTE_DNI IS NOT NULL;

    -- 2) Create the user accounts and capture "source row -> new user_id".
    --    MERGE ... ON 1 = 0 is used only because, unlike INSERT, its OUTPUT
    --    clause can return columns of the source next to the generated identity.
    CREATE TABLE #user_map (
        source_row_id  INT NOT NULL PRIMARY KEY,
        user_id        INT NOT NULL
    );

    MERGE CHIRIPIORCA.UserAccount AS tgt
    USING #customer_source AS src
       ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (username, user_password, created_on)
        VALUES (src.username, src.user_password, src.created_on)
    OUTPUT src.source_row_id, inserted.user_id
      INTO #user_map (source_row_id, user_id);

    -- 3) Customer role.
    INSERT INTO CHIRIPIORCA.Customer (user_id, dni, first_name, last_name, birth_date, email)
    SELECT um.user_id, cs.dni, cs.first_name, cs.last_name, cs.birth_date, cs.email
    FROM #customer_source AS cs
    JOIN #user_map AS um
      ON um.source_row_id = cs.source_row_id;

    -- 4) Addresses: resolved separately so a customer with several addresses
    --    keeps all of them under the same user account.
    INSERT INTO CHIRIPIORCA.Address (user_id, street, street_number, floor_number, apartment, postal_code, city_id)
    SELECT DISTINCT c.user_id,
           m.CLI_USUARIO_DOMICILIO_CALLE, m.CLI_USUARIO_DOMICILIO_NRO_CALLE, m.CLI_USUARIO_DOMICILIO_PISO,
           m.CLI_USUARIO_DOMICILIO_DEPTO, m.CLI_USUARIO_DOMICILIO_CP, ci.city_id
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.Customer AS c
      ON  c.dni        = m.CLIENTE_DNI
      AND c.last_name  = m.CLIENTE_APELLIDO
      AND c.first_name = m.CLIENTE_NOMBRE
    JOIN CHIRIPIORCA.Province AS p
      ON p.province_name = m.CLI_USUARIO_DOMICILIO_PROVINCIA
    JOIN CHIRIPIORCA.City AS ci
      ON  ci.province_id = p.province_id
      AND ci.city_name   = m.CLI_USUARIO_DOMICILIO_LOCALIDAD
    WHERE m.CLIENTE_DNI IS NOT NULL;
END;
GO

/* ---------------------------------------------------------------------------
   Sellers: user account + seller role + addresses
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateSellers
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #seller_source (
        source_row_id  INT IDENTITY(1, 1) PRIMARY KEY,
        cuit           NVARCHAR(50) NOT NULL,
        business_name  NVARCHAR(50) NOT NULL,
        email          NVARCHAR(50) NOT NULL,
        username       NVARCHAR(50) NOT NULL,
        user_password  NVARCHAR(50) NOT NULL,
        created_on     DATE         NOT NULL
    );

    INSERT INTO #seller_source (cuit, business_name, email, username, user_password, created_on)
    SELECT DISTINCT m.VENDEDOR_CUIT, m.VENDEDOR_RAZON_SOCIAL, m.VENDEDOR_MAIL,
                    m.VEN_USUARIO_NOMBRE, m.VEN_USUARIO_PASS, m.VEN_USUARIO_FECHA_CREACION
    FROM gd_esquema.Maestra AS m
    WHERE m.VENDEDOR_CUIT IS NOT NULL;

    CREATE TABLE #user_map (
        source_row_id  INT NOT NULL PRIMARY KEY,
        user_id        INT NOT NULL
    );

    MERGE CHIRIPIORCA.UserAccount AS tgt
    USING #seller_source AS src
       ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (username, user_password, created_on)
        VALUES (src.username, src.user_password, src.created_on)
    OUTPUT src.source_row_id, inserted.user_id
      INTO #user_map (source_row_id, user_id);

    INSERT INTO CHIRIPIORCA.Seller (user_id, cuit, business_name, email)
    SELECT um.user_id, ss.cuit, ss.business_name, ss.email
    FROM #seller_source AS ss
    JOIN #user_map AS um
      ON um.source_row_id = ss.source_row_id;

    INSERT INTO CHIRIPIORCA.Address (user_id, street, street_number, floor_number, apartment, postal_code, city_id)
    SELECT DISTINCT s.user_id,
           m.VEN_USUARIO_DOMICILIO_CALLE, m.VEN_USUARIO_DOMICILIO_NRO_CALLE, m.VEN_USUARIO_DOMICILIO_PISO,
           m.VEN_USUARIO_DOMICILIO_DEPTO, m.VEN_USUARIO_DOMICILIO_CP, ci.city_id
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.Seller AS s
      ON s.cuit = m.VENDEDOR_CUIT
    JOIN CHIRIPIORCA.Province AS p
      ON p.province_name = m.VEN_USUARIO_DOMICILIO_PROVINCIA
    JOIN CHIRIPIORCA.City AS ci
      ON  ci.province_id = p.province_id
      AND ci.city_name   = m.VEN_USUARIO_DOMICILIO_LOCALIDAD
    WHERE m.VENDEDOR_CUIT IS NOT NULL;
END;
GO

/* ---------------------------------------------------------------------------
   Product catalog
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateCatalog
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO CHIRIPIORCA.Category (category_name)
    SELECT DISTINCT m.PRODUCTO_RUBRO_DESCRIPCION
    FROM gd_esquema.Maestra AS m
    WHERE m.PRODUCTO_RUBRO_DESCRIPCION IS NOT NULL;

    INSERT INTO CHIRIPIORCA.Subcategory (category_id, subcategory_name)
    SELECT DISTINCT c.category_id, m.PRODUCTO_SUB_RUBRO
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.Category AS c
      ON c.category_name = m.PRODUCTO_RUBRO_DESCRIPCION
    WHERE m.PRODUCTO_SUB_RUBRO IS NOT NULL;

    INSERT INTO CHIRIPIORCA.Brand (brand_name)
    SELECT DISTINCT m.PRODUCTO_MARCA
    FROM gd_esquema.Maestra AS m
    WHERE m.PRODUCTO_MARCA IS NOT NULL;

    INSERT INTO CHIRIPIORCA.ProductModel (model_code, model_description)
    SELECT DISTINCT m.PRODUCTO_MOD_CODIGO, m.PRODUCTO_MOD_DESCRIPCION
    FROM gd_esquema.Maestra AS m
    WHERE m.PRODUCTO_MOD_CODIGO IS NOT NULL;

    INSERT INTO CHIRIPIORCA.Product (product_code, product_description, unit_price,
                                     subcategory_id, brand_id, model_code)
    SELECT DISTINCT m.PRODUCTO_CODIGO, m.PRODUCTO_DESCRIPCION, m.PRODUCTO_PRECIO,
                    sc.subcategory_id, b.brand_id, m.PRODUCTO_MOD_CODIGO
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.Category AS c
      ON c.category_name = m.PRODUCTO_RUBRO_DESCRIPCION
    JOIN CHIRIPIORCA.Subcategory AS sc
      ON  sc.category_id      = c.category_id
      AND sc.subcategory_name = m.PRODUCTO_SUB_RUBRO
    JOIN CHIRIPIORCA.Brand AS b
      ON b.brand_name = m.PRODUCTO_MARCA
    WHERE m.PRODUCTO_CODIGO IS NOT NULL;
END;
GO

/* ---------------------------------------------------------------------------
   Warehouses and listings
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateWarehouses
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO CHIRIPIORCA.Warehouse (warehouse_code, street, street_number, daily_cost, city_id)
    SELECT DISTINCT m.ALMACEN_CODIGO, m.ALMACEN_CALLE, m.ALMACEN_NRO_CALLE, m.ALMACEN_COSTO_DIA_AL, ci.city_id
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.Province AS p
      ON p.province_name = m.ALMACEN_PROVINCIA
    JOIN CHIRIPIORCA.City AS ci
      ON  ci.province_id = p.province_id
      AND ci.city_name   = m.ALMACEN_Localidad
    WHERE m.ALMACEN_CODIGO IS NOT NULL;
END;
GO

CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateListings
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Only listing rows carry seller/product/warehouse: VENDEDOR_CUIT IS NOT NULL
    -- selects exactly one row per listing, so no fan-out is possible.
    INSERT INTO CHIRIPIORCA.Listing WITH (TABLOCK)
           (listing_code, listing_description, start_date, end_date, initial_stock, unit_price,
            listing_cost, sale_fee_rate, product_id, seller_id, warehouse_code)
    SELECT DISTINCT m.PUBLICACION_CODIGO, m.PUBLICACION_DESCRIPCION, m.PUBLICACION_FECHA, m.PUBLICACION_FECHA_V,
                    m.PUBLICACION_STOCK, m.PUBLICACION_PRECIO, m.PUBLICACION_COSTO, m.PUBLICACION_PORC_VENTA,
                    pr.product_id, s.seller_id, m.ALMACEN_CODIGO
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.Seller AS s
      ON s.cuit = m.VENDEDOR_CUIT
    JOIN CHIRIPIORCA.Category AS c
      ON c.category_name = m.PRODUCTO_RUBRO_DESCRIPCION
    JOIN CHIRIPIORCA.Subcategory AS sc
      ON  sc.category_id      = c.category_id
      AND sc.subcategory_name = m.PRODUCTO_SUB_RUBRO
    JOIN CHIRIPIORCA.Product AS pr
      ON  pr.product_code   = m.PRODUCTO_CODIGO
      AND pr.subcategory_id = sc.subcategory_id
    WHERE m.VENDEDOR_CUIT IS NOT NULL
      AND m.PUBLICACION_CODIGO IS NOT NULL;
END;
GO

/* ---------------------------------------------------------------------------
   Lookup tables used by sales and invoices
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateLookups
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO CHIRIPIORCA.PaymentMethodType (type_name)
    SELECT DISTINCT m.PAGO_TIPO_MEDIO_PAGO
    FROM gd_esquema.Maestra AS m
    WHERE m.PAGO_TIPO_MEDIO_PAGO IS NOT NULL;

    INSERT INTO CHIRIPIORCA.PaymentMethod (method_name, payment_method_type_id)
    SELECT DISTINCT m.PAGO_MEDIO_PAGO, pmt.payment_method_type_id
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.PaymentMethodType AS pmt
      ON pmt.type_name = m.PAGO_TIPO_MEDIO_PAGO
    WHERE m.PAGO_MEDIO_PAGO IS NOT NULL;

    INSERT INTO CHIRIPIORCA.ShippingType (type_name)
    SELECT DISTINCT m.ENVIO_TIPO
    FROM gd_esquema.Maestra AS m
    WHERE m.ENVIO_TIPO IS NOT NULL;

    INSERT INTO CHIRIPIORCA.InvoiceConcept (concept_name)
    SELECT DISTINCT m.FACTURA_DET_TIPO
    FROM gd_esquema.Maestra AS m
    WHERE m.FACTURA_DET_TIPO IS NOT NULL;
END;
GO

/* ---------------------------------------------------------------------------
   Sales, lines, shipments and payments
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateSales
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO CHIRIPIORCA.Sale WITH (TABLOCK) (sale_code, customer_id, sale_date, total_amount)
    SELECT DISTINCT m.VENTA_CODIGO, c.customer_id, m.VENTA_FECHA, m.VENTA_TOTAL
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.Customer AS c
      ON  c.dni        = m.CLIENTE_DNI
      AND c.last_name  = m.CLIENTE_APELLIDO
      AND c.first_name = m.CLIENTE_NOMBRE
    WHERE m.VENTA_CODIGO IS NOT NULL;

    -- Natural keys (sale and listing codes) are the foreign keys: no lookup join.
    INSERT INTO CHIRIPIORCA.SaleDetail WITH (TABLOCK) (sale_code, listing_code, quantity, unit_price, subtotal)
    SELECT m.VENTA_CODIGO, m.PUBLICACION_CODIGO, m.VENTA_DET_CANT, m.VENTA_DET_PRECIO, m.VENTA_DET_SUB_TOTAL
    FROM gd_esquema.Maestra AS m
    WHERE m.VENTA_CODIGO IS NOT NULL
      AND m.VENTA_DET_CANT IS NOT NULL;
END;
GO

CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateShipments
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- The delivery address is the customer's address that appears in the row.
    INSERT INTO CHIRIPIORCA.Shipment WITH (TABLOCK)
           (sale_code, address_id, shipping_type_id, scheduled_date, window_start_hour,
            window_end_hour, shipping_cost, delivered_at)
    SELECT DISTINCT m.VENTA_CODIGO, a.address_id, st.shipping_type_id, m.ENVIO_FECHA_PROGAMADA,
                    m.ENVIO_HORA_INICIO, m.ENVIO_HORA_FIN_INICIO, m.ENVIO_COSTO, m.ENVIO_FECHA_ENTREGA
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.ShippingType AS st
      ON st.type_name = m.ENVIO_TIPO
    JOIN CHIRIPIORCA.Customer AS c
      ON  c.dni        = m.CLIENTE_DNI
      AND c.last_name  = m.CLIENTE_APELLIDO
      AND c.first_name = m.CLIENTE_NOMBRE
    JOIN CHIRIPIORCA.Province AS p
      ON p.province_name = m.CLI_USUARIO_DOMICILIO_PROVINCIA
    JOIN CHIRIPIORCA.City AS ci
      ON  ci.province_id = p.province_id
      AND ci.city_name   = m.CLI_USUARIO_DOMICILIO_LOCALIDAD
    JOIN CHIRIPIORCA.Address AS a
      ON  a.user_id       = c.user_id
      AND a.city_id       = ci.city_id
      AND a.street        = m.CLI_USUARIO_DOMICILIO_CALLE
      AND a.street_number = m.CLI_USUARIO_DOMICILIO_NRO_CALLE
    WHERE m.VENTA_CODIGO IS NOT NULL
      AND m.ENVIO_TIPO IS NOT NULL;
END;
GO

CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigratePayments
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #card_detail (
        payment_id            INT            NOT NULL PRIMARY KEY,
        card_number           NVARCHAR(50)   NULL,
        card_expiration_date  DATE           NULL,
        installments          DECIMAL(18, 0) NULL
    );

    -- The payment method is resolved by its own name. (The original script
    -- joined by payment *type* and kept MIN(id), assigning the wrong method.)
    -- MERGE is used for its OUTPUT clause: the card columns of each source row
    -- are captured next to the new payment_id. OUTPUT cannot write straight to
    -- CardPaymentDetail because a table referenced by a foreign key cannot be
    -- an OUTPUT INTO target.
    MERGE CHIRIPIORCA.Payment AS tgt
    USING (
        SELECT m.VENTA_CODIGO, pm.payment_method_id, m.PAGO_FECHA, m.PAGO_IMPORTE,
               m.PAGO_NRO_TARJETA, m.PAGO_FECHA_VENC_TARJETA, m.PAGO_CANT_CUOTAS
        FROM gd_esquema.Maestra AS m
        JOIN CHIRIPIORCA.PaymentMethod AS pm
          ON pm.method_name = m.PAGO_MEDIO_PAGO
        WHERE m.VENTA_CODIGO IS NOT NULL
          AND m.PAGO_IMPORTE IS NOT NULL
    ) AS src (sale_code, payment_method_id, payment_date, amount,
              card_number, card_expiration_date, installments)
       ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (sale_code, payment_method_id, payment_date, amount)
        VALUES (src.sale_code, src.payment_method_id, src.payment_date, src.amount)
    OUTPUT inserted.payment_id, src.card_number, src.card_expiration_date, src.installments
      INTO #card_detail (payment_id, card_number, card_expiration_date, installments);

    INSERT INTO CHIRIPIORCA.CardPaymentDetail (payment_id, card_number, card_expiration_date, installments)
    SELECT cd.payment_id, cd.card_number, cd.card_expiration_date, cd.installments
    FROM #card_detail AS cd
    WHERE cd.card_number IS NOT NULL;
END;
GO

/* ---------------------------------------------------------------------------
   Invoices
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_MigrateInvoices
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Invoice rows carry no seller data: the invoiced user is the seller that
    -- owns the invoiced listing.
    INSERT INTO CHIRIPIORCA.Invoice WITH (TABLOCK) (invoice_number, seller_id, invoice_date, total_amount)
    SELECT DISTINCT m.FACTURA_NUMERO, l.seller_id, m.FACTURA_FECHA, m.FACTURA_TOTAL
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.Listing AS l
      ON l.listing_code = m.PUBLICACION_CODIGO
    WHERE m.FACTURA_NUMERO IS NOT NULL;

    -- Every line is kept (3 per invoice). The original model stored a single
    -- MIN(detail id) per invoice and lost the other two concepts.
    INSERT INTO CHIRIPIORCA.InvoiceDetail WITH (TABLOCK)
           (invoice_number, listing_code, invoice_concept_id, quantity, unit_price, subtotal)
    SELECT m.FACTURA_NUMERO, m.PUBLICACION_CODIGO, ic.invoice_concept_id,
           m.FACTURA_DET_CANTIDAD, m.FACTURA_DET_PRECIO, m.FACTURA_DET_SUBTOTAL
    FROM gd_esquema.Maestra AS m
    JOIN CHIRIPIORCA.InvoiceConcept AS ic
      ON ic.concept_name = m.FACTURA_DET_TIPO
    WHERE m.FACTURA_NUMERO IS NOT NULL;
END;
GO

/* ---------------------------------------------------------------------------
   Orchestrator: runs every step in dependency order inside ONE transaction.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE CHIRIPIORCA.usp_RunMigration
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @execution_id INT;

    INSERT INTO CHIRIPIORCA.ExecutionLog (process_name, started_at, status)
    VALUES (N'usp_RunMigration', SYSDATETIME(), 'RUNNING');
    SET @execution_id = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC CHIRIPIORCA.usp_MigrateProvinces;
        EXEC CHIRIPIORCA.usp_MigrateCities;
        EXEC CHIRIPIORCA.usp_MigrateCustomers;
        EXEC CHIRIPIORCA.usp_MigrateSellers;
        EXEC CHIRIPIORCA.usp_MigrateCatalog;
        EXEC CHIRIPIORCA.usp_MigrateWarehouses;
        EXEC CHIRIPIORCA.usp_MigrateListings;
        EXEC CHIRIPIORCA.usp_MigrateLookups;
        EXEC CHIRIPIORCA.usp_MigrateSales;
        EXEC CHIRIPIORCA.usp_MigrateShipments;
        EXEC CHIRIPIORCA.usp_MigratePayments;
        EXEC CHIRIPIORCA.usp_MigrateInvoices;

        COMMIT TRANSACTION;

        UPDATE CHIRIPIORCA.ExecutionLog
        SET finished_at = SYSDATETIME(), status = 'SUCCEEDED'
        WHERE execution_id = @execution_id;
    END TRY
    BEGIN CATCH
        -- XACT_STATE(): -1 = doomed, 1 = committable, 0 = none. Under
        -- XACT_ABORT it is -1 after any error; either way nothing partial may
        -- survive, so any open transaction is rolled back.
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        -- Logged after the rollback, otherwise the log row would be undone too.
        UPDATE CHIRIPIORCA.ExecutionLog
        SET finished_at   = SYSDATETIME(),
            status        = 'FAILED',
            error_number  = ERROR_NUMBER(),
            error_message = CONCAT(ERROR_PROCEDURE(), N' (line ', ERROR_LINE(), N'): ', ERROR_MESSAGE())
        WHERE execution_id = @execution_id;

        THROW;  -- re-raise with the original number, message and line
    END CATCH;
END;
GO

/* ---------- src/transactional/03_run_migration.sql ---------- */
/* =============================================================================
   03_run_migration.sql
   Executes the whole migration as a single atomic unit of work.
   Nonclustered indexes are created afterwards (04_indexes.sql): building an
   index once over loaded data is a single sort, while maintaining it during
   ~350k inserts costs one B-tree insertion per row and per index.
   ============================================================================= */
USE GD2C2024;
GO

EXEC CHIRIPIORCA.usp_RunMigration;
GO

/* ---------- src/transactional/04_indexes.sql ---------- */
/* =============================================================================
   04_indexes.sql
   Nonclustered indexes that support foreign keys and the access paths used by
   the BI load. Primary keys and UNIQUE constraints already provide indexes for
   their own columns (e.g. UQ_City_Province_Name serves City.province_id as its
   leading column), so they are not duplicated here.

   INCLUDE columns make the index "covering": the query reads everything it
   needs from the narrow index leaf and skips the key lookup into the
   clustered index (one random page read per row saved).
   ============================================================================= */
USE GD2C2024;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Addresses by owner (customer/seller location in the BI load) and by city.
CREATE NONCLUSTERED INDEX IX_Address_User ON CHIRIPIORCA.Address (user_id) INCLUDE (city_id);
CREATE NONCLUSTERED INDEX IX_Address_City ON CHIRIPIORCA.Address (city_id);

-- Catalog navigation: products per subcategory / brand.
CREATE NONCLUSTERED INDEX IX_Product_Subcategory ON CHIRIPIORCA.Product (subcategory_id);
CREATE NONCLUSTERED INDEX IX_Product_Brand       ON CHIRIPIORCA.Product (brand_id);

CREATE NONCLUSTERED INDEX IX_Warehouse_City ON CHIRIPIORCA.Warehouse (city_id);

-- Listings per product, per seller and per warehouse.
CREATE NONCLUSTERED INDEX IX_Listing_Product   ON CHIRIPIORCA.Listing (product_id);
CREATE NONCLUSTERED INDEX IX_Listing_Seller    ON CHIRIPIORCA.Listing (seller_id);
CREATE NONCLUSTERED INDEX IX_Listing_Warehouse ON CHIRIPIORCA.Listing (warehouse_code);

CREATE NONCLUSTERED INDEX IX_PaymentMethod_Type ON CHIRIPIORCA.PaymentMethod (payment_method_type_id);

-- A customer's sales, covering the date and amount used by reports.
CREATE NONCLUSTERED INDEX IX_Sale_Customer ON CHIRIPIORCA.Sale (customer_id)
    INCLUDE (sale_date, total_amount);

-- Lines of a sale (header -> lines join), covering the measures.
CREATE NONCLUSTERED INDEX IX_SaleDetail_Sale ON CHIRIPIORCA.SaleDetail (sale_code)
    INCLUDE (listing_code, quantity, subtotal);
CREATE NONCLUSTERED INDEX IX_SaleDetail_Listing ON CHIRIPIORCA.SaleDetail (listing_code);

CREATE NONCLUSTERED INDEX IX_Shipment_Address      ON CHIRIPIORCA.Shipment (address_id);
CREATE NONCLUSTERED INDEX IX_Shipment_ShippingType ON CHIRIPIORCA.Shipment (shipping_type_id);

CREATE NONCLUSTERED INDEX IX_Payment_Sale ON CHIRIPIORCA.Payment (sale_code)
    INCLUDE (payment_method_id, payment_date, amount);
CREATE NONCLUSTERED INDEX IX_Payment_PaymentMethod ON CHIRIPIORCA.Payment (payment_method_id);

CREATE NONCLUSTERED INDEX IX_Invoice_Seller ON CHIRIPIORCA.Invoice (seller_id)
    INCLUDE (invoice_date, total_amount);

CREATE NONCLUSTERED INDEX IX_InvoiceDetail_Invoice ON CHIRIPIORCA.InvoiceDetail (invoice_number)
    INCLUDE (invoice_concept_id, subtotal);
CREATE NONCLUSTERED INDEX IX_InvoiceDetail_Listing ON CHIRIPIORCA.InvoiceDetail (listing_code);
CREATE NONCLUSTERED INDEX IX_InvoiceDetail_Concept ON CHIRIPIORCA.InvoiceDetail (invoice_concept_id);
GO

-- Fresh statistics after the bulk load, so the optimizer's row estimates for
-- the BI load reflect the real data instead of the empty tables.
EXEC sys.sp_executesql N'
    DECLARE @sql NVARCHAR(MAX);
    SELECT @sql = STRING_AGG(CAST(N''UPDATE STATISTICS CHIRIPIORCA.'' + QUOTENAME(t.name) + N'' WITH FULLSCAN'' AS NVARCHAR(MAX)), N'';'')
    FROM sys.tables AS t
    WHERE t.schema_id = SCHEMA_ID(N''CHIRIPIORCA'') AND t.name NOT LIKE N''BI[_]%'';
    EXEC sys.sp_executesql @sql;';
GO
