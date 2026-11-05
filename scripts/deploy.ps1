#Requires -Version 7.3
<#
.SYNOPSIS
    Despliegue continuo de Keycloak con Terraform y rolling update sin pérdida
    de disponibilidad (Entregable 4).

.DESCRIPTION
    1. terraform init (estado fuera de la carpeta del runner) y workspace del ambiente.
    2. Para cada réplica de Keycloak que Terraform va a cambiar:
         a. la saca del balanceador (HAProxy, estado MAINT) para que no reciba tráfico nuevo;
         b. espera a que terminen las peticiones en curso;
         c. la reemplaza con terraform apply -target (Terraform espera a que esté "healthy");
         d. la devuelve al balanceador y espera a que HAProxy la marque UP.
       Mientras tanto, la otra réplica atiende todo el tráfico.
    3. terraform apply completo para converger el resto (balanceador, BD, redes).
    4. Smoke test a través del balanceador y verificación de idempotencia (plan sin cambios).

    Los secretos llegan por variables de entorno (TF_VAR_db_password y
    TF_VAR_keycloak_admin_password); el script nunca los imprime.

.EXAMPLE
    # Despliegue manual de la imagen de un commit (desde la raíz del repositorio)
    $env:TF_VAR_db_password = "..."; $env:TF_VAR_keycloak_admin_password = "..."
    ./scripts/deploy.ps1 -Environment prod -Image ghcr.io/jdcarranzas/devops-grupo-3:sha-1a2b3c4 -StateDir C:\terraform-state\devops-grupo-3
#>
[CmdletBinding()]
param(
    [ValidateSet("dev", "prod")]
    [string] $Environment = "prod",

    # Imagen de Keycloak a desplegar. Vacío = la definida en environments/<ambiente>.tfvars.
    [string] $Image = "",

    # Carpeta del estado de Terraform. En el runner debe estar FUERA del workspace,
    # porque actions/checkout limpia los archivos ignorados por git en cada ejecución.
    # Vacío = terraform.tfstate.d dentro de /terraform (uso manual, igual que antes).
    [string] $StateDir = "",

    # Segundos para que terminen las peticiones en curso antes de reemplazar una réplica.
    [int] $DrainSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false   # se revisa $LASTEXITCODE a mano
# La consola de Windows usa por defecto otra página de códigos: sin esto, las tildes de la
# salida de Terraform se ven como "r├®plica" (el contenido real sí está en UTF-8).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent $PSScriptRoot
$tfDir = Join-Path $repoRoot "terraform"
$varFile = "environments/$Environment.tfvars"
$prefix = "keycloak-$Environment"
$lbContainer = "$prefix-lb"
$httpPort = if ($Environment -eq "prod") { 8081 } else { 8080 }

if (-not $env:TF_VAR_db_password -or -not $env:TF_VAR_keycloak_admin_password) {
    throw "Faltan TF_VAR_db_password y/o TF_VAR_keycloak_admin_password en el entorno."
}

$env:TF_IN_AUTOMATION = "true"
$env:TF_INPUT = "false"
# Docker Desktop en Windows escucha en un named pipe; en Linux/macOS se usa el socket por defecto.
if ($IsWindows -and -not $env:TF_VAR_docker_host) { $env:TF_VAR_docker_host = "npipe:////./pipe/docker_engine" }

$tfVars = @("-var-file=$varFile")
if ($Image) { $tfVars += "-var=keycloak_image=$Image" }

function Write-Step([string] $msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

# Ejecuta terraform mostrando su salida en consola (queda en el log del pipeline)
# y devuelve solo el código de salida.
function Invoke-Terraform([string[]] $arguments, [int[]] $okCodes = @(0)) {
    & terraform @arguments | Out-Host
    if ($okCodes -notcontains $LASTEXITCODE) {
        throw "terraform $($arguments[0]) falló (código $LASTEXITCODE)"
    }
    return $LASTEXITCODE
}

# Envía un comando a la API de runtime de HAProxy (solo accesible dentro del contenedor).
function Send-HAProxyCommand([string] $command) {
    $out = docker exec $lbContainer sh -c "echo '$command' | nc 127.0.0.1 9999" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "HAProxy: '$command' falló: $out" }
    return $out
}

# Espera a que HAProxy marque la réplica como UP (health check activo a /health/ready).
function Wait-ReplicaUp([string] $server, [int] $timeoutSeconds = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $csv = Send-HAProxyCommand "show stat"
        $line = $csv | Where-Object { $_ -like "be_keycloak,$server,*" } | Select-Object -First 1
        if ($line -and ($line -split ",")[17] -eq "UP") { return }
        Start-Sleep -Seconds 2
    }
    throw "La réplica $server no volvió a estado UP en el balanceador en $timeoutSeconds s."
}

# La imagen debe existir ANTES de tocar nada: si no, se fallaría con una réplica ya
# fuera del balanceador. (Solo los commits de main tienen imagen publicada por el CI.)
if ($Image) {
    Write-Step "Verificando que la imagen exista: $Image"
    docker pull $Image | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "La imagen $Image no existe o no se puede descargar. Use el tag de un commit de main (ver 'Resolver la imagen a desplegar' en el último job Deploy). No se hizo ningún cambio."
    }
}

$previousDataDir = $env:TF_DATA_DIR
Push-Location $tfDir
try {
    # ------------------------------------------------------------------ init
    Write-Step "terraform init y workspace '$Environment'"
    $initArgs = @("init", "-input=false", "-reconfigure")
    if ($StateDir) {
        # Con una carpeta de estado externa, Terraform ve el estado "suelto" de
        # terraform/terraform.tfstate.d como un estado anterior y pide migrarlo
        # (prompt que falla en modo no interactivo). Se pide moverlo una sola vez.
        $legacyState = Join-Path $tfDir "terraform.tfstate.d"
        if (Test-Path $legacyState) {
            throw ("Hay estado local en '$legacyState'. Muévalo una sola vez a la carpeta de estado:`n" +
                "  Move-Item terraform\terraform.tfstate.d\* '$StateDir'`n" +
                "  Remove-Item terraform\terraform.tfstate.d")
        }

        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        $initArgs += "-backend-config=workspace_dir=$($StateDir -replace '\\', '/')"
        # Carpeta de trabajo de Terraform propia (providers, backend y workspace
        # seleccionado), junto al estado. Así no se mezcla con terraform/.terraform
        # de las ejecuciones manuales (p. ej. el workspace "dev" del Entregable 2),
        # que haría que terraform init pidiera confirmación en modo no interactivo.
        $env:TF_DATA_DIR = Join-Path $StateDir ".terraform-data"
    }

    # Se parte del workspace "default", que siempre existe, y luego se selecciona el del ambiente.
    $dataDir = if ($env:TF_DATA_DIR) { $env:TF_DATA_DIR } else { Join-Path $tfDir ".terraform" }
    $envFile = Join-Path $dataDir "environment"
    if (Test-Path $envFile) { Set-Content -Path $envFile -Value "default" -NoNewline }

    Invoke-Terraform $initArgs | Out-Null
    Invoke-Terraform @("workspace", "select", "-or-create", $Environment) | Out-Null

    # Réplicas que ya existen en el estado (vacío en el primer despliegue).
    $state = & terraform state list 2>$null
    $replicas = @($state | Select-String -Pattern 'module\.keycloak\.docker_container\.keycloak\["(\d+)"\]' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object)
    $lbRunning = [bool](docker ps -q --filter "name=^/$lbContainer$")

    # --------------------------------------------------------- rolling update
    if ($replicas.Count -ge 2 -and $lbRunning) {
        foreach ($id in $replicas) {
            $target = "-target=module.keycloak.docker_container.keycloak[`"$id`"]"
            $server = "keycloak-$id"

            # ¿Esta réplica cambia? (-detailed-exitcode: 0 = sin cambios, 2 = con cambios)
            $code = Invoke-Terraform (@("plan", "-detailed-exitcode", "-no-color", "-input=false", $target) + $tfVars) @(0, 2)
            if ($code -eq 0) {
                Write-Step "Réplica $server sin cambios: se mantiene en servicio"
                continue
            }

            Write-Step "Réplica ${server}: fuera del balanceador (MAINT) y drenado de $DrainSeconds s"
            Send-HAProxyCommand "set server be_keycloak/$server state maint" | Out-Null
            Start-Sleep -Seconds $DrainSeconds

            Write-Step "Réplica ${server}: reemplazo con Terraform (espera a /health/ready = UP)"
            try {
                Invoke-Terraform (@("apply", "-auto-approve", "-input=false", $target) + $tfVars) | Out-Null
            }
            catch {
                # No dejar la réplica fuera del balanceador: si sigue viva, vuelve a atender;
                # si quedó caída, el health check de HAProxy la mantiene fuera igualmente.
                Write-Warning "Falló el reemplazo de ${server}: se devuelve al balanceador antes de terminar."
                Send-HAProxyCommand "set server be_keycloak/$server state ready" | Out-Null
                throw
            }

            Write-Step "Réplica ${server}: de vuelta al balanceador"
            Send-HAProxyCommand "set server be_keycloak/$server state ready" | Out-Null
            Wait-ReplicaUp $server
            Write-Host "    $server UP en HAProxy" -ForegroundColor Green
        }
    }
    else {
        Write-Step "Primer despliegue (o menos de 2 réplicas): apply completo, sin rolling update"
    }

    # ------------------------------------------------- converger todo lo demás
    Write-Step "terraform apply completo (balanceador, base de datos, redes)"
    Invoke-Terraform (@("apply", "-auto-approve", "-input=false") + $tfVars) | Out-Null

    # ------------------------------------------------------------- smoke test
    Write-Step "Smoke test a través del balanceador"
    $base = "http://127.0.0.1:$httpPort"
    $checks = @(
        "$base/realms/master/.well-known/openid-configuration",
        "$base/realms/master/protocol/openid-connect/certs"
    )
    foreach ($url in $checks) {
        $ok = $false
        for ($i = 0; $i -lt 10 -and -not $ok; $i++) {
            try {
                $resp = Invoke-WebRequest -Uri $url -TimeoutSec 5 -SkipHttpErrorCheck
                $ok = $resp.StatusCode -eq 200
            }
            catch { $ok = $false }
            if (-not $ok) { Start-Sleep -Seconds 3 }
        }
        if (-not $ok) { throw "Smoke test fallido: $url" }
        Write-Host "    200 OK  $url" -ForegroundColor Green
    }

    # Keycloak debe anunciarse con la URL por la que se le llega (incluido el puerto). Un
    # "issuer" incorrecto hace que las aplicaciones rechacen los tokens aunque todo responda 200.
    $issuer = (Invoke-RestMethod -Uri $checks[0] -TimeoutSec 5).issuer
    $esperado = "$base/realms/master"
    if ($issuer -ne $esperado) {
        throw "Smoke test fallido: issuer '$issuer' (se esperaba '$esperado'). Revisar encabezados X-Forwarded-* del balanceador."
    }
    Write-Host "    issuer correcto: $issuer" -ForegroundColor Green

    # -------------------------------------------------------- idempotencia
    Write-Step "Verificación de idempotencia (el plan no debe tener cambios)"
    $code = Invoke-Terraform (@("plan", "-detailed-exitcode", "-no-color", "-input=false") + $tfVars) @(0, 2)
    if ($code -ne 0) { throw "Después del despliegue el plan todavía tiene cambios (deriva)." }

    Write-Step "Despliegue completado"
    & terraform output keycloak_url
    & terraform output loadbalancer_stats_url
}
finally {
    Pop-Location
    # No dejar TF_DATA_DIR cambiada en la sesión de PowerShell de quien ejecutó el script.
    $env:TF_DATA_DIR = $previousDataDir
}
