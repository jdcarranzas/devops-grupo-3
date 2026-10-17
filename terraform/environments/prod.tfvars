# Ambiente "productivo": imagen ya escaneada y publicada por el CI en GHCR
# (tag inmutable por commit), más recursos y puerto de gestión sin publicar.
# Secretos: NO van aquí -> TF_VAR_db_password y TF_VAR_keycloak_admin_password

environment = "prod"

frontend_subnet = "172.30.20.0/24"
backend_subnet  = "172.30.21.0/24"

db_memory_mb = 1024
db_cpus      = "1.0"

keycloak_image             = "ghcr.io/jdcarranzas/devops-grupo-3:sha-a3676e7"
keycloak_build_from_source = false

keycloak_http_port               = 8081
keycloak_management_port         = 9001
keycloak_publish_management_port = false
keycloak_log_level               = "INFO"
keycloak_memory_mb               = 2048
keycloak_cpus                    = "2.0"
