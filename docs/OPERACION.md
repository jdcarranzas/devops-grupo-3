# Guía rápida de operación (PowerShell 7)

Todos los comandos se ejecutan en `pwsh`, desde la raíz del repositorio.

## 0. Al abrir cada terminal (siempre)

```powershell
pwsh                         # si la ventana es "Windows PowerShell" (5.1)
. ./scripts/sesion.ps1       # con el punto inicial: secretos desde .env, $P, TF_STATE_DIR y KC_IMAGE
```

Todo debe salir en `[OK]`. Las variables se pierden al cerrar la ventana o reiniciar el equipo.

## 1. Encender todo (después de reiniciar el equipo).

```powershell
# Docker Desktop debe estar abierto ("Engine running")
./scripts/deploy.ps1 -Environment prod -Image $env:KC_IMAGE -StateDir $env:TF_STATE_DIR
docker compose --env-file .env -f observability/docker-compose.yml up -d
./gameday/gameday.ps1 -Accion carga -Duracion 2h
./gameday/gameday.ps1 -Accion estado          # 2 réplicas UP, 5xx 0 %, sin alertas
```

Runner de GitHub (para despliegues automáticos), en **otra** ventana: `cd C:\actions-runner; ./run.cmd`.

## 2. Revisar

| Qué | Dónde |
|---|---|
| Dashboard | http://localhost:3000 |
| Balanceador (réplicas UP/DOWN) | http://localhost:8405/stats |
| Alertas | http://localhost:9093 (Alertmanager) · http://localhost:9090/alerts |
| Keycloak (consola) | http://localhost:8081 |
| Pipeline de logs | http://localhost:12345 (Alloy) |

## 3. GameDay (inyectar → observar → revertir)

```powershell
./gameday/gameday.ps1 -Escenario bd      -Accion inyectar    # caída de PostgreSQL (RB-01)
./gameday/gameday.ps1 -Escenario bd      -Accion revertir

./gameday/gameday.ps1 -Escenario replica -Accion inyectar    # docker kill de keycloak-2 (RB-03)
./gameday/gameday.ps1 -Escenario replica -Accion revertir

./gameday/gameday.ps1 -Escenario saturacion -Accion inyectar    # 0.15 CPU por réplica + pico de 60 it/s en 20 s (RB-02)
./gameday/gameday.ps1 -Escenario saturacion -Accion revertir
#    ajustes: -Cpus 0.1 (más presión)  -TasaMax 40 (menos presión)  -DuracionPico 3m
```

| Escenario | Señal en vivo | Alerta y tiempo |
|---|---|---|
| `bd` | 5xx ~85 % en `/token`, p95 en segundos, `PSQLException` en logs; réplicas siguen UP en `/stats` | `PostgreSQLCaido` ~1 min · `KeycloakDisponibilidadBurnRateAlto` ~7 min |
| `replica` | Réplicas sanas = 1, tráfico pasa a la otra, 5xx al usuario = 0, *redispatch* | `KeycloakReplicaCaida` (warning) ~1 min |
| `saturacion` | p95 de `/token` arriba y CPU del contenedor pegada al límite en ~1 min | Ninguna crítica en minutos (exige 72 % de lentas en 1 h): se muestra en el dashboard |

- Un escenario a la vez. Si se combinan (saturación + réplica), revertir en orden inverso.
- Siempre revertir la saturación: el pico de k6 termina solo (~7 min), pero el límite de CPU queda hasta `revertir`.
- No desplegar mientras la saturación esté activa (Terraform devolvería la CPU).
- Las horas de cada inyección y mitigación quedan en `gameday/registro-<fecha>.log`.

## 3b. Diagnóstico rápido en producción (Docker)

Requiere `$P` (lo define `sesion.ps1`). Si sale `unknown shorthand flag: 'k' in -keycloak-1`, `$P` está vacía:
ejecutar `. ./scripts/sesion.ps1` o `$P = "keycloak-prod"`.

```powershell
docker ps -a --filter "name=$P" --format "table {{.Names}}\t{{.Status}}"            # ¿qué corre y qué está detenido?
docker stats --no-stream "$P-keycloak-1" "$P-keycloak-2" "$P-postgres"             # CPU y memoria reales
docker inspect --format '{{.Name}} cpus={{.HostConfig.NanoCpus}}' "$P-keycloak-1" "$P-keycloak-2"   # límite de CPU
docker inspect --format '{{.Name}} {{.State.Status}} exit={{.State.ExitCode}} OOM={{.State.OOMKilled}} reinicios={{.RestartCount}}' "$P-keycloak-1" "$P-keycloak-2"
```

Cómo leer `docker stats`:

| Columna | Cómo interpretarla |
|---|---|
| **CPU %** | 100 % = **un núcleo**. Comparar con el límite: `NanoCpus` ÷ 1 000 000 000 = núcleos (2000000000 = 2 núcleos = 200 %). Si CPU % ≈ límite (p. ej. 15 % con `cpus=150000000`), la réplica está **saturada** → RB-02 |
| **MEM USAGE / LIMIT** | Cerca del 100 % del límite = riesgo de OOM. En Keycloak, ~25-30 % es normal |
| **PIDS** | Procesos e hilos (en Keycloak, hilos de la JVM: ~80-90 es normal). **No son errores**. `0` = contenedor detenido |
| `0B / 0B` y PIDS 0 | El contenedor **no está corriendo** → `docker inspect` para ver el motivo |

Cómo leer `docker inspect` del estado:

| Resultado | Significado | Runbook |
|---|---|---|
| `exited exit=137 OOM=false` | Terminación externa (`docker kill`, GameDay) | RB-03 |
| `OOM=true` | Se quedó sin memoria | RB-03 (subir `keycloak_memory_mb` por PR) |
| `running` pero sin responder | Saturación o bloqueo | RB-02 |
| `reinicios` aumentando | Falla al arrancar (configuración, BD) | RB-01 / RB-03 + logs |

Los **errores** no se ven en `docker stats`. Se ven en:

| Dónde | Qué mirar |
|---|---|
| http://localhost:8405/stats | **Errors → Conn / Resp**, **Warnings → Retr / Redis**, **Status** y **LastChk** de cada réplica |
| `./gameday/gameday.ps1 -Accion estado` | Réplicas en HAProxy (Estado, Redispatch, ErroresConexion), SLIs de 5 min y alertas activas |
| Grafana · *Alta disponibilidad* | *5xx entregados al usuario, reintentos y redispatch* |
| Grafana · *Golden Signals* | *Errores por código HTTP* y *Tasa de error 5xx* |
| Grafana · *Logs estructurados* | Causa raíz (`PSQLException`, `FATAL`, etc.) por réplica |

## 4. Desplegar un cambio

Normal (por el pipeline): rama → PR → aprobación de un compañero → merge → *Actions → Deploy* corre solo.

A mano (pruebas o emergencia):

```powershell
git checkout main; git pull
. ./scripts/sesion.ps1                         # recalcula KC_IMAGE con el commit actual
./scripts/deploy.ps1 -Environment prod -Image $env:KC_IMAGE -StateDir $env:TF_STATE_DIR
```

Debe terminar en `issuer correcto` y `No changes`. Rollback: el mismo comando con `-Image ghcr.io/jdcarranzas/devops-grupo-3:sha-<commit anterior>`.

## 5. Reiniciar la telemetría (historial limpio)

Borra **métricas (Prometheus) y logs (Loki)** para empezar desde 0. No toca Keycloak, HAProxy ni Postgres
(son de Terraform), solo la pila `obs-*`. Calendario previo a la sesión:

- **Jueves:** reinicio de prueba (limpiar lo de los ensayos).
- **Viernes en la noche:** reinicio definitivo + carga de 14 h, para llegar el sábado con historia limpia y SLO al 100 %.
- **Sábado:** no reiniciar; en Grafana usar el rango *Last 30 minutes*.

```powershell
# 1. Detener la carga si estaba corriendo
./gameday/gameday.ps1 -Accion detener-carga

# 2. Bajar la pila de observabilidad y borrar el historial
docker compose --env-file .env -f observability/docker-compose.yml down
docker volume rm keycloak-observability_promdata keycloak-observability_lokidata

# 3. Levantarla de nuevo y relanzar la carga
docker compose --env-file .env -f observability/docker-compose.yml up -d
./gameday/gameday.ps1 -Accion carga -Duracion 14h
```

**Si el `volume rm` falla con `volume is in use`**, quedó algún contenedor usando el volumen (el `down` no
corrió o no los encontró). Ver cuál es y forzar su borrado:

```powershell
docker ps -a --filter volume=keycloak-observability_promdata --filter volume=keycloak-observability_lokidata --format "table {{.Names}}\t{{.Status}}"

docker rm -f obs-prometheus obs-loki
docker volume rm keycloak-observability_promdata keycloak-observability_lokidata
docker compose --env-file .env -f observability/docker-compose.yml up -d
./gameday/gameday.ps1 -Accion carga -Duracion 14h
```

Qué esperar después del reinicio:

- Los primeros minutos el SLO y el burn rate se ven "nerviosos": con poco tráfico acumulado cualquier error pesa
  mucho. Se estabilizan con horas de carga continua.
- Los WARN `LOGIN_ERROR` (`invalid_user_credentials`, usuario `usuario-demo`) reaparecen apenas arranca k6: son
  intencionales (k6 prueba una contraseña incorrecta). No son una falla.

Si se cambia algún archivo de configuración de `observability/`, recrear la pila (`down` + `up -d`) o reiniciar el
contenedor afectado: `up -d` no recarga los archivos montados.

## 6. Respaldo de la base de datos

```powershell
./scripts/backup-db.ps1          # crea y verifica backups/keycloak-prod-<fecha>.dump
```

## 7. Al terminar

```powershell
./gameday/gameday.ps1 -Accion detener-carga
```

Cerrar la ventana de `run.cmd` (los despliegues quedan en cola hasta volver a abrirla). Los contenedores pueden
quedar encendidos o apagarse con Docker Desktop: al reiniciar, el paso 1 los deja como estaban.
