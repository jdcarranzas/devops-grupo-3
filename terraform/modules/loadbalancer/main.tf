# =============================================================================
# Módulo loadbalancer: HAProxy delante de las réplicas de Keycloak.
#   - Es el ÚNICO contenedor que publica puertos (tier = "edge"), siempre en
#     127.0.0.1. Las réplicas de Keycloak y PostgreSQL quedan solo en la red
#     backend interna.
#   - La configuración se genera con templatefile() y se copia al contenedor
#     (bloque upload): no depende de rutas del host, así que funciona igual en
#     Windows, Linux y en el runner de GitHub Actions.
#   - Equivalente en la nube: un balanceador gestionado (AWS ALB, GCP Load
#     Balancer, Azure Application Gateway) con health checks sobre /health/ready.
# =============================================================================

resource "docker_image" "haproxy" {
  name         = var.image
  keep_locally = true
}

resource "docker_container" "haproxy" {
  name    = "${var.name_prefix}-lb"
  image   = docker_image.haproxy.image_id
  restart = "unless-stopped"

  upload {
    file = "/usr/local/etc/haproxy/haproxy.cfg"
    content = templatefile("${path.module}/haproxy.cfg.tftpl", {
      servers = var.backend_servers
    })
  }

  # Frontend: puertos publicados hacia el host.
  networks_advanced {
    name = var.frontend_network_name
  }

  # Backend: llega a las réplicas. El alias "keycloak-lb" lo usan k6 y las
  # pruebas internas para pasar por el balanceador igual que un usuario.
  networks_advanced {
    name    = var.backend_network_name
    aliases = ["keycloak-lb"]
  }

  # Tráfico de usuarios hacia Keycloak.
  ports {
    internal = 8080
    external = var.http_port
    ip       = "127.0.0.1"
  }

  # Estadísticas del balanceador (estado de cada réplica) y /metrics.
  ports {
    internal = 8404
    external = var.stats_port
    ip       = "127.0.0.1"
  }

  memory      = var.memory_mb
  cpus        = var.cpus
  memory_swap = var.memory_mb

  # La imagen oficial corre como usuario "haproxy" (no root) y solo escucha en
  # puertos > 1024, así que no necesita ninguna capability.
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
    test     = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8404/healthz"]
    interval = "10s"
    timeout  = "3s"
    retries  = 3
  }

  wait         = true
  wait_timeout = 60

  dynamic "labels" {
    for_each = merge(var.labels, { "tier" = "edge" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}
