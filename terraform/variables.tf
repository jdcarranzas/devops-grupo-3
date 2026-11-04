# =============================================================================
# Variables de entrada del módulo raíz.
# Los valores que no son secretos van en environments/<ambiente>.tfvars.
# Los SECRETOS no tienen valor por defecto ni se escriben en ningún .tf/.tfvars
# versionado: se pasan por variables de entorno TF_VAR_<nombre>.
# =============================================================================

# ---------- Generales ----------
variable "environment" {
  description = "Nombre del ambiente (dev o prod). Debe coincidir con el workspace de Terraform."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment debe ser \"dev\" o \"prod\"."
  }
}

variable "project_name" {
  description = "Nombre del proyecto; se usa como prefijo de todos los recursos."
  type        = string
  default     = "keycloak"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name debe tener entre 3 y 21 caracteres: minúsculas, números o guiones."
  }
}

variable "docker_host" {
  description = "Endpoint del daemon de Docker. null = usar DOCKER_HOST o el socket por defecto."
  type        = string
  default     = null
}

# ---------- Red ----------
variable "frontend_subnet" {
  description = "CIDR de la subred frontend (tráfico de usuarios hacia Keycloak)."
  type        = string

  validation {
    condition     = can(cidrhost(var.frontend_subnet, 0))
    error_message = "frontend_subnet debe ser un CIDR válido, por ejemplo 172.30.10.0/24."
  }
}

variable "backend_subnet" {
  description = "CIDR de la subred backend interna (Keycloak <-> PostgreSQL)."
  type        = string

  validation {
    condition     = can(cidrhost(var.backend_subnet, 0))
    error_message = "backend_subnet debe ser un CIDR válido, por ejemplo 172.30.11.0/24."
  }
}

# ---------- Persistencia (PostgreSQL) ----------
variable "postgres_image" {
  description = "Imagen de PostgreSQL con tag fijo (no se permite latest)."
  type        = string
  default     = "postgres:17-alpine"
}

variable "db_name" {
  description = "Nombre de la base de datos de Keycloak."
  type        = string
  default     = "keycloak"
}

variable "db_user" {
  description = "Usuario dueño de la base de datos de Keycloak."
  type        = string
  default     = "keycloak"
}

variable "db_password" {
  description = "Contraseña de PostgreSQL. SECRETO: se pasa con TF_VAR_db_password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 12
    error_message = "db_password debe tener al menos 12 caracteres."
  }
}

variable "db_memory_mb" {
  description = "Límite de memoria (MB) del contenedor de PostgreSQL."
  type        = number

  validation {
    condition     = var.db_memory_mb >= 256
    error_message = "db_memory_mb debe ser al menos 256 MB."
  }
}

variable "db_cpus" {
  description = "Límite de CPU del contenedor de PostgreSQL (ej. \"0.5\", \"1.0\")."
  type        = string
}

# ---------- Cómputo (Keycloak) ----------
variable "keycloak_image" {
  description = "Nombre:tag de la imagen de Keycloak (local si se construye, o la publicada en GHCR)."
  type        = string
}

variable "keycloak_build_from_source" {
  description = "true = construir la imagen con el Dockerfile del repo; false = descargarla del registro."
  type        = bool
  default     = false
}

variable "keycloak_admin_user" {
  description = "Usuario administrador inicial de Keycloak (solo se usa en el primer arranque)."
  type        = string
  default     = "admin"
}

variable "keycloak_admin_password" {
  description = "Contraseña del administrador inicial. SECRETO: se pasa con TF_VAR_keycloak_admin_password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.keycloak_admin_password) >= 12
    error_message = "keycloak_admin_password debe tener al menos 12 caracteres."
  }
}

variable "keycloak_http_port" {
  description = "Puerto del host (solo 127.0.0.1) por el que el balanceador recibe el tráfico de Keycloak."
  type        = number
}

variable "keycloak_replicas" {
  description = "Número de réplicas de Keycloak detrás del balanceador (2 o más = sin SPOF en el cómputo)."
  type        = number
  default     = 2

  validation {
    condition     = var.keycloak_replicas >= 1 && var.keycloak_replicas <= 5
    error_message = "keycloak_replicas debe estar entre 1 y 5."
  }
}

variable "keycloak_log_console_output" {
  description = "Formato de los logs de Keycloak: json (estructurado, para Loki) o default (texto)."
  type        = string
  default     = "json"

  validation {
    condition     = contains(["json", "default"], var.keycloak_log_console_output)
    error_message = "keycloak_log_console_output debe ser \"json\" o \"default\"."
  }
}

variable "keycloak_log_level" {
  description = "Nivel de log de Keycloak (INFO, WARN, DEBUG...)."
  type        = string
  default     = "INFO"
}

variable "keycloak_memory_mb" {
  description = "Límite de memoria (MB) del contenedor de Keycloak; la JVM usa ~70% como heap."
  type        = number

  validation {
    condition     = var.keycloak_memory_mb >= 768
    error_message = "keycloak_memory_mb debe ser al menos 768 MB (Keycloak es una aplicación JVM)."
  }
}

variable "keycloak_cpus" {
  description = "Límite de CPU del contenedor de Keycloak (ej. \"1.0\", \"2.0\")."
  type        = string
}

# ---------- Balanceador (HAProxy) ----------
variable "lb_image" {
  description = "Imagen de HAProxy con tag fijo (rama LTS)."
  type        = string
  default     = "haproxy:3.2.26-alpine"
}

variable "lb_stats_port" {
  description = "Puerto del host (solo 127.0.0.1) para /stats y /metrics de HAProxy."
  type        = number
}

variable "lb_memory_mb" {
  description = "Límite de memoria (MB) del contenedor de HAProxy."
  type        = number
  default     = 256

  validation {
    condition     = var.lb_memory_mb >= 64
    error_message = "lb_memory_mb debe ser al menos 64 MB."
  }
}

variable "lb_cpus" {
  description = "Límite de CPU del contenedor de HAProxy."
  type        = string
  default     = "0.5"
}
