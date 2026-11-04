# RB-04 · Restaurar la base de datos de Keycloak desde un respaldo

| Campo | Valor |
|---|---|
| Severidad | **SEV-1**: se usa cuando PostgreSQL no puede volver con sus propios datos (volumen corrupto, borrado o datos dañados) |
| Viene de | [RB-01 §2.A](RB-01-errores-5xx.md), cuando `docker start` de PostgreSQL no basta |
| Respaldos | `scripts/backup-db.ps1` → carpeta `backups/` (formato `pg_dump` custom, verificados con `pg_restore --list`) |
| Objetivos | **RTO** ≤ 60 min (restaurar) · **RPO** = intervalo entre respaldos (6 h si está programado) |

> **Las dos réplicas de Keycloak no protegen de esto:** comparten la misma base de datos. Todo lo que
> se haya creado después del último respaldo (usuarios, clientes, cambios de configuración) se pierde.
> Por eso el respaldo debe estar programado y la restauración, ensayada.

```powershell
$P = "keycloak-prod"
$D = "C:/terraform-state/devops-grupo-3"        # carpeta del estado de Terraform
```

## 1. Detener la escritura (minuto 0-5)

Sacar las dos réplicas del balanceador y detenerlas, para que nadie escriba en una BD a medio restaurar:

```powershell
docker stop "$P-keycloak-1" "$P-keycloak-2"
```

Desde aquí el servicio está caído para todos los usuarios (presupuesto: ≈ 0.46 % por minuto).

## 2. Elegir el respaldo

```powershell
Get-ChildItem backups -Filter "$P-*.dump" | Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name, LastWriteTime, Length
$respaldo = "backups/<archivo>.dump"
```

Anotar la hora del respaldo elegido: es el punto al que vuelve el sistema (pérdida de datos = ahora − esa hora).

## 3. Recrear la base de datos vacía (solo si el volumen está dañado)

Si PostgreSQL arranca pero los datos están mal, saltar al paso 4. Si el volumen está corrupto, se
recrea con Terraform **solo** la capa de datos:

```powershell
cd terraform
$env:TF_DATA_DIR = "$D/.terraform-data"
terraform workspace select prod
terraform apply -var-file=environments/prod.tfvars `
  -replace=module.database.docker_volume.data `
  -target=module.database
Remove-Item Env:TF_DATA_DIR
cd ..
```

`-target=module.database` evita que Terraform vuelva a iniciar las réplicas de Keycloak antes de restaurar.

## 4. Restaurar

```powershell
docker cp $respaldo "${P}-postgres:/tmp/restaurar.dump"
docker exec "$P-postgres" pg_restore -U keycloak -d keycloak --clean --if-exists --no-owner /tmp/restaurar.dump
docker exec "$P-postgres" rm -f /tmp/restaurar.dump
```

Comprobar que quedaron los datos:

```powershell
docker exec "$P-postgres" psql -U keycloak -d keycloak -c "SELECT name FROM realm;"
docker exec "$P-postgres" psql -U keycloak -d keycloak -c "SELECT count(*) AS usuarios FROM user_entity;"
```

## 5. Volver a poner el servicio

```powershell
docker start "$P-keycloak-1"
# esperar a keycloak-1 UP en http://localhost:8405/stats, luego:
docker start "$P-keycloak-2"
```

O, equivalente y además verificado: `./scripts/deploy.ps1 -Environment prod -Image <imagen actual> -StateDir $D`
(converge todo el estado, hace el smoke test y comprueba que no queda deriva).

## 6. Verificación

- [ ] Las dos réplicas en **UP** en HAProxy y `terraform plan` sin cambios.
- [ ] Login de un usuario real y obtención de un token (ver RB-01 §3).
- [ ] *Tasa de error 5xx* en 0 % y alertas resueltas.
- [ ] Hacer **un respaldo nuevo de inmediato** (`./scripts/backup-db.ps1`).
- [ ] Registrar en el postmortem: hora del incidente, respaldo usado, datos perdidos (RPO real) y
      duración de la restauración (RTO real).

## Ensayo (recomendado una vez por sprint, en dev)

Restaurar en `keycloak-dev` el último respaldo de prod y comprobar el conteo de realms y usuarios. Un
respaldo que nunca se ha restaurado no es un respaldo: es una suposición.
