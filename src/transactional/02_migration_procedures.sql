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
