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

Detener: `docker compose down` · Detener y borrar datos: `docker compose down -v`

Creado por: 
- Juan Carranza (jdcarranzas@unal.edu.co)
