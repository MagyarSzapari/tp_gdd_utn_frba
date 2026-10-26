/* =============================================================================
   00_reset_bi.sql
   Makes the BI script re-runnable on its own: drops only the BI_ objects of the
   group schema (the transactional model is left untouched), in dependency-safe
   order: foreign keys, views, procedures, functions, tables.
   ============================================================================= */
USE GD2C2024;
GO

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'CHIRIPIORCA.Sale', N'U') IS NULL
    THROW 50001, N'The transactional model is missing: run script_creacion_inicial.sql first.', 1;
GO

DECLARE @drop_statements NVARCHAR(MAX);

SELECT @drop_statements = STRING_AGG(
           CAST(N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
                + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) AS NVARCHAR(MAX)),
           N';' + NCHAR(10))
FROM sys.foreign_keys AS fk
JOIN sys.tables  AS t ON t.object_id = fk.parent_object_id
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE s.name = N'CHIRIPIORCA'
  AND t.name LIKE N'BI[_]%';

IF @drop_statements IS NOT NULL
    EXEC sys.sp_executesql @drop_statements;

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
  AND o.name LIKE N'BI[_]%'
  AND o.type IN ('V', 'P', 'U', 'FN', 'IF', 'TF');

IF @drop_statements IS NOT NULL
    EXEC sys.sp_executesql @drop_statements;
GO
