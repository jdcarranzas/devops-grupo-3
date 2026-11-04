# =============================================================================
# Módulo keycloak: capa de cómputo, sin estado y con N réplicas (Entregable 4).
#   - Imagen: se construye con el Dockerfile del repositorio (dev) o se descarga
#     ya escaneada por el CI desde GHCR (prod).
#   - Réplicas: un contenedor por réplica (for_each), conectado SOLO a la red
#     backend interna. Ninguna réplica publica puertos: el único punto de entrada
#     es el balanceador (módulo loadbalancer).
#   - Clúster: las réplicas forman un clúster Infinispan. En modo "start"
#     Keycloak usa por defecto cache=ispn y la pila de descubrimiento jdbc-ping,
#     que registra los nodos en la misma PostgreSQL: no hace falta multicast ni
#     configuración adicional de red. Las sesiones de usuario se persisten en la
#     BD (persistent-user-sessions, activo por defecto en Keycloak 26), así que
#     reemplazar una réplica no cierra las sesiones.
#   - Rolling update: cada réplica es un recurso independiente
#     (docker_container.keycloak["1"], ["2"], ...) y se puede actualizar una a la
#     vez (ver scripts/deploy.ps1) mientras la otra atiende el tráfico.
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

  # "1", "2", ... : identificadores estables de las réplicas.
  replica_ids = toset([for i in range(var.replicas) : tostring(i + 1)])
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

# La instancia única del Entregable 2 pasa a ser la réplica "1" sin destruirse
# por un simple cambio de dirección en el estado.
moved {
  from = docker_container.keycloak
  to   = docker_container.keycloak["1"]
}

resource "docker_container" "keycloak" {
  for_each = local.replica_ids

  name    = "${var.name_prefix}-keycloak-${each.key}"
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
    # Detrás del balanceador: Keycloak confía en X-Forwarded-For / X-Forwarded-Proto
    # para construir URLs y registrar la IP real del cliente.
    "KC_PROXY_HEADERS=xforwarded",
    "KC_LOG_LEVEL=${var.log_level}",
    # Logs estructurados (JSON) en la consola: cada línea es un objeto con
    # timestamp, nivel, logger, mensaje y excepción, listo para Loki/Grafana.
    "KC_LOG_CONSOLE_OUTPUT=${var.log_console_output}",
    "KC_BOOTSTRAP_ADMIN_USERNAME=${var.admin_user}",
    "KC_BOOTSTRAP_ADMIN_PASSWORD=${var.admin_password}",
    # Observabilidad: histograma de latencia con bucket exacto en 250 ms (umbral del SLO).
    "KC_HTTP_METRICS_HISTOGRAMS_ENABLED=true",
    "KC_HTTP_METRICS_SLOS=100,250,500,1000",
  ]

  # Solo red backend. El alias "keycloak-<n>" es estable entre ambientes y lo
  # usan el balanceador y Prometheus para encontrar cada réplica.
  networks_advanced {
    name    = var.backend_network_name
    aliases = ["keycloak-${each.key}"]
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

  # Apagado ordenado: al reemplazar una réplica, Docker envía SIGTERM y espera
  # hasta 30 s antes de forzar la terminación (peticiones en curso).
  destroy_grace_seconds = 30

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

  # El apply de cada réplica termina cuando responde "UP" en /health/ready.
  wait         = true
  wait_timeout = 240

  dynamic "labels" {
    for_each = merge(var.labels, { "tier" = "compute", "replica" = each.key })
    content {
      label = labels.key
      value = labels.value
    }
  }
}
