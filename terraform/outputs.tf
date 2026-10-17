# Salidas del módulo raíz: lo que se necesita para usar y operar el sistema.
# No hay ninguna salida con secretos.

output "environment" {
  description = "Ambiente desplegado."
  value       = var.environment
}

output "keycloak_url" {
  description = "URL de Keycloak (consola de administración y endpoints OIDC)."
  value       = module.keycloak.url
}

output "keycloak_health_url" {
  description = "Endpoint de readiness (null si el puerto de gestión no se publica)."
  value       = module.keycloak.health_url
}

output "keycloak_container_name" {
  description = "Nombre del contenedor de Keycloak."
  value       = module.keycloak.container_name
}

output "database_container_name" {
  description = "Nombre del contenedor de PostgreSQL."
  value       = module.database.container_name
}

output "database_volume_name" {
  description = "Volumen donde viven los datos de PostgreSQL (capa de persistencia)."
  value       = module.database.volume_name
}

output "database_jdbc_url" {
  description = "Cadena JDBC usada por Keycloak (sin credenciales)."
  value       = module.database.jdbc_url
}

output "networks" {
  description = "Redes creadas y sus subredes."
  value = {
    frontend = { name = module.network.frontend_network_name, subnet = var.frontend_subnet }
    backend  = { name = module.network.backend_network_name, subnet = var.backend_subnet, internal = true }
  }
}
