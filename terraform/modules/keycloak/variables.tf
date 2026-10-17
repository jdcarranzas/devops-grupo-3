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

variable "frontend_network_name" {
  description = "Red frontend (puertos publicados)."
  type        = string
}

variable "backend_network_name" {
  description = "Red backend interna (acceso a PostgreSQL)."
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

variable "http_port" {
  description = "Puerto del host para HTTP (8080 dentro del contenedor)."
  type        = number
}

variable "management_port" {
  description = "Puerto del host para gestión (9000 dentro del contenedor)."
  type        = number
}

variable "publish_management_port" {
  description = "Publicar o no el puerto de gestión en el host."
  type        = bool
  default     = false
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
