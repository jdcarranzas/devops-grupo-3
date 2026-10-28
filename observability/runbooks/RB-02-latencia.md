# RB-02 · Degradación severa de latencia en Keycloak (saturación)

| Campo | Valor |
|---|---|
| Severidad | **SEV-2 / crítica** si dispara `KeycloakLatenciaBurnRateAlto`; ticket si es `...BurnRateLento` |
| SLO afectado | Latencia: 95 % de las peticiones a `/realms/*` en ≤ 250 ms (30 días) |
| Dashboard | `http://localhost:3000/d/keycloak-slo`, filas *Golden Signals · Keycloak* y *Saturación* |

## 1. Triage (minuto 0-10)

1. Confirmar que **no** hay 5xx masivos. Si los hay, seguir primero [RB-01](RB-01-errores-5xx.md).
2. Panel *Latencia p95 por endpoint*: ¿afecta a todos los endpoints o solo a `/token`?
   - Solo `/token` con *password grant*: es el hash de contraseñas (PBKDF2/Argon2), que consume CPU.
     Suele indicar un pico de logins o un ataque de fuerza bruta.
   - Todos los endpoints: saturación general de CPU, memoria o BD.
3. Identificar el recurso saturado:

| Panel | Umbral de atención | Causa probable |
|---|---|---|
| *CPU del proceso* | > 80 % sostenido | Pico de tráfico o de logins: falta CPU |
| *Heap usado / máximo* | > 85 % y GC frecuente | Memoria insuficiente para la JVM o sesiones en caché |
| *Hilos esperando conexión* | > 0 sostenido | Pool de BD agotado (ir a RB-01 §2.B) |
| *Tráfico total* | Muy por encima de lo habitual | Pico legítimo, prueba de carga o abuso |

```bash
docker stats --no-stream kc-app kc-postgres                  # CPU y memoria reales
docker logs --since 10m kc-app 2>&1 | grep -iE "warn|error" | tail -20
```

```promql
histogram_quantile(0.95, sum by (le, uri) (rate(http_server_requests_seconds_bucket{job="keycloak"}[5m])))
process_cpu_usage{job="keycloak"}
sum by (uri) (rate(http_server_requests_seconds_count{job="keycloak", uri=~"/realms/.+"}[5m]))
```

## 2. Mitigación rápida

- **Prueba de carga o cliente abusivo:** detenerlo (`docker compose ... run` de k6 → `Ctrl+C`) o
  bloquear el cliente en Keycloak (*Clients → Enabled: off*). Si hay fuerza bruta, activar
  *Realm settings → Security defenses → Brute force detection*.
- **Falta de CPU/memoria:** subir los recursos del contenedor (`keycloak_cpus`, `keycloak_memory_mb`
  en `terraform/environments/*.tfvars`) y aplicar con Terraform. Solo se recrea el contenedor de
  Keycloak; la base de datos no se toca.
- **Escalar horizontalmente** (si el despliegue lo permite): una segunda réplica de Keycloak detrás de
  un balanceador. Keycloak 26 forma clúster por la BD (JDBC_PING).

## 3. Verificación

- [ ] *Latencia p95* por debajo de 250 ms durante al menos 15 minutos.
- [ ] *Burn rate 1 h · latencia* < 6 y bajando.
- [ ] Las alertas de latencia pasan a *resolved* en Alertmanager.

## Simulación controlada

```bash
docker compose --env-file .env -f observability/docker-compose.yml \
  run --rm -e PERFIL=estres k6 run /scripts/carga.js
```
