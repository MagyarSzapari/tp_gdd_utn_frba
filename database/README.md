# Base de datos de la cátedra

Scripts provistos por la cátedra para crear la base `GD2C2024` y la tabla `gd_esquema.Maestra`.

| Archivo | En el repo | Descripción |
|---------|:---------:|-------------|
| `catedra/gd_esquema.Schema.sql` | ✔ | Crea el esquema `gd_esquema` (UTF-16 LE, se versiona sin conversión). |
| `catedra/gd_esquema.Maestra.sql` | ✔ | DDL de la tabla `Maestra` (sin datos). Útil para consultar los tipos de cada columna. |
| `catedra/EjecutarScriptTablaMaestra.bat` | ✔ | Batch original que corre `sqlcmd` sobre los dos scripts. |
| `catedra/gd_esquema.Maestra.Table.sql` | ✘ | DDL + ~1.4 GB de `INSERT`s. Excede el límite de GitHub (100 MB). |
| `catedra/gd_esquema.Maestra.Table.rar` | ✘ | El mismo script comprimido (16 MB). Se ignora por ser un binario de datos. |

## Cómo cargar la tabla maestra

1. Instalar SQL Server 2019 (Express o Developer) y crear la base `GD2C2024` con los valores por defecto.
2. Copiar `gd_esquema.Maestra.Table.sql` (o descomprimir el `.rar`) dentro de `database/catedra/`.
3. Desde esa carpeta, ejecutar (autenticación de Windows):

```bat
sqlcmd -S localhost\SQLEXPRESS -E -i gd_esquema.Schema.sql,gd_esquema.Maestra.Table.sql -a 32767 -o resultado_output.txt
```

Con autenticación SQL reemplazar `-E` por `-U <usuario> -P <password>`. La carga tarda unos 40 minutos.
El batch original apunta a la instancia de la máquina donde se desarrolló (`DESKTOP-DOKIHA\SQLEXPRESS`);
hay que editar el `-S` antes de usarlo.
