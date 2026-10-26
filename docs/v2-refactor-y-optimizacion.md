# Fase 2 — Refactor y optimización del T-SQL

Documento de estudio que acompaña al código de [`src/`](../src/README.md). Explica qué estaba
mal en la versión entregada ([`entregas/entrega-3-final-y-bi/sql/`](../entregas/entrega-3-final-y-bi/sql/)),
qué se cambió y por qué, con la teoría necesaria para defender cada decisión en la materia.

> **Estado de verificación.** Ejecutado sobre **SQL Server 2019 Express (15.0.2000.5)** con la
> maestra completa (242.108 filas): ambos scripts corren sin errores ni advertencias, en una
> base limpia y por segunda vez (idempotentes), y pasan los 57 checks de `tests/`
> (34 transaccionales + 23 de BI). Detalle en la sección 4.1.

---

## 1. Executive Summary & Architectural Overview

### 1.1 Qué hay realmente en la tabla maestra

Antes de tocar código se perfiló el dataset completo (cargado en SQLite desde el
`gd_esquema.Maestra.Table.sql` original). Hallazgos que condicionan todo el diseño:

| Hecho medido | Valor | Consecuencia de diseño |
|---|---|---|
| Formas de fila | 34.629 de publicación · 103.592 de venta · 103.887 de factura (disjuntas) | Cada SP filtra por la columna que identifica su forma. |
| Detalles por venta / envíos / pagos | exactamente 1 / 1 / 1 | `Sale` 1‑N `SaleDetail`, `Shipment` único por venta. |
| Ítems por factura | exactamente 3 (uno por concepto) | `Invoice` 1‑N `InvoiceDetail`. |
| Códigos de producto distintos | **10** para **6.893** productos | El código no identifica: la clave es (código, subrubro). |
| Subrubros | 45 nombres en 815 pares (subrubro, rubro) | La clave es (rubro, subrubro). |
| Localidades | 1.612 nombres repetidos entre provincias | La clave es (provincia, localidad). |
| DNI | 14 DNI con dos personas distintas | La clave de cliente es (DNI, apellido, nombre). |
| Montos con centavos | ~100 % de ventas, pagos, facturas, envíos | Dinero en `DECIMAL(18,2)`, nunca `(18,0)`. |
| `PUBLICACION_PORC_VENTA` | 0,00 o 0,10 | En `DECIMAL(18,0)` el 0,10 se vuelve **0**. |
| `VENTA_FECHA` | `DATE` (sin hora) | El indicador 5 (rango horario) no tiene dato real: todo cae en 00–06. |
| Inconsistencias de origen | 19.699 ventas fuera de la vigencia de su publicación; total ≠ subtotal+envío en 12.024 ventas | Se documentan y **no** se corrigen (regla del enunciado). |

### 1.2 Diagnóstico del código original

No había cursores ni triggers. Los problemas eran de **corrección** primero y de rendimiento después:

| # | Defecto en el original | Impacto |
|---|---|---|
| D1 | Montos y `porcentaje_por_venta` en `DECIMAL(18,0)` | Se pierden los centavos en todas las tablas; la comisión 0,10 se guarda como 0. |
| D2 | `Venta.detalle_venta` apunta a **un** detalle; `Facturacion.detalle_factura` guarda `MIN(id)` | Modelo invertido: la factura pierde 2 de sus 3 conceptos; una venta no puede tener más de un ítem. |
| D3 | `Venta.cliente_usuario` tiene FK a `Cliente_usuario` pero se carga con `Cliente.codigo_cliente` | La FK apunta a un usuario que no es el comprador (los IDs coinciden solo por casualidad de orden). |
| D4 | `Pago` toma `MIN(id_pago)` uniendo por **tipo** de medio | Todos los pagos con tarjeta de crédito quedan asignados al mismo medio. |
| D5 | Detalles de factura y venta se resuelven con joins por `(codigo, costo)` y un `UPDATE` con subconsulta correlacionada y `CONVERT` en el `ON` | Lógica frágil, no sargable, una búsqueda por fila. |
| D6 | Migración transaccional con `INSERT` sueltos, sin stored procedures ni transacción | Incumple el enunciado ("deberán utilizarse Stored Procedures") y un error deja la base a medio migrar. |
| D7 | `Provincia.nombre VARCHAR(30)` | Tipo distinto al origen (`NVARCHAR(50)`); riesgo de truncar y de perder caracteres fuera de la página de códigos. |
| D8 | El script transaccional borra objetos BI a mano, lista que ya había quedado desactualizada | Mantenimiento propenso a errores. |
| D9 | Función escalar `OBTENER_ID_RANGO_ETARIO` con `GETDATE()` y lecturas por rama | Cálculo fila por fila, plan serial y **edad que cambia según el día en que se corre el script**. |
| D10 | Dimensiones unidas por texto (`YEAR(fecha) = anio`, nombre de localidad) | Joins no sargables y ambigüedad entre localidades homónimas. |
| D11 | Hechos que guardan **promedios** (`AVG(stock)`, `AVG(costo_envio)`) que después las vistas vuelven a promediar | El promedio de promedios no es el promedio: resultados incorrectos. |
| D12 | Indicador 10 usa la provincia del **almacén** en vez de la del vendedor; indicador 5 sin vista; vista 9 con subconsulta correlacionada | Requisitos funcionales incumplidos. |
| D13 | Sin índices no agrupados, sin restricciones `CHECK`, constraints sin nombre | Peor rendimiento de joins y mensajes de error ilegibles. |

### 1.3 Enfoque

1. **Modelo primero.** Se rediseñó el modelo relacional (3FN) con las claves de negocio que
   revela el perfilado, nombres en inglés y tipos idénticos al origen.
2. **Migración set-based y atómica.** Un SP por agregado, orquestados por
   `usp_RunMigration` dentro de una única transacción con `TRY…CATCH`, `XACT_ABORT` y
   `XACT_STATE()`.
3. **Estrella correcta.** Hechos con medidas aditivas, dimensiones con claves enteras, funciones
   inline y vistas que derivan promedios y porcentajes.
4. **Modularidad con entregable único.** El código vive en módulos por responsabilidad y
   [`build.ps1`](../build.ps1) genera los dos archivos únicos que exige la cátedra en `dist/`.
5. **Verificabilidad.** Tests ejecutables ([`tests/`](../tests)) con conteos medidos y
   conciliaciones de montos al centavo.

### 1.4 Arquitectura resultante

```
gd_esquema.Maestra ──(usp_RunMigration: 12 SPs, 1 transacción)──► modelo transaccional (24 tablas + bitácora)
                                                                         │
                                         (BI_usp_RunLoad: 6 SPs, 1 transacción)
                                                                         ▼
                                     9 dimensiones BI_Dim* + 5 hechos BI_Fact* ──► 10 vistas BI_vw_*
```

Correspondencia de nombres (para leer el DER original contra el nuevo):

| Original | Refactor | Original | Refactor |
|---|---|---|---|
| Provincia / Localidad | `Province` / `City` | Publicacion | `Listing` |
| Cliente / Cliente_usuario | `Customer` / `UserAccount` + `Address` | Venta / Detalle_de_venta | `Sale` / `SaleDetail` |
| Vendedor / Vendedor_usuario | `Seller` / `UserAccount` + `Address` | Envio / Tipo_envio | `Shipment` / `ShippingType` |
| Rubro / Subrubro | `Category` / `Subcategory` | Pago / Medio_de_pago / Tipo_medio_de_pago | `Payment` + `CardPaymentDetail` / `PaymentMethod` / `PaymentMethodType` |
| Marca / Modelo / Producto | `Brand` / `ProductModel` / `Product` | Facturacion / Detalle_de_factura / Tipo_detalle_factura | `Invoice` / `InvoiceDetail` / `InvoiceConcept` |
| Almacen | `Warehouse` | BI_TIEMPO, BI_UBICACION, … | `BI_DimTime`, `BI_DimLocation`, … |

El esquema sigue llamándose `CHIRIPIORCA` (lo exige el enunciado) y los objetos BI conservan
el prefijo `BI_`.

---

## 2. Refactored Code (English T-SQL)

El código completo está en el repositorio; acá se resume la estructura y se muestran los
fragmentos que concentran las decisiones importantes.

| Módulo | Contenido |
|---|---|
| [`src/transactional/00_reset_schema.sql`](../src/transactional/00_reset_schema.sql) | Borrado dinámico, ordenado por dependencias, de todo el esquema. |
| [`src/transactional/01_tables.sql`](../src/transactional/01_tables.sql) | 24 tablas + `ExecutionLog`, con PK, FK, UNIQUE y CHECK nombrados. |
| [`src/transactional/02_migration_procedures.sql`](../src/transactional/02_migration_procedures.sql) | 12 SPs de migración + orquestador transaccional. |
| [`src/transactional/03_run_migration.sql`](../src/transactional/03_run_migration.sql) | `EXEC CHIRIPIORCA.usp_RunMigration`. |
| [`src/transactional/04_indexes.sql`](../src/transactional/04_indexes.sql) | Índices no agrupados (con `INCLUDE`) y `UPDATE STATISTICS … FULLSCAN`. |
| [`src/bi/00_reset_bi.sql`](../src/bi/00_reset_bi.sql) | Borrado dinámico solo de objetos `BI_`. |
| [`src/bi/01_dimension_tables.sql`](../src/bi/01_dimension_tables.sql) / [`02_fact_tables.sql`](../src/bi/02_fact_tables.sql) | 9 dimensiones y 5 hechos. |
| [`src/bi/03_functions.sql`](../src/bi/03_functions.sql) | 4 funciones inline (iTVF) con `SCHEMABINDING`. |
| [`src/bi/04_load_procedures.sql`](../src/bi/04_load_procedures.sql) | Carga de dimensiones y hechos + orquestador. |
| [`src/bi/05_views.sql`](../src/bi/05_views.sql) | Las 10 vistas de indicadores. |
| [`src/bi/06_run_load.sql`](../src/bi/06_run_load.sql) | `EXEC CHIRIPIORCA.BI_usp_RunLoad` + estadísticas. |

### 2.1 Orquestador transaccional (patrón aplicado a migración y a BI)

```sql
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
        -- ... 10 more steps in dependency order ...
        EXEC CHIRIPIORCA.usp_MigrateInvoices;
        COMMIT TRANSACTION;

        UPDATE CHIRIPIORCA.ExecutionLog
        SET finished_at = SYSDATETIME(), status = 'SUCCEEDED'
        WHERE execution_id = @execution_id;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        UPDATE CHIRIPIORCA.ExecutionLog
        SET finished_at = SYSDATETIME(), status = 'FAILED',
            error_number = ERROR_NUMBER(),
            error_message = CONCAT(ERROR_PROCEDURE(), N' (line ', ERROR_LINE(), N'): ', ERROR_MESSAGE())
        WHERE execution_id = @execution_id;

        THROW;
    END CATCH;
END;
```

### 2.2 Unpivot en una sola lectura (antes: tres lecturas con `UNION`)

```sql
INSERT INTO CHIRIPIORCA.Province (province_name)
SELECT DISTINCT src.province_name
FROM gd_esquema.Maestra AS m
CROSS APPLY (VALUES (m.ALMACEN_PROVINCIA),
                    (m.CLI_USUARIO_DOMICILIO_PROVINCIA),
                    (m.VEN_USUARIO_DOMICILIO_PROVINCIA)) AS src (province_name)
WHERE src.province_name IS NOT NULL;
```

### 2.3 Identidades generadas + correlación con el origen (`MERGE … OUTPUT`)

```sql
MERGE CHIRIPIORCA.UserAccount AS tgt
USING #customer_source AS src
   ON 1 = 0
WHEN NOT MATCHED THEN
    INSERT (username, user_password, created_on)
    VALUES (src.username, src.user_password, src.created_on)
OUTPUT src.source_row_id, inserted.user_id
  INTO #user_map (source_row_id, user_id);
```

### 2.4 Función inline en lugar de función escalar

```sql
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
```

### 2.5 Porcentaje por ventana (antes: subconsulta correlacionada)

```sql
SELECT calendar_year, calendar_month, concept_name, invoiced_amount,
       CAST(100.0 * invoiced_amount
            / SUM(invoiced_amount) OVER (PARTITION BY calendar_year, calendar_month) AS DECIMAL(5, 2))
FROM concept_totals;
```

---

## 3. Engineering Justification Matrix

Referencias: **SWEBOK v4.0** (IEEE Computer Society, 2024) — áreas de conocimiento (KA)
*Software Architecture*, *Software Design*, *Software Construction*, *Software Testing*,
*Software Maintenance*, *Software Configuration Management*, *Software Quality*,
*Software Security*. **ISO/IEC 25010:2023** — modelo de calidad de producto (entre paréntesis
el nombre de la versión 2011 cuando cambió).

### C1. Tipos de dato fieles al origen (dinero en `DECIMAL(18,2)`)

- **Change Implemented:** todas las columnas monetarias y `sale_fee_rate` pasan de `DECIMAL(18,0)` a `DECIMAL(18,2)`; provincias y localidades de `VARCHAR(30/50)` a `NVARCHAR(50)`.
- **SWEBOK v4.0:** *Software Design* (diseño de datos: el tipo es parte del contrato del dato); *Software Quality* (defectos de dominio detectables por revisión).
- **ISO/IEC 25010:** *Functional suitability → functional correctness*; *Security → integrity* (el dato almacenado es el dato recibido).
- **Deep-Dive:** `DECIMAL(p,s)` es punto fijo: `s` dígitos después de la coma. Al insertar `16126.88` en `DECIMAL(18,0)` SQL Server **redondea** a `16127` sin error ni advertencia (conversión implícita permitida). Sobre 103.592 ventas el error acumulado es real, y una comisión de `0.10` se redondea a `0`: el negocio "deja de cobrar". El enunciado exige respetar los tipos de la maestra, que ya son `(18,2)`. `VARCHAR` usa la página de códigos de la intercalación; `NVARCHAR` (UTF‑16) representa cualquier carácter. Con el mismo tipo en ambos lados de un `JOIN` tampoco hay conversión implícita, que puede volver no sargable un predicado (ver C6). Los tests concilian cada suma de montos contra la maestra al centavo.

### C2. Cabecera 1‑N detalle (ventas y facturas)

- **Change Implemented:** `SaleDetail.sale_code → Sale` e `InvoiceDetail.invoice_number → Invoice` (antes la cabecera apuntaba a un único detalle). Se cargan los 3 conceptos de cada factura.
- **SWEBOK v4.0:** *Software Design* (modelado de datos, cardinalidades); *Software Architecture* (decisiones estructurales difíciles de revertir).
- **ISO/IEC 25010:** *Functional suitability → functional completeness / correctness*; *Maintainability → modifiability*.
- **Deep-Dive:** en una relación 1‑N la FK va **en el lado N**. Poner la FK en la cabecera obliga a elegir un único hijo (de ahí el `MIN(detalle_factura_id)` original) y destruye información: 69.258 ítems de factura quedaban sin vínculo. Además impedía ventas con más de un producto, que el enunciado describe ("Detalle de la venta"). Con la FK en el detalle, el índice `IX_SaleDetail_Sale (sale_code) INCLUDE (...)` resuelve "las líneas de una venta" con un *index seek* + lectura de rango contiguo.

### C3. Claves de negocio medidas, no supuestas

- **Change Implemented:** `UNIQUE (product_code, subcategory_id)`, `UNIQUE (category_id, subcategory_name)`, `UNIQUE (province_id, city_name)`, `UNIQUE (dni, last_name, first_name)`; códigos naturales únicos (`sale_code`, `listing_code`, `invoice_number`, `warehouse_code`, `model_code`) como PK.
- **SWEBOK v4.0:** *Software Design*; *Software Requirements* (el análisis de datos es elicitación de reglas de negocio).
- **ISO/IEC 25010:** *Security → integrity*; *Reliability → faultlessness (maturity)*.
- **Deep-Dive:** una restricción `UNIQUE` crea un índice único y le da al optimizador una garantía de cardinalidad: al hacer `JOIN … ON (province_id, city_name)` sabe que habrá como mucho una fila y elige *nested loops* con *seek* en lugar de *hash join* con *build* completo. Si los datos violaran el supuesto, la migración **falla** en vez de duplicar filas en silencio (el original duplicaba publicaciones al unir productos solo por código). Usar los códigos naturales como PK elimina la "re-búsqueda" del ID sustituto en cada hecho: `SaleDetail` se carga con `m.VENTA_CODIGO` y `m.PUBLICACION_CODIGO` directamente, sin joins.

### C4. Claves sustitutas `INT` en lugar de `DECIMAL(18,0)`

- **Change Implemented:** todas las `IDENTITY` nuevas son `INT`.
- **SWEBOK v4.0:** *Software Design* (diseño físico); *Software Construction* (estándares de codificación).
- **ISO/IEC 25010:** *Performance efficiency → resource utilization / time behaviour*.
- **Deep-Dive:** `DECIMAL(18,0)` ocupa 9 bytes; `INT`, 4. La clave agrupada se copia en **cada** índice no agrupado como localizador de fila, así que una clave más angosta achica todos los índices: más filas por página de 8 KB, menos páginas que leer y cachear en el *buffer pool*, comparaciones de enteros más baratas en los joins. Con ~41.000 usuarios sobra el rango de `INT` (2.147 millones). Las columnas que vienen de la maestra conservan su tipo (regla del enunciado); solo cambian las claves que crea el alumno, que el enunciado permite.

### C5. Migración en stored procedures, todo-o-nada

- **Change Implemented:** 12 SPs (`usp_Migrate*`) y un orquestador `usp_RunMigration` con una transacción, `SET XACT_ABORT ON`, `TRY…CATCH`, `XACT_STATE()`, `THROW` y bitácora `ExecutionLog`. Igual para BI (`BI_usp_RunLoad`).
- **SWEBOK v4.0:** *Software Construction* (manejo de errores, construcción para la verificación); *Software Architecture* (separación orquestación/pasos); *Software Engineering Operations* (observabilidad).
- **ISO/IEC 25010:** *Reliability → fault tolerance / recoverability*; *Security → integrity / accountability*; *Maintainability → modularity / analysability*.
- **Deep-Dive (ACID):**
  - **Atomicidad:** sin transacción explícita cada `INSERT` es su propia transacción (*autocommit*). Si el paso 9 falla, los pasos 1–8 quedan confirmados y la base queda inconsistente. Con una transacción externa todo se confirma o se deshace junto.
  - **`XACT_ABORT ON`:** por defecto, muchos errores de ejecución (p. ej. violación de FK) abortan **solo la sentencia** y la transacción sigue abierta y "committable". Con `XACT_ABORT ON` cualquier error de ejecución condena la transacción completa (`XACT_STATE() = -1`), que es lo que se quiere en una carga.
  - **`XACT_STATE()` vs `@@TRANCOUNT`:** `@@TRANCOUNT` dice si hay transacción; `XACT_STATE()` dice además si se puede confirmar (1), si está condenada (-1) o si no hay (0). En un `CATCH` solo se puede hacer `ROLLBACK` de una transacción condenada; intentar `COMMIT` falla. Revisar `<> 0` evita además el error 3903 (`ROLLBACK` sin transacción) y las **transacciones huérfanas** que retienen bloqueos hasta que se cierra la conexión.
  - **`THROW` vs `RAISERROR`:** `THROW` sin argumentos relanza el error original (número, severidad, línea), así `sqlcmd -b` termina con código de error y el orquestador no "se traga" la falla.
  - **Bitácora fuera de la transacción:** el `INSERT` de `RUNNING` se hace antes del `BEGIN TRANSACTION` y el `UPDATE` de `FAILED` después del `ROLLBACK`; si se hicieran adentro, el rollback borraría también el registro del error.
  - **Por qué los SPs hijos no abren su propia transacción:** SQL Server no tiene transacciones anidadas reales (un `ROLLBACK` interno deshace todo y deja `@@TRANCOUNT` en 0, provocando el error 266 al volver). Un único dueño de la transacción es más simple y correcto.
  - **Durabilidad:** se delega en el log de transacciones (WAL). Una carga en una sola transacción usa más log; en el modelo de recuperación `SIMPLE` (habitual en la base del TP) el espacio se libera en el siguiente *checkpoint*.

### C6. Joins sargables y sin funciones sobre columnas

- **Change Implemented:** se eliminaron `CONVERT(numeric, …)` en el `ON`, la subconsulta correlacionada del `UPDATE` de ventas, los `YEAR(fecha) = anio AND MONTH(fecha) = mes` contra la dimensión tiempo y los joins de dimensiones por nombre.
- **SWEBOK v4.0:** *Software Construction* (eficiencia del código); *Software Design* (diseño para el rendimiento).
- **ISO/IEC 25010:** *Performance efficiency → time behaviour*.
- **Deep-Dive:** un predicado es **SARGable** (*Search ARGument able*) cuando el motor puede usarlo para posicionarse en un índice (*seek*) en lugar de recorrerlo (*scan*). `WHERE col = @x` lo es; `WHERE YEAR(col) = 2025` no, porque el índice está ordenado por `col`, no por `YEAR(col)`: hay que calcular la función para cada fila. Lo mismo con `CONVERT` sobre la columna, y con comparar tipos distintos (conversión implícita de la columna). Además, las funciones sobre columnas arruinan la **estimación de cardinalidad**: el optimizador no tiene histograma de `YEAR(col)` y adivina, lo que lleva a malas elecciones de join y a *memory grants* erróneos. En el refactor:
  - la dimensión tiempo usa una **clave inteligente `YYYYMM`** que se calcula a partir de la fecha del hecho; no hay join con predicados funcionales;
  - las dimensiones guardan el **ID de origen** (`city_id`, `subcategory_id`, …) con índice único, y los hechos se unen por entero;
  - las búsquedas de la migración se hacen por columnas de igual tipo con índice único detrás.

### C7. Una lectura en lugar de tres (`CROSS APPLY (VALUES …)`)

- **Change Implemented:** provincias y localidades se extraen de las tres columnas de domicilio en una sola pasada.
- **SWEBOK v4.0:** *Software Construction* (reutilización de construcciones del lenguaje).
- **ISO/IEC 25010:** *Performance efficiency → resource utilization*.
- **Deep-Dive:** `SELECT … UNION SELECT … UNION SELECT …` sobre la maestra (que no tiene índices y no se puede indexar porque no pertenece al esquema del grupo) implica tres *table scans* completos más un operador de eliminación de duplicados. `CROSS APPLY (VALUES (a),(b),(c))` genera tres filas por cada fila leída en **un solo scan** (un *unpivot*), y un único `DISTINCT` (un *hash aggregate*) elimina duplicados. Las lecturas lógicas bajan a un tercio, lo que se puede comprobar con `SET STATISTICS IO ON`.

### C8. `MERGE … OUTPUT` para correlacionar identidades

- **Change Implemented:** usuarios de clientes/vendedores y pagos con su detalle de tarjeta se crean con `MERGE … ON 1 = 0 … OUTPUT src.col, inserted.id`.
- **SWEBOK v4.0:** *Software Construction* (técnicas de construcción set-based); *Software Design*.
- **ISO/IEC 25010:** *Functional suitability → correctness*; *Performance efficiency → time behaviour*.
- **Deep-Dive:** cuando la tabla padre genera la clave (`IDENTITY`), la tabla hija necesita saber qué ID le tocó a cada fila de origen. Las alternativas clásicas son malas: un **cursor** que inserta de a una fila y lee `SCOPE_IDENTITY()` (RBAR: *Row By Agonizing Row*, 41.000 viajes); o volver a unir por los datos insertados, que falla si no son únicos (hay 41 usuarios con nombre+clave+fecha idénticos para dos clientes distintos). `INSERT … OUTPUT` solo puede devolver columnas de `inserted`; `MERGE … OUTPUT` puede devolver también columnas del **origen**, así que se obtiene el mapa `fila_origen → id_nuevo` en la misma operación set-based. `ON 1 = 0` hace que todas las filas caigan en `WHEN NOT MATCHED` (es un insert masivo). `OUTPUT INTO` no puede apuntar a una tabla que participe de una FK, por eso se usa una tabla temporal intermedia.

### C9. Funciones inline (iTVF) en lugar de funciones escalares; edad determinística

- **Change Implemented:** `OBTENER_ID_RANGO_ETARIO` (escalar, `GETDATE()`, `IF/ELSE` con lecturas) → `BI_fn_GetAgeRangeKey(@birth, @at)` inline, con rangos en la tabla `BI_DimAgeRange`; se agregan `BI_fn_GetTimeKey`, `BI_fn_GetTimeRangeKey` y `BI_fn_GetSaleCustomerCity`.
- **SWEBOK v4.0:** *Software Design* (abstracción, ocultamiento de información); *Software Construction*; *Software Testing* (determinismo como condición de testeabilidad).
- **ISO/IEC 25010:** *Performance efficiency → time behaviour*; *Maintainability → reusability / modifiability / testability*; *Functional suitability → correctness*.
- **Deep-Dive:** una función escalar con varias sentencias es una caja negra para el optimizador: se invoca **una vez por fila** (y el original la llamaba dos veces, en el `SELECT` y en el `GROUP BY`), obliga a un plan **serial** y su costo no aparece en el plan estimado. La *Scalar UDF Inlining* de SQL Server 2019 no la puede inlinear porque usa `GETDATE()` y lee tablas en ramas. Una **iTVF** es un único `SELECT` que el optimizador expande dentro de la consulta que la llama (como una vista con parámetros), así que participa del plan con joins, paralelismo y estadísticas. `SCHEMABINDING` impide que se modifique una tabla de la que depende y le permite al motor marcarla como determinística. Además, calcular la edad con `GETDATE()` hace que **el resultado dependa del día de ejecución**: el mismo script dado en 2024 y en 2026 clasifica distinto a los mismos clientes. Ahora la edad se calcula a la fecha de la venta, lo cual es reproducible y, conceptualmente, lo correcto para "rango etario del cliente que compró". Poner los límites en una tabla (dato) en vez de en ramas `IF` (código) permite cambiarlos con un `UPDATE`.

### C10. Hechos con medidas aditivas; promedios en las vistas

- **Change Implemented:** los hechos guardan conteos y sumas (`listing_count`, `total_active_days`, `sales_amount`, `sale_count`, `on_time_count`, …). Las vistas calculan `SUM(numerador) / SUM(denominador)`.
- **SWEBOK v4.0:** *Software Design* (modelado dimensional); *Mathematical Foundations*.
- **ISO/IEC 25010:** *Functional suitability → correctness*.
- **Deep-Dive:** en modelado dimensional (Kimball) las medidas se clasifican en **aditivas** (se pueden sumar por cualquier dimensión), **semiaditivas** (saldos) y **no aditivas** (promedios, porcentajes). Las no aditivas no se pueden reagregar: si un grupo tiene 1 publicación de 10 días y otro 9 de 30, el promedio de promedios da 20 y el real es 28. El original guardaba `AVG(stock)` por (mes, subrubro, marca) y la vista volvía a hacer `AVG` por año: resultado incorrecto. Guardando suma y cantidad, cualquier nivel de agregación da el promedio exacto.

### C11. Grano explícito como clave agrupada del hecho

- **Change Implemented:** la PK agrupada de cada hecho es la combinación de sus claves de dimensión, empezando por `time_key`.
- **SWEBOK v4.0:** *Software Design*; *Software Quality* (prevención de defectos por diseño).
- **ISO/IEC 25010:** *Reliability → faultlessness*; *Performance efficiency → time behaviour*.
- **Deep-Dive:** el **grano** es la definición de qué representa una fila del hecho. Declararlo como PK impide cargar dos veces la misma combinación (error de carga detectado, no sumado). Como índice agrupado, ordena físicamente las filas por tiempo: todas las vistas agrupan por año/mes/cuatrimestre, y los rangos de tiempo se leen como páginas contiguas. Las tablas de hechos son agregadas (miles de filas, no millones), por lo que no se justifican índices adicionales ni *columnstore*; si el volumen creciera, un *clustered columnstore index* sería el siguiente paso (compresión por columna y ejecución en *batch mode*).

### C12. Índices no agrupados de soporte (covering) creados después de la carga

- **Change Implemented:** índices sobre todas las FK que no quedan cubiertas por otra restricción, con `INCLUDE` donde la consulta lo pide (`IX_Sale_Customer … INCLUDE (sale_date, total_amount)`, `IX_SaleDetail_Sale … INCLUDE (listing_code, quantity, subtotal)`, etc.), creados en `04_indexes.sql` tras la migración, seguidos de `UPDATE STATISTICS … WITH FULLSCAN`.
- **SWEBOK v4.0:** *Software Design* (diseño físico); *Software Engineering Operations*.
- **ISO/IEC 25010:** *Performance efficiency → time behaviour / resource utilization*.
- **Deep-Dive:**
  - SQL Server **no** crea índices automáticamente para las FK. Sin índice, cada `DELETE` en el padre y cada join padre‑hijo escanea la tabla hija completa y toma más bloqueos de los necesarios.
  - Un **índice agrupado** *es* la tabla ordenada por la clave (las hojas son las filas). Un **no agrupado** es una estructura aparte con la clave y un puntero (la clave agrupada). Si la consulta necesita columnas que no están en el índice, por cada fila hace un **key lookup** (una lectura aleatoria al agrupado). `INCLUDE` agrega columnas solo al nivel hoja: el índice "cubre" la consulta sin agrandar los niveles intermedios del árbol B.
  - Crear los índices **después** de cargar es más rápido: se ordena una vez (`O(n log n)`) en lugar de insertar fila por fila en cada árbol (con *page splits* y fragmentación). Se mantienen antes de la carga solo los índices de PK/UNIQUE, que la migración necesita para buscar y para validar.
  - Las **estadísticas** (histograma de hasta 200 pasos por columna) son lo que el optimizador usa para estimar cuántas filas devuelve cada operador. Tras cargar 350.000 filas en tablas vacías, las estadísticas auto-creadas pueden ser de muestra; `FULLSCAN` las deja exactas para la carga del BI.
  - `WITH (TABLOCK)` en los `INSERT … SELECT` masivos toma un único bloqueo de tabla en vez de miles de bloqueos de fila/página (evita la escalada de bloqueos y su costo de memoria) y habilita el registro mínimo en el log cuando el modelo de recuperación lo permite.

### C13. Reset del esquema generado desde el catálogo

- **Change Implemented:** los `DROP` se generan con `STRING_AGG` sobre `sys.foreign_keys` y `sys.objects`, en orden FK → vistas → procedimientos → funciones → tablas. El script BI borra solo `BI_%`.
- **SWEBOK v4.0:** *Software Maintenance* (reducción del costo de cambio); *Software Configuration Management* (scripts idempotentes y reproducibles).
- **ISO/IEC 25010:** *Maintainability → modifiability*; *Flexibility → installability*.
- **Deep-Dive:** el original mantenía dos listas manuales de `DROP` casi iguales (el script transaccional copiaba a mano los `DROP` de los objetos BI para poder recrear el esquema) que había que sincronizar ante cada objeto nuevo o renombrado. Generarla desde el catálogo hace que el script sea **idempotente** (se puede correr N veces con el mismo resultado) sin mantener nada. Borrar primero las FK elimina el problema del orden entre tablas.

### C14. Restricciones `CHECK` nombradas en lugar de triggers

- **Change Implemented:** `CK_Listing_Dates`, `CK_Listing_Stock`, `CK_SaleDetail_Quantity`, `CK_Shipment_Window`, `CK_Payment_Amount`, etc.; todas las restricciones tienen nombre (`PK_`, `FK_`, `UQ_`, `CK_`).
- **SWEBOK v4.0:** *Software Design* (elegir el mecanismo más simple que cumple); *Software Security* (validación de entrada en la capa de datos).
- **ISO/IEC 25010:** *Security → integrity*; *Maintainability → analysability*.
- **Deep-Dive:** el enunciado pide triggers "cuando fuese necesario". Para reglas de una sola fila, una `CHECK` es **declarativa**: el motor la valida en el mismo operador de inserción, el optimizador puede usarla para simplificar planes (si es *trusted*) y no puede olvidarse de dispararse. Un trigger es procedural, corre después de la sentencia sobre las pseudo-tablas `inserted`/`deleted`, agrega costo a cada DML y es más difícil de razonar. Solo se justificaría para reglas entre filas o tablas (p. ej. "el total de la venta = suma de sus líneas"), y esa regla **no se cumple en los datos de origen** (12.024 ventas), por lo que imponerla rechazaría datos que el enunciado prohíbe modificar. Se dejaron afuera las `CHECK` que el origen viola (venta dentro de la vigencia de la publicación). Con nombre, un error dice `CK_Listing_Dates` en lugar de `CK__Listing__3A81B327`.

### C15. Ranking determinístico en vistas "Top N"

- **Change Implemented:** vistas 4, 6 y 8 usan `ROW_NUMBER() OVER (PARTITION BY … ORDER BY medida DESC, nombre)` y exponen la posición; la 9 usa `SUM() OVER (PARTITION BY …)`.
- **SWEBOK v4.0:** *Software Construction*; *Software Testing* (resultados reproducibles).
- **ISO/IEC 25010:** *Functional suitability → correctness*; *Performance efficiency → time behaviour*.
- **Deep-Dive:** `TOP 5 … ORDER BY` dentro de una vista solo define **qué** filas entran, no el orden en que se devuelven, y sin desempate dos ejecuciones pueden traer filas distintas ante empates. `ROW_NUMBER` con desempate por nombre es determinístico. En la vista 9 la subconsulta correlacionada recalculaba el total del período por cada grupo; la función de ventana lo calcula una vez por partición sobre las filas ya agregadas (un único operador *Window Spool/Segment*).

### C16. Requisitos funcionales del BI corregidos

- **Change Implemented:** indicador 5 implementado (faltaba); indicador 10 por provincia del **vendedor**; ubicación del cliente tomada del **domicilio del envío** (indicador 6); envío "en término" = entregado el día programado dentro de la franja horaria.
- **SWEBOK v4.0:** *Software Requirements* (trazabilidad requisito → vista); *Software Testing*.
- **ISO/IEC 25010:** *Functional suitability → functional completeness / correctness*.
- **Deep-Dive:** cada vista lleva el número de indicador del enunciado como comentario. Limitación documentada: la maestra solo trae la **fecha** de venta (sin hora), así que la vista 5 asigna todas las ventas a 00:00–06:00; el modelo queda listo para cuando exista el dato, sin inventarlo (regla del enunciado). Límites de rango etario: "< 25" y "> 50" son estrictos, por lo que 50 cae en "35 - 50" y el 35 compartido se asigna a "25 - 35".

### C17. Código modular, en inglés, con entregable único generado

- **Change Implemented:** módulos por responsabilidad en `src/`, `build.ps1` genera `dist/script_creacion_inicial.sql` y `dist/script_creacion_BI.sql`; nombres y comentarios en inglés con convenciones uniformes (`usp_`, `BI_usp_`, `BI_fn_`, `BI_vw_`, `IX_`, `PK_`, `FK_`, `UQ_`, `CK_`).
- **SWEBOK v4.0:** *Software Configuration Management* (artefactos derivados reproducibles); *Software Construction* (estándares de codificación); *Software Maintenance*.
- **ISO/IEC 25010:** *Maintainability → modularity / analysability / modifiability*.
- **Deep-Dive:** la cátedra exige un único archivo por modelo, pero mantener 900 líneas en un archivo mezcla responsabilidades (DDL, ETL, vistas) y hace ilegible cualquier diff. Separar fuente (módulos) de artefacto (archivo único generado) es la práctica estándar de gestión de configuración: se edita la fuente, se regenera el artefacto y nunca se edita a mano lo generado (el encabezado del archivo lo advierte).

---

## 4. Verification & Execution Recommendations

### 4.1 Lo que ya se verificó

Entorno: SQL Server 2019 Express RTM (15.0.2000.5), Windows 11, 16 núcleos, base `GD2C2024`
en modelo de recuperación `SIMPLE`, maestra cargada con los scripts de la cátedra (2 min 39 s).

| Verificación | Resultado |
|---|---|
| Perfilado del dataset completo (242.108 filas) en SQLite | Cardinalidades y claves de la sección 1.1; valores esperados de los tests. |
| Parseo con `TSql150Parser` de `dist/*.sql` y `tests/*.sql` | Sin errores de sintaxis. |
| `script_creacion_inicial.sql` sobre base limpia | Sin errores. ~19 s en total; `usp_RunMigration` 17,9 s. |
| `tests/verify_transactional.sql` | **34/34 PASS** (conteos, montos al centavo, coherencia envío/comprador, factura/dueño, medio de pago). |
| `script_creacion_BI.sql` | Sin errores. ~18 s en total; `BI_usp_RunLoad` 16,6 s. |
| `tests/verify_bi.sql` | **23/23 PASS** (hechos conciliados con el transaccional, rangos etarios y envíos en término iguales al perfilado). |
| Reejecución de ambos scripts sobre la base ya cargada | Sin errores; tests en verde (idempotencia). |
| Atomicidad: `EXEC usp_RunMigration` sobre datos ya migrados | Falla en el primer paso (error 2627, `UQ_Province_Name`), `ROLLBACK` total, `@@TRANCOUNT = 0`, datos intactos y `FAILED` en `ExecutionLog` con procedimiento y línea. |

Hallazgo durante la verificación: el primer `verify_bi.sql` marcaba FAIL en las 4 conciliaciones
de montos, aunque los datos eran correctos. Causa: en un `UNION ALL`, una rama `DECIMAL(38,0)`
(suma de stock) y otras `DECIMAL(38,2)` requieren precisión 40; como el máximo es 38, SQL Server
conserva los dígitos enteros y **reduce la escala a 0**, redondeando los montos al compararlos.
Se corrigió casteando esa rama a `DECIMAL(18,2)`. Es el mismo tipo de pérdida silenciosa de
centavos que la sección C1 corrige en el modelo, pero en una expresión intermedia.

### 4.2 Cómo ejecutarlo

Requisito: base `GD2C2024` con la maestra cargada ([`database/README.md`](../database/README.md)).

```powershell
.\build.ps1
sqlcmd -S localhost\SQLEXPRESS -E -b -i dist\script_creacion_inicial.sql
sqlcmd -S localhost\SQLEXPRESS -E -b -i tests\verify_transactional.sql
sqlcmd -S localhost\SQLEXPRESS -E -b -i dist\script_creacion_BI.sql
sqlcmd -S localhost\SQLEXPRESS -E -b -i tests\verify_bi.sql
```

`-b` hace que `sqlcmd` corte y devuelva código de error ante el primer error (sin `-b` sigue
con el próximo lote). Los tests muestran una tabla PASS/FAIL y terminan con `THROW` si algo falla.
Si un orquestador falla, el detalle queda en `SELECT * FROM CHIRIPIORCA.ExecutionLog`.

### 4.3 Medir rendimiento (antes vs después)

1. Restaurar la base limpia, correr el script **original** y luego el **refactor**, cada uno con:
   ```sql
   SET STATISTICS IO, TIME ON;
   ```
   Comparar *logical reads* por tabla (la maestra debería leerse menos veces) y *CPU time / elapsed time*.
2. En SSMS activar **Include Actual Execution Plan** (Ctrl+M) para los SPs más pesados
   (`usp_MigrateShipments`, `BI_usp_LoadFactSale`) y revisar:
   - *Index Seek* vs *Index/Table Scan* en las búsquedas de dimensiones;
   - *Estimated vs Actual Number of Rows*: diferencias de 10× o más indican estadísticas malas o predicados no sargables;
   - advertencias amarillas: conversiones implícitas, *spills* a `tempdb` por *memory grant* insuficiente;
   - *Key Lookup*: candidato a sumar columnas al `INCLUDE`.
3. Habilitar **Query Store** (`ALTER DATABASE GD2C2024 SET QUERY_STORE = ON;`) para guardar planes y métricas por consulta entre ejecuciones.
4. Revisar índices sin uso o faltantes con `sys.dm_db_index_usage_stats` y `sys.dm_db_missing_index_details` después de correr las vistas.

### 4.4 Pruebas adicionales sugeridas

- **Atomicidad:** forzar un error en un paso intermedio (p. ej. `THROW 50000, 'test', 1;` al
  inicio de `usp_MigrateSales`), correr `usp_RunMigration` y verificar que todas las tablas
  quedan vacías, `@@TRANCOUNT = 0` y `ExecutionLog` registra `FAILED` con el mensaje.
- **Idempotencia:** ejecutar cada script dos veces seguidas; la segunda debe terminar igual.
- **Volumen:** duplicar la maestra con códigos desplazados (por ejemplo `+ 10.000.000`) en una
  copia, y comparar tiempos para ver que el costo crece linealmente (planes set-based) y no
  cuadráticamente (síntoma de búsquedas por fila).
- **Concurrencia:** durante la carga, desde otra sesión, consultar
  `sys.dm_tran_locks` para ver los bloqueos de tabla de `TABLOCK` y su liberación al `COMMIT`.
