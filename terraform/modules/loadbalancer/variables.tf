variable "name_prefix" {
  description = "Prefijo de nombres (<proyecto>-<ambiente>)."
  type        = string
}

variable "image" {
  description = "Imagen de HAProxy con tag fijo."
  type        = string
}

variable "frontend_network_name" {
  description = "Red frontend (desde aquí se publican los puertos)."
  type        = string
}

variable "backend_network_name" {
  description = "Red backend interna donde están las réplicas de Keycloak."
  type        = string
}

variable "backend_servers" {
  description = "Alias DNS de las réplicas de Keycloak (keycloak-1, keycloak-2, ...)."
  type        = list(string)

  validation {
    condition     = length(var.backend_servers) >= 1
    error_message = "Se necesita al menos una réplica detrás del balanceador."
  }
}

variable "http_port" {
  description = "Puerto del host (solo 127.0.0.1) para el tráfico de usuarios."
  type        = number
}

variable "stats_port" {
  description = "Puerto del host (solo 127.0.0.1) para /stats y /metrics de HAProxy."
  type        = number
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
