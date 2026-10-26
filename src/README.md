# src — Versión refactorizada (T-SQL, SQL Server 2019)

Código fuente modular del refactor. Las decisiones y su fundamento están en
[`docs/v2-refactor-y-optimizacion.md`](../docs/v2-refactor-y-optimizacion.md).

```
src/
├── transactional/                  -> dist/script_creacion_inicial.sql
│   ├── 00_reset_schema.sql         drop of every object in CHIRIPIORCA, generated from the catalog
│   ├── 01_tables.sql               24 tables + ExecutionLog, named PK/FK/UQ/CK constraints
│   ├── 02_migration_procedures.sql 12 set-based procedures + usp_RunMigration (one transaction)
│   ├── 03_run_migration.sql        EXEC usp_RunMigration
│   └── 04_indexes.sql              supporting nonclustered indexes + statistics
└── bi/                             -> dist/script_creacion_BI.sql
    ├── 00_reset_bi.sql             drop of BI_ objects only
    ├── 01_dimension_tables.sql     9 dimensions
    ├── 02_fact_tables.sql          5 aggregated facts (grain = clustered PK)
    ├── 03_functions.sql            inline table-valued functions
    ├── 04_load_procedures.sql      dimension/fact loads + BI_usp_RunLoad (one transaction)
    ├── 05_views.sql                the 10 business indicators
    └── 06_run_load.sql             EXEC BI_usp_RunLoad + statistics
```

## Generar y ejecutar

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
sqlcmd -S localhost\SQLEXPRESS -E -b -i dist\script_creacion_inicial.sql
sqlcmd -S localhost\SQLEXPRESS -E -b -i tests\verify_transactional.sql
sqlcmd -S localhost\SQLEXPRESS -E -b -i dist\script_creacion_BI.sql
sqlcmd -S localhost\SQLEXPRESS -E -b -i tests\verify_bi.sql
```

Los archivos de `dist/` se generan: no se editan a mano.

## Convenciones

| Elemento | Formato | Ejemplo |
|---|---|---|
| Tabla transaccional | PascalCase, singular | `SaleDetail` |
| Tabla BI | `BI_Dim*` / `BI_Fact*` | `BI_FactShipment` |
| Columna | snake_case | `scheduled_date` |
| Procedimiento | `usp_<Verb><Object>` / `BI_usp_…` | `usp_MigrateSales` |
| Función / vista BI | `BI_fn_…` / `BI_vw_…` | `BI_vw_TopCitiesByShippingCost` |
| Restricciones | `PK_`, `FK_<Child>_<Parent>`, `UQ_`, `CK_` | `FK_Shipment_Address` |
| Índices | `IX_<Table>_<Columns>` | `IX_Payment_Sale` |
