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
