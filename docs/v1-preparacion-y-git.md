# Fase 1 — Preparación, estructura de entregas y Git

Guía de lo que se hizo para pasar de la carpeta local desordenada (`TP-GDD.zip`) a este
repositorio. Todos los comandos son para **PowerShell** en Windows.

## 1. Estado de requisitos previos

```powershell
git --version                       # Git instalado (se usó 2.49.0.windows.1)
git config --global user.name       # Nombre con el que se firman los commits
git config --global user.email      # Mail asociado (debe coincidir con el de GitHub)
git config --global init.defaultBranch   # Rama por defecto; si no devuelve nada, se usa "master"
```

Si falta alguno:

```powershell
git config --global user.name  "Tu Nombre"
git config --global user.email "tu@mail.com"
git config --global init.defaultBranch main
git config --global core.autocrlf true   # Windows: CRLF en disco, LF en el repo
```

## 2. Estructura recomendada de directorios

### Diagnóstico del desorden original

| Origen en el zip | Qué era en realidad |
|------------------|---------------------|
| `TP2C2024 K3571 CHIRIPIORCA 38.zip123` | La **Entrega 1** (DER + estrategia), todavía comprimida. |
| `Entrega2/DER.rar` | DER de la **Entrega 2**; el script de esa entrega no estaba en ningún lado. |
| `Entrega/` + `Entrega/data/` | **Entrega 3** (reentrega final del 04/12/2024, con BI). |
| `gdd/` | Clon del repo de trabajo del grupo. Scripts casi idénticos a `Entrega/data` (solo agrega `SELECT`s de prueba al final) y con CRLF. |
| `Enunciado.pdf` (×2), `Apéndice…pdf`, `Registro de Cambios.pdf` | Documentación de la cátedra, duplicada. |
| `Base de Datos/` | Scripts de la cátedra + 1.4 GB de datos + salida de `sqlcmd` (5 MB). |

Decisiones:

- **Una carpeta por entrega**, nombrada por número y alcance, con la misma forma interna
  (`docs/` para DER y estrategia, `sql/` para scripts) y un `README.md` de procedencia.
- Los scripts de las entregas **no se modifican**: son el registro de lo que se evaluó.
- El script de la Entrega 2 se **recuperó del historial git** de `gdd/` (commit `f797e2a`,
  30/10/2024 11:17, último antes del vencimiento de las 12:00).
- La copia `gdd/` se descarta como duplicado; de ella solo se conserva el `git log` en `docs/historial/`.
- La documentación de la cátedra se deduplica en `docs/enunciado/`.

### Árbol final

```
TP_Gestion_de_Datos/
├── .gitignore
├── .gitattributes
├── README.md
├── database/
│   ├── README.md
│   └── catedra/          gd_esquema.Schema.sql, gd_esquema.Maestra.sql, EjecutarScriptTablaMaestra.bat
├── docs/
│   ├── enunciado/        Enunciado_2C2024.pdf, Apendice_Enunciado_2C2024.pdf, Registro_de_Cambios_2C2024.pdf
│   ├── historial/        git-log-repo-original.txt
│   └── FASE-1-preparacion-y-git.md
└── entregas/
    ├── entrega-1-der-y-estrategia/    docs/ (DER.jpg, Estrategia.pdf)
    ├── entrega-2-modelo-y-migracion/  docs/ (DER.jpg)   sql/ (script_creacion_inicial.sql)
    └── entrega-3-final-y-bi/          docs/ (DER.jpg, DER_BI.jpg, Estrategia.pdf)
                                       sql/ (script_creacion_inicial.sql, script_creacion_BI.sql)
```

### Comandos para crear la jerarquía

```powershell
$repo = "D:\Para Valen\UTN\GdD\TP_Gestion_de_Datos"
$dirs = @(
  "database\catedra", "docs\enunciado", "docs\historial",
  "entregas\entrega-1-der-y-estrategia\docs", "entregas\entrega-1-der-y-estrategia\sql",
  "entregas\entrega-2-modelo-y-migracion\docs", "entregas\entrega-2-modelo-y-migracion\sql",
  "entregas\entrega-3-final-y-bi\docs", "entregas\entrega-3-final-y-bi\sql"
)
$dirs | ForEach-Object { New-Item -ItemType Directory -Force -Path (Join-Path $repo $_) | Out-Null }
```

Recuperar el script de la Entrega 2 desde el repo viejo del grupo:

```powershell
git -C "<ruta>\TP-GDD\gdd" show f797e2a:script_creacion_inicial.sql |
  Out-File -Encoding utf8 "$repo\entregas\entrega-2-modelo-y-migracion\sql\script_creacion_inicial.sql"
```

> Git no versiona carpetas vacías: `entrega-1-.../sql/` existe en disco pero no en el repo,
> porque esa entrega no tenía scripts.

## 3. Estrategia de ignorados (SQL Server / SSMS)

| Patrón | Por qué no se sube |
|--------|--------------------|
| `*.mdf`, `*.ndf`, `*.ldf` | Archivos físicos de datos y de log de transacciones. Son binarios enormes, quedan bloqueados mientras el servicio corre y dependen de la versión del motor. La base se reconstruye con los scripts. |
| `*.bak`, `*.dif`, `*.trn`, `*.tuf` | Backups (completo, diferencial, de log) y archivos de undo de log shipping. Pesados y con datos. |
| `*.ss`, `*.bacpac`, `*.dacpac` | Snapshots y exportaciones de data-tier: artefactos generados. |
| `gd_esquema.Maestra.Table.sql`, `*.rar` | El dataset de 1.4 GB supera el límite de 100 MB por archivo de GitHub; además es material de la cátedra. |
| `resultado_output*.txt`, `*.rpt`, `*.log` | Salidas de `sqlcmd` y de resultados exportados desde SSMS. |
| `*.user`, `*.suo`, `*.ssmssqlproj.user` | Preferencias personales del usuario de SSMS / Visual Studio. |
| `*.sqlplan` | Planes de ejecución guardados: se regeneran y cambian con las estadísticas. |
| `SQLQuery*.sql`, `~*.sql` | Pestañas sin guardar y archivos de autorecuperación de SSMS. |
| `bin/`, `obj/`, `.vs/`, `*.dbmdl`, `*.jfm` | Salida de compilación y caché de proyectos SSDT. |
| `.idea/`, `.vscode/` | Configuración de IDE (el repo original del grupo llegó a commitear `.idea/` dos veces). |
| `*.zip`, `*.zip123`, `.env`, `*.publishsettings` | Empaquetados de entrega y credenciales. |

El contenido exacto está en [`.gitignore`](../.gitignore). Además, [`.gitattributes`](../.gitattributes)
fija CRLF para `.sql`/`.bat` (lo que espera SSMS), trata PDF/JPG como binarios y deja el
`gd_esquema.Schema.sql` de la cátedra (UTF-16 LE) sin conversión para no corromperlo.

## 4. Paso a paso en la terminal

```powershell
cd "D:\Para Valen\UTN\GdD\TP_Gestion_de_Datos"

# 1) Inicializar el repositorio con rama principal "main"
git init -b main

# 2) Revisar qué entraría y comprobar que lo pesado queda afuera
git status --short --ignored
git check-ignore -v database/catedra/gd_esquema.Maestra.Table.rar

# 3) Agregar por bloques lógicos (facilita revisar cada parte)
git add .gitignore .gitattributes README.md
git add database docs entregas

# 4) Verificar lo preparado antes de confirmar
git status
git diff --cached --stat

# 5) Commit inicial con mensaje estructurado (tipo: resumen + cuerpo)
git commit -m "chore: initial repository structure for TP Gestion de Datos" `
           -m "Organize the three deliveries (DER, relational model + migration, BI) under entregas/, add the course statement and the chair's database scripts, and ignore SQL Server/SSMS artifacts."

# 6) Conferir el resultado
git log --stat --oneline
```

### Subida a GitHub (cuando lo decidas)

```powershell
gh repo create TP_Gestion_de_Datos --private --source . --remote origin   # o crearlo desde la web
git push -u origin main
```
