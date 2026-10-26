<#
.SYNOPSIS
    Builds the two single-file deliverables required by the course from the
    modular sources in src/.

.DESCRIPTION
    The course runs exactly two files, once each, on a clean database:
      dist/script_creacion_inicial.sql  <- src/transactional/*.sql (in name order)
      dist/script_creacion_BI.sql       <- src/bi/*.sql            (in name order)
    Output is UTF-8 with BOM and CRLF line endings, which both SSMS and sqlcmd
    read correctly.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

function Build-Script {
    param(
        [string] $SourceDir,
        [string] $OutputFile,
        [string] $Title
    )
    $parts = Get-ChildItem -Path (Join-Path $root $SourceDir) -Filter '*.sql' | Sort-Object Name
    if (-not $parts) { throw "No .sql files found in $SourceDir" }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('/* ' + ('=' * 77))
    [void]$builder.AppendLine("   $Title")
    [void]$builder.AppendLine('   GENERATED FILE - do not edit. Source: ' + $SourceDir + '/ (run build.ps1)')
    [void]$builder.AppendLine('   ' + ('=' * 77) + ' */')
    foreach ($part in $parts) {
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine("/* ---------- $SourceDir/$($part.Name) ---------- */")
        $text = [System.IO.File]::ReadAllText($part.FullName)
        [void]$builder.AppendLine($text.TrimEnd())
    }
    $content = ($builder.ToString() -replace "`r?`n", "`r`n")
    $path = Join-Path $dist $OutputFile
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ("{0,-28} <- {1} files from {2}" -f $OutputFile, $parts.Count, $SourceDir)
}

Build-Script -SourceDir 'src/transactional' -OutputFile 'script_creacion_inicial.sql' `
             -Title 'TP Gestion de Datos 2C2024 - CHIRIPIORCA - Transactional model and migration'
Build-Script -SourceDir 'src/bi' -OutputFile 'script_creacion_BI.sql' `
             -Title 'TP Gestion de Datos 2C2024 - CHIRIPIORCA - Business intelligence model'
