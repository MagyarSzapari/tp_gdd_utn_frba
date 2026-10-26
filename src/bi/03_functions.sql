/* =============================================================================
   03_functions.sql
   Inline table-valued functions (iTVF) used by the fact loads.

   Why iTVF instead of scalar UDFs (the original OBTENER_ID_RANGO_ETARIO was a
   scalar UDF with IF/ELSE branches and table reads):
   - An iTVF is a single SELECT that the optimizer expands into the calling
     query, like a parameterized view: it joins set-based and allows parallelism.
   - A multi-statement scalar UDF that reads tables runs once per row (hidden
     RBAR), cannot be inlined by SQL Server 2019's UDF inlining and forces a
     serial plan.
   - The original function also used GETDATE(), so a customer's age range
     changed depending on the day the script was run. Age is now computed at
     the date of the event, which makes the load deterministic and repeatable.
   ============================================================================= */
USE GD2C2024;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- YYYYMM key of the time dimension for a given date.
CREATE OR ALTER FUNCTION CHIRIPIORCA.BI_fn_GetTimeKey (@event_date DATE)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT YEAR(@event_date) * 100 + MONTH(@event_date) AS time_key;
GO

-- Age range of a person at a given date (full years, birthday-aware).
CREATE OR ALTER FUNCTION CHIRIPIORCA.BI_fn_GetAgeRangeKey (@birth_date DATE, @at_date DATE)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT ar.age_range_key
    FROM (
        SELECT DATEDIFF(YEAR, @birth_date, @at_date)
               - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, @birth_date, @at_date), @birth_date) > @at_date
                      THEN 1 ELSE 0 END AS age_years
    ) AS a
    JOIN CHIRIPIORCA.BI_DimAgeRange AS ar
      ON a.age_years BETWEEN ar.min_age AND ar.max_age;
GO

-- Time-of-day range for a given instant.
CREATE OR ALTER FUNCTION CHIRIPIORCA.BI_fn_GetTimeRangeKey (@event_at DATETIME)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT tr.time_range_key
    FROM CHIRIPIORCA.BI_DimTimeRange AS tr
    WHERE DATEPART(HOUR, @event_at) BETWEEN tr.start_hour AND tr.end_hour;
GO

-- City where a customer receives a sale: the shipment address when there is a
-- shipment (statement, indicator 6), otherwise the customer's first address.
CREATE OR ALTER FUNCTION CHIRIPIORCA.BI_fn_GetSaleCustomerCity (@sale_code DECIMAL(18, 0), @customer_user_id INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT COALESCE(
               (SELECT a.city_id
                FROM CHIRIPIORCA.Shipment AS sh
                JOIN CHIRIPIORCA.Address  AS a ON a.address_id = sh.address_id
                WHERE sh.sale_code = @sale_code),
               (SELECT TOP (1) a.city_id
                FROM CHIRIPIORCA.Address AS a
                WHERE a.user_id = @customer_user_id
                ORDER BY a.address_id)
           ) AS city_id;
GO
