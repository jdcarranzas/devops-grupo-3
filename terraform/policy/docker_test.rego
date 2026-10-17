# Pruebas unitarias de las políticas: conftest verify --policy policy/
package main

import rego.v1

labels(tier) := [
	{"label": "project", "value": "keycloak"},
	{"label": "environment", "value": "dev"},
	{"label": "managed-by", "value": "terraform"},
	{"label": "tier", "value": tier},
]

good_db := {
	"address": "module.database.docker_container.postgres",
	"type": "docker_container",
	"change": {"actions": ["create"], "after": {
		"memory": 512, "cpus": "0.5", "privileged": false,
		"security_opts": ["no-new-privileges:true"], "ports": [],
		"env": ["POSTGRES_PASSWORD=Sup3r-Segura-2026"], "labels": labels("data"),
	}},
}

good_kc := {
	"address": "module.keycloak.docker_container.keycloak",
	"type": "docker_container",
	"change": {"actions": ["create"], "after": {
		"memory": 1024, "cpus": "1.0", "privileged": false,
		"security_opts": ["no-new-privileges:true"],
		"ports": [{"internal": 8080, "external": 8080, "ip": "127.0.0.1"}],
		"env": ["KC_DB_PASSWORD=Sup3r-Segura-2026"], "labels": labels("compute"),
	}},
}

good_net := {
	"address": "module.network.docker_network.backend",
	"type": "docker_network",
	"change": {"actions": ["create"], "after": {"internal": true, "labels": labels("backend")}},
}

good_img := {
	"address": "module.database.docker_image.postgres",
	"type": "docker_image",
	"change": {"actions": ["create"], "after": {"name": "postgres:17-alpine"}},
}

plan(rcs) := {"resource_changes": rcs}

test_plan_correcto_no_tiene_violaciones if {
	count(deny) == 0 with input as plan([good_db, good_kc, good_net, good_img])
}

test_bd_con_puerto_publicado if {
	bad := json.patch(good_db, [{"op": "replace", "path": "/change/after/ports", "value": [{"internal": 5432, "ip": "127.0.0.1"}]}])
	some msg in deny with input as plan([bad])
	contains(msg, "capa de datos")
}

test_puerto_en_todas_las_interfaces if {
	bad := json.patch(good_kc, [{"op": "replace", "path": "/change/after/ports/0/ip", "value": "0.0.0.0"}])
	some msg in deny with input as plan([bad])
	contains(msg, "127.0.0.1")
}

test_sin_limite_de_memoria if {
	bad := json.patch(good_kc, [{"op": "remove", "path": "/change/after/memory"}])
	some msg in deny with input as plan([bad])
	contains(msg, "memoria")
}

test_contenedor_privilegiado if {
	bad := json.patch(good_kc, [{"op": "replace", "path": "/change/after/privileged", "value": true}])
	some msg in deny with input as plan([bad])
	contains(msg, "privilegiados")
}

test_sin_no_new_privileges if {
	bad := json.patch(good_kc, [{"op": "replace", "path": "/change/after/security_opts", "value": []}])
	some msg in deny with input as plan([bad])
	contains(msg, "no-new-privileges")
}

test_imagen_latest if {
	bad := json.patch(good_img, [{"op": "replace", "path": "/change/after/name", "value": "postgres:latest"}])
	some msg in deny with input as plan([bad])
	contains(msg, "latest")
}

test_imagen_sin_tag if {
	bad := json.patch(good_img, [{"op": "replace", "path": "/change/after/name", "value": "postgres"}])
	some msg in deny with input as plan([bad])
	contains(msg, "tag explícito")
}

test_red_backend_no_interna if {
	bad := json.patch(good_net, [{"op": "replace", "path": "/change/after/internal", "value": false}])
	some msg in deny with input as plan([bad])
	contains(msg, "interna")
}

test_faltan_etiquetas if {
	bad := json.patch(good_db, [{"op": "replace", "path": "/change/after/labels", "value": [{"label": "tier", "value": "data"}]}])
	some msg in deny with input as plan([bad])
	contains(msg, "etiquetas obligatorias")
}

test_contrasena_de_ejemplo if {
	bad := json.patch(good_db, [{"op": "replace", "path": "/change/after/env/0", "value": "POSTGRES_PASSWORD=cambiar_esta_clave"}])
	some msg in deny with input as plan([bad])
	contains(msg, "contraseña de ejemplo")
}
