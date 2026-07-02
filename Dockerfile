# syntax=docker/dockerfile:1.25@sha256:0adf442eae370b6087e08edc7c50b552d80ddf261576f4ebd6421006b2461f12

# =============================================================================
# Build stage — compile shaded JAR from source
# =============================================================================
# The official Maven + Temurin 25 image — mvn + JDK in one layer.
# Renovate-tracked via the `dockerfile` manager; digest pin keeps the
# build reproducible across registry-tag retags.
FROM maven:3.9-eclipse-temurin-25@sha256:7e461cec477077c1d9e50b13df8aef9018764410f4c4cd7c34803f10c4c99e4c AS build

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
FROM eclipse-temurin:25.0.3_9-jre-alpine@sha256:28db6fdf60e38945e43d840c0333aeaec66c15943070104f7586fd3c9d1665b0

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

# Pull baked-in Alpine OS packages (libcrypto3/libssl3, busybox, zlib, ...) up
# to the latest in the pinned branch at BUILD time, so a CVE Alpine has already
# fixed clears the blocking Trivy image gate immediately instead of waiting on
# the upstream eclipse-temurin base rebuild. Run as root, before USER.
# `--no-cache` leaves no apk index behind. This is a real fix (the vulnerable
# package is removed), not a `.trivyignore` waiver. The base FROM stays
# digest-pinned for reproducibility of everything else.
RUN apk --no-cache upgrade

# Non-root user. Alpine ships busybox `addgroup`/`adduser`; -S = system,
# -D = no password, -H = no home. /sbin/nologin denies interactive shells.
RUN addgroup -S -g ${APP_GID} ldap \
 && adduser  -S -u ${APP_UID} -G ldap -H -D -s /sbin/nologin ldap

RUN mkdir -p /ldap/ldif \
 && chown -R ${APP_UID}:${APP_GID} /ldap

WORKDIR /ldap

COPY --from=build --chown=${APP_UID}:${APP_GID} \
     /workspace/target/ldap-server.jar /ldap/ldap-server.jar

# Pre-seed the bundled example tree so a bare `docker run` (no mount) starts
# WITH data (dc=ldap,dc=example: uid=jduke/theduke + an Admin group). A
# `-v <dir>:/ldap/ldif/` bind mount shadows this directory, so custom seeds
# still fully replace it.
COPY --from=build --chown=${APP_UID}:${APP_GID} \
     /workspace/src/main/resources/ldap-example.ldif /ldap/ldif/ldap-example.ldif

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

# /ldap/ldif/ ships pre-seeded with ldap-example.ldif (above), so a bare
# `docker run` starts with the example tree. Bind-mount your own directory
# (`docker run -v ./ldif:/ldap/ldif/ ...`) to replace it with custom `.ldif`
# files. A mount of an EMPTY directory shadows the baked-in seed and leaves the
# server running with no entries (it does NOT fall back to bundled defaults on
# an empty directory arg — matches legacy behavior).
CMD java -jar /ldap/ldap-server.jar -b 0.0.0.0 -p ${APP_INTERNAL_PORT} /ldap/ldif/
