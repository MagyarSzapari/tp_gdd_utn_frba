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
