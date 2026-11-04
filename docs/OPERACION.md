# Guía rápida de operación (PowerShell 7)

Todos los comandos se ejecutan en `pwsh`, desde la raíz del repositorio.

## 0. Al abrir cada terminal (siempre)

```powershell
pwsh                         # si la ventana es "Windows PowerShell" (5.1)
. ./scripts/sesion.ps1       # con el punto inicial: carga secretos desde .env, TF_STATE_DIR y KC_IMAGE
```

Todo debe salir en `[OK]`. Las variables se pierden al cerrar la ventana o reiniciar el equipo.

## 1. Encender todo (después de reiniciar el equipo)

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

./gameday/gameday.ps1 -Escenario saturacion -Accion inyectar -Cpus 0.1 -TasaMax 80   # CPU + estrés (RB-02)
./gameday/gameday.ps1 -Escenario saturacion -Accion revertir
```

- Un escenario a la vez. Si se combinan (saturación + réplica), revertir en orden inverso.
- No desplegar mientras la saturación esté activa (Terraform devolvería la CPU).
- Las horas de cada inyección y mitigación quedan en `gameday/registro-<fecha>.log`.

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

```powershell
docker compose --env-file .env -f observability/docker-compose.yml down
docker volume rm keycloak-observability_promdata
docker compose --env-file .env -f observability/docker-compose.yml up -d
./gameday/gameday.ps1 -Accion carga -Duracion 14h
```

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
