# Observabilidad y SRE · Keycloak (Entregable 3)

Marco SRE y pila de observabilidad del sistema **Keycloak + PostgreSQL**: SLIs/SLOs, presupuesto de error,
Prometheus, Grafana, alertas por *burn rate* y runbooks.

```
observability/
├── docker-compose.yml                  # Prometheus, Alertmanager, Grafana, postgres-exporter, cAdvisor, k6
├── prometheus/
│   ├── prometheus.yml                  # Qué se recolecta y cada cuánto
│   ├── rules/
│   │   ├── slo-recording.yml           # SLIs precalculados (5m … 30d), presupuesto restante y burn rate
│   │   └── slo-alertas.yml             # Alertas multiventana de burn rate + servicio caído
│   └── tests/slo-alertas.test.yml      # Pruebas unitarias de las reglas (promtool)
├── alertmanager/alertmanager.yml       # Agrupación, enrutamiento por severidad e inhibición
├── grafana/
│   ├── provisioning/                   # Fuentes de datos y carga de dashboards como código
│   └── dashboards/keycloak-slo.json    # Dashboard: SLOs, Error Budget y Golden Signals
├── k6/carga.js                         # Generador de tráfico (perfil nominal y de estrés)
└── runbooks/
    ├── RB-01-errores-5xx.md            # Caída de PostgreSQL / 5xx masivos (incidente crítico)
    └── RB-02-latencia.md               # Degradación de latencia por saturación
```

## Arquitectura de la recolección

```
                ┌──────────────── red keycloak-devops_backend ─────────────────┐
  k6 ──HTTP──►  │  kc-app (Keycloak)  :8080 tráfico   :9000 /metrics            │
                │        │ JDBC                         ▲                       │
                │        ▼                              │ scrape 15 s           │
                │  kc-postgres ◄── postgres-exporter :9187 ◄──┐                 │
                └───────────────────────────────────────┼─────┼─────────────────┘
                                                        │     │
          cAdvisor :8080 (CPU/mem por contenedor) ◄─────┤  Prometheus :9090 ──reglas──► Alertmanager :9093
                                                              │
                                                        Grafana :3000 (PromQL)
```

- **Keycloak** expone métricas Micrometer en el puerto de gestión `9000` (`KC_METRICS_ENABLED=true`,
  fijado en el `Dockerfile`). Con `KC_HTTP_METRICS_SLOS=100,250,500,1000` y
  `KC_HTTP_METRICS_HISTOGRAMS_ENABLED=true` (en `docker-compose.yml`) publica el histograma
  `http_server_requests_seconds_bucket` con un bucket exacto en 250 ms, el umbral del SLO de latencia.
- **PostgreSQL** no habla Prometheus: `postgres-exporter` consulta `pg_stat_*` y lo traduce.
- **cAdvisor** aporta CPU y memoria de cada contenedor.
- **Prometheus** recolecta cada 15 s, guarda 35 días (la ventana del SLO es de 30) y evalúa las reglas.
- **Grafana** se aprovisiona por completo desde archivos: no hay configuración manual.

## Puesta en marcha

Requisitos: Docker Desktop y el archivo `.env` (copiado de `.env.example`, con `GRAFANA_ADMIN_PASSWORD`).

```bash
# 1. Sistema (Keycloak + PostgreSQL)
docker compose up -d --build

# 2. Observabilidad
docker compose --env-file .env -f observability/docker-compose.yml up -d

# 3. Tráfico nominal (5 req/s durante 10 min; DURACION=30m para más tiempo)
docker compose --env-file .env -f observability/docker-compose.yml run --rm k6 run /scripts/carga.js
```

| Interfaz | URL |
|---|---|
| Grafana (dashboard de inicio) | http://localhost:3000 · usuario `admin` |
| Prometheus · alertas | http://localhost:9090/alerts |
| Alertmanager | http://localhost:9093 |

Pruebas de las reglas (no necesitan Docker en marcha):

```bash
docker run --rm -v "${PWD}/observability/prometheus:/p" --entrypoint promtool \
  prom/prometheus:v3.5.0 test rules /p/tests/slo-alertas.test.yml
```

## SLIs y SLOs

Alcance: peticiones a los endpoints públicos del IdP, `uri=~"/realms/.+"` (token, login, logout, userinfo,
discovery, JWKS). Se excluyen `/health`, `/metrics` y la API de administración.

| SLI | Definición | SLO (30 días) | Presupuesto |
|---|---|---|---|
| Disponibilidad | peticiones sin 5xx / peticiones totales | **99.5 %** | 0.5 % ≈ 3 h 36 min de caída total |
| Latencia | peticiones atendidas en ≤ 250 ms / peticiones totales | **95 %** | 5 % de peticiones lentas |

```promql
# Disponibilidad
1 - (
  sum(rate(http_server_requests_seconds_count{job="keycloak", uri=~"/realms/.+", outcome="SERVER_ERROR"}[30d]))
  / sum(rate(http_server_requests_seconds_count{job="keycloak", uri=~"/realms/.+"}[30d]))
)
# Latencia
sum(rate(http_server_requests_seconds_bucket{job="keycloak", uri=~"/realms/.+", le="0.25"}[30d]))
/ sum(rate(http_server_requests_seconds_count{job="keycloak", uri=~"/realms/.+"}[30d]))
```

## Política de presupuesto de error

| Presupuesto restante (30 d) | Estado | Acuerdo entre desarrollo y operaciones |
|---|---|---|
| > 50 % | Verde | Desarrollo normal. Se permiten despliegues diarios y experimentos. |
| 25 % – 50 % | Amarillo | Despliegues solo con revisión de un segundo integrante y plan de rollback probado. Se revisan las alertas *warning* abiertas. |
| 0 % – 25 % | Naranja | Solo cambios de bajo riesgo. Al menos el 50 % del siguiente sprint se dedica a confiabilidad y deuda técnica. |
| Agotado (≤ 0 %) | Rojo | **Congelamiento de cambios**: solo correcciones de confiabilidad o de seguridad (CVE críticos) hasta recuperar saldo positivo. Postmortem obligatorio. |

Reglas adicionales:

- Un solo incidente que consuma **más del 20 %** del presupuesto exige postmortem sin culpables en 48 h
  y acciones correctivas priorizadas en el siguiente sprint.
- Si el presupuesto se agota por una **dependencia externa** (proveedor de infraestructura, por ejemplo),
  no se congela el desarrollo, pero se registra y se evalúa una mitigación (réplica, failover).
- La excepción al congelamiento la aprueban los tres integrantes y queda registrada en el PR.
- Los SLOs se revisan cada trimestre: si se cumplen con mucho margen se pueden endurecer; si se
  incumplen sin que los usuarios lo noten, se pueden relajar.

## Alertas

Esquema *multiwindow, multi-burn-rate* del Google SRE Workbook. Una alerta salta solo si el consumo es
alto en una ventana larga (significancia) **y** en una corta (el problema sigue ocurriendo).

| Alerta | Severidad | Condición |
|---|---|---|
| `KeycloakDisponibilidadBurnRateAlto` | critical | burn rate > 14.4 en 1 h y 5 m, o > 6 en 6 h y 30 m |
| `KeycloakDisponibilidadBurnRateLento` | warning | burn rate > 3 en 1 d y 2 h, o > 1 en 3 d y 6 h |
| `KeycloakLatenciaBurnRateAlto` / `...Lento` | critical / warning | iguales, sobre el SLO de latencia |
| `KeycloakPresupuestoErrorAgotado` | warning | presupuesto restante ≤ 0 → aplicar la política |
| `KeycloakNoResponde` | critical | Prometheus no puede leer `/metrics` durante 2 min |
| `PostgreSQLCaido` | critical | `pg_up == 0` durante 1 min |

## Simulación de incidentes

```bash
# Caída de la base de datos (RB-01)
docker compose stop postgres     # esperar ~5-7 min con tráfico corriendo
docker compose start postgres

# Saturación / latencia (RB-02)
docker compose --env-file .env -f observability/docker-compose.yml run --rm -e PERFIL=estres k6 run /scripts/carga.js
```

> En un laboratorio con poco historial, el presupuesto de 30 días se calcula sobre los datos que existan.
> Por ejemplo, 3 minutos de caída dentro de 1 hora de datos son un 5 % de errores, que agota el
> presupuesto (0.5 %). En producción, con 30 días de datos, esa misma caída consume ≈ 1.4 %.
> Tome las capturas con carga nominal **antes** de simular incidentes.
