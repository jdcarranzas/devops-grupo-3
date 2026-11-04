# RB-02 · Degradación severa de latencia en Keycloak (saturación)

| Campo | Valor |
|---|---|
| Severidad | **SEV-2 / crítica** si dispara `KeycloakLatenciaBurnRateAlto`; ticket si es `...BurnRateLento` |
| SLO afectado | Latencia: 95 % de las peticiones a `/realms/*` en ≤ 250 ms (30 días) |
| Dashboard | `http://localhost:3000/d/keycloak-slo`, filas *Golden Signals · Keycloak* y *Saturación* |

Los comandos son de PowerShell 7 (`pwsh`), desde la raíz del repositorio:

```powershell
$P = "keycloak-prod"     # o keycloak-dev
```

> **Sobre el tiempo de detección:** la alerta crítica exige que más del 72 % de las peticiones de la
> **última hora** sean lentas (burn rate 14.4x). Una saturación de pocos minutos se ve de inmediato en
> el dashboard (p95 y *burn rate 5 m*), pero no despierta a nadie: es el comportamiento buscado para no
> alertar por picos que no ponen en riesgo el SLO mensual.

## 1. Triage (minuto 0-10)

1. Confirmar que **no** hay 5xx masivos. Si los hay, seguir primero [RB-01](RB-01-errores-5xx.md)
   (una BD caída también sube la latencia, porque las peticiones esperan la conexión antes de fallar).
2. Panel *Latencia p95 por endpoint*: ¿afecta a todos los endpoints o solo a `/token`?
   - Solo `/token` con *password grant*: es el hash de contraseñas (PBKDF2/Argon2), que consume CPU.
     Suele indicar un pico de logins o un ataque de fuerza bruta.
   - Todos los endpoints: saturación general de CPU, memoria o BD.
3. ¿Afecta a una réplica o a las dos? (panel *Tráfico por réplica* y la consulta por `replica` abajo).
   Si es solo una, sacarla del balanceo (paso 2) suele bastar.
4. Identificar el recurso saturado:

| Panel | Umbral de atención | Causa probable |
|---|---|---|
| *CPU del proceso* / *CPU por contenedor* | > 80 % del límite, sostenido | Pico de tráfico o de logins: falta CPU |
| *Heap usado / máximo* | > 85 % y GC frecuente | Memoria insuficiente para la JVM o sesiones en caché |
| *Hilos esperando conexión* | > 0 sostenido | Pool de BD agotado (ir a RB-01 §2.B) |
| *Tráfico total* | Muy por encima de lo habitual | Pico legítimo, prueba de carga o abuso |
| Panel de logs: `WARN` de `org.keycloak.events` con `LOGIN_ERROR` repetidos | Muchas claves erradas | Fuerza bruta |

```powershell
docker stats --no-stream "$P-keycloak-1" "$P-keycloak-2" "$P-postgres"   # CPU y memoria reales
docker inspect --format '{{.Name}} cpus={{.HostConfig.NanoCpus}}' "$P-keycloak-1" "$P-keycloak-2"   # límite actual
```

```promql
histogram_quantile(0.95, sum by (le, replica) (rate(http_server_requests_seconds_bucket{job="keycloak", uri=~"/realms/.+"}[5m])))
histogram_quantile(0.95, sum by (le, uri) (rate(http_server_requests_seconds_bucket{job="keycloak"}[5m])))
process_cpu_usage{job="keycloak"}
```

```logql
{tier="compute", level=~"WARN|ERROR"} | json | line_format "{{.replica}} {{.loggerName}}: {{.message}}"
```

## 2. Mitigación rápida

- **Una sola réplica degradada:** sacarla del balanceador mientras se investiga (la otra atiende todo):
  ```powershell
  docker exec "$P-lb" sh -c "echo 'set server be_keycloak/keycloak-2 state maint' | nc 127.0.0.1 9999"
  # devolverla:  ... state ready
  ```
- **Prueba de carga o cliente abusivo:** detenerlo (`./gameday/gameday.ps1 -Accion detener-carga`) o
  deshabilitar el cliente en Keycloak (*Clients → Enabled: off*). Si hay fuerza bruta, activar
  *Realm settings → Security defenses → Brute force detection*.
- **Límite de CPU reducido a mano** (por ejemplo, después de un GameDay): restaurarlo con
  `./gameday/gameday.ps1 -Escenario saturacion -Accion revertir` y comprobar con `terraform plan` que no
  quedó deriva.
- **Falta de CPU/memoria real:** subir `keycloak_cpus`, `keycloak_memory_mb` o `keycloak_replicas` en
  `terraform/environments/<ambiente>.tfvars` con un PR. El despliegue es un rolling update: no hay corte.

## 3. Verificación

- [ ] *Latencia p95* por debajo de 250 ms durante al menos 15 minutos, en las dos réplicas.
- [ ] *Burn rate 1 h · latencia* < 6 y bajando.
- [ ] Las alertas de latencia pasan a *resolved* en Alertmanager.
- [ ] `terraform plan` sin cambios (no quedó configuración manual).

## Simulación controlada (GameDay)

```powershell
./gameday/gameday.ps1 -Escenario saturacion -Accion inyectar    # limita la CPU de las réplicas + carga de estrés
./gameday/gameday.ps1 -Escenario saturacion -Accion revertir    # restaura la CPU y detiene la carga
```
