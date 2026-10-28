# RB-01 · Keycloak responde 5xx de forma masiva (caída o degradación de PostgreSQL)

| Campo | Valor |
|---|---|
| Severidad | **SEV-1 / crítica**: los usuarios no pueden iniciar sesión ni obtener tokens |
| Alertas que lo disparan | `KeycloakDisponibilidadBurnRateAlto` (página), `PostgreSQLCaido`, `KeycloakNoResponde` |
| SLO afectado | Disponibilidad: 99.5 % de peticiones a `/realms/*` sin 5xx en 30 días (presupuesto ≈ 3 h 36 min) |
| Dashboard | Grafana → *Keycloak SRE* → **Keycloak · SRE (SLOs y Golden Signals)** (`http://localhost:3000/d/keycloak-slo`) |
| Dueño | Persona de guardia del Grupo 3 |
| Tiempo objetivo | Acusar recibo ≤ 5 min · mitigar ≤ 30 min |

> **Por qué importa:** con una tasa de error del 100 %, el burn rate es 200x. Cada minuto de caída
> consume ≈ 0.46 % del presupuesto mensual, y el presupuesto completo se agota en ~3.6 horas.

---

## 0. Acusar recibo (minuto 0-5)

1. Tomar la alerta en Alertmanager (`http://localhost:9093`) y avisar en el canal del equipo:
   *"Tomo RB-01, investigando 5xx en Keycloak"*.
2. Si la alerta es un falso positivo evidente (por ejemplo, una prueba de carga programada),
   crear un **silencio** en Alertmanager con duración acotada y comentario.
3. Abrir el dashboard y anotar la hora de inicio del incidente (primer punto rojo del panel
   *Tasa de error 5xx*).

## 1. Triage: ¿qué está fallando? (minuto 5-10)

Mirar en este orden la fila **Golden Signals · Keycloak** y la fila **PostgreSQL**:

| Observación en el dashboard | Hipótesis más probable | Ir a |
|---|---|---|
| `PostgreSQL = CAÍDA` (pg_up = 0) y 5xx en `/token` | Base de datos caída o inalcanzable | 2.A |
| PostgreSQL arriba, *Hilos esperando conexión* > 0 y conexiones / máximo cerca de 100 % | Pool de conexiones agotado o BD saturada | 2.B |
| `Keycloak · métricas disponibles = CAÍDO` | El contenedor de Keycloak está detenido o reiniciándose | 2.C |
| Solo 5xx, sin problemas en BD ni en la JVM | Error de aplicación (despliegue reciente o configuración) | 2.D |

Señal característica de la caída de la BD: `discovery` y `certs` siguen respondiendo 200
(Keycloak los sirve desde caché), pero `/token` y el login devuelven **500**.

Comandos de diagnóstico (desde la raíz del repositorio, en PowerShell o bash):

```bash
# Estado y health de los contenedores
docker compose ps
docker inspect --format '{{.State.Health.Status}}' kc-app kc-postgres

# Health de Keycloak: el check "database connections" pasa a DOWN si no hay BD
curl -s http://localhost:9000/health/ready

# Errores recientes de Keycloak
docker logs --since 15m kc-app 2>&1 | grep -E "ERROR|PSQLException" | tail -20
#   Patrones típicos:
#   "ModelException: Database operation failed"            -> la BD no responde
#   "PSQLException: Connection to ... refused"             -> PostgreSQL detenido
#   "Sorry, acquisition timeout expired"                   -> pool de conexiones agotado

# ¿PostgreSQL acepta conexiones?
docker exec kc-postgres pg_isready -U keycloak -d keycloak
docker logs --since 15m kc-postgres | tail -30
```

Consultas PromQL útiles (Prometheus → `http://localhost:9090/graph`):

```promql
# Tasa de error del SLI en los últimos 5 minutos
keycloak:sli_disponibilidad:error_ratio_rate5m

# ¿Qué endpoints fallan?
sum by (uri, status) (rate(http_server_requests_seconds_count{job="keycloak", outcome="SERVER_ERROR"}[5m]))

# Estado de la base de datos y del pool
pg_up{job="postgres"}
agroal_awaiting_count{job="keycloak"}
sum(pg_stat_activity_count{datname="keycloak"}) / max(pg_settings_max_connections)
```

## 2. Mitigación

### 2.A PostgreSQL caído

```bash
# 1. Ver por qué se detuvo (OOM, disco lleno, apagado manual, error de arranque)
docker inspect --format '{{.State.Status}} {{.State.ExitCode}} OOM={{.State.OOMKilled}}' kc-postgres
docker logs --tail 50 kc-postgres

# 2. Levantarlo de nuevo (los datos están en el volumen pgdata, no se pierden)
docker compose start postgres          # o: docker start kc-postgres

# 3. Esperar a que esté healthy
docker compose ps postgres
```

- Si murió por **OOM** (`OOMKilled=true`), subir la memoria del contenedor
  (`db_memory_mb` en `terraform/environments/*.tfvars`) y volver a aplicar.
- Si el **disco está lleno**: `docker system df`, liberar espacio de imágenes o volúmenes huérfanos
  (`docker image prune`). **Nunca** borrar el volumen `pgdata`.
- Si el volumen está corrupto y PostgreSQL no arranca: escalar al responsable de datos y restaurar
  el último respaldo (`pg_dump`) en un volumen nuevo.

Keycloak **se reconecta solo** cuando la BD vuelve: no hace falta reiniciarlo. Si después de
2 minutos con la BD arriba sigue respondiendo 5xx, reiniciarlo: `docker compose restart keycloak`.

### 2.B Pool de conexiones agotado / BD saturada

```bash
# Consultas activas y lentas en PostgreSQL
docker exec kc-postgres psql -U keycloak -d keycloak -c \
  "SELECT pid, state, now() - xact_start AS duracion, left(query, 80)
     FROM pg_stat_activity WHERE datname = 'keycloak' ORDER BY duracion DESC NULLS LAST LIMIT 10;"

# Terminar una transacción bloqueada (solo si lleva minutos y bloquea a otras)
docker exec kc-postgres psql -U keycloak -d keycloak -c "SELECT pg_terminate_backend(<pid>);"
```

- Si la causa es un pico de tráfico, reducir la carga (detener la prueba de carga o limitar al
  cliente que la origina) y, si el host lo permite, subir CPU/RAM de PostgreSQL.
- Ajuste permanente (no durante el incidente): `KC_DB_POOL_MAX_SIZE` en Keycloak y
  `max_connections` en PostgreSQL, documentado en un ticket.

### 2.C Keycloak detenido o en ciclo de reinicio

```bash
docker compose ps keycloak
docker inspect --format '{{.State.Status}} reinicios={{.RestartCount}} OOM={{.State.OOMKilled}}' kc-app
docker logs --tail 100 kc-app
docker compose up -d keycloak
```

Si fue OOM, subir `keycloak_memory_mb` (la JVM toma ~70 % del límite como heap).

### 2.D Error de aplicación tras un cambio

1. Revisar el último despliegue (`git log -5 --oneline`, pestaña *Actions* en GitHub).
2. **Rollback** a la imagen anterior, que está en GHCR con tag inmutable `sha-<commit>`:
   ```bash
   # Despliegue con Terraform (prod):
   terraform apply -var-file=environments/prod.tfvars \
     -var 'keycloak_image=ghcr.io/jdcarranzas/devops-grupo-3:sha-<commit_anterior>'
   ```
3. Abrir un incidente con el commit sospechoso. Por la Error Budget Policy no se hace *roll-forward*
   con un parche nuevo mientras el servicio está caído.

## 3. Verificación del restablecimiento

El incidente solo se cierra cuando se cumplen **todas** estas condiciones:

- [ ] `docker compose ps` muestra `kc-app` y `kc-postgres` como **healthy**.
- [ ] `curl -s http://localhost:9000/health/ready` devuelve `"status": "UP"` con el check de base de datos en UP.
- [ ] Se puede obtener un token:
  ```bash
  curl -s -o /dev/null -w "%{http_code}\n" -X POST \
    http://localhost:8080/realms/master/protocol/openid-connect/token \
    -d grant_type=password -d client_id=admin-cli \
    -d username="$KC_BOOTSTRAP_ADMIN_USERNAME" -d password="$KC_BOOTSTRAP_ADMIN_PASSWORD"
  # Esperado: 200
  ```
- [ ] En el dashboard, *Tasa de error 5xx* vuelve a 0 % y el *burn rate 5 m* baja de 14.4.
- [ ] La alerta `KeycloakDisponibilidadBurnRateAlto` pasa a **resolved** en Alertmanager.
      Se apaga cuando la ventana corta deja de ver errores: unos 5 minutos si saltó por la condición
      1 h / 5 m, y hasta 30 minutos si saltó por la condición 6 h / 30 m. Mientras tanto, confirmar en el
      panel *Burn rate · disponibilidad* que la serie de 5 m está en 0.

## 4. Después del incidente

1. Anotar en el dashboard (Grafana → clic derecho sobre el panel → *Add annotation*) el inicio,
   la mitigación y la causa.
2. Registrar el **presupuesto consumido** (panel *Saldo del presupuesto de error*). Si quedó por debajo
   del 25 % o se agotó, aplicar la [Error Budget Policy](../README.md#política-de-presupuesto-de-error).
3. Hacer un **postmortem sin culpables** dentro de las 48 horas si el incidente consumió más del 20 %
   del presupuesto, con acciones correctivas priorizadas en el siguiente sprint.

## Simulación controlada (para pruebas y para el informe)

```bash
# Con la pila y la carga nominal corriendo:
docker compose stop postgres         # provoca el incidente
#   ~1 min  -> PostgreSQLCaido (FIRING)
#   ~5-7 min -> KeycloakDisponibilidadBurnRateAlto (PENDING -> FIRING)
docker compose start postgres        # mitigación
```
