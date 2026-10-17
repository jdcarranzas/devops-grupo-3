# =============================================================================
# Módulo database: capa de persistencia, separada del cómputo.
#   - docker_volume   : los datos viven aquí y tienen su propio ciclo de vida.
#                       Recrear el contenedor (cambio de imagen, de límites,
#                       etc.) no borra los datos.
#   - docker_container: PostgreSQL solo en la red backend interna y sin
#                       puertos publicados en el host.
# =============================================================================

resource "docker_image" "postgres" {
  name         = var.image
  keep_locally = true
}

resource "docker_volume" "data" {
  name = "${var.name_prefix}-pgdata"

  dynamic "labels" {
    for_each = merge(var.labels, { "tier" = "data" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "postgres" {
  name    = "${var.name_prefix}-postgres"
  image   = docker_image.postgres.image_id
  restart = "unless-stopped"

  env = [
    "POSTGRES_DB=${var.db_name}",
    "POSTGRES_USER=${var.db_user}",
    "POSTGRES_PASSWORD=${var.db_password}",
  ]

  networks_advanced {
    name    = var.network_name
    aliases = ["postgres"]
  }

  volumes {
    volume_name    = docker_volume.data.name
    container_path = "/var/lib/postgresql/data"
  }

  # Límites de recursos (dimensionamiento por ambiente)
  memory = var.memory_mb
  cpus   = var.cpus
  # Sin swap: Docker por defecto asigna memory_swap = 2 x memory, y si no se
  # declara, Terraform detecta ese valor como un cambio en cada plan.
  memory_swap = var.memory_mb

  security_opts = ["no-new-privileges:true"]

  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  healthcheck {
    test     = ["CMD-SHELL", "pg_isready -U ${var.db_user} -d ${var.db_name}"]
    interval = "10s"
    timeout  = "5s"
    retries  = 5
  }

  # Terraform espera a que PostgreSQL esté "healthy" antes de seguir; así
  # Keycloak (que depende de este módulo) no arranca contra una BD a medio iniciar.
  wait         = true
  wait_timeout = 120

  dynamic "labels" {
    for_each = merge(var.labels, { "tier" = "data" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}
