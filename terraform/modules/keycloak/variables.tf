variable "name_prefix" {
  description = "Prefijo de nombres (<proyecto>-<ambiente>)."
  type        = string
}

variable "image" {
  description = "Nombre:tag de la imagen de Keycloak."
  type        = string
}

variable "build_from_source" {
  description = "true = construir la imagen con el Dockerfile; false = descargarla."
  type        = bool
  default     = false
}

variable "build_context" {
  description = "Ruta absoluta del contexto de build (raíz del repositorio)."
  type        = string
}

variable "backend_network_name" {
  description = "Red backend interna: PostgreSQL, balanceador y réplicas."
  type        = string
}

variable "db_jdbc_url" {
  description = "Cadena JDBC de la base de datos."
  type        = string
}

variable "db_user" {
  description = "Usuario de la base de datos."
  type        = string
}

variable "db_password" {
  description = "Contraseña de la base de datos (secreto)."
  type        = string
  sensitive   = true
}

variable "admin_user" {
  description = "Usuario administrador inicial."
  type        = string
}

variable "admin_password" {
  description = "Contraseña del administrador inicial (secreto)."
  type        = string
  sensitive   = true
}

variable "replicas" {
  description = "Número de réplicas de Keycloak detrás del balanceador."
  type        = number
  default     = 2

  validation {
    condition     = var.replicas >= 1 && var.replicas <= 5
    error_message = "replicas debe estar entre 1 y 5."
  }
}

variable "log_console_output" {
  description = "Formato de los logs de consola: json (estructurado) o default (texto)."
  type        = string
  default     = "json"

  validation {
    condition     = contains(["json", "default"], var.log_console_output)
    error_message = "log_console_output debe ser \"json\" o \"default\"."
  }
}

variable "log_level" {
  description = "Nivel de log de Keycloak."
  type        = string
  default     = "INFO"
}

variable "memory_mb" {
  description = "Límite de memoria del contenedor en MB."
  type        = number
}

variable "cpus" {
  description = "Límite de CPU del contenedor."
  type        = string
}

variable "labels" {
  description = "Etiquetas comunes para los recursos."
  type        = map(string)
  default     = {}
}
