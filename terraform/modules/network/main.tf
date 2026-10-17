# =============================================================================
# Módulo network: dos redes bridge con subredes fijas.
#   - frontend: se conecta solo Keycloak; desde aquí se publican puertos al host.
#   - backend : red INTERNA (internal = true), sin salida al exterior ni puertos
#               publicados. Aquí están Keycloak y PostgreSQL.
# Los valores que Docker completa por su cuenta (gateway, attachable, ipv6) se
# declaran explícitamente para que un segundo plan no muestre cambios.
# =============================================================================

resource "docker_network" "frontend" {
  name       = "${var.name_prefix}-frontend"
  driver     = "bridge"
  internal   = false
  attachable = false
  ipv6       = false

  ipam_config {
    subnet  = var.frontend_subnet
    gateway = cidrhost(var.frontend_subnet, 1)
  }

  dynamic "labels" {
    for_each = merge(var.labels, { "tier" = "frontend" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_network" "backend" {
  name       = "${var.name_prefix}-backend"
  driver     = "bridge"
  internal   = true
  attachable = false
  ipv6       = false

  ipam_config {
    subnet  = var.backend_subnet
    gateway = cidrhost(var.backend_subnet, 1)
  }

  dynamic "labels" {
    for_each = merge(var.labels, { "tier" = "backend" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}
