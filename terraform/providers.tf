# Provider Docker: el "entorno virtualizado" donde se aprovisiona todo.
# Si var.docker_host es null se usa DOCKER_HOST o el socket por defecto.
#   Linux / macOS / WSL : unix:///var/run/docker.sock
#   Windows (Desktop)   : npipe:////./pipe/docker_engine
provider "docker" {
  host = var.docker_host
}
