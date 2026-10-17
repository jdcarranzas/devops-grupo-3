# -----------------------------------------------------------------------------
# Versiones de Terraform y del provider, y backend del estado.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.6"
    }
  }

  # Estado local. Cada ambiente usa su propio workspace, así que los estados
  # quedan separados en terraform.tfstate.d/<workspace>/terraform.tfstate.
  # Los archivos *.tfstate están en .gitignore porque guardan los secretos en
  # texto plano. Para trabajar en equipo o en la nube se cambia este bloque
  # por un backend remoto cifrado y con bloqueo (ver README.md).
  backend "local" {}
}
