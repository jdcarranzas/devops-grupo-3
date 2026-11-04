output "url" {
  description = "URL pública (local) de Keycloak a través del balanceador."
  value       = "http://localhost:${var.http_port}"
}

output "stats_url" {
  description = "Página de estadísticas de HAProxy (estado de cada réplica)."
  value       = "http://localhost:${var.stats_port}/stats"
}

output "container_name" {
  description = "Nombre del contenedor del balanceador."
  value       = docker_container.haproxy.name
}
