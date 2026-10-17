variable "name_prefix" {
  description = "Prefijo de nombres (<proyecto>-<ambiente>)."
  type        = string
}

variable "frontend_subnet" {
  description = "CIDR de la red frontend."
  type        = string
}

variable "backend_subnet" {
  description = "CIDR de la red backend interna."
  type        = string
}

variable "labels" {
  description = "Etiquetas comunes para los recursos."
  type        = map(string)
  default     = {}
}
