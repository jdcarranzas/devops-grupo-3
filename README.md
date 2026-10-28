# devops-grupo-3 · Keycloak

Proyecto del módulo del diplomado **Fundamentos de DevOps y SRE** (Posgrados en Ingeniería de Sistemas y Computación, 2026-02).

Empaquetado, ejecución local e integración continua de **[Keycloak](https://www.keycloak.org/)** (gestión de identidades y acceso, IAM) con **PostgreSQL** como persistencia.

## Estructura

| Archivo | Propósito |
|---|---|
| `Dockerfile` | Imagen optimizada multi-stage de Keycloak (pre-compilada con `kc.sh build`) |
| `docker-compose.yml` | Keycloak + PostgreSQL + volumen persistente, levantados con un solo comando |
| `.env.example` | Plantilla de variables de entorno (credenciales) |
| `.github/workflows/ci.yml` | Pipeline de CI: lint → build → escaneo de vulnerabilidades → publicación |
| `terraform/` | Infraestructura como Código (Entregable 2): módulos network, database y keycloak, ambientes dev/prod y políticas. Ver [terraform/README.md](terraform/README.md) |
| `.github/workflows/terraform.yml` | Pipeline de IaC: fmt → validate → TFLint → Checkov → plan (dev/prod) → políticas OPA con conftest |
| `observability/` | Observabilidad y SRE (Entregable 3): Prometheus, Grafana, Alertmanager, reglas de SLO y burn rate, dashboard JSON, carga con k6 y runbooks. Ver [observability/README.md](observability/README.md) |
| `.github/workflows/observability.yml` | Pipeline de observabilidad: promtool (config, reglas y pruebas unitarias de alertas), amtool, JSON de dashboards y compose |

## Ejecución local

Requisitos: Docker Desktop (o Docker Engine + plugin Compose).

```bash
cp .env.example .env          # ajustar las contraseñas
docker compose up -d --build  # levanta todo el sistema
docker compose ps             # ambos servicios deben quedar "healthy"
```

- Consola de administración: <http://localhost:8080> (usuario/clave definidos en `.env`)
- Health check: <http://localhost:9000/health/ready>
- Métricas (Prometheus): <http://localhost:9000/metrics>

### Observabilidad (Entregable 3)

```bash
docker compose --env-file .env -f observability/docker-compose.yml up -d   # Prometheus, Grafana, Alertmanager...
docker compose --env-file .env -f observability/docker-compose.yml run --rm k6 run /scripts/carga.js  # tráfico
```

- Grafana: <http://localhost:3000> · Prometheus: <http://localhost:9090> · Alertmanager: <http://localhost:9093>

Detener: `docker compose down` · Detener y borrar datos: `docker compose down -v`

Creado por: 
- Juan Carranza (jdcarranzas@unal.edu.co)
