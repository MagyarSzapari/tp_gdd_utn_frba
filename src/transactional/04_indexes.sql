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
