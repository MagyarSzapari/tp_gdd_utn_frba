/* =============================================================================
   verify_transactional.sql
   Post-migration checks. Run after script_creacion_inicial.sql.

   Two kinds of checks:
   - Row counts against values profiled from the full gd_esquema.Maestra data
     set (242,108 rows, 2C2024).
   - Reconciliations computed at run time against gd_esquema.Maestra: money
     totals must match to the cent (the original DECIMAL(18,0) columns lost
     the cents) and every source row must land in exactly one target row.

   The script ends with THROW if any check fails, so `sqlcmd -b` returns a
   non-zero exit code and the check can run unattended.
   ============================================================================= */
USE GD2C2024;
GO

SET NOCOUNT ON;

DECLARE @checks TABLE (
    check_name  NVARCHAR(100)  NOT NULL,
    expected    DECIMAL(18, 2) NOT NULL,
    actual      DECIMAL(18, 2) NULL
);

/* ---- Row counts (profiled) ---- */
INSERT INTO @checks (check_name, expected, actual)
VALUES (N'Province rows',          24,     (SELECT COUNT(*) FROM CHIRIPIORCA.Province)),
       (N'City rows',              16918,  (SELECT COUNT(*) FROM CHIRIPIORCA.City)),
       (N'UserAccount rows',       41387,  (SELECT COUNT(*) FROM CHIRIPIORCA.UserAccount)),
       (N'Address rows',           41387,  (SELECT COUNT(*) FROM CHIRIPIORCA.Address)),
       (N'Customer rows',          41298,  (SELECT COUNT(*) FROM CHIRIPIORCA.Customer)),
       (N'Seller rows',            89,     (SELECT COUNT(*) FROM CHIRIPIORCA.Seller)),
       (N'Category rows',          22,     (SELECT COUNT(*) FROM CHIRIPIORCA.Category)),
       (N'Subcategory rows',       815,    (SELECT COUNT(*) FROM CHIRIPIORCA.Subcategory)),
       (N'Brand rows',             4,      (SELECT COUNT(*) FROM CHIRIPIORCA.Brand)),
       (N'ProductModel rows',      7,      (SELECT COUNT(*) FROM CHIRIPIORCA.ProductModel)),
       (N'Product rows',           6893,   (SELECT COUNT(*) FROM CHIRIPIORCA.Product)),
       (N'Warehouse rows',         68,     (SELECT COUNT(*) FROM CHIRIPIORCA.Warehouse)),
       (N'Listing rows',           34629,  (SELECT COUNT(*) FROM CHIRIPIORCA.Listing)),
       (N'PaymentMethodType rows', 2,      (SELECT COUNT(*) FROM CHIRIPIORCA.PaymentMethodType)),
       (N'PaymentMethod rows',     5,      (SELECT COUNT(*) FROM CHIRIPIORCA.PaymentMethod)),
       (N'ShippingType rows',      3,      (SELECT COUNT(*) FROM CHIRIPIORCA.ShippingType)),
       (N'InvoiceConcept rows',    3,      (SELECT COUNT(*) FROM CHIRIPIORCA.InvoiceConcept)),
       (N'Sale rows',              103592, (SELECT COUNT(*) FROM CHIRIPIORCA.Sale)),
       (N'SaleDetail rows',        103592, (SELECT COUNT(*) FROM CHIRIPIORCA.SaleDetail)),
       (N'Shipment rows',          103592, (SELECT COUNT(*) FROM CHIRIPIORCA.Shipment)),
       (N'Payment rows',           103592, (SELECT COUNT(*) FROM CHIRIPIORCA.Payment)),
       (N'CardPaymentDetail rows', 103592, (SELECT COUNT(*) FROM CHIRIPIORCA.CardPaymentDetail)),
       (N'Invoice rows',           34629,  (SELECT COUNT(*) FROM CHIRIPIORCA.Invoice)),
       (N'InvoiceDetail rows',     103887, (SELECT COUNT(*) FROM CHIRIPIORCA.InvoiceDetail));

/* ---- Money reconciliation against the source (to the cent) ---- */
INSERT INTO @checks (check_name, expected, actual)
SELECT N'Sale.total_amount sum',
       (SELECT SUM(VENTA_TOTAL) FROM gd_esquema.Maestra WHERE VENTA_CODIGO IS NOT NULL),
       (SELECT SUM(total_amount) FROM CHIRIPIORCA.Sale)
UNION ALL
SELECT N'SaleDetail.subtotal sum',
       (SELECT SUM(VENTA_DET_SUB_TOTAL) FROM gd_esquema.Maestra WHERE VENTA_CODIGO IS NOT NULL),
       (SELECT SUM(subtotal) FROM CHIRIPIORCA.SaleDetail)
UNION ALL
SELECT N'Payment.amount sum',
       (SELECT SUM(PAGO_IMPORTE) FROM gd_esquema.Maestra WHERE PAGO_IMPORTE IS NOT NULL),
       (SELECT SUM(amount) FROM CHIRIPIORCA.Payment)
UNION ALL
SELECT N'Shipment.shipping_cost sum',
       (SELECT SUM(ENVIO_COSTO) FROM gd_esquema.Maestra WHERE ENVIO_TIPO IS NOT NULL),
       (SELECT SUM(shipping_cost) FROM CHIRIPIORCA.Shipment)
UNION ALL
SELECT N'InvoiceDetail.subtotal sum',
       (SELECT SUM(FACTURA_DET_SUBTOTAL) FROM gd_esquema.Maestra WHERE FACTURA_NUMERO IS NOT NULL),
       (SELECT SUM(subtotal) FROM CHIRIPIORCA.InvoiceDetail)
UNION ALL
SELECT N'Listing.sale_fee_rate sum (cents kept)',
       (SELECT SUM(PUBLICACION_PORC_VENTA) FROM gd_esquema.Maestra WHERE VENDEDOR_CUIT IS NOT NULL),
       (SELECT SUM(sale_fee_rate) FROM CHIRIPIORCA.Listing);

/* ---- Referential sanity not expressible as a foreign key ---- */
INSERT INTO @checks (check_name, expected, actual)
SELECT N'Shipments delivered to an address of the buyer', 0,
       (SELECT COUNT(*)
        FROM CHIRIPIORCA.Shipment AS sh
        JOIN CHIRIPIORCA.Sale     AS s ON s.sale_code   = sh.sale_code
        JOIN CHIRIPIORCA.Customer AS c ON c.customer_id = s.customer_id
        JOIN CHIRIPIORCA.Address  AS a ON a.address_id  = sh.address_id
        WHERE a.user_id <> c.user_id)
UNION ALL
SELECT N'Invoices billed to the listing owner', 0,
       (SELECT COUNT(*)
        FROM CHIRIPIORCA.InvoiceDetail AS idt
        JOIN CHIRIPIORCA.Invoice AS i ON i.invoice_number = idt.invoice_number
        JOIN CHIRIPIORCA.Listing AS l ON l.listing_code   = idt.listing_code
        WHERE l.seller_id <> i.seller_id)
UNION ALL
SELECT N'Payments whose method differs from the source', 0,
       (SELECT COUNT(*)
        FROM gd_esquema.Maestra AS m
        JOIN CHIRIPIORCA.Payment AS p ON p.sale_code = m.VENTA_CODIGO
        JOIN CHIRIPIORCA.PaymentMethod AS pm ON pm.payment_method_id = p.payment_method_id
        WHERE m.PAGO_IMPORTE IS NOT NULL
          AND pm.method_name <> m.PAGO_MEDIO_PAGO)
UNION ALL
SELECT N'Last migration run succeeded', 1,
       (SELECT TOP (1) CASE WHEN status = 'SUCCEEDED' THEN 1 ELSE 0 END
        FROM CHIRIPIORCA.ExecutionLog
        WHERE process_name = N'usp_RunMigration'
        ORDER BY execution_id DESC);

SELECT check_name, expected, actual,
       CASE WHEN actual = expected THEN 'PASS' ELSE 'FAIL' END AS result
FROM @checks
ORDER BY result, check_name;

IF EXISTS (SELECT 1 FROM @checks WHERE actual IS NULL OR actual <> expected)
    THROW 50010, N'verify_transactional: one or more checks failed (see result set).', 1;
ELSE
    PRINT N'verify_transactional: all checks passed.';
GO
