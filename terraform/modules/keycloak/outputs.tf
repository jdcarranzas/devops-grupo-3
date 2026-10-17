output "url" {
  description = "URL local de Keycloak."
  value       = "http://localhost:${var.http_port}"
}

output "health_url" {
  description = "URL de readiness (null si el puerto de gestión no se publica)."
  value       = var.publish_management_port ? "http://localhost:${var.management_port}/health/ready" : null
}

output "container_name" {
  description = "Nombre del contenedor de Keycloak."
  value       = docker_container.keycloak.name
}

output "image_id" {
  description = "ID de la imagen usada por el contenedor."
  value       = docker_image.keycloak.image_id
}
