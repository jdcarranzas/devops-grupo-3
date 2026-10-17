# Configuración de TFLint: linter de buenas prácticas para Terraform.
# Se usa el ruleset "terraform" con el preset "all": variables y outputs
# documentados y tipados, convención de nombres snake_case, versiones fijadas
# en cada módulo, estructura estándar de módulos, declaraciones sin usar, etc.
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}
