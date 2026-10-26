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
