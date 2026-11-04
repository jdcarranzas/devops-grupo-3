# Salidas del módulo raíz: lo que se necesita para usar y operar el sistema.
# No hay ninguna salida con secretos.

output "environment" {
  description = "Ambiente desplegado."
  value       = var.environment
}

output "keycloak_url" {
  description = "URL de Keycloak a través del balanceador (consola de administración y endpoints OIDC)."
  value       = module.loadbalancer.url
}

output "loadbalancer_stats_url" {
  description = "Estado de cada réplica en HAProxy (UP, DOWN, MAINT)."
  value       = module.loadbalancer.stats_url
}

output "loadbalancer_container_name" {
  description = "Nombre del contenedor del balanceador."
  value       = module.loadbalancer.container_name
}

output "keycloak_container_names" {
  description = "Nombres de los contenedores de las réplicas de Keycloak."
  value       = module.keycloak.container_names
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
    # Red a la que se une la pila de observabilidad (KC_BACKEND_NETWORK en .env).
    backend = { name = module.network.backend_network_name, subnet = var.backend_subnet, internal = true }
  }
}
