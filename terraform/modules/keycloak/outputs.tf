output "container_names" {
  description = "Nombres de los contenedores de las réplicas de Keycloak."
  value       = [for c in docker_container.keycloak : c.name]
}

output "replica_hosts" {
  description = "Alias DNS de cada réplica dentro de la red backend (keycloak-1, keycloak-2, ...)."
  value       = sort([for id in keys(docker_container.keycloak) : "keycloak-${id}"])
}

output "image_id" {
  description = "ID de la imagen usada por las réplicas."
  value       = docker_image.keycloak.image_id
}
