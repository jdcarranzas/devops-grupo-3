# Infraestructura como Código · Terraform

Aprovisiona Keycloak + PostgreSQL de forma declarativa sobre **Docker** (entorno
virtualizado local) con el provider [`kreuzwerker/docker`](https://registry.terraform.io/providers/kreuzwerker/docker/latest).
Reemplaza la ejecución manual con `docker compose` por un despliegue idempotente,
modular y validado automáticamente en GitHub Actions.

## Estructura

```
terraform/
├── versions.tf            # versión de Terraform, provider y backend (estado local)
├── providers.tf           # conexión al daemon de Docker
├── locals.tf              # prefijo de nombres y etiquetas comunes
├── main.tf                # módulo raíz: une network -> database -> keycloak
├── variables.tf           # variables de entrada (con tipos y validaciones)
├── outputs.tf             # salidas (URLs, nombres, redes) sin secretos
├── environments/
│   ├── dev.tfvars         # dimensionamiento y parámetros de desarrollo
│   └── prod.tfvars        # dimensionamiento y parámetros de producción
├── modules/
│   ├── network/           # redes frontend y backend (interna) con subredes fijas
│   ├── database/          # PERSISTENCIA: volumen + contenedor PostgreSQL
│   └── keycloak/          # CÓMPUTO: imagen + contenedor Keycloak
├── policy/
│   ├── docker.rego        # políticas OPA (conftest) evaluadas sobre el plan
│   └── docker_test.rego   # pruebas unitarias de las políticas
├── .tflint.hcl            # reglas de TFLint
└── .checkov.yaml          # configuración de Checkov
```

## Requisitos

- Terraform >= 1.6 y Docker (Docker Desktop en Windows/macOS).
- Detener el `docker compose` del Entregable 1 si está corriendo (usa el puerto 8080).

## Uso

Los **secretos** no van en ningún archivo: se pasan como variables de entorno.

**PowerShell (Windows)**

```powershell
cd terraform
$env:TF_VAR_db_password = "<clave-de-al-menos-12-caracteres>"
$env:TF_VAR_keycloak_admin_password = "<clave-de-al-menos-12-caracteres>"
$env:TF_VAR_docker_host = "npipe:////./pipe/docker_engine"   # Docker Desktop

terraform init
terraform workspace select -or-create dev
terraform plan  -var-file="environments/dev.tfvars"
terraform apply -var-file="environments/dev.tfvars"
```

**Bash (Linux / macOS / WSL)**

```bash
cd terraform
export TF_VAR_db_password='<clave>' TF_VAR_keycloak_admin_password='<clave>'
terraform init
terraform workspace select -or-create dev
terraform apply -var-file=environments/dev.tfvars
```

Para producción se cambia `dev` por `prod` en el workspace y en el `-var-file`.
Ambos ambientes pueden convivir en el mismo host (nombres, subredes y puertos distintos).

| | dev | prod |
|---|---|---|
| Imagen Keycloak | construida del `Dockerfile` | `ghcr.io/...:sha-<commit>` publicada por el CI |
| Keycloak | 1 CPU · 1024 MB | 2 CPU · 2048 MB |
| PostgreSQL | 0.5 CPU · 512 MB | 1 CPU · 1024 MB |
| URL | http://localhost:8080 | http://localhost:8081 |
| Health/métricas | http://localhost:9000 | no se publica (solo red interna) |
| Subredes | 172.30.10.0/24 · 172.30.11.0/24 | 172.30.20.0/24 · 172.30.21.0/24 |

> La imagen de prod se descarga de GHCR. Si el paquete es privado, primero
> `docker login ghcr.io`. Verifique que el tag de `prod.tfvars` exista en el registro.

Idempotencia: un segundo `terraform apply` sin cambios debe responder
`No changes. Your infrastructure matches the configuration.`

Destruir: `terraform destroy -var-file=environments/<amb>.tfvars` (borra también el volumen de datos).

## Estado (`terraform.tfstate`)

- Backend **local** con un **workspace por ambiente** → `terraform.tfstate.d/dev/` y `terraform.tfstate.d/prod/`.
- El estado guarda los secretos en texto plano, por eso `*.tfstate*`, los planes y `.terraform/` están en `.gitignore`.
- Un bloque `check` avisa si el workspace no coincide con `var.environment`.
- Se recomienda versionar `.terraform.lock.hcl` (lo genera `terraform init`) para fijar el hash exacto del provider.
- Para un equipo o una nube, el bloque `backend "local" {}` se cambia por uno remoto con cifrado y bloqueo
  (S3 + DynamoDB, Azure Blob, GCS o HCP Terraform) y se migra con `terraform init -migrate-state`.

## Validación local (lo mismo que corre en CI)

```bash
terraform fmt -check -recursive
terraform validate
tflint --init && tflint --recursive
checkov --config-file .checkov.yaml --skip-download
terraform plan -var-file=environments/dev.tfvars -out=tfplan
terraform show -json tfplan > tfplan.json
conftest verify --policy policy/
conftest test tfplan.json --policy policy/
```
