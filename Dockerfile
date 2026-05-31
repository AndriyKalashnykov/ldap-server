# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# =============================================================================
# Build stage — compile shaded JAR from source
# =============================================================================
# The official Maven + Temurin 21 image — mvn + JDK in one layer.
# Renovate-tracked via the `dockerfile` manager; digest pin keeps the
# build reproducible across registry-tag retags.
FROM maven:3.9-eclipse-temurin-21@sha256:1bb51c5ed28b95aef2bc7b46bff6940da43747cdaf838ce4afc2081ce9403750 AS build

WORKDIR /workspace

# Layer-cache deps before sources so a no-source change doesn't redownload.
COPY pom.xml ./
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -e -ntp -DskipTests dependency:go-offline

COPY src ./src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -e -ntp -DskipTests clean package

# Sanity: the shaded JAR is what `make package` produces locally.
RUN test -s /workspace/target/ldap-server.jar


# =============================================================================
# Runtime stage — slim JRE, non-root, env-driven tunables
# =============================================================================
FROM eclipse-temurin:21-jre-alpine@sha256:704db3c40204a44f471191446ddd9cda5d60dab40f0e15c6507b815ed897238b

# === Operator tunables (slot 2 — ARG defaults; see configuration.md) ===
ARG APP_INTERNAL_PORT=10389
ARG HEALTHCHECK_HOST=localhost
ARG APP_UID=10001
ARG APP_GID=10001

# Promote tunable ARGs to ENV so:
#   - HEALTHCHECK CMD's shell-time expansion sees HEALTHCHECK_HOST + APP_INTERNAL_PORT
#   - The entrypoint's `-p ${APP_INTERNAL_PORT}` honors `docker run -e ...` overrides
# HEALTHCHECK flag timings (interval/timeout/...) are LITERAL — Docker's parser
# does not expand ARG/ENV in those slots — so they're hardcoded below.
ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT} \
    HEALTHCHECK_HOST=${HEALTHCHECK_HOST}

LABEL maintainer="AndriyKalashnykov@gmail.com" \
      org.opencontainers.image.source="https://github.com/AndriyKalashnykov/ldap-server" \
      org.opencontainers.image.description="In-memory LDAP server based on ApacheDS"

# Non-root user. Alpine ships busybox `addgroup`/`adduser`; -S = system,
# -D = no password, -H = no home. /sbin/nologin denies interactive shells.
RUN addgroup -S -g ${APP_GID} ldap \
 && adduser  -S -u ${APP_UID} -G ldap -H -D -s /sbin/nologin ldap

RUN mkdir -p /ldap/ldif \
 && chown -R ${APP_UID}:${APP_GID} /ldap

WORKDIR /ldap

COPY --from=build --chown=${APP_UID}:${APP_GID} \
     /workspace/target/ldap-server.jar /ldap/ldap-server.jar

USER ${APP_UID}

EXPOSE ${APP_INTERNAL_PORT}

# ApacheDS exposes only the LDAP protocol — no HTTP /healthz. Probe the
# TCP listener via busybox `nc -z` (bundled with alpine; no extra
# package install needed). HEALTHCHECK flag values are literal — Docker's
# parser does NOT expand ARG/ENV in --interval/etc., so timings are
# hardcoded here. The CMD's `${VAR}` expand at container start, so
# HEALTHCHECK_HOST / APP_INTERNAL_PORT honor `docker run -e`.
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD nc -z "${HEALTHCHECK_HOST}" "${APP_INTERNAL_PORT}" || exit 1

# Mount any directory with `.ldif` files to /ldap/ldif/ to seed the server,
# e.g. `docker run -v ./ldif:/ldap/ldif/ ...`. An empty mount leaves the
# server running with no entries (it does NOT fall back to bundled defaults
# when an empty `--ldifs` arg is supplied — that's a regression from no-arg
# invocation, but matches the legacy Dockerfile's behavior).
CMD java -jar /ldap/ldap-server.jar -b 0.0.0.0 -p ${APP_INTERNAL_PORT} /ldap/ldif/
