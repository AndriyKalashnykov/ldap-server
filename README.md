[![CI](https://github.com/AndriyKalashnykov/ldap-server/actions/workflows/build-test-push.yml/badge.svg?branch=master)](https://github.com/AndriyKalashnykov/ldap-server/actions/workflows/build-test-push.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/ldap-server.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/ldap-server/)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-brightgreen.svg)](https://opensource.org/licenses/Apache-2.0)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/ldap-server)

# ldap-server — In-Memory LDAP Server (Apache Directory)

Single-JAR, in-memory LDAP server wrapping [Apache Directory Server](https://directory.apache.org/apacheds/) 2.0.0-M24 — useful for integration testing, SSO simulators, and local development without standing up a real directory. The **runtime surface** exposes the LDAP protocol (default partition `dc=ldap,dc=example`) with optional LDAPS, configurable bind address / port, a swappable admin password (`uid=admin,ou=system`), and one-or-more `.ldif` files imported at boot via JCommander-driven CLI flags; the **delivery surface** ships as a self-contained Maven-shaded JAR, a multi-stage non-root Docker image on Docker Hub ([`andriykalashnykov/apacheds-ad`](https://hub.docker.com/r/andriykalashnykov/apacheds-ad)), an [`mise`](https://mise.jdx.dev/)-pinned Java 21 + Maven 3.9.11 toolchain, a GitHub Actions pipeline gated by `dorny/paths-filter` and `aquasecurity/trivy-action` (CRITICAL/HIGH blocking image scan + TCP-probe smoke test before push), and Renovate-managed dependencies.

> This is a fork of [intoolswetrust/ldap-server](https://github.com/intoolswetrust/ldap-server) — every Java change lives upstream; the fork adds the Docker pipeline, Makefile, hardened CI, and Renovate. Java package `com.github.kwart.ldap` is intentionally kept aligned with upstream so future syncs stay clean diffs.

## Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Java (compiles on JDK 21; bytecode target 1.8 for ApacheDS compat) |
| LDAP engine | Apache Directory Server 2.0.0-M24 |
| Build | Maven 3.9.11 + `maven-shade-plugin` 3.3.0 (single runnable JAR) |
| CLI parser | JCommander 1.32 |
| Logging | SLF4J 1.7.36 + `slf4j-simple` |
| Tests | JUnit 4.13.2 (8 tests; 1 `@Ignore`d) |
| Container | Multi-stage Dockerfile: `maven:3.9-eclipse-temurin-21` → `eclipse-temurin:21-jre`, non-root UID 10001, TCP HEALTHCHECK |
| Version manager | [mise](https://mise.jdx.dev/) (`.mise.toml` pins Java 21 LTS + Maven 3.9.11) |
| Dep management | Renovate (Maven + GitHub Actions + Dockerfile + `.mise.toml`) |
| CI | GitHub Actions — paths-filter changes detector + `jdx/mise-action` + Trivy image scan + TCP smoke test |

## Quick Start

```bash
make deps          # install Java 21 + Maven via mise (one-time, asks you to activate shell)
make ci            # lint + test + package -> target/ldap-server.jar
make run-jar       # start the server on 0.0.0.0:10389 with bundled LDIF
# Bind URL:  ldap://127.0.0.1:10389/dc=ldap,dc=example
# Admin:     uid=admin,ou=system  /  secret
# Test user: uid=jduke,ou=Users,dc=ldap,dc=example  /  theduke
```

Override the bind address / port / LDIF directory via `.env` (see [`.env.example`](.env.example)):

```bash
LDAP_PORT=10399 LDAPS_PORT=10636 BIND_ADDRESS=127.0.0.1 make run-jar
```

For a quick poke from another terminal:

```bash
ldapsearch -x -H ldap://127.0.0.1:10389 -D 'uid=admin,ou=system' -w secret \
  -b dc=ldap,dc=example '(objectClass=*)'
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [GNU Make](https://www.gnu.org/software/make/) | 3.81+ | Build orchestration |
| [Git](https://git-scm.com/) | any | Source control |
| [mise](https://mise.jdx.dev/) | latest | Pins Java + Maven from [`.mise.toml`](.mise.toml); `make deps` installs it on first run |
| [JDK (Temurin)](https://adoptium.net/) | 21 LTS | Auto-installed by `mise install` |
| [Maven](https://maven.apache.org/) | 3.9.11 | Auto-installed by `mise install` |
| [Docker](https://www.docker.com/) | 20.10+ | Optional — required only for `make docker-build` / `make docker-smoke-test` |

`make deps` bootstraps mise (no root required, installs to `~/.local/bin`), then runs `mise install` which reads `.mise.toml` and provisions the pinned Java + Maven. Run `make deps-check` afterward to verify the toolchain is on PATH.

## CLI Reference

```
$ java -jar target/ldap-server.jar --help

The ldap-server is a simple LDAP server implementation based on ApacheDS. It
creates one user partition with root 'dc=ldap,dc=example'.

Usage: java -jar ldap-server.jar [options] [LDIFs to import]

  Options:
    --admin-password, -ap        change password for 'uid=admin,ou=system' (default 'secret')
    --allow-anonymous, -a        allow anonymous bind                                (default false)
    --bind, -b                   bind address                                        (default 0.0.0.0)
    --port, -p                   LDAP port                                           (default 10389)
    --ssl-port, -sp              enable LDAPS on this port (optional)
    --ssl-keystore-file, -skf    JKS keystore path with the LDAPS private key
    --ssl-keystore-password, -skp keystore password
    --ssl-enabled-protocol, -sep enable a TLS protocol (repeatable; default TLSv1, TLSv1.1, TLSv1.2)
    --ssl-enabled-ciphersuite, -scs  enable a cipher suite (repeatable)
    --ssl-need-client-auth, -snc enable SSL needClientAuth                           (default false)
    --ssl-want-client-auth, -swc enable SSL wantClientAuth                           (default false)
    --help, -h                   show this help

  LDIFs to import:
    - empty                     -> bundled `ldap-example.ldif` is loaded
    - one or more `.ldif` files -> imported in order
    - a directory               -> every `*.ldif` inside (case-insensitive) imported
```

### Default seed data ([`src/main/resources/ldap-example.ldif`](src/main/resources/ldap-example.ldif))

```
dc=ldap,dc=example                                  (root domain)
├── ou=Users,dc=ldap,dc=example
│   └── uid=jduke,ou=Users,dc=ldap,dc=example       (Java Duke / theduke)
└── ou=Roles,dc=ldap,dc=example
    └── cn=Admin,ou=Roles,dc=ldap,dc=example        (member: jduke)
```

### LDAPS / StartTLS

Generate (or import) a JKS keystore with the server private key, then pass `--ssl-keystore-file` + `--ssl-keystore-password` alongside `--ssl-port`:

```bash
keytool -validity 365 -genkey -alias myserver -keyalg RSA \
  -keystore /tmp/ldaps.keystore -storepass 123456 -keypass 123456 \
  -dname cn=myserver.example.com

java -Djavax.net.debug=ssl \
  -jar target/ldap-server.jar \
  -sp 10636 -skf /tmp/ldaps.keystore -skp 123456
```

> StartTLS is also wired (the server registers a `StartTlsHandler`), but [`StartTlsTest`](src/test/java/com/github/kwart/ldap/StartTlsTest.java) is currently `@Ignore`d — ApacheDS 2.0.0-M24's MINA TLS stack predates TLSv1.3, and the test pins `TLSv1.3` + `TLS_AES_128_GCM_SHA256`. The test reactivates the moment ApacheDS is bumped to a version with TLSv1.3 support.

## Docker

Pre-built images are published to Docker Hub on every `v*` git tag:

```bash
docker pull andriykalashnykov/apacheds-ad:latest
docker run -it --rm -p 10389:10389 andriykalashnykov/apacheds-ad:latest
```

Mount your own `.ldif` files to seed custom entries:

```bash
docker run -it --rm \
  -v "$PWD/ldif:/ldap/ldif/" \
  -p 10389:10389 \
  andriykalashnykov/apacheds-ad:latest
```

Or build locally:

```bash
make docker-build         # multi-stage build from src/, tags as $(IMAGE_REF)
make docker-smoke-test    # boot the image, wait for HEALTHCHECK = healthy
make docker-run           # interactive run with $(LDIF_DIR) bind-mounted
```

The runtime image is `eclipse-temurin:21-jre`-based, runs as a non-root user (UID 10001), and ships a TCP HEALTHCHECK that probes `localhost:${APP_INTERNAL_PORT}` via bash `/dev/tcp` — no `curl` / `nc` / `wget` in the image.

## Available Make Targets

Run `make help` to see every target with its description.

### Build & Run

| Target | Description |
|--------|-------------|
| `make deps` | Install Java + Maven via mise (reads `.mise.toml`) |
| `make deps-check` | Show installed toolchain (java / mvn / docker / mise versions) |
| `make build` | Compile source (no tests) |
| `make test` | Run JUnit tests |
| `make package` | Build the shaded runnable JAR at `target/ldap-server.jar` |
| `make run-jar` | Run the packaged JAR with the bundled LDIF |
| `make lint` | Validate `pom.xml` |
| `make clean` | Remove Maven build artifacts |

### Docker

| Target | Description |
|--------|-------------|
| `make docker-build` | Multi-stage build from `src/`, tagged as `$(IMAGE_REF)` |
| `make docker-run` | Run the image with `$(LDIF_DIR)` bind-mounted into `/ldap/ldif/` |
| `make docker-smoke-test` | Boot the image and wait for its HEALTHCHECK to report healthy |
| `make docker-login` | Log into `$(DOCKER_REGISTRY)` using `DOCKER_LOGIN` + `$$DOCKER_PWD` (stdin-only) |
| `make docker-push` | Push `$(IMAGE_REF)` to `$(DOCKER_REGISTRY)` |

### CI

| Target | Description |
|--------|-------------|
| `make ci` | Full local CI pipeline: `deps → lint → test → package` |
| `make ci-run` | Run the GitHub Actions workflow locally via [act](https://github.com/nektos/act) |

## Configuration

Every operator-tunable value is sourced from env vars with `?=` fallbacks in the Makefile. Copy `.env.example` to `.env` and override per host — `make` picks up overrides automatically.

| Variable | Default | Used by |
|----------|---------|---------|
| `DOCKER_REGISTRY` | `registry-1.docker.io` | `docker-login`, `docker-push` |
| `DOCKER_LOGIN` | _(unset)_ | tags `${DOCKER_LOGIN}/${IMAGE_NAME}:${IMAGE_TAG}` |
| `DOCKER_PWD` | _(unset; gitignored `.env` only)_ | piped to `docker login --password-stdin` — NEVER on argv |
| `IMAGE_NAME` | `apacheds-ad` | image-name segment |
| `IMAGE_TAG` | `latest` | image-tag segment |
| `JAR_PATH` | `target/ldap-server.jar` | `run-jar` |
| `LDIF_DIR` | `target/classes/` | bind-mounted into `/ldap/ldif/` for `docker-run` |
| `LDAP_PORT` | `10389` | host-side port mapping |
| `LDAPS_PORT` | _(unset)_ | when set, `run-jar` enables `-sp $LDAPS_PORT` |
| `BIND_ADDRESS` | `0.0.0.0` | `run-jar`'s `-b` flag |
| `APP_INTERNAL_PORT` | `10389` | container-internal LDAP port (baked into image via `--build-arg`) |

## CI/CD

GitHub Actions runs on every push to `master`, every `v*` git tag, and every pull request. The workflow ([`build-test-push.yml`](.github/workflows/build-test-push.yml)) is structured as separate jobs with `needs:` dependencies for fail-fast + parallelism; a single `ci-pass` aggregator is the only check the branch-protection ruleset needs to gate.

| Job | Triggers | Purpose |
|-----|----------|---------|
| `changes` | every event | [`dorny/paths-filter`](https://github.com/dorny/paths-filter) — doc-only PRs skip every job below |
| `build` | code-changing events + every tag | Provisions Java 21 + Maven 3.9.11 via `jdx/mise-action`, restores `~/.m2` from `actions/cache`, runs `make ci` (lint + test + package), uploads `target/ldap-server.jar` as an artifact |
| `release` | push to master OR `v*` tag | Downloads the JAR, recreates the `latest` GitHub Release via `softprops/action-gh-release` (replaces the deprecated `actions/create-release` + `actions/upload-release-asset` combo) |
| `docker` | `v*` tag only | Build image for scan → Trivy CRITICAL/HIGH gate → `make docker-smoke-test` → log in to Docker Hub → push single-arch `linux/amd64` image. Every gate blocks the push |
| `ci-pass` | always | `if: always() && contains(needs.*.result, 'failure')` — single aggregator for branch protection |

Every action is SHA-pinned (verified via `gh api …/git/refs/tags`). A separate [`cleanup-runs.yml`](.github/workflows/cleanup-runs.yml) prunes old workflow runs and caches from deleted branches weekly via the native `gh` CLI.

### Required secrets

Configure under **Settings → Secrets and variables → Actions**.

| Name | Type | Used by | How to obtain |
|------|------|---------|---------------|
| `DOCKERHUB_USERNAME` | Secret | `docker` job — image push | Your Docker Hub account name |
| `DOCKERHUB_TOKEN` | Secret | `docker` job — image push | Docker Hub → Account Settings → Personal access tokens |
| `GITHUB_TOKEN` | _(auto-provisioned)_ | `release` + `cleanup-runs` jobs | GitHub injects automatically |

## License

[Apache License 2.0](LICENSE). Java code derived from [intoolswetrust/ldap-server](https://github.com/intoolswetrust/ldap-server) (Josef Cacek, same license).
