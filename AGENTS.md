# AGENTS.md

This file provides guidance to AI assistants when working with code in this repository.

> A more detailed companion doc lives in [CLAUDE.md](CLAUDE.md) (build/run/test, CI job matrix, Docker pipeline, the AM27 migration cheat-sheet). Keep both in sync when the toolchain or architecture changes.

## Project overview

Single-JAR, in-memory LDAP server built on top of **ApacheDS 2.0.0.AM27**, intended for testing. The shaded jar (`target/ldap-server.jar`, ~16 MB) is fully self-contained; data lives only in memory and is wiped on restart. This repo is a fork of [intoolswetrust/ldap-server](https://github.com/intoolswetrust/ldap-server) that adds a Docker pipeline (`ghcr.io/andriykalashnykov/ldap-server/apacheds-ad`), Makefile, hardened GitHub Actions workflow, Renovate config, and `.mise.toml` toolchain pinning. The Java package `com.github.kwart.ldap` is intentionally kept aligned with upstream so future `git merge upstream/master` runs stay clean — don't rename it.

## Build & test

JDK 21 LTS + Maven 3.9.x, both pinned in [`.mise.toml`](.mise.toml). `make deps` installs mise on first run, then `mise install` provisions the toolchain.

- Bootstrap toolchain: `make deps` (one-time mise + Java/Maven install).
- Full local CI: `make ci` → `deps → check-java-alignment → check-maven-alignment → lint → test → package`. The two alignment guards fail fast when the Java major in `.mise.toml` drifts from the Dockerfile `FROM` lines, or the Maven minor drifts from the build-stage tag.
- Build the shaded jar only: `mvn -B clean package` → `target/ldap-server.jar` (uberjar via `maven-shade-plugin`).
- Run all tests: `make test` (or `mvn test`).
- Run a single test class: `mvn test -Dtest=LdapServerTest`.
- Run the server from sources: `mvn exec:java` (main class is `com.github.kwart.ldap.LdapServer`, via the `exec.mainClass` property).
- Run the built jar: `java -jar target/ldap-server.jar [options] [LDIFs...]` — see `--help` for the full CLI (includes `--admin-password`, `--ssl-*`, `--allow-anonymous`).
- CVE scan: `make cve-check` (OWASP dependency-check; ~2 GB NVD cold start, `NVD_API_KEY` strongly recommended).

`pom.xml` sets `maven.compiler.source=21` (matches the `eclipse-temurin:21-jre` runtime). AM27 ships bytecode 52 (Java 8) but the consumer can target whatever runtime it deploys on. Dependency bumps are handled by **Renovate** — there is **no Maven Central publishing** in this fork (the upstream `release` profile with GPG signing, `nexus-staging-maven-plugin`, and the `[1.8,1.9)` Java enforcer was removed; re-add from upstream only if Central publishing is ever wanted).

## Architecture

The runtime wiring is small enough to hold in your head, but the ApacheDS plumbing is opaque — and the startup sequence in `LdapServer` is **order-sensitive**. Read `LdapServer.java` end-to-end before changing any step.

- **`LdapServer`** (`src/main/java/.../LdapServer.java`) is both the CLI entry point and the orchestrator. `main` parses args via `ExtCommander`, then constructs `LdapServer(CLIArguments)`. The constructor: builds the `DirectoryService` via `InMemoryDirectoryServiceFactory`, sets anonymous access, imports LDIFs (default or user-supplied), optionally rewrites the `uid=admin,ou=system` password, unconditionally registers a `StartTlsHandler`, then starts ApacheDS' `LdapServer` with one or two `TcpTransport`s (plain `ldap://`, optional `ldaps://` when `--ssl-port` is set). Default partition root `dc=ldap,dc=example`; default admin bind `uid=admin,ou=system` / `secret` on port `10389`.

- **`CLIArguments`** is the single source of truth for flag definitions (JCommander 1.82 annotations). **Do NOT mark `@Parameter` fields `final`** — JCommander 1.82 rejects final fields at parse time. **`ExtCommander`** is a thin wrapper that registers a custom `IUsageFormatter` (`ExtUsageFormatter extends DefaultUsageFormatter`) to inject custom usage head/tail strings — JCommander 1.82 moved usage rendering into pluggable formatters, so the legacy `usage(StringBuilder, String)` override is gone.

- **`InMemoryDirectoryServiceFactory`** is the heart of the in-memory behavior. It uses `AvlPartitionFactory` (AVL = in-memory tree partitions, no disk persistence), loads schemas via the classpath, and installs **`InMemorySchemaPartition`** as the wrapped schema partition — this is what makes the server "no config files needed." AM27 removed EhCache from `DirectoryService` (`DefaultDnFactory` now uses an internal Caffeine cache), so there is no cache wiring here. The instance layout still points at `${java.io.tmpdir}/server-work-<name>` and that directory is deleted at startup — a leftover skeleton, not real persistence.

- **AM27 transactional writes** (the load-bearing migration change): `AbstractBTreePartition.add()` asserts a `PartitionWriteTxn` on the `OperationContext`. The schema-load loop in `InMemorySchemaPartition.doInit()` is wrapped in a `beginWriteTransaction()` / `commit()` / `abort()` block. `LdapServer.importLdif()` goes through `directoryService.getAdminSession().add()`, which handles the transaction internally — no change needed there.

- **LDIF import** in `LdapServer.importLdif` has a deliberate workaround: each `LdifReader` is built via the local `newLdifReader(path)` helper which overrides `parseEntry()` to reset change/entry state between entries. This works around an ApacheDS limitation where files mixing `changetype: modify` records and plain entries fail to parse. No args → loads bundled `src/main/resources/ldap-example.ldif`; a directory path → iterates `*.ldif` inside (case-insensitive); a file path → imports directly. Regression exercised by `src/test/resources/modify_new_entries.ldif` (`LdapServer2Test`).

- **Dynamic partition creation**: `checkPartition` inspects each LDIF entry's parent DN and, if it doesn't exist, registers a new `AvlPartition` rooted there. This lets users import LDIFs with arbitrary suffixes without pre-configuring partitions — but the suffix of the *first* entry per branch silently becomes a partition root.

- **StartTLS / keystore**: AM27's `CertificateUtil.loadKeyStore(null, null)` returns `null`, so when no SSL keystore is supplied the server generates a self-signed temp keystore (`CertificateUtil.createTempKeyStore(...)`) to avoid an NPE in `StartTlsHandler.setLdapServer()`. StartTLS is wired in unconditionally; the handler uses whatever keystore is configured.

- **Default data**: `src/main/resources/ldap-example.ldif` defines the `dc=ldap,dc=example` partition with `uid=jduke` (password `theduke`) and an `Admin` group. Tests rely on these exact values.

- **Auxiliary main classes**: `Authenticate` (simple bind) and `AuthenticateWithSearch` (admin-bind → search by uid → user-bind) are utility entry points in the same jar. They're not the manifest `Main-Class` but can be invoked via `java -cp ldap-server.jar com.github.kwart.ldap.AuthenticateWithSearch ...` (used by `make e2e`).

- **`CountLookupInterceptor`** exists but is intentionally not registered (commented out in the `LdapServer` constructor). It's a debug aid for counting lookups.

## Test conventions

JUnit 5 Jupiter (`org.junit:junit-bom:6.1.0`) — **8 tests, all passing on AM27**, under `src/test/java/com/github/kwart/ldap/`. Surefire's built-in JUnit 5 support handles the BOM; no `junit-platform-launcher` dependency needed.

| Class | Notes |
|---|---|
| `LdapServerTest` | 4 tests — `@ParameterizedTest` + `@MethodSource("data")` over `(ipv6, tls)`, basic bind + search |
| `LdapServer2Test` | 1 test — multi-entry LDIF with `changetype: modify` |
| `CustomPasswordTest` | 2 tests — `--admin-password` flag |
| `StartTlsTest` | 1 test — pins `TLSv1.3` + `TLS_AES_128_GCM_SHA256` on AM27's MINA TLS stack |

Each test starts a real LDAP server on `10389` (and a TLS port for TLS variants) and connects via JNDI — there are no mocks. Tests bind to all interfaces by default, so port conflicts manifest as failures, not skips.

## Docker

Multi-stage `Dockerfile`, **builds from source** (does not download a released JAR):

- **Builder**: `maven:3.9-eclipse-temurin-21` runs `mvn -B -DskipTests clean package` with a BuildKit cache mount on `~/.m2`.
- **Runtime**: `eclipse-temurin:21-jre-alpine`. Non-root user UID/GID 10001 (busybox `addgroup`/`adduser`, no home, `/sbin/nologin`), owns `/ldap`. No `apk add` in the runtime layer.
- **HEALTHCHECK**: `nc -z ${HEALTHCHECK_HOST} ${APP_INTERNAL_PORT}` (busybox netcat) — probes the LDAP TCP listener since ApacheDS exposes no HTTP endpoint. The flag *timings* are literal because Docker's parser does not expand ARG/ENV in those slots; the CMD's `${VAR}` honor `docker run -e ...` overrides.
- **CMD** (shell form): `java -jar /ldap/ldap-server.jar -b 0.0.0.0 -p ${APP_INTERNAL_PORT} /ldap/ldif/`. Mount a directory of `.ldif` files into `/ldap/ldif/` to seed entries.

Container workflows: `make image-build`, `make image-smoke-test`, `make image-run`, `make e2e`. The `e2e` target overrides the entrypoint with no LDIF arg so the server loads the bundled `ldap-example.ldif` defaults.
