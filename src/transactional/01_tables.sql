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
