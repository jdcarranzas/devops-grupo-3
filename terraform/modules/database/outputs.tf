output "container_name" {
  description = "Nombre del contenedor de PostgreSQL (resoluble por DNS dentro de la red)."
  value       = docker_container.postgres.name
}

output "host" {
  description = "Host por el que otros contenedores de la red llegan a PostgreSQL."
  value       = docker_container.postgres.name
}

output "port" {
  description = "Puerto de PostgreSQL dentro de la red interna."
  value       = 5432
}

output "jdbc_url" {
  description = "Cadena de conexión JDBC (sin credenciales)."
  value       = "jdbc:postgresql://${docker_container.postgres.name}:5432/${var.db_name}"
}

output "volume_name" {
  description = "Volumen donde se guardan los datos."
  value       = docker_volume.data.name
}
