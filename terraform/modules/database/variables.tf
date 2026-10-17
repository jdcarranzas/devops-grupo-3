variable "name_prefix" {
  description = "Prefijo de nombres (<proyecto>-<ambiente>)."
  type        = string
}

variable "network_name" {
  description = "Red interna a la que se conecta PostgreSQL."
  type        = string
}

variable "image" {
  description = "Imagen de PostgreSQL con tag fijo."
  type        = string
}

variable "db_name" {
  description = "Nombre de la base de datos."
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
