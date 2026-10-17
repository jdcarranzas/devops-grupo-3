# =============================================================================
# Políticas como código (OPA / Rego) que se evalúan con conftest sobre el plan
# de Terraform en JSON (terraform show -json tfplan). Si una regla "deny" se
# cumple, el pipeline falla ANTES de cualquier despliegue.
# =============================================================================
package main

import rego.v1

containers contains rc if {
	some rc in input.resource_changes
	rc.type == "docker_container"
	not "delete" in rc.change.actions
}

images contains rc if {
	some rc in input.resource_changes
	rc.type == "docker_image"
	not "delete" in rc.change.actions
}

networks contains rc if {
	some rc in input.resource_changes
	rc.type == "docker_network"
	not "delete" in rc.change.actions
}

label_value(after, key) := value if {
	some l in after.labels
	l.label == key
	value := l.value
}

# 1. La capa de datos nunca publica puertos en el host.
deny contains msg if {
	some rc in containers
	label_value(rc.change.after, "tier") == "data"
	count(object.get(rc.change.after, "ports", [])) > 0
	msg := sprintf("%s: la capa de datos no puede publicar puertos en el host", [rc.address])
}

# 2. Los puertos publicados solo se exponen en 127.0.0.1 (no en 0.0.0.0).
deny contains msg if {
	some rc in containers
	some p in object.get(rc.change.after, "ports", [])
	object.get(p, "ip", "0.0.0.0") != "127.0.0.1"
	msg := sprintf("%s: el puerto %v debe publicarse solo en 127.0.0.1", [rc.address, p.internal])
}

# 3. Todo contenedor tiene límite de memoria y de CPU.
deny contains msg if {
	some rc in containers
	object.get(rc.change.after, "memory", 0) <= 0
	msg := sprintf("%s: debe definir un límite de memoria", [rc.address])
}

deny contains msg if {
	some rc in containers
	object.get(rc.change.after, "cpus", "") == ""
	msg := sprintf("%s: debe definir un límite de CPU", [rc.address])
}

# 4. Ningún contenedor corre en modo privilegiado.
deny contains msg if {
	some rc in containers
	rc.change.after.privileged == true
	msg := sprintf("%s: no se permiten contenedores privilegiados", [rc.address])
}

# 5. Todos los contenedores deshabilitan la escalada de privilegios.
deny contains msg if {
	some rc in containers
	not "no-new-privileges:true" in object.get(rc.change.after, "security_opts", [])
	msg := sprintf("%s: debe incluir security_opts = [\"no-new-privileges:true\"]", [rc.address])
}

# 6. Las imágenes usan un tag explícito y nunca "latest".
deny contains msg if {
	some rc in images
	name := rc.change.after.name
	not regex.match(`:[A-Za-z0-9_][A-Za-z0-9._-]*$`, name)
	msg := sprintf("%s: la imagen '%s' debe tener un tag explícito", [rc.address, name])
}

deny contains msg if {
	some rc in images
	endswith(rc.change.after.name, ":latest")
	msg := sprintf("%s: no se permite el tag 'latest' (%s)", [rc.address, rc.change.after.name])
}

# 7. La red backend (donde vive la BD) debe ser interna.
deny contains msg if {
	some rc in networks
	label_value(rc.change.after, "tier") == "backend"
	not rc.change.after.internal == true
	msg := sprintf("%s: la red backend debe ser interna (internal = true)", [rc.address])
}

# 8. Todo recurso con etiquetas lleva las etiquetas obligatorias de trazabilidad.
required_labels := {"project", "environment", "managed-by"}

deny contains msg if {
	some rc in input.resource_changes
	rc.type in {"docker_container", "docker_network", "docker_volume"}
	not "delete" in rc.change.actions
	present := {l.label | some l in object.get(rc.change.after, "labels", [])}
	missing := required_labels - present
	count(missing) > 0
	msg := sprintf("%s: faltan las etiquetas obligatorias %v", [rc.address, missing])
}

# 9. Ningún secreto de ejemplo llega a desplegarse.
weak_values := {"cambiar_esta_clave", "cambiar_esta_clave_admin", "admin", "password", "keycloak"}

deny contains msg if {
	some rc in containers
	some e in object.get(rc.change.after, "env", [])
	parts := split(e, "=")
	endswith(parts[0], "PASSWORD")
	parts[1] in weak_values
	msg := sprintf("%s: %s usa una contraseña de ejemplo o débil", [rc.address, parts[0]])
}
