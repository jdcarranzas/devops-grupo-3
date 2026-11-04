# Ambiente de desarrollo: imagen construida desde el Dockerfile local,
# recursos mínimos. Las réplicas no publican puertos: se depura por el balanceador.
# Secretos: NO van aquí -> TF_VAR_db_password y TF_VAR_keycloak_admin_password

environment = "dev"

frontend_subnet = "172.30.10.0/24"
backend_subnet  = "172.30.11.0/24"

db_memory_mb = 512
db_cpus      = "0.5"

keycloak_image             = "ghcr.io/jdcarranzas/devops-grupo-3:local"
keycloak_build_from_source = true

keycloak_replicas  = 2
keycloak_http_port = 8080
keycloak_log_level = "DEBUG"
keycloak_memory_mb = 1024
keycloak_cpus      = "1.0"

# Balanceador: único contenedor con puertos publicados (siempre en 127.0.0.1)
lb_stats_port = 8404
