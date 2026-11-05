#Requires -Version 7.3
<#
.SYNOPSIS
    Prepara la terminal para operar el proyecto. Ejecutar al abrir cada terminal nueva,
    "con punto" para que las variables queden en la sesión actual:

        . ./scripts/sesion.ps1

.DESCRIPTION
    1. Verifica PowerShell 7 y que Docker Desktop esté encendido.
    2. Carga los secretos de Terraform desde el archivo .env (no versionado), que ya
       tiene las mismas contraseñas que usan postgres-exporter y k6:
         POSTGRES_PASSWORD           -> TF_VAR_db_password
         KC_BOOTSTRAP_ADMIN_PASSWORD -> TF_VAR_keycloak_admin_password
    3. Define $P (prefijo de los contenedores, "keycloak-prod") para los comandos de los
       runbooks, y TF_STATE_DIR y KC_IMAGE para los comandos de docs/OPERACION.md.

    Las variables solo existen en esta ventana: al cerrarla o reiniciar hay que volver
    a ejecutar este script. Nunca imprime los secretos.
#>
$repoRoot = Split-Path -Parent $PSScriptRoot
$ok = $true

function Write-Check([bool] $cond, [string] $okMsg, [string] $failMsg) {
    if ($cond) { Write-Host "  [OK]    $okMsg" -ForegroundColor Green }
    else { Write-Host "  [FALTA] $failMsg" -ForegroundColor Red; $script:ok = $false }
}

Write-Host "`nPreparando la sesión de operación" -ForegroundColor Cyan

# 1. PowerShell y Docker
Write-Check ($PSVersionTable.PSVersion.Major -ge 7) "PowerShell $($PSVersionTable.PSVersion)" "Se necesita PowerShell 7: escriba 'pwsh' y vuelva a ejecutar este script"
docker info --format "{{.ServerVersion}}" *> $null
Write-Check ($LASTEXITCODE -eq 0) "Docker Desktop encendido" "Docker no responde: abra Docker Desktop y espere a que diga 'Engine running'"

# 2. Secretos desde .env
$envFile = Join-Path $repoRoot ".env"
if (Test-Path $envFile) {
    $vars = @{}
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') { $vars[$Matches[1]] = $Matches[2].Trim('"', "'") }
    }
    $env:TF_VAR_db_password = $vars["POSTGRES_PASSWORD"]
    $env:TF_VAR_keycloak_admin_password = $vars["KC_BOOTSTRAP_ADMIN_PASSWORD"]
    Write-Check ([bool]$env:TF_VAR_db_password -and $env:TF_VAR_db_password.Length -ge 12) "TF_VAR_db_password (desde POSTGRES_PASSWORD)" "POSTGRES_PASSWORD falta en .env o tiene menos de 12 caracteres"
    Write-Check ([bool]$env:TF_VAR_keycloak_admin_password -and $env:TF_VAR_keycloak_admin_password.Length -ge 12) "TF_VAR_keycloak_admin_password (desde KC_BOOTSTRAP_ADMIN_PASSWORD)" "KC_BOOTSTRAP_ADMIN_PASSWORD falta en .env o tiene menos de 12 caracteres"
}
else {
    Write-Check $false "" "No existe .env en la raíz del repositorio (copiar .env.example y completar)"
}

# 3. Prefijo de los contenedores, usado en los comandos de los runbooks ("$P-keycloak-1", ...)
$global:P = "keycloak-prod"
Write-Host "  [INFO]  P = $global:P (prefijo de los contenedores en los runbooks)" -ForegroundColor Yellow

# 4. Estado de Terraform e imagen del commit actual
if (-not $env:TF_STATE_DIR) { $env:TF_STATE_DIR = "C:/terraform-state/devops-grupo-3" }
Write-Check (Test-Path $env:TF_STATE_DIR) "TF_STATE_DIR = $env:TF_STATE_DIR" "No existe la carpeta de estado $env:TF_STATE_DIR"

# Solo los commits de main tienen imagen publicada por el CI: KC_IMAGE se arma con el
# último commit de origin/main, sin importar en qué rama se esté trabajando.
git -C $repoRoot fetch origin main --quiet 2>$null
$sha = git -C $repoRoot rev-parse --short=7 origin/main 2>$null
$branch = git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null
$env:KC_IMAGE = "ghcr.io/jdcarranzas/devops-grupo-3:sha-$sha"
Write-Host "  [INFO]  Rama actual '$branch'; KC_IMAGE = $env:KC_IMAGE (último commit de origin/main)" -ForegroundColor Yellow

if ($ok) { Write-Host "`nListo. Siguiente paso: ver docs/OPERACION.md`n" -ForegroundColor Green }
else { Write-Host "`nCorrija lo marcado como [FALTA] antes de desplegar.`n" -ForegroundColor Red }

# Como el script se ejecuta "con punto", se limpian las variables auxiliares
# (en especial $vars, que contiene los valores leídos del .env).
Remove-Variable -Name vars, line, envFile, sha, branch, ok, repoRoot -ErrorAction SilentlyContinue
Remove-Item Function:\Write-Check -ErrorAction SilentlyContinue
