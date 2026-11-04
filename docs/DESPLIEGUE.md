# Despliegue continuo (CD) · Entregable 4

Este documento describe cómo llega un cambio de `main` al sistema en ejecución y qué haría falta para hacer lo
mismo en una nube pública.

## 1. Arquitectura desplegada

```
                      127.0.0.1:8081 (prod)              red backend (internal = true)
 usuario / k6 ──HTTP──► keycloak-lb (HAProxy) ──┬──► keycloak-1 ─┐
                       127.0.0.1:8405 /stats    └──► keycloak-2 ─┼──JDBC──► postgres ──► volumen pgdata
                                                    clúster Infinispan (jdbc-ping)  │
                                                                                     └──► Prometheus / Grafana
```

| Capa | Recurso de Terraform | Notas |
|---|---|---|
| Entrada | `module.loadbalancer` (HAProxy 3.2 LTS) | Único contenedor con puertos publicados (política OPA 1b). Health checks activos a `/health/ready`, reintentos y *redispatch*, afinidad por cookie |
| Cómputo | `module.keycloak` (`for_each`, 2 réplicas) | Sin puertos publicados, solo red backend. Clúster con `jdbc-ping` (descubrimiento por la misma BD); sesiones persistidas en la BD |
| Persistencia | `module.database` | PostgreSQL 17 + volumen con ciclo de vida propio. **Sigue siendo SPOF** (ver Pre-Mortem) |
| Red | `module.network` | Frontend (bridge) y backend interna |

## 2. Flujo de un cambio

```
PR ──► CI (lint, build, Trivy) ─┐
   ──► Terraform (fmt, validate, TFLint, Checkov, plan dev/prod, OPA)  ── revisión ──► merge a main
   ──► Observability (promtool, pruebas de alertas)                 ─┘
main ──► CI: build + Trivy + push ghcr.io/...:sha-<commit>
     ──► Deploy (runner autoalojado en el equipo del laboratorio):
           1. checkout del commit que pasó el CI y docker pull de sha-<commit>
           2. por cada réplica que cambia: MAINT en HAProxy → drenado 5 s → terraform apply -target
              (espera /health/ready = UP) → READY en HAProxy → espera UP
           3. terraform apply completo (balanceador, BD, redes)
           4. smoke test por el balanceador (discovery y JWKS) + plan sin cambios (idempotencia)
```

Mientras una réplica se reemplaza, la otra atiende el 100 % del tráfico; por eso el despliegue no tiene pérdida
de disponibilidad. Si la imagen no cambió de contenido (mismo *digest*), Terraform no recrea las réplicas.

**Rollback:** *Actions → Deploy → Run workflow* con `image_tag = sha-<commit anterior>`.

## 3. Preparación del equipo (una sola vez, PowerShell)

Requisitos: Docker Desktop, PowerShell 7.3 o superior (`pwsh -v`), Git y Terraform
(`winget install Hashicorp.Terraform`) para las ejecuciones manuales.

1. **Carpeta del estado fuera del repositorio.** `actions/checkout` borra los archivos ignorados por git, y entre
   ellos estaría el estado. Se usa una carpeta fija, la misma para el runner y para las ejecuciones manuales:

   ```powershell
   New-Item -ItemType Directory -Force C:\terraform-state\devops-grupo-3
   # El estado de los Entregables 2 y 3 (workspaces dev/prod) se MUEVE a esa carpeta. Si se deja en
   # terraform\terraform.tfstate.d, terraform init pide migrarlo y el despliegue no interactivo falla.
   Move-Item terraform\terraform.tfstate.d\* C:\terraform-state\devops-grupo-3
   Remove-Item terraform\terraform.tfstate.d
   ```

2. **GitHub → Settings → Environments → New environment `production`**, con los secretos
   `TF_VAR_DB_PASSWORD` y `TF_VAR_KEYCLOAK_ADMIN_PASSWORD`. Deben ser los mismos valores del `.env` (los usan
   postgres-exporter y k6) y, si la BD ya existe, la contraseña con la que se creó.

3. **GitHub → Settings → Secrets and variables → Actions → Variables**: `TF_STATE_DIR = C:/terraform-state/devops-grupo-3`.

4. **GitHub → Settings → Actions → Runners → New self-hosted runner → Windows x64.** Seguir los comandos que muestra
   GitHub (descarga y `config.cmd`), aceptando la etiqueta `windows`. Para la demo se ejecuta con el usuario propio:

   ```powershell
   cd C:\actions-runner
   .\run.cmd          # dejar esta ventana abierta durante la sustentación
   ```

   No se instala como servicio de Windows: por defecto correría como *NETWORK SERVICE*, que no tiene acceso al pipe
   de Docker Desktop. Si se quiere como servicio, se configura con la cuenta del usuario (miembro de `docker-users`).

5. **Settings → Actions → General → Fork pull request workflows**: exigir aprobación para colaboradores externos.
   El workflow de deploy no se dispara por `pull_request`, así que el código de un fork nunca llega a este equipo.

6. **Primer despliegue (pasa de 1 a 2 réplicas).** El bloque `moved` conserva la réplica 1 en el estado, pero la
   réplica cambia de red y deja de publicar puertos, así que el primer apply la reemplaza (corte breve). Se hace
   antes de la demo, a mano:

   ```powershell
   $env:TF_VAR_db_password = "<igual que en .env>"
   $env:TF_VAR_keycloak_admin_password = "<igual que en .env>"
   # Contraseñas de al menos 12 caracteres, sin < >; las mismas en el .env y en los secretos de GitHub
   ./scripts/deploy.ps1 -Environment prod -Image ghcr.io/jdcarranzas/devops-grupo-3:sha-<commit> `
       -StateDir C:/terraform-state/devops-grupo-3
   ```

## 4. Guion de la demostración (5 minutos)

Antes de la sesión: sistema arriba, observabilidad arriba, k6 con tráfico nominal
(`run --rm -e DURACION=60m k6 run /scripts/carga.js`) y el PR del cambio ya abierto con los checks en verde.

1. Mostrar la arquitectura (sección 1) y `http://localhost:8405/stats` con las dos réplicas UP.
2. Hacer *merge* del PR. Cambio sugerido: en `terraform/environments/prod.tfvars`,
   `keycloak_log_level = "INFO,org.keycloak.events:DEBUG"` (los eventos de login empiezan a aparecer en los logs).
3. Mostrar el workflow **CI** y luego **Deploy** corriendo en el runner `windows`.
4. En Grafana (fila *Alta disponibilidad*): una réplica pasa a CAÍDA y el tráfico se va a la otra; luego la otra.
   El panel de *5xx al usuario* se queda en 0 y el SLI de disponibilidad no se mueve.
5. Cerrar con el resumen del job (imagen, commit, contenedores) y el plan sin cambios del final.

> El CI de `main` tarda unos minutos (build con caché + Trivy). Conviene medirlo en el ensayo y hacer el merge al
> inicio del bloque, mientras se explica la arquitectura.

## 5. Qué haría falta en un entorno cloud de producción

El runner autoalojado del laboratorio cumple el papel de un runner dentro de la red privada del proveedor. Solo
necesita **salida HTTPS (443) hacia GitHub**: hace *polling* de trabajos, así que no hay que abrir puertos de entrada
ni montar túneles o VPN para que el pipeline llegue al entorno.

| Pieza | Laboratorio (hoy) | Nube (ej. AWS; equivalentes en GCP/Azure) |
|---|---|---|
| Autenticación del pipeline | Runner con acceso al Docker local | **OIDC de GitHub** → rol IAM con `aws-actions/configure-aws-credentials` (`role-to-assume`), sin llaves de larga duración; la confianza del rol se limita a `repo:jdcarranzas/devops-grupo-3:environment:production` |
| Dónde corre el job | Runner autoalojado en Windows | Runner de GitHub (si los recursos tienen API pública) o autoalojado en una subred privada de la VPC (ej. ECS/EC2 con *Actions Runner Controller*) |
| Estado de Terraform | Backend local en `C:/terraform-state` | Bucket S3 cifrado y versionado con bloqueo (`use_lockfile` o DynamoDB) |
| Secretos | Secrets del environment de GitHub → `TF_VAR_*` | AWS Secrets Manager; el contenedor los lee en el arranque y no pasan por Terraform |
| Balanceador | HAProxy en un contenedor | ALB gestionado (multi-AZ) con health check a `/health/ready` del puerto 9000 y TLS con ACM |
| Cómputo | 2 contenedores en un host | Servicio ECS Fargate (o Deployment de Kubernetes) con `minimumHealthyPercent = 100`: el rolling update lo hace la plataforma |
| Base de datos | 1 PostgreSQL + volumen | RDS PostgreSQL Multi-AZ con respaldos automáticos y PITR |
| Aprobación | Environment `production` (opcional) | *Required reviewers* en el environment y ventanas de despliegue |

El código de Terraform ya está separado por módulos con interfaces (variables y salidas) que no dependen de Docker,
así que migrar implica reemplazar los recursos dentro de cada módulo, no reescribir el despliegue.
