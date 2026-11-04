# Pre-Mortem · Plataforma de identidad Keycloak (Grupo 3)

| Campo | Valor |
|---|---|
| Sistema | Keycloak 26.8 (2 réplicas en clúster) + HAProxy + PostgreSQL 17, desplegado con Terraform sobre Docker |
| Participantes | Juan David Carranza Sánchez, Diana Fernanda Reyes Marciales, Pablo Esteban Olaya Arias |
| Fecha del ejercicio | Noviembre de 2026 (Entregable 4) |
| Documentos relacionados | [DESPLIEGUE.md](DESPLIEGUE.md) · runbooks [RB-01](../observability/runbooks/RB-01-errores-5xx.md), [RB-02](../observability/runbooks/RB-02-latencia.md), [RB-03](../observability/runbooks/RB-03-replica-caida.md), [RB-04](../observability/runbooks/RB-04-restauracion-bd.md) |

## 0. El supuesto

> *Es lunes 7 de diciembre de 2026. Durante el fin de semana la plataforma de identidad sufrió una falla
> catastrófica: por varias horas ninguna aplicación integrada pudo autenticar a sus usuarios, y una parte
> de la configuración se perdió. El presupuesto de error del mes se agotó y el equipo está en congelamiento
> de cambios. ¿Qué pasó?*

Un pre-mortem invierte el postmortem: se da por hecho que el desastre ocurrió y se trabaja hacia atrás
para encontrar las causas **antes** de que sucedan. Keycloak es una dependencia transversal: si no emite
tokens, fallan todas las aplicaciones que dependen de él, así que su caída tiene un radio de impacto mayor
que el de cualquier aplicación individual.

## 1. Método y supuestos de cálculo

1. Cada integrante propuso de forma independiente formas en que la plataforma podría fallar.
2. Se consolidaron en un mapa de riesgos (sección 2) y se priorizaron por **probabilidad × impacto**.
3. Para los tres escenarios prioritarios: cadena de falla, **5 Porqués**, impacto cuantitativo sobre los
   SLOs y controles (preventivos, detectivos y de contingencia) enlazados a los runbooks.

**SLOs vigentes (Entregable 3):**

| SLO | Meta (30 días móviles) | Presupuesto |
|---|---|---|
| Disponibilidad | 99.5 % de peticiones a `/realms/*` sin 5xx | 0.5 % de las peticiones ≈ 216 min de caída total |
| Latencia | 95 % de peticiones en ≤ 250 ms | 5 % de las peticiones |

**Fórmulas** (tráfico aproximadamente uniforme; 30 días = 43 200 min):

- Burn rate = tasa de error ÷ (1 − SLO). Para disponibilidad: tasa de error ÷ 0.005.
- Presupuesto consumido = burn rate × duración ÷ 43 200 min.
- Una **caída total** (100 % de errores) tiene burn rate 200x y consume **0.46 % del presupuesto por minuto**.
- **Mezcla de tráfico** (perfil de k6 y uso típico de un IdP): ~82 % de las peticiones van a `/token`
  (client credentials y login) y ~18 % a discovery/JWKS. Discovery y JWKS se sirven desde caché aunque
  la BD esté caída, así que una caída de la BD produce **≈ 82 % de errores** (en el Entregable 3 se midió
  ~85 %): burn rate ≈ 164x, **≈ 0.38 % del presupuesto por minuto**.

**Tiempos de detección reales del sistema de alertas** (multiventana, Entregable 3). La alerta crítica de
disponibilidad exige tasa de error > 7.2 % en 1 h **y** en 5 min, durante 2 min. Con 82 % de errores y una
hora completa de historial, la ventana de 1 h cruza el umbral a los 0.072 × 60 / 0.82 ≈ **5.3 min**, y la
alerta pasa a FIRING a los **≈ 7.3 min**. `PostgreSQLCaido` dispara antes (≈ 1-1.5 min) y orienta el
diagnóstico. En el GameDay del laboratorio la crítica saltó a los 2.5 min porque solo había ~30 min de
historial: con menos historia, la ventana de 1 h es más sensible.

## 2. Mapa de riesgos

| # | Modo de falla | Probabilidad | Impacto | Estado tras el Entregable 4 |
|---|---|---|---|---|
| R1 | **Pérdida o corrupción de la base de datos** (disco lleno, volumen dañado, `terraform destroy` accidental) | Media | **Catastrófico** (caída total + pérdida de datos) | PostgreSQL sigue siendo SPOF → **Escenario 1** |
| R2 | **Despliegue defectuoso que pasa todo el pipeline** | Media-alta | Alto (caída de logins en minutos, en todas las réplicas) | Rolling update sin verificación funcional → **Escenario 2** |
| R3 | **Caída del host único** (reinicio por actualización, apagado, Docker Desktop cerrado) | Alta en laboratorio | Catastrófico (todo, incluido el monitoreo) | Riesgo aceptado en el laboratorio → **Escenario 3** |
| R4 | Caída de una réplica de Keycloak (OOM, *kill*) | Media | Bajo (el balanceador la absorbe) | **Mitigado**: 2 réplicas + HAProxy. Probado en el GameDay: 0 errores al usuario |
| R5 | Saturación por tormenta de logins o fuerza bruta (hash de contraseñas en CPU) | Media | Medio (consume presupuesto de latencia) | Detectado por SLO de latencia; mitigación en RB-02 |
| R6 | Compromiso de la cadena de suministro (acción de CI o imagen base) | Baja | Alto | Mitigado en parte: Trivy, versiones fijadas (incidente real de `trivy-action`, Entregable 1) |
| R8 | Health check del balanceador acoplado a una dependencia compartida (readiness) | Ocurrió en el GameDay | Alto (503 a todo + SLI ciego) | **Corregido**: liveness + alerta `BalanceadorSinReplicas` (sección 8) |
| R7 | Credenciales o secretos expuestos (estado de Terraform en texto plano) | Baja | Alto | Mitigado: estado fuera del repo y en `.gitignore`; pendiente: backend cifrado |

---

## 3. Escenario 1 · Pérdida de la base de datos

### 3.1 Narrativa y cadena de falla

El sábado en la noche el disco del host se llena (logs de contenedores y capas de imágenes acumuladas).
PostgreSQL no puede escribir el WAL y se detiene; al reiniciar, el volumen `keycloak-prod-pgdata` queda
inconsistente y PostgreSQL no arranca. Las dos réplicas de Keycloak siguen vivas, pero todo `/token` y
todo login responde 500. Al intentar recuperar, alguien ejecuta `terraform destroy` + `apply` para "empezar
limpio" y el volumen se borra. No hay un respaldo reciente probado: hay que recrear a mano realms,
clientes y usuarios.

```
disco lleno → PostgreSQL se detiene → volumen inconsistente → 5xx en /token (≈ 82 %)
            → recuperación improvisada → volumen borrado → sin respaldo → reconstrucción manual (horas)
```

### 3.2 Los 5 Porqués

| # | Pregunta | Respuesta |
|---|---|---|
| 1 | ¿Por qué ningún usuario pudo iniciar sesión? | Porque las dos réplicas de Keycloak respondían 500: no podían leer ni escribir en PostgreSQL. |
| 2 | ¿Por qué no podían usar PostgreSQL? | Porque PostgreSQL se detuvo al quedarse sin disco y su volumen quedó inconsistente. |
| 3 | ¿Por qué la caída de una sola base de datos tumbó todo el servicio? | Porque la HA del Entregable 4 se hizo en el cómputo: las réplicas comparten **una** instancia de PostgreSQL, sin réplica ni failover. |
| 4 | ¿Por qué no se pudo volver al estado anterior en minutos? | Porque no existía un respaldo reciente **y probado**, y no había un procedimiento de restauración escrito: se improvisó y se borró el volumen. |
| 5 | ¿Por qué no existían? | Porque el riesgo de pérdida de datos no estaba en los SLOs (miden disponibilidad y latencia, no durabilidad) y nunca se ensayó una restauración. Lo que no se mide ni se ensaya no se prioriza. |

**Causa raíz:** la persistencia es un punto único de falla sin estrategia de recuperación ensayada; la
durabilidad de los datos no tenía un objetivo explícito (RPO/RTO).

### 3.3 Impacto sobre los SLIs, SLOs y el presupuesto

| Variante | Duración de la caída | Burn rate (disp.) | Presupuesto de disponibilidad consumido | Datos perdidos |
|---|---|---|---|---|
| BD se detiene y vuelve con `docker start` (lo que ensayamos en el GameDay) | 10 min | 164x | 164 × 10 / 43 200 ≈ **3.8 %** | Ninguno |
| Volumen dañado, **con** respaldo probado (RB-04) | 60 min | 164x | ≈ **22.8 %** → postmortem obligatorio (> 20 %) | Desde el último respaldo (RPO 6 h) |
| Volumen borrado, **sin** respaldo | 8 h | 164x | ≈ **182 %** → presupuesto **agotado**, congelamiento | Todo: realms, clientes y usuarios |

Efecto adicional sobre el **SLO de latencia**: durante la caída las peticiones no fallan rápido. Keycloak
espera la conexión antes de responder 500 (p95 de ~20 ms a 9.4 s en el Entregable 3), así que el 82 % de
las peticiones también son "lentas": burn rate de latencia ≈ 0.82 / 0.05 ≈ 16x. En 60 minutos eso es
~2.3 % del presupuesto de latencia.

**Hallazgo:** los SLOs no ven la pérdida de datos. En la variante "sin respaldo", una vez reconstruido el
sistema, las métricas vuelven a verde aunque los usuarios hayan perdido sus cuentas. La durabilidad necesita
su propio objetivo: **RPO ≤ 6 h y RTO ≤ 60 min**.

### 3.4 Controles

| Tipo | Control | Estado |
|---|---|---|
| Preventivo | Respaldo lógico verificado (`scripts/backup-db.ps1`: `pg_dump` + `pg_restore --list`, retención de 14) | **Implementado**; programarlo cada 6 h (Programador de tareas) |
| Preventivo | Ensayo de restauración en dev una vez por sprint (RB-04, "Ensayo") | Procedimiento escrito |
| Preventivo | `lifecycle { prevent_destroy = true }` en el volumen de datos | Pendiente (bloquea también los `destroy` legítimos de laboratorio) |
| Preventivo | Rotación de logs de contenedores (`max-size 10m`, `max-file 3`) para no llenar el disco | **Implementado** en todos los contenedores |
| Detectivo | `PostgreSQLCaido` (≈ 1 min), `KeycloakDisponibilidadBurnRateAlto` (≈ 7 min con historial completo) | **Implementado** y probado en el GameDay |
| Detectivo | Panel de logs: `FATAL` de PostgreSQL y `PSQLException` de Keycloak en la misma vista | **Implementado** (Loki) |
| Detectivo | Alerta de uso de disco del host (> 80 %) | Pendiente |
| Contingencia | RB-01 §2.A (BD detenida) → RB-04 (restauración desde respaldo) | **Escrito** |
| Arquitectura (nube) | RDS PostgreSQL Multi-AZ con failover automático y PITR (RPO de segundos) | Propuesto en DESPLIEGUE.md §5 |

---

## 4. Escenario 2 · Despliegue defectuoso que pasa todo el pipeline

### 4.1 Narrativa y cadena de falla

Un viernes se aprueba un PR que actualiza la versión de Keycloak (por un CVE) y ajusta una opción de
configuración. El CI pasa: lint, build, Trivy sin CRITICAL, plan de Terraform y políticas OPA en verde. El
despliegue hace el rolling update: la réplica 1 arranca y `/health/ready` responde UP (la BD está
accesible), así que el script continúa con la réplica 2. El smoke test final consulta discovery y JWKS:
200. El despliegue termina en verde. Pero la nueva configuración rompe la emisión de tokens: todo
`/token` responde 500 en las dos réplicas.

```
PR aprobado → CI verde → réplica 1 "healthy" → réplica 2 "healthy" → smoke test (discovery/JWKS) verde
            → /token roto en el 100 % de las réplicas → caída de logins hasta que alguien hace rollback
```

### 4.2 Los 5 Porqués

| # | Pregunta | Respuesta |
|---|---|---|
| 1 | ¿Por qué los usuarios no pudieron iniciar sesión? | Porque `/token` respondía 500 en las dos réplicas después del despliegue. |
| 2 | ¿Por qué quedaron afectadas las dos réplicas si el despliegue es gradual? | Porque el rolling update pasó a la réplica 2 apenas la 1 estuvo "healthy", sin comprobar que funcionara. |
| 3 | ¿Por qué "healthy" no detectó el problema? | Porque `/health/ready` solo verifica que el proceso esté arriba y que la BD responda, no que se puedan emitir tokens. |
| 4 | ¿Por qué tampoco lo detectó el smoke test? | Porque el smoke test consulta discovery y JWKS, que se sirven desde caché y funcionan aunque la emisión de tokens esté rota. |
| 5 | ¿Por qué se diseñó así? | Porque se optimizó para un pipeline rápido y sin credenciales: se verificó que el servicio **responde**, no que cumple su función. Las verificaciones de salud no reproducen el recorrido del usuario. |

**Causa raíz:** las compuertas del despliegue verifican el estado del proceso (*liveness*), no el
comportamiento que miden los SLIs (emitir tokens), y no hay una compuerta entre réplicas (*canary*).

### 4.3 Impacto sobre los SLIs, SLOs y el presupuesto

| Fase | Tiempo | Detalle |
|---|---|---|
| Despliegue completo | 0 → ~3 min | La réplica 1 falla desde ~1 min; tras la réplica 2, el 100 % de `/token` falla (≈ 82 % del tráfico) |
| Detección | ~7 min | `KeycloakDisponibilidadBurnRateAlto` (burn rate 164x) |
| Diagnóstico | ~3 min | Panel de logs: errores nuevos en las dos réplicas justo después del despliegue → RB-01 §2.D |
| Rollback | ~5 min | *Deploy → Run workflow* con el `sha-` anterior; imagen ya en caché; rolling update |
| **Total** | **≈ 15 min** | Presupuesto consumido ≈ 164 × 15 / 43 200 ≈ **5.7 %** del mes |

La variante más peligrosa es una configuración que **no** produce 5xx: por ejemplo, un `hostname` mal
configurado que emite tokens con un *issuer* incorrecto. Keycloak responde 200, el SLI marca 100 % y las
aplicaciones rechazan los tokens. Ningún SLO lo detecta: lo reportan los usuarios, horas después. Es un
hueco de cobertura del SLI, que mide el servidor y no el resultado en el cliente.

### 4.4 Controles

| Tipo | Control | Estado |
|---|---|---|
| Preventivo | **Compuerta canary**: después de reemplazar la réplica 1, pedir un token real (`client_credentials`) solo a esa réplica y validar su *issuer*; si falla, detener el despliegue y devolverla a la imagen anterior | Pendiente: acción prioritaria |
| Preventivo | Smoke test que valida el *issuer* anunciado por Keycloak contra la URL pública | **Implementado** tras el ensayo (sección 8) |
| Preventivo | Smoke test que emite y valida un token a través del balanceador (no solo discovery/JWKS) | Pendiente |
| Preventivo | Error Budget Policy: en amarillo, todo despliegue requiere plan de rollback probado y revisión de un segundo integrante | **Vigente** (Entregable 3) |
| Detectivo | Alertas de burn rate de disponibilidad; panel de logs por réplica | **Implementado** |
| Detectivo | Sonda sintética externa que hace login y valida el token (cubre la variante sin 5xx) | Pendiente |
| Contingencia | Rollback por `workflow_dispatch` a un tag inmutable `sha-<commit>`; también es un rolling update | **Implementado** (DESPLIEGUE.md) |

---

## 5. Escenario 3 · Caída del host único

### 5.1 Narrativa y cadena de falla

Windows instala actualizaciones y reinicia el equipo del laboratorio un domingo a las 3 a. m. Docker
Desktop no arranca solo y nadie inicia sesión hasta el lunes a las 7 a. m. Todo está en ese host: las dos
réplicas, el balanceador, PostgreSQL, Prometheus, Alertmanager y el runner de despliegue. No llega ninguna
alerta, porque el sistema que debía avisar también estaba apagado.

```
reinicio del host → Docker Desktop no arranca → todo apagado (servicio y monitoreo)
                  → cero alertas → 4 h de caída descubiertas por los usuarios
```

### 5.2 Los 5 Porqués

| # | Pregunta | Respuesta |
|---|---|---|
| 1 | ¿Por qué el servicio estuvo caído 4 horas? | Porque el host se reinició y Docker Desktop no volvió a levantar los contenedores. |
| 2 | ¿Por qué nadie actuó antes? | Porque no llegó ninguna alerta. |
| 3 | ¿Por qué no llegó ninguna alerta? | Porque Prometheus y Alertmanager corren en el mismo host: cayeron junto con el servicio. |
| 4 | ¿Por qué el monitoreo comparte destino con lo monitoreado? | Porque toda la plataforma (servicio, observabilidad y despliegue) vive en un solo host para simplificar el laboratorio, y nunca se planteó cómo detectar la ausencia total de señales. |
| 5 | ¿Por qué no se planteó? | Porque la redundancia se pensó por componente (réplicas, balanceador) y no por **dominio de falla**: dos réplicas en el mismo host fallan juntas. |

**Causa raíz:** un único dominio de falla para el servicio y para su monitoreo; no existe una señal
externa que detecte el silencio.

### 5.3 Impacto sobre los SLIs, SLOs y el presupuesto

- Caída total, 100 % de errores para el usuario: 200x. 240 min → 200 × 240 / 43 200 ≈ **111 % del
  presupuesto**. Se agota en una noche y el equipo entra en congelamiento de cambios.
- **Pero el SLI no lo registra.** Se mide en el servidor, a partir de las métricas de Keycloak: si Keycloak
  y Prometheus están apagados, no hay peticiones contadas ni errores. El dashboard muestra un hueco
  ("sin datos"), no rojo. El presupuesto calculado no baja, aunque el presupuesto real se agotó.
  Un SLO que solo mide desde adentro no ve las caídas totales.

### 5.4 Controles

| Tipo | Control | Estado |
|---|---|---|
| Preventivo | Docker Desktop configurado para iniciar con la sesión de Windows; `restart: unless-stopped` en todos los contenedores | Contenedores: **implementado**. Docker Desktop: configurar en el equipo |
| Preventivo | Ventana de actualizaciones de Windows controlada (horas activas) | Pendiente (configuración del equipo) |
| Detectivo | **Sonda externa** (blackbox) desde otro dominio de falla, por ejemplo un workflow programado de GitHub Actions o un servicio de uptime, que pida `/.well-known` y alerte si falla | Pendiente: acción prioritaria |
| Detectivo | **Dead man's switch**: una alerta `Watchdog` siempre activa que Alertmanager envía a un receptor externo; si deja de llegar, el monitoreo está caído | Pendiente |
| Contingencia | Arranque ordenado tras reinicio: `./scripts/deploy.ps1` (converge y verifica) y luego la pila de observabilidad | **Implementado** |
| Arquitectura (nube) | Réplicas en al menos 2 zonas de disponibilidad, balanceador gestionado y monitoreo en una cuenta o región distinta | Propuesto en DESPLIEGUE.md §5 |
| Aceptación del riesgo | En el laboratorio se acepta: es la razón por la que el SLO es 99.5 % y no 99.9 % (Entregable 3) | Documentado |

---

## 6. Resumen: presupuesto en juego

| Escenario | Con los controles actuales | Con los controles pendientes |
|---|---|---|
| 1. Pérdida de la BD | 3.8 % (BD vuelve) a 182 % (sin respaldo) | ≤ 22.8 % (restauración ensayada); ~0 % con Multi-AZ en la nube |
| 2. Despliegue defectuoso | ≈ 5.7 % | < 1 % (la compuerta canary detiene el despliegue en la réplica 1 y el balanceador la saca) |
| 3. Caída del host | ≈ 111 % real, **invisible** para el SLI | Detectada en minutos por la sonda externa; ~0 % con multi-AZ |
| 4. Caída de una réplica (probado) | **0 %** (0 errores al usuario, 19 peticiones redirigidas por HAProxy) | — |

## 7. Plan de acción priorizado

| Prioridad | Acción | Mitiga | Runbook |
|---|---|---|---|
| 1 | Programar `backup-db.ps1` cada 6 h y ensayar RB-04 en dev | Escenario 1 | RB-04 |
| 2 | Compuerta canary con token real en `deploy.ps1` + rollback automático | Escenario 2 | RB-01 §2.D |
| 3 | Sonda externa + alerta *Watchdog* hacia un receptor fuera del host | Escenario 3 | — |
| 4 | Alerta de disco del host > 80 % | Escenario 1 | RB-01 §2.A |
| 5 | `prevent_destroy` en el volumen de datos de prod | Escenario 1 | RB-04 |
| 6 | Migración a nube: RDS Multi-AZ, ALB, ECS en 2 zonas, OIDC y estado remoto cifrado | 1, 2 y 3 | DESPLIEGUE.md §5 |

## 8. Lo que confirmó el GameDay

- **Caída de una réplica** (`docker kill`): HAProxy la retiró en segundos, redirigió 19 peticiones y
  entregó **0 errores**; `KeycloakReplicaCaida` pasó a FIRING al minuto como *warning* (ticket, no página)
  y se resolvió sola al reponer la réplica. El SLI de disponibilidad se mantuvo en 100 %. El SLI de latencia
  bajó a 99.99 % por el arranque en frío de la JVM de la réplica repuesta: el margen del 5 % existe
  justamente para eso.
- **Hallazgo: el balanceador volvió invisible la caída de la BD.** En el primer ensayo, HAProxy revisaba
  `/health/ready`, que pasa a DOWN cuando falta la BD. Como la BD es **compartida**, las dos réplicas
  salieron del balanceo a la vez: HAProxy respondió 503 a todo (incluso discovery y JWKS, que Keycloak
  sirve desde caché) y, como ninguna petición llegaba a Keycloak, el SLI quedó en 0/0 (`NaN`) y **ninguna
  alerta de burn rate disparó**. La HA empeoró la experiencia del usuario y cegó el monitoreo.
  - *5 Porqués resumidos:* sin alertas → el SLI no veía peticiones → HAProxy no enviaba tráfico → las dos
    réplicas fallaban el health check → el health check medía una dependencia compartida (readiness) en
    lugar de la salud del proceso (liveness).
  - *Corrección aplicada:* HAProxy revisa `/health/live`; nueva alerta `BalanceadorSinReplicas` calculada con
    las métricas de HAProxy (un SLI medido más cerca del usuario cubre el punto ciego del SLI de Keycloak).
  - *Lección:* un health check de balanceador no debe depender de algo que comparten todas las réplicas, y
    cada SLI debe tener una alerta que no dependa de que las peticiones lleguen a la aplicación.
- **Hallazgo: tokens con un *issuer* incorrecto y el SLI en verde.** Al abrir la consola por el balanceador,
  Keycloak redirigía a `http://localhost/...` sin el puerto: su *issuer* era `http://localhost/realms/master`.
  HAProxy enviaba `X-Forwarded-Proto: http` sin `X-Forwarded-Port`, y Keycloak asumía el puerto 80. Todo
  respondía 200 y el smoke test (que solo pedía discovery y JWKS) pasaba: es exactamente la variante
  silenciosa del escenario 2. *Corrección:* HAProxy ya no envía `X-Forwarded-Proto` (sin TLS no aporta) y
  el smoke test de `deploy.ps1` ahora **falla si el issuer no coincide** con la URL pública.
- **Caída de PostgreSQL (después de la corrección)**: confirma la cadena del escenario 1. Las dos réplicas fallan juntas, el
  balanceador no puede hacer nada y el presupuesto se consume a ≈ 0.38 % por minuto: la HA del cómputo no
  protege la persistencia.
