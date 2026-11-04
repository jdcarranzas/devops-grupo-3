# RB-01 · Keycloak responde 5xx de forma masiva (caída o degradación de PostgreSQL)

| Campo | Valor |
|---|---|
| Severidad | **SEV-1 / crítica**: los usuarios no pueden iniciar sesión ni obtener tokens |
| Alertas que lo disparan | `KeycloakDisponibilidadBurnRateAlto` (página), `PostgreSQLCaido`, `KeycloakNoResponde`, `BalanceadorSinReplicas` |
| SLO afectado | Disponibilidad: 99.5 % de peticiones a `/realms/*` sin 5xx en 30 días (presupuesto ≈ 3 h 36 min) |
| Dashboard | Grafana → **Keycloak · SRE (SLOs y Golden Signals)** (`http://localhost:3000/d/keycloak-slo`) |
| Balanceador | `http://localhost:8405/stats` (estado de cada réplica) |
| Dueño | Persona de guardia del Grupo 3 |
| Tiempo objetivo | Acusar recibo ≤ 5 min · mitigar ≤ 30 min |

> **Por qué importa:** con una tasa de error del 100 %, el burn rate es 200x. Cada minuto de caída
> consume ≈ 0.46 % del presupuesto mensual, y el presupuesto completo se agota en ~3.6 horas.
> Las dos réplicas de Keycloak **no** protegen de este incidente: comparten la misma base de datos,
> que sigue siendo un punto único de falla (ver `docs/PRE-MORTEM.md`, escenario 1).

Los comandos son de PowerShell 7 (`pwsh`), desde la raíz del repositorio. Prefijo del ambiente:

```powershell
$P = "keycloak-prod"     # o keycloak-dev
```

---

## 0. Acusar recibo (minuto 0-5)

1. Tomar la alerta en Alertmanager (`http://localhost:9093`) y avisar en el canal del equipo:
   *"Tomo RB-01, investigando 5xx en Keycloak"*.
2. Si la alerta es un falso positivo evidente (por ejemplo, una prueba de carga programada),
   crear un **silencio** en Alertmanager con duración acotada y comentario.
3. Abrir el dashboard y anotar la hora de inicio del incidente (primer punto rojo del panel
   *Tasa de error 5xx*).

## 1. Triage: ¿qué está fallando? (minuto 5-10)

Mirar en este orden las filas **Alta disponibilidad**, **Logs estructurados**, **Golden Signals · Keycloak** y **PostgreSQL**:

| Observación en el dashboard | Hipótesis más probable | Ir a |
|---|---|---|
| `PostgreSQL = CAÍDA` (pg_up = 0) y 5xx en `/token` en **las dos** réplicas | Base de datos caída o inalcanzable | 2.A |
| PostgreSQL arriba, *Hilos esperando conexión* > 0 y conexiones / máximo cerca de 100 % | Pool de conexiones agotado o BD saturada | 2.B |
| *Réplicas sanas = 0* y `KeycloakNoResponde` | Las dos réplicas detenidas o reiniciándose | 2.C |
| *Réplicas sanas = 0* y `BalanceadorSinReplicas`, pero Keycloak **sí** entrega métricas | El health check del balanceador falla en las dos réplicas (revisar `/stats`, columna *LastChk*): HAProxy responde 503 y el SLI de Keycloak no lo ve | 2.C |
| *Réplicas sanas = 1*, sin 5xx al usuario | Una réplica caída: no es este runbook | [RB-03](RB-03-replica-caida.md) |
| Solo 5xx, sin problemas en BD ni en la JVM, justo después de un despliegue | Error de aplicación o de configuración | 2.D |

Señal característica de la caída de la BD: `discovery` y `certs` siguen respondiendo 200
(Keycloak los sirve desde caché), pero `/token` y el login devuelven **500**, y lo hacen **tarde**
(Keycloak espera la conexión antes de fallar), así que también sube la latencia.

**Logs (Grafana → panel *Errores y advertencias*, o Explore → Loki):**

```logql
# Errores de las réplicas, con la réplica que los produjo
{tier="compute", level="ERROR"} | json | line_format "{{.replica}} {{.loggerName}}: {{.message}}"

# Mensajes de PostgreSQL (FATAL al apagarse, errores de disco, etc.)
{tier="data", level=~"FATAL|ERROR|PANIC"}
```

Patrones típicos en el mensaje:

| Mensaje | Significado |
|---|---|
| `ModelException: Database operation failed` | La BD no responde |
| `PSQLException: Connection to ... refused` | PostgreSQL detenido |
| `Sorry, acquisition timeout expired` | Pool de conexiones agotado |
| `FATAL: the database system is shutting down` (PostgreSQL) | Apagado de la BD |

**Comandos de diagnóstico:**

```powershell
# Estado y health de los contenedores del ambiente
docker ps -a --filter "name=$P" --format "table {{.Names}}\t{{.Status}}"

# ¿PostgreSQL acepta conexiones?
docker exec "$P-postgres" pg_isready -U keycloak -d keycloak
docker logs --since 15m "$P-postgres" 2>&1 | Select-Object -Last 30

# Errores recientes de una réplica (los logs son JSON)
docker logs --since 15m "$P-keycloak-1" 2>&1 | Select-String '"level":"ERROR"' | Select-Object -Last 10
```

**Consultas PromQL** (Prometheus → `http://localhost:9090/graph`):

```promql
# Tasa de error del SLI en los últimos 5 minutos
keycloak:sli_disponibilidad:error_ratio_rate5m

# ¿Qué endpoints y qué réplica fallan?
sum by (replica, uri, status) (rate(http_server_requests_seconds_count{job="keycloak", outcome="SERVER_ERROR"}[5m]))

# Estado de la base de datos y del pool
pg_up{job="postgres"}
agroal_awaiting_count{job="keycloak"}
sum(pg_stat_activity_count{datname="keycloak"}) / max(pg_settings_max_connections)
```

## 2. Mitigación

### 2.A PostgreSQL caído

```powershell
# 1. Ver por qué se detuvo (OOM, disco lleno, apagado manual, error de arranque)
docker inspect --format '{{.State.Status}} exit={{.State.ExitCode}} OOM={{.State.OOMKilled}}' "$P-postgres"
docker logs --tail 50 "$P-postgres"

# 2. Levantarlo de nuevo (los datos están en el volumen $P-pgdata, no se pierden)
docker start "$P-postgres"

# 3. Esperar a que esté healthy
docker inspect --format '{{.State.Health.Status}}' "$P-postgres"
```

- Si murió por **OOM** (`OOMKilled=true`), subir `db_memory_mb` en `terraform/environments/<ambiente>.tfvars`
  y desplegar con un PR (no a mano: el cambio debe quedar en el código).
- Si el **disco está lleno**: `docker system df`, liberar imágenes o volúmenes huérfanos
  (`docker image prune`). **Nunca** borrar el volumen `$P-pgdata`.
- Si el volumen está corrupto y PostgreSQL no arranca: restaurar el último respaldo con
  [RB-04](RB-04-restauracion-bd.md).

Keycloak **se reconecta solo** cuando la BD vuelve: no hace falta reiniciar las réplicas. Si después
de 2 minutos con la BD arriba alguna sigue respondiendo 5xx, reiniciarla de a una
(`docker restart "$P-keycloak-1"`, esperar UP en `/stats`, luego la otra).

### 2.B Pool de conexiones agotado / BD saturada

```powershell
# Consultas activas y lentas en PostgreSQL
docker exec "$P-postgres" psql -U keycloak -d keycloak -c `
  "SELECT pid, state, now() - xact_start AS duracion, left(query, 80) FROM pg_stat_activity WHERE datname = 'keycloak' ORDER BY duracion DESC NULLS LAST LIMIT 10;"

# Terminar una transacción bloqueada (solo si lleva minutos y bloquea a otras)
docker exec "$P-postgres" psql -U keycloak -d keycloak -c "SELECT pg_terminate_backend(<pid>);"
```

- Si la causa es un pico de tráfico, reducir la carga (detener la prueba de carga o deshabilitar al
  cliente que la origina) y, si el host lo permite, subir CPU/RAM de PostgreSQL.
- Con dos réplicas, cada una abre su propio pool: el máximo de conexiones a la BD es
  `réplicas × KC_DB_POOL_MAX_SIZE`. Ajuste permanente (no durante el incidente) con un ticket.

### 2.C Las dos réplicas detenidas o en ciclo de reinicio

```powershell
docker inspect --format '{{.Name}} {{.State.Status}} reinicios={{.RestartCount}} OOM={{.State.OOMKilled}}' "$P-keycloak-1" "$P-keycloak-2"
docker logs --tail 100 "$P-keycloak-1"
docker start "$P-keycloak-1" "$P-keycloak-2"
```

Si fue OOM, subir `keycloak_memory_mb` (la JVM toma ~70 % del límite como heap). Si no arrancan por
configuración, ir a 2.D.

### 2.D Error de aplicación tras un cambio

1. Revisar el último despliegue: GitHub → *Actions → Deploy* (commit e imagen desplegados) y `git log -5 --oneline`.
2. **Rollback** a la imagen anterior, que está en GHCR con tag inmutable `sha-<commit>`:
   GitHub → *Actions → Deploy → Run workflow* con `image_tag = sha-<commit_anterior>`, o a mano:
   ```powershell
   ./scripts/deploy.ps1 -Environment prod -Image ghcr.io/jdcarranzas/devops-grupo-3:sha-<commit_anterior> `
       -StateDir C:/terraform-state/devops-grupo-3
   ```
   El rollback también es un rolling update: no agrega tiempo de caída.
3. Abrir un incidente con el commit sospechoso. Por la Error Budget Policy no se hace *roll-forward*
   con un parche nuevo mientras el servicio está caído.

## 3. Verificación del restablecimiento

El incidente solo se cierra cuando se cumplen **todas** estas condiciones:

- [ ] `http://localhost:8405/stats`: `keycloak-1` y `keycloak-2` en **UP**; `$P-postgres` healthy.
- [ ] Se puede obtener un token a través del balanceador:
  ```powershell
  $r = Invoke-WebRequest -Method Post -Uri http://localhost:8081/realms/demo/protocol/openid-connect/token `
    -Body @{ grant_type='client_credentials'; client_id='servicio-demo'; client_secret='secreto-solo-para-pruebas-de-carga' } `
    -SkipHttpErrorCheck
  $r.StatusCode    # Esperado: 200
  ```
- [ ] En el dashboard, *Tasa de error 5xx* vuelve a 0 % y el *burn rate 5 m* baja de 14.4.
- [ ] El panel *Errores y advertencias* deja de mostrar `PSQLException`.
- [ ] La alerta `KeycloakDisponibilidadBurnRateAlto` pasa a **resolved** en Alertmanager.
      Se apaga cuando la ventana corta deja de ver errores: unos 5 minutos si saltó por la condición
      1 h / 5 m, y hasta 30 minutos si saltó por la condición 6 h / 30 m. Mientras tanto, confirmar en el
      panel *Burn rate · disponibilidad* que la serie de 5 m está en 0.

## 4. Después del incidente

1. Anotar en el dashboard (Grafana → clic derecho sobre el panel → *Add annotation*) el inicio,
   la mitigación y la causa.
2. Registrar el **presupuesto consumido** (panel *Saldo del presupuesto de error*). Si quedó por debajo
   del 25 % o se agotó, aplicar la Error Budget Policy (congelamiento de cambios no críticos).
3. Hacer un **postmortem sin culpables** dentro de las 48 horas si el incidente consumió más del 20 %
   del presupuesto, con acciones correctivas priorizadas en el siguiente sprint.

## Simulación controlada (GameDay)

```powershell
./gameday/gameday.ps1 -Escenario bd -Accion inyectar     # docker stop de PostgreSQL
#   ~1 min    -> PostgreSQLCaido (FIRING)
#   ~3-7 min  -> KeycloakDisponibilidadBurnRateAlto (PENDING -> FIRING; depende del historial de 1 h)
./gameday/gameday.ps1 -Escenario bd -Accion revertir     # docker start de PostgreSQL
```
