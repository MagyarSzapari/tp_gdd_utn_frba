# Entrega 3 — Modelo de BI (reentrega final)

| Dato | Valor |
|------|-------|
| Fecha límite BI (enunciado) | 25/11/2024, 12:00 hs |
| Fecha final de reentregas | 09/12/2024 |
| Versión guardada | 04/12/2024 |

## Contenido

| Carpeta | Archivo | Descripción |
|---------|---------|-------------|
| `docs/` | `DER.jpg` | DER final del modelo transaccional. |
| `docs/` | `DER_BI.jpg` | DER del modelo dimensional (BI). |
| `docs/` | `Estrategia.pdf` | Documento de estrategia actualizado. |
| `sql/`  | `script_creacion_inicial.sql` | Creación del esquema `CHIRIPIORCA`, tablas y migración desde `gd_esquema.Maestra`. |
| `sql/`  | `script_creacion_BI.sql` | Dimensiones, hechos, stored procedures de carga y las 10 vistas de indicadores. |

## Orden de ejecución (como lo corre la cátedra)

1. Base `GD2C2024` limpia con `gd_esquema.Maestra` cargada (ver [`database/`](../../database/README.md)).
2. `script_creacion_inicial.sql`
3. `script_creacion_BI.sql`

Estos archivos se conservan **sin modificaciones** como registro académico. La versión
refactorizada vive en [`src/`](../../src/README.md).
