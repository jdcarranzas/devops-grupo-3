#Requires -Version 7.3
<#
.SYNOPSIS
    Respaldo lógico de la base de datos de Keycloak (pg_dump en formato custom).

.DESCRIPTION
    Control preventivo del Pre-Mortem (escenario 1, pérdida de la base de datos).
    El volcado se genera DENTRO del contenedor y se copia con "docker cp": así el
    archivo binario no pasa por la tubería de PowerShell, que lo corrompería.
    Conserva los últimos -Conservar respaldos y borra los más antiguos.

    Los respaldos contienen datos de usuarios y hashes de contraseñas: la carpeta
    está en .gitignore y no se debe compartir.

    Para restaurar: observability/runbooks/RB-04-restauracion-bd.md

.EXAMPLE
    ./scripts/backup-db.ps1                         # prod, en .\backups
    ./scripts/backup-db.ps1 -Destino D:\respaldos   # otra carpeta

    # Programado cada 6 horas con el Programador de tareas de Windows:
    # schtasks /Create /SC HOURLY /MO 6 /TN "Keycloak backup" /TR "pwsh -File <repo>\scripts\backup-db.ps1"
#>
[CmdletBinding()]
param(
    [ValidateSet("dev", "prod")]
    [string] $Ambiente = "prod",

    [string] $Destino = (Join-Path (Split-Path -Parent $PSScriptRoot) "backups"),

    [int] $Conservar = 14
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$contenedor = "keycloak-$Ambiente-postgres"
$archivo = "keycloak-$Ambiente-{0:yyyyMMdd-HHmmss}.dump" -f (Get-Date)
$tmp = "/tmp/$archivo"

New-Item -ItemType Directory -Force -Path $Destino | Out-Null

docker exec $contenedor pg_dump -U keycloak -d keycloak --format=custom --file=$tmp
if ($LASTEXITCODE -ne 0) { throw "pg_dump falló en $contenedor" }

# Verificación: el respaldo se puede leer (pg_restore lista su contenido sin restaurarlo).
$objetos = docker exec $contenedor pg_restore --list $tmp
if ($LASTEXITCODE -ne 0) { throw "El respaldo generado no es legible por pg_restore" }
Write-Host "Respaldo verificado: $(@($objetos | Where-Object { $_ -notmatch '^;' }).Count) objetos (tablas, índices, datos)"

docker cp "${contenedor}:$tmp" (Join-Path $Destino $archivo)
if ($LASTEXITCODE -ne 0) { throw "No se pudo copiar el respaldo desde $contenedor" }
docker exec $contenedor rm -f $tmp | Out-Null

$ruta = Join-Path $Destino $archivo
$tamano = (Get-Item $ruta).Length
if ($tamano -lt 1024) { throw "El respaldo $ruta es sospechosamente pequeño ($tamano bytes)" }
Write-Host ("Respaldo creado: {0} ({1:N0} KB)" -f $ruta, ($tamano / 1KB)) -ForegroundColor Green

# Retención: se conservan los $Conservar más recientes.
Get-ChildItem -Path $Destino -Filter "keycloak-$Ambiente-*.dump" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $Conservar |
    ForEach-Object { Remove-Item -Force $_.FullName; Write-Host "Respaldo antiguo eliminado: $($_.Name)" }
