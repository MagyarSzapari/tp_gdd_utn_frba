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
