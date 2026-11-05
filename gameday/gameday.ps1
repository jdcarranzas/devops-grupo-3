#Requires -Version 7.3
<#
.SYNOPSIS
    GameDay (Entregable 4): inyección controlada y reproducible de fallas sobre el despliegue
    de Keycloak, con registro de tiempos para la línea de tiempo del incidente.

.DESCRIPTION
    Escenarios:
      bd          Desconexión de la dependencia crítica: se detiene PostgreSQL (docker stop).
                  Esperado: 5xx en /token, PostgreSQLCaido (~1 min) y KeycloakDisponibilidadBurnRateAlto.
                  Runbook: RB-01.
      replica     Terminación abrupta de una réplica de Keycloak (docker kill).
                  Esperado: HAProxy la saca del balanceo, 0 errores al usuario, KeycloakReplicaCaida (warning).
                  Runbook: RB-03.
      saturacion  Agotamiento de recursos: se limita la CPU de las réplicas (docker update --cpus) y se
                  lanza un pico de carga con k6 (llega a -TasaMax en 20 s y dura -DuracionPico).
                  Esperado en ~1 min: sube el p95 de /token, la CPU queda al límite y se dispara el
                  burn rate de latencia de 5 m. La alerta crítica de latencia NO salta en minutos
                  (exige 72 % de lentas en 1 h): se detecta en el dashboard. Runbook: RB-02.

    Acciones:
      inyectar       Provoca la falla del escenario.
      revertir       Deshace la falla (mitigación) y espera a que el servicio se recupere.
      estado         Contenedores, réplicas en HAProxy, SLIs de 5 minutos y alertas activas.
      carga          Inicia k6 en segundo plano con tráfico nominal (-Duracion).
      detener-carga  Detiene k6.

    Cada acción queda registrada con fecha y hora en gameday/registro-<fecha>.log.

.EXAMPLE
    ./gameday/gameday.ps1 -Accion carga -Duracion 90m
    ./gameday/gameday.ps1 -Escenario bd -Accion inyectar
    ./gameday/gameday.ps1 -Accion estado
    ./gameday/gameday.ps1 -Escenario bd -Accion revertir
#>
[CmdletBinding()]
param(
    [ValidateSet("bd", "replica", "saturacion")]
    [string] $Escenario,

    [Parameter(Mandatory)]
    [ValidateSet("inyectar", "revertir", "estado", "carga", "detener-carga")]
    [string] $Accion,

    [ValidateSet("dev", "prod")]
    [string] $Ambiente = "prod",

    # Réplica que se termina en el escenario "replica".
    [int] $Replica = 2,

    # Límite de CPU por réplica durante el escenario "saturacion".
    [string] $Cpus = "0.15",

    # Tasa máxima (iteraciones/s) del pico de carga del escenario "saturacion".
    [int] $TasaMax = 60,

    # Cuánto se mantiene el pico de carga del escenario "saturacion" (formato de k6).
    [string] $DuracionPico = "6m",

    # Duración de la carga nominal (acción "carga").
    [string] $Duracion = "60m"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent $PSScriptRoot
$P = "keycloak-$Ambiente"
$lb = "$P-lb"
$statsPort = if ($Ambiente -eq "prod") { 8405 } else { 8404 }
$prometheus = "http://localhost:9090"
$compose = @("compose", "--env-file", (Join-Path $repoRoot ".env"), "-f", (Join-Path $repoRoot "observability/docker-compose.yml"))
$registro = Join-Path $PSScriptRoot ("registro-{0:yyyyMMdd}.log" -f (Get-Date))
$cpuFile = Join-Path $PSScriptRoot ".cpus-$Ambiente.json"

if ($Accion -in @("inyectar", "revertir") -and -not $Escenario) {
    throw "La acción '$Accion' necesita -Escenario (bd, replica o saturacion)."
}

# ------------------------------------------------------------------ utilidades
function Write-Evento([string] $mensaje, [string] $color = "Cyan") {
    $linea = "{0:yyyy-MM-dd HH:mm:ss}  [{1}] {2}" -f (Get-Date), ($Escenario ? $Escenario : "-"), $mensaje
    Add-Content -Path $registro -Value $linea -Encoding utf8
    Write-Host $linea -ForegroundColor $color
}

function Invoke-Docker([string[]] $arguments, [switch] $Quiet) {
    $out = & docker @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker $($arguments -join ' ') falló: $out" }
    if (-not $Quiet) { $out | Out-Host }
}

function Get-HAProxyServers {
    $csv = docker exec $lb sh -c "echo 'show stat' | nc 127.0.0.1 9999" 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    $csv | Where-Object { $_ -like "be_keycloak,keycloak-*" } | ForEach-Object {
        $f = $_ -split ","
        [pscustomobject]@{ Replica = $f[1]; Estado = $f[17]; Redispatch = $f[16]; ErroresConexion = $f[13] }
    }
}

function Get-PromValue([string] $query) {
    try {
        $r = Invoke-RestMethod -Uri "$prometheus/api/v1/query" -Body @{ query = $query } -TimeoutSec 5
        if ($r.data.result.Count -gt 0) { return [double]$r.data.result[0].value[1] }
    }
    catch { }
    return $null
}

function Wait-Healthy([string] $container, [int] $timeoutSeconds = 180) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $h = docker inspect --format '{{.State.Health.Status}}' $container 2>$null
        if ($h -eq "healthy") { return }
        Start-Sleep -Seconds 3
    }
    Write-Warning "$container no quedó healthy en $timeoutSeconds s."
}

function Wait-ReplicaUp([string] $server, [int] $timeoutSeconds = 180) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $s = Get-HAProxyServers | Where-Object Replica -eq $server
        if ($s -and $s.Estado -eq "UP") { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Show-Estado {
    Write-Host "`n--- Contenedores ($P) ---" -ForegroundColor Yellow
    docker ps -a --filter "name=$P" --format "table {{.Names}}\t{{.Status}}" | Out-Host

    Write-Host "--- Réplicas en HAProxy (http://localhost:$statsPort/stats) ---" -ForegroundColor Yellow
    $servers = Get-HAProxyServers
    if ($servers) { Write-Host ($servers | Format-Table -AutoSize | Out-String -Width 200).TrimEnd() } else { Write-Host "  (balanceador no disponible)" }

    Write-Host "--- SLIs (ventana de 5 minutos) ---" -ForegroundColor Yellow
    $err = Get-PromValue "keycloak:sli_disponibilidad:error_ratio_rate5m"
    $lat = Get-PromValue "keycloak:sli_latencia:error_ratio_rate5m"
    $pg = Get-PromValue 'pg_up{job="postgres"}'
    $up = Get-PromValue 'sum(up{job="keycloak"})'
    $p95 = Get-PromValue 'histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{job="keycloak", uri=~"/realms/.+"}[5m])))'
    # NaN = 0/0: no hubo peticiones en la ventana (por ejemplo, justo después de iniciar la carga).
    $fmt = { param($v, $f) if ($null -eq $v) { "sin datos" } elseif ([double]::IsNaN($v)) { "sin tráfico" } else { $f -f $v } }
    Write-Host ("  5xx (5 m): {0}   ·  lentas > 250 ms (5 m): {1}   ·  p95: {2}" -f `
        (& $fmt $err "{0:P2}"), (& $fmt $lat "{0:P2}"), (& $fmt $p95 "{0:N3} s"))
    Write-Host ("  Réplicas con métricas: {0}   ·  PostgreSQL (pg_up): {1}" -f (& $fmt $up "{0:N0}"), (& $fmt $pg "{0:N0}"))

    Write-Host "--- Alertas activas (Prometheus) ---" -ForegroundColor Yellow
    try {
        $alerts = (Invoke-RestMethod -Uri "$prometheus/api/v1/alerts" -TimeoutSec 5).data.alerts
        if ($alerts.Count -eq 0) { Write-Host "  ninguna" }
        foreach ($a in $alerts) {
            $color = if ($a.state -eq "firing") { "Red" } else { "DarkYellow" }
            Write-Host ("  {0,-38} {1,-8} {2}" -f $a.labels.alertname, $a.state, $a.labels.severity) -ForegroundColor $color
        }
    }
    catch { Write-Host "  (Prometheus no disponible en $prometheus)" }
    Write-Host ""
}

# ------------------------------------------------------------------- acciones
switch ($Accion) {
    "estado" { Show-Estado }

    "carga" {
        if (docker ps -q --filter "name=^/gameday-k6$") { Write-Host "La carga nominal ya está corriendo (gameday-k6)."; break }
        Invoke-Docker (@($compose) + @("run", "-d", "--rm", "--name", "gameday-k6", "-e", "DURACION=$Duracion", "k6", "run", "--quiet", "/scripts/carga.js")) -Quiet
        Write-Evento "Carga nominal iniciada con k6 (~5 req/s durante $Duracion)" "Green"
    }

    "detener-carga" {
        foreach ($c in @("gameday-k6", "gameday-k6-estres")) {
            if (docker ps -q --filter "name=^/$c$") { docker stop $c | Out-Null; Write-Evento "Carga detenida ($c)" "Green" }
        }
    }

    "inyectar" {
        switch ($Escenario) {
            "bd" {
                Write-Evento "INYECCIÓN: se detiene PostgreSQL ($P-postgres)" "Red"
                Invoke-Docker @("stop", "$P-postgres") -Quiet
                Write-Host "Esperado: 5xx en /token, PostgreSQLCaido en ~1 min, burn rate crítico en ~3-7 min (RB-01)."
            }
            "replica" {
                Write-Evento "INYECCIÓN: terminación abrupta de la réplica keycloak-$Replica (docker kill)" "Red"
                Invoke-Docker @("kill", "$P-keycloak-$Replica") -Quiet
                Write-Host "Esperado: HAProxy la saca en segundos, 0 errores al usuario, KeycloakReplicaCaida en ~1 min (RB-03)."
            }
            "saturacion" {
                $replicas = docker ps --filter "name=^/$P-keycloak-" --format "{{.Names}}"
                $actual = @{}
                foreach ($r in $replicas) { $actual[$r] = docker inspect --format '{{.HostConfig.NanoCpus}}' $r }
                $actual | ConvertTo-Json | Set-Content -Path $cpuFile -Encoding utf8
                Write-Evento "INYECCIÓN: CPU de las réplicas limitada a $Cpus núcleos ($($replicas -join ', '))" "Red"
                foreach ($r in $replicas) { Invoke-Docker @("update", "--cpus", $Cpus, $r) -Quiet }
                if (-not (docker ps -q --filter "name=^/gameday-k6-estres$")) {
                    Invoke-Docker (@($compose) + @("run", "-d", "--rm", "--name", "gameday-k6-estres", "-e", "PERFIL=pico",
                            "-e", "TASA_MAX=$TasaMax", "-e", "DURACION=$DuracionPico", "k6", "run", "--quiet", "/scripts/carga.js")) -Quiet
                    Write-Evento "Pico de carga iniciado: $TasaMax iteraciones/s en 20 s, durante $DuracionPico" "Red"
                }
                Write-Host "Esperado en ~1 min: p95 de /token arriba, CPU al límite, burn rate de latencia 5 m disparado (RB-02)."
                Write-Host "La alerta crítica de latencia no salta en minutos (exige 72 % de lentas en 1 h): mostrarlo en el dashboard."
            }
        }
    }

    "revertir" {
        switch ($Escenario) {
            "bd" {
                Write-Evento "MITIGACIÓN: se inicia PostgreSQL ($P-postgres)" "Green"
                Invoke-Docker @("start", "$P-postgres") -Quiet
                Wait-Healthy "$P-postgres"
                Write-Evento "PostgreSQL healthy; Keycloak se reconecta sin reiniciarse" "Green"
            }
            "replica" {
                Write-Evento "MITIGACIÓN: se inicia la réplica keycloak-$Replica" "Green"
                Invoke-Docker @("start", "$P-keycloak-$Replica") -Quiet
                if (Wait-ReplicaUp "keycloak-$Replica") { Write-Evento "keycloak-$Replica de nuevo UP en HAProxy" "Green" }
                else { Write-Warning "keycloak-$Replica no volvió a UP en HAProxy (ver RB-03)." }
            }
            "saturacion" {
                if (docker ps -q --filter "name=^/gameday-k6-estres$") {
                    docker stop gameday-k6-estres | Out-Null
                    Write-Evento "Carga de estrés detenida" "Green"
                }
                if (Test-Path $cpuFile) {
                    $guardado = Get-Content $cpuFile -Raw | ConvertFrom-Json
                    foreach ($prop in $guardado.PSObject.Properties) {
                        $cpus = [double]$prop.Value / 1e9
                        Invoke-Docker @("update", "--cpus", "$cpus", $prop.Name) -Quiet
                    }
                    Remove-Item -Force $cpuFile
                    Write-Evento "MITIGACIÓN: CPU de las réplicas restaurada al valor de Terraform" "Green"
                }
                else {
                    Write-Warning "No hay valores de CPU guardados: restaure con 'terraform apply' (los límites están en el tfvars)."
                }
            }
        }
    }
}

if ($Accion -in @("inyectar", "revertir")) { Show-Estado }
