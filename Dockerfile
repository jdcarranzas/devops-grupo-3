# syntax=docker/dockerfile:1
# =============================================================================
# Imagen optimizada de Keycloak (patrón "optimized image" de la doc. oficial)
# Etapa 1 (builder): pre-compila Keycloak con las opciones de build fijas
#                    (BD PostgreSQL, health y métricas) -> arranque más rápido.
# Etapa 2 (runtime): copia solo el resultado compilado sobre una imagen limpia.
# =============================================================================
ARG KC_VERSION=26.7.3

# ---------- Etapa 1: build ----------
FROM quay.io/keycloak/keycloak:${KC_VERSION} AS builder

# Opciones de build (quedan "horneadas" en la imagen)
ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true

WORKDIR /opt/keycloak
RUN /opt/keycloak/bin/kc.sh build

# ---------- Etapa 2: runtime ----------
FROM quay.io/keycloak/keycloak:${KC_VERSION}

LABEL org.opencontainers.image.title="keycloak-devops-grupo-3" \
      org.opencontainers.image.description="Keycloak optimizado con PostgreSQL - Proyecto Fundamentos de DevOps y SRE" \
      org.opencontainers.image.source="https://github.com/jdcarranzas/devops-grupo-3" \
      org.opencontainers.image.licenses="Apache-2.0"

COPY --from=builder /opt/keycloak/ /opt/keycloak/

ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true

# Usuario no root (UID 1000 = usuario "keycloak" de la imagen oficial)
USER 1000

# 8080: tráfico HTTP de la aplicación | 9000: puerto de gestión (health y métricas)
EXPOSE 8080 9000

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized"]
