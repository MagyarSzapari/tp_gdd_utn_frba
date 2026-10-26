# TP Gestión de Datos — Marketplace (UTN FRBA, 2C2024)

Trabajo práctico de **Gestión de Datos** (Ingeniería en Sistemas de Información, UTN FRBA),
2º cuatrimestre 2024. Grupo **CHIRIPIORCA** (Nº 38, curso K3571).

El TP parte de una única tabla desnormalizada (`gd_esquema.Maestra`, ~1.4 GB de datos de un
marketplace) y pide:

1. Diseñar un **modelo relacional normalizado** y migrar todos los datos con T-SQL.
2. Construir un **modelo dimensional (BI)** sobre ese modelo y exponer 10 indicadores de negocio como vistas.

Motor: **Microsoft SQL Server 2019**. Todo objeto propio vive en el esquema `CHIRIPIORCA`.

## Estructura del repositorio

```
TP_Gestion_de_Datos/
├── build.ps1                      Genera dist/ a partir de src/
├── database/                      Scripts de la cátedra (tabla maestra) y cómo cargarla
│   └── catedra/
├── dist/                          Entregables de un solo archivo GENERADOS por build.ps1
│   ├── script_creacion_inicial.sql
│   └── script_creacion_BI.sql
├── docs/
│   ├── enunciado/                 Enunciado, apéndice y registro de cambios (PDF)
│   ├── historial/                 Log del repositorio git original del grupo
│   ├── v1-preparacion-y-git.md
│   └── v2-refactor-y-optimizacion.md
├── entregas/                      Entregas tal como se enviaron (registro académico, sin cambios)
│   ├── entrega-1-der-y-estrategia/      07/10/2024 — DER
│   ├── entrega-2-modelo-y-migracion/    30/10/2024 — modelo relacional + migración
│   └── entrega-3-final-y-bi/            04/12/2024 — reentrega final + modelo BI
├── src/                           Versión refactorizada, modular y en inglés
│   ├── transactional/
│   └── bi/
└── tests/                         Verificaciones post-ejecución (conteos y conciliaciones)
```

Cada entrega tiene la misma forma: `docs/` (DER, estrategia) y `sql/` (scripts), más un
`README.md` con fechas, contenido y procedencia de cada archivo.

## Versión refactorizada (v2.0)

Rediseño del modelo y de toda la lógica T-SQL: tipos fieles al origen (sin perder centavos),
cabecera‑detalle correcto en ventas y facturas, migración con stored procedures set-based en
una única transacción (`TRY…CATCH` + `XACT_STATE()`), estrella con medidas aditivas, funciones
inline, índices de soporte y tests de conciliación. Detalle y fundamentos (SWEBOK v4.0,
ISO/IEC 25010) en [`docs/v2-refactor-y-optimizacion.md`](docs/v2-refactor-y-optimizacion.md).

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
sqlcmd -S localhost\SQLEXPRESS -E -b -i dist\script_creacion_inicial.sql
sqlcmd -S localhost\SQLEXPRESS -E -b -i tests\verify_transactional.sql
sqlcmd -S localhost\SQLEXPRESS -E -b -i dist\script_creacion_BI.sql
sqlcmd -S localhost\SQLEXPRESS -E -b -i tests\verify_bi.sql
```

> Ejecutado en SQL Server 2019 Express con la maestra completa: sin errores, idempotente,
> migración ~19 s + BI ~18 s, y 57/57 checks de `tests/` en verde.

## Cómo ejecutar la versión entregada

1. Cargar la tabla maestra en la base `GD2C2024` → [`database/README.md`](database/README.md).
2. Ejecutar, en este orden, sobre `GD2C2024`:
   - `entregas/entrega-3-final-y-bi/sql/script_creacion_inicial.sql`
   - `entregas/entrega-3-final-y-bi/sql/script_creacion_BI.sql`

## Integrantes

Federico Hygonenq · Federico Hartwig · Sebastián Romero · MagyarSzapari

## Metodología de Desarrollo y Asistencia de IA

El proceso de refactorización del TP se llevó a cabo implementando un flujo de trabajo híbrido,
combinando el criterio de ingeniería principal con la asistencia del modelo de lenguaje avanzado
**Claude AI** (Anthropic). Todas las sugerencias de optimización fueron exhaustivamente revisadas y
validadas mediante pruebas funcionales antes de su integración final en la rama principal.
