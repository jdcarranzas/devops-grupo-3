# =============================================================================
# Módulo raíz: arma la infraestructura de Keycloak a partir de tres módulos
#   1. network  -> redes y subredes (frontend pública / backend interna)
#   2. database -> capa de persistencia: PostgreSQL + volumen de datos
#   3. keycloak -> capa de cómputo: servidor Keycloak
# El orden de creación sale de las referencias entre módulos:
# network -> database (espera a "healthy") -> keycloak.
# =============================================================================

module "network" {
  source = "./modules/network"

  name_prefix     = local.name_prefix
  frontend_subnet = var.frontend_subnet
  backend_subnet  = var.backend_subnet
  labels          = local.common_labels
}

module "database" {
  source = "./modules/database"

  name_prefix  = local.name_prefix
  network_name = module.network.backend_network_name
  image        = var.postgres_image
  db_name      = var.db_name
  db_user      = var.db_user
  db_password  = var.db_password
  memory_mb    = var.db_memory_mb
  cpus         = var.db_cpus
  labels       = local.common_labels
}

module "keycloak" {
  source = "./modules/keycloak"

  name_prefix           = local.name_prefix
  image                 = var.keycloak_image
  build_from_source     = var.keycloak_build_from_source
  build_context         = local.repo_root
  frontend_network_name = module.network.frontend_network_name
  backend_network_name  = module.network.backend_network_name

  db_jdbc_url = module.database.jdbc_url
  db_user     = var.db_user
  db_password = var.db_password

  admin_user     = var.keycloak_admin_user
  admin_password = var.keycloak_admin_password

  http_port               = var.keycloak_http_port
  management_port         = var.keycloak_management_port
  publish_management_port = var.keycloak_publish_management_port
  log_level               = var.keycloak_log_level
  memory_mb               = var.keycloak_memory_mb
  cpus                    = var.keycloak_cpus
  labels                  = local.common_labels
}

# Control para evitar aplicar los tfvars de un ambiente sobre el estado de otro.
check "workspace_matches_environment" {
  assert {
    condition     = terraform.workspace == var.environment
    error_message = "El workspace actual (${terraform.workspace}) no coincide con var.environment (${var.environment}). Ejecute: terraform workspace select ${var.environment}"
  }
}
