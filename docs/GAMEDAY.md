# GameDay y sustentación · guion (Entregable 4)

Sesión: **sábado 7 de noviembre de 2026, 7:00-10:00 a. m.** · 20 minutos por equipo · pantalla compartida.
Todos los comandos son de PowerShell 7 (`pwsh`), desde la raíz del repositorio.

## 1. Preparación

### Viernes en la noche (≥ 10 h antes)

```powershell
# 1. Sistema desplegado y sin deriva (debe terminar en "No changes")
./scripts/deploy.ps1 -Environment prod -Image ghcr.io/jdcarranzas/devops-grupo-3:sha-<último main> -StateDir C:/terraform-state/devops-grupo-3

# 2. Telemetría limpia (borra el historial de pruebas anteriores)
docker compose --env-file .env -f observability/docker-compose.yml down
docker volume rm keycloak-observability_promdata
docker compose --env-file .env -f observability/docker-compose.yml up -d

# 3. Tráfico nominal toda la noche: los SLIs de 30 días quedan con historia suficiente
#    para que una falla en vivo consuma presupuesto de forma proporcional, no de golpe.
./gameday/gameday.ps1 -Accion carga -Duracion 14h

# 4. Respaldo de la BD (control del Pre-Mortem)
./scripts/backup-db.ps1
```

Además: Docker Desktop configurado para iniciar con Windows, suspensión del equipo desactivada y
actualizaciones de Windows pausadas hasta el domingo.

### Sábado, 6:30 a. m. (checklist)

- [ ] `./gameday/gameday.ps1 -Accion estado`: 2 réplicas UP, PostgreSQL con métricas, **sin alertas**, 5xx = 0 %.
- [ ] k6 sigue corriendo (`docker ps --filter name=gameday-k6`). Si terminó: `-Accion carga -Duracion 4h`.
- [ ] Runner de GitHub en línea (*Settings → Actions → Runners*: `Idle`) con `run.cmd` abierto en su ventana.
- [ ] PR del cambio de la demo abierto, con todos los checks en verde y aprobado (sin hacer merge).
- [ ] Pestañas abiertas en este orden:
  1. GitHub: PR · *Actions*
  2. Grafana `http://localhost:3000` (dashboard, rango *Last 15 minutes*, refresco 5 s)
  3. HAProxy `http://localhost:8405/stats`
  4. Alertmanager `http://localhost:9093`
  5. Prometheus `http://localhost:9090/alerts`
  6. `docs/PRE-MORTEM.md` en GitHub
- [ ] Dos terminales `pwsh` en la raíz del repo (una para comandos, otra con `-Accion estado` a mano).
- [ ] Zoom del navegador al 110-125 % para que se lea en la pantalla compartida.

## 2. Guion (20 minutos)

Los roles rotan para que los tres hablen. Cualquiera puede recibir una pregunta: todos deben poder
explicar cualquier bloque.

### Bloque 1 · Despliegue continuo (5 min) · presenta: Integrante A

| Min | Acción | Qué decir |
|---|---|---|
| 0:00 | Arquitectura: `DESPLIEGUE.md` §1 o el panel *Alta disponibilidad* + `/stats` | HAProxy es la única entrada; 2 réplicas en clúster (`jdbc-ping`) sin puertos publicados; PostgreSQL en red interna. Todo con Terraform (10 recursos, 4 módulos) |
| 1:00 | **Merge del PR** | Cambio: `keycloak_log_level = "INFO,org.keycloak.events:DEBUG"` en `prod.tfvars` |
| 1:15 | *Actions*: workflow **CI** corriendo | Lint → build → Trivy (compuerta CRITICAL) → push `sha-<commit>` a GHCR. Mientras corre: el PR ya pasó Terraform (plan + OPA) y Observability (promtool) |
| ~3:30 | Workflow **Deploy** en el runner `windows` | Runner autoalojado: solo hace *polling* saliente; en la nube sería OIDC + runner en la VPC |
| ~4:00 | Grafana: *Estado de cada réplica* (una en rojo y luego la otra) y *5xx al usuario* en 0 | Rolling update: MAINT en HAProxy → drenado → `apply -target` → UP → siguiente. El SLI de disponibilidad no se mueve |
| ~5:00 | Resumen del job (imagen, commit) y `No changes` final | Idempotencia comprobada en cada despliegue |

> Si el CI tarda más de lo previsto, se continúa con el Bloque 2 y se vuelve a mostrar el Deploy al final.
> Plan B si GitHub falla: `./scripts/deploy.ps1` a mano (mismo rolling update) y mostrar una ejecución
> anterior exitosa del workflow.

### Bloque 2 · GameDay (10 min) · presentan: Integrante B (inyecta y mitiga), Integrante C (triage)

**Escenario principal: desconexión de la base de datos** (RB-01)

| Min | Acción | Qué mirar / decir |
|---|---|---|
| 5:00 | `./gameday/gameday.ps1 -Escenario bd -Accion inyectar` | "Simulamos la caída de la dependencia crítica" |
| 5:30 | Grafana, fila *Golden Signals*: **errores** (tasa 5xx ~82 %), **latencia** (p95 sube a segundos), **tráfico** estable, **saturación** (pool de conexiones) | Las dos réplicas fallan igual → no es una réplica, es algo compartido. En `/stats` las réplicas siguen UP: el health check es de *liveness* (hallazgo del ensayo, ver Pre-Mortem §8) |
| 6:00 | Panel *Errores y advertencias* (Loki): `PSQLException: Connection refused` en keycloak-1 y keycloak-2 + `FATAL` de PostgreSQL | **Causa raíz identificada con los logs**; discovery/JWKS siguen en 200 (caché) |
| 6:30 | Alertmanager: `PostgreSQLCaido` FIRING | Alerta de causa, ~1 min |
| 7:00 | Panel *Burn rate*: 5 m muy por encima de 14.4x; 1 h subiendo | Explicar multiventana: la página exige 1 h **y** 5 m → ~5-7 min con historial completo. Evita páginas por picos |
| ~11:00 | `KeycloakDisponibilidadBurnRateAlto` FIRING (critical) | Presupuesto consumido visible en el gauge |
| 11:30 | `./gameday/gameday.ps1 -Escenario bd -Accion revertir` | Mitigación de RB-01 §2.A; Keycloak se reconecta solo |
| 12:30 | 5xx vuelve a 0, `-Accion estado` limpio | Verificación de RB-01 §3; la alerta tarda en resolverse por la ventana corta (explicar) |

**Escenario adicional, si queda tiempo: terminación de una réplica** (RB-03), ~2 min

| Min | Acción | Qué mirar / decir |
|---|---|---|
| 13:00 | `./gameday/gameday.ps1 -Escenario replica -Accion inyectar` | `/stats`: keycloak-2 en MAINT (resolution); *Redis* sube; **0 errores** |
| 14:00 | `KeycloakReplicaCaida` PENDING → FIRING como *warning* | Ticket, no página: el usuario no se afectó, pero se perdió la redundancia |
| 14:30 | `./gameday/gameday.ps1 -Escenario replica -Accion revertir` | Vuelve sola a UP en HAProxy |

> Si el burn rate tarda más de lo esperado en disparar, no se espera: se explica la condición con el panel
> (1 h todavía por debajo de 7.2 %) y se pasa al escenario de réplica. Es una respuesta correcta.

### Bloque 3 · Pre-Mortem y preguntas (5 min) · presenta: Integrante C o A

| Min | Qué decir |
|---|---|
| 15:00 | Supuesto: "la plataforma de identidad cayó todo un fin de semana". Mapa de riesgos (§2) |
| 16:00 | Escenario 1 (BD): 5 Porqués → la HA se hizo en el cómputo, no en la persistencia. Lo acabamos de ver en vivo. Presupuesto: 3.8 % a 182 % según haya respaldo. Control implementado: `backup-db.ps1` + RB-04 |
| 17:00 | Escenario 3 (host): el SLI se mide adentro, así que una caída total **no se ve**. Sonda externa + *dead man's switch* |
| 18:00 | Escenario 2 en una frase: un despliegue "healthy" que no emite tokens → compuerta canary |
| 18:30 | Preguntas |

## 3. Preguntas probables (todos deben poder responderlas)

| Pregunta | Respuesta corta |
|---|---|
| ¿Por qué el SLO es 99.5 % y no 99.9 %? | Un solo host y una sola BD: 99.9 % (43 min/mes) no es alcanzable sin HA de la persistencia. 99.5 % ≈ 3 h 36 min |
| ¿Por qué excluyen los 4xx del SLI? | Una clave errada es una respuesta correcta del sistema (400 `invalid_grant`, RFC 6749). Solo los 5xx son fallas del servicio |
| ¿Por qué la alerta de la BD tarda minutos y no segundos? | Multiventana: 1 h da significancia (no alertar por picos), 5 m asegura que sigue pasando. `PostgreSQLCaido` avisa antes como alerta de causa |
| ¿Por qué la caída de una réplica no consume presupuesto? | HAProxy la detecta en ~4 s (health check cada 2 s, 2 fallos) y reintenta en la otra (`retry-on` + `redispatch`) |
| ¿Por qué keycloak-2 aparece en MAINT y no en DOWN? | El contenedor muerto pierde su registro DNS; HAProxy resuelve dinámicamente y lo pone en mantenimiento por resolución. Vuelve solo al reaparecer |
| ¿Por qué bajó el SLI de latencia al reponer una réplica? | JVM en frío (JIT, cachés vacías): las primeras peticiones superan 250 ms. Lo absorbe el 5 % del SLO |
| ¿Cómo forman clúster las réplicas? | Infinispan con `jdbc-ping`: los nodos se registran en la misma PostgreSQL. Log: `cluster view (2)` |
| ¿Cómo garantizan que no hay credenciales en el código? | `TF_VAR_*` / secrets del environment, `sensitive = true`, Checkov `secrets`, política OPA de claves débiles, estado fuera del repo |
| ¿Qué cambia para llevarlo a la nube? | OIDC en el pipeline, estado remoto cifrado, ALB, ECS en 2 AZ, RDS Multi-AZ, Secrets Manager (DESPLIEGUE.md §5) |
| ¿Por qué el balanceador usa `/health/live` y no `/health/ready`? | Lo encontramos en el ensayo: con readiness, la caída de la BD (compartida) sacaba a las dos réplicas, HAProxy respondía 503 a todo y el SLI quedaba ciego. Sacar réplicas solo sirve si la falla es de la réplica |
| ¿Qué son los ERROR rojos en los logs durante el despliegue? | `org.jgroups.protocols.TCP ... failed sending graceful close` con `[Error Occurred After Shutdown]`: al apagarse una réplica, su compañera no alcanza a cerrar ordenadamente la conexión del clúster (puerto 7800). Son esperables en cada rolling update; no hay 5xx ni pérdida de sesiones. De hecho, sus horas muestran la secuencia: réplica 1 se apaga y vuelve, y solo después la 2 |
| ¿Qué es lo más débil de la arquitectura? | PostgreSQL (SPOF) y el host único, incluido el monitoreo. Está en el Pre-Mortem con su plan |

## 4. Después de la sesión

- Guardar `gameday/registro-<fecha>.log` (línea de tiempo con hora de cada inyección y mitigación) para el informe.
- `./gameday/gameday.ps1 -Accion detener-carga` y comprobar `terraform plan` sin cambios.
