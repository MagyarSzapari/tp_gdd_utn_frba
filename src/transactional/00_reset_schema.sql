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
