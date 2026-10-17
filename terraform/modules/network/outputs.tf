output "frontend_network_name" {
  description = "Nombre de la red frontend."
  value       = docker_network.frontend.name
}

output "backend_network_name" {
  description = "Nombre de la red backend interna."
  value       = docker_network.backend.name
}

output "frontend_network_id" {
  description = "ID de la red frontend."
  value       = docker_network.frontend.id
}

output "backend_network_id" {
  description = "ID de la red backend interna."
  value       = docker_network.backend.id
}
