# RB-03 · Una réplica de Keycloak fuera de servicio (pérdida de redundancia)

| Campo | Valor |
|---|---|
| Severidad | **SEV-3 / warning**: los usuarios no lo notan, pero la plataforma queda sin redundancia |
| Alertas que lo disparan | `KeycloakReplicaCaida` (ticket). Si cae también la otra réplica: `KeycloakNoResponde` (página, ir a RB-01) |
| SLO afectado | Ninguno de forma directa: el balanceador saca la réplica en ~4 s y reintenta en la otra |
| Dashboard | Grafana → **Keycloak · SRE** → fila *Alta disponibilidad · balanceador (HAProxy) y réplicas* |
| Estado del balanceador | `http://localhost:8405/stats` (prod) · `http://localhost:8404/stats` (dev) |
| Tiempo objetivo | Restablecer la redundancia ≤ 30 min (en horario laboral) |

> **Por qué importa:** con una sola réplica, cualquier segunda falla (reinicio, OOM, despliegue)
> es una caída total. Mientras dure, se aplica la regla de la política: **no se despliega** hasta
> recuperar las dos réplicas, porque el rolling update dejaría el servicio sin instancias.

En PowerShell, definir primero el prefijo del ambiente:

```powershell
$P = "keycloak-prod"     # o keycloak-dev
```

## 1. Confirmar el alcance (minuto 0-5)

1. Panel **Réplicas sanas en el balanceador**: debe mostrar `1` (naranja). Si muestra `0`, es una
   caída total: ir a **RB-01**.
2. Panel **Balanceador · 5xx al usuario**: debe estar en 0. Si hay reintentos o *redispatch*
   en el momento de la falla, el balanceador absorbió las peticiones que iban a la réplica caída.
3. Panel **Tráfico por réplica**: todo el tráfico pasa a la réplica sana y el total no cambia.

```powershell
docker ps -a --filter "name=$P-keycloak" --format "table {{.Names}}\t{{.Status}}"
docker inspect --format '{{.Name}} {{.State.Status}} exit={{.State.ExitCode}} OOM={{.State.OOMKilled}} reinicios={{.RestartCount}}' $P-keycloak-1 $P-keycloak-2
```

## 2. Diagnóstico de la causa

| Observación | Causa probable | Acción |
|---|---|---|
| `OOM=true` | La JVM superó el límite de memoria del contenedor | Revisar heap en el dashboard; subir `keycloak_memory_mb` en el tfvars (PR) |
| `exit=137` sin OOM | Terminación externa (`docker kill`, GameDay, host) | Reponer la réplica (paso 3) |
| `exit=1` y reinicios en bucle | Error de arranque (configuración, BD, clúster) | Revisar logs (abajo) |
| `Status=Up (unhealthy)` | Arrancó pero `/health/ready` no responde UP | Revisar logs y conexión a la BD |

Los logs son JSON: se filtran por nivel con Grafana (Explore → Loki) o directamente:

```powershell
docker logs --since 15m "$P-keycloak-2" 2>&1 | Select-String '"level":"(ERROR|WARN)"' | Select-Object -Last 20
```

## 3. Mitigación: reponer la réplica

La forma correcta es dejar que Terraform reconcilie el estado declarado (2 réplicas):

```powershell
cd terraform
terraform workspace select prod
terraform plan  -var-file=environments/prod.tfvars -var "keycloak_image=<imagen actual>"
terraform apply -var-file=environments/prod.tfvars -var "keycloak_image=<imagen actual>"
```

Si solo se detuvo el contenedor (sin cambios de configuración), basta con arrancarlo:

```powershell
docker start "$P-keycloak-2"
```

## 4. Verificar el restablecimiento

- [ ] `Réplicas sanas en el balanceador = 2` (verde) y ambas réplicas `UP` en `/stats`.
- [ ] Panel **Tráfico por réplica**: el tráfico vuelve a repartirse entre las dos.
- [ ] La alerta `KeycloakReplicaCaida` se resuelve en Alertmanager.
- [ ] Registrar el incidente (hora de inicio y fin, causa) aunque no haya consumido presupuesto.
