locals {
  # Prefijo común para que dev y prod convivan en el mismo host sin chocar.
  name_prefix = "${var.project_name}-${var.environment}"

  # Etiquetas que llevan todos los recursos (trazabilidad y políticas).
  common_labels = {
    "project"     = var.project_name
    "environment" = var.environment
    "managed-by"  = "terraform"
    "team"        = "grupo-3"
  }

  # Contexto de build: la raíz del repositorio, donde está el Dockerfile.
  repo_root = abspath("${path.root}/..")
}
