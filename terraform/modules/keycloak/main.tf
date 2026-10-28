# =============================================================================
# Módulo keycloak: capa de cómputo, sin estado.
#   - Imagen: se construye con el Dockerfile del repositorio (dev) o se descarga
#     ya escaneada por el CI desde GHCR (prod).
#   - Contenedor: conectado a frontend (puertos publicados solo en 127.0.0.1) y
#     a backend (para llegar a PostgreSQL). Todos sus datos persistentes están
#     en la BD, así que se puede destruir y recrear sin perder información.
# =============================================================================

locals {
  # La imagen de Keycloak no trae curl: se usa /dev/tcp de bash contra /health/ready.
  # (En los heredoc de HCL las barras invertidas llegan tal cual a printf.)
  healthcheck_script = trimspace(<<-EOT
    exec 3<>/dev/tcp/127.0.0.1/9000 &&
    printf 'GET /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3 &&
    grep -q '"UP"' <&3
  EOT
  )
}

resource "docker_image" "keycloak" {
  name         = var.image
  keep_locally = true

  # Construir desde el código fuente solo cuando se pide (ambiente dev).
  dynamic "build" {
    for_each = var.build_from_source ? [1] : []
    content {
      context    = var.build_context
      dockerfile = "Dockerfile"
      tag        = [var.image]
    }
  }

  # Si cambia el Dockerfile, Terraform vuelve a construir la imagen.
  triggers = var.build_from_source ? {
    dockerfile_sha1 = filesha1("${var.build_context}/Dockerfile")
  } : {}
}

resource "docker_container" "keycloak" {
  name    = "${var.name_prefix}-keycloak"
  image   = docker_image.keycloak.image_id
  restart = "unless-stopped"
  command = ["start", "--optimized"]

  # Parámetros de conexión y de ejecución: llegan desde variables, no están en el código.
  env = [
    "KC_DB_URL=${var.db_jdbc_url}",
    "KC_DB_USERNAME=${var.db_user}",
    "KC_DB_PASSWORD=${var.db_password}",
    "KC_HTTP_ENABLED=true",
    "KC_HOSTNAME_STRICT=false",
    "KC_LOG_LEVEL=${var.log_level}",
    "KC_BOOTSTRAP_ADMIN_USERNAME=${var.admin_user}",
    "KC_BOOTSTRAP_ADMIN_PASSWORD=${var.admin_password}",
    # Observabilidad: histograma de latencia con bucket exacto en 250 ms (umbral del SLO).
    "KC_HTTP_METRICS_HISTOGRAMS_ENABLED=true",
    "KC_HTTP_METRICS_SLOS=100,250,500,1000",
  ]

  networks_advanced {
    name = var.frontend_network_name
  }

  networks_advanced {
    name = var.backend_network_name
  }

  # Tráfico de la aplicación: solo en la interfaz local del host.
  ports {
    internal = 8080
    external = var.http_port
    ip       = "127.0.0.1"
  }

  # Puerto de gestión (health y métricas): opcional y también solo en localhost.
  dynamic "ports" {
    for_each = var.publish_management_port ? [var.management_port] : []
    content {
      internal = 9000
      external = ports.value
      ip       = "127.0.0.1"
    }
  }

  memory = var.memory_mb
  cpus   = var.cpus
  # Sin swap: Docker por defecto asigna memory_swap = 2 x memory, y si no se
  # declara, Terraform detecta ese valor como un cambio en cada plan.
  memory_swap = var.memory_mb

  # Endurecimiento: proceso no root (lo define el Dockerfile), sin capabilities
  # de Linux y sin escalar privilegios.
  capabilities {
    drop = ["ALL"]
  }
  security_opts = ["no-new-privileges:true"]

  log_driver = "json-file"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  healthcheck {
    test         = ["CMD", "bash", "-c", local.healthcheck_script]
    interval     = "15s"
    timeout      = "5s"
    retries      = 10
    start_period = "1m0s" # formato que devuelve Docker; "60s" genera diferencias
  }

  # El apply termina cuando Keycloak responde "UP" en /health/ready.
  wait         = true
  wait_timeout = 240

  dynamic "labels" {
    for_each = merge(var.labels, { "tier" = "compute" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}
