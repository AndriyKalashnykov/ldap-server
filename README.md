[![CI](https://github.com/AndriyKalashnykov/ldap-server/actions/workflows/build-test-push.yml/badge.svg?branch=master)](https://github.com/AndriyKalashnykov/ldap-server/actions/workflows/build-test-push.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/ldap-server.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/ldap-server/)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-brightgreen.svg)](https://opensource.org/licenses/Apache-2.0)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/ldap-server)

# ldap-server — In-Memory LDAP Server (Apache Directory)

Single-JAR, in-memory LDAP server wrapping [Apache Directory Server](https://directory.apache.org/apacheds/) 2.0.0.AM27 — useful for integration testing, SSO simulators, and local development without standing up a real directory. The **runtime surface** exposes the LDAP protocol (default partition `dc=ldap,dc=example`) with optional LDAPS, configurable bind address / port, a swappable admin password (`uid=admin,ou=system`), and one-or-more `.ldif` files imported at boot via JCommander-driven CLI flags; the **delivery surface** ships as a self-contained Maven-shaded JAR, a multi-stage non-root Docker image on [GHCR](https://github.com/AndriyKalashnykov/ldap-server/pkgs/container/ldap-server%2Fapacheds-ad) (`ghcr.io/andriykalashnykov/ldap-server/apacheds-ad`) built from `@sha256:`-digest-pinned base images, toolchain-alignment guards keeping `.mise.toml` and `Dockerfile` in lockstep on Java 25 + Maven 3.9.16, a GitHub Actions pipeline gated by `dorny/paths-filter`, Trivy filesystem + image scans (CRITICAL/HIGH blocking on the image side), a TCP-probe smoke test, an LDAP-bind + search end-to-end gate before push, OWASP dependency-check (weekly cron + tag pushes + manual dispatch), and Renovate-managed dependencies.

> This is a fork of [intoolswetrust/ldap-server](https://github.com/intoolswetrust/ldap-server) — every Java change lives upstream; the fork adds the Docker pipeline, Makefile, hardened CI, and Renovate. Java package `com.github.kwart.ldap` is intentionally kept aligned with upstream so future syncs stay clean diffs.

## Tech Stack

| Component | Technology |
|-----------|------------|
| Language | Java 25 LTS (source + bytecode target 25; matches `eclipse-temurin:25-jre-alpine` runtime) |
| LDAP engine | Apache Directory Server 2.0.0.AM27 |
| Build | Maven 3.9.16 + `maven-shade-plugin` 3.6.2 (single runnable JAR) |
| CLI parser | JCommander 1.82 (`IUsageFormatter`-based) |
| Logging | SLF4J 2.0.18 + `slf4j-simple` (ServiceLoader binding) |
| Tests | JUnit 5 Jupiter 6.1.0 via `junit-bom` (8 tests, all passing — incl. StartTLS over TLSv1.3) |
| Container | Multi-stage Dockerfile: `maven:3.9-eclipse-temurin-25` → `eclipse-temurin:25-jre-alpine` (both `@sha256:`-digest-pinned), non-root UID 10001, TCP HEALTHCHECK |
| Version manager | [mise](https://mise.jdx.dev/) (`.mise.toml` pins Java 25 LTS + Maven 3.9.16) |
| Dep management | Renovate (Maven + GitHub Actions + Dockerfile + `.mise.toml`) |
| CI | GitHub Actions — paths-filter changes detector + `jdx/mise-action` + Trivy image scan + TCP smoke test |

## Quick Start

```bash
make deps          # install Java 25 + Maven via mise (one-time, asks you to activate shell)
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
| [JDK (Temurin)](https://adoptium.net/) | 25 LTS | Auto-installed by `mise install` |
| [Maven](https://maven.apache.org/) | 3.9.11 | Auto-installed by `mise install` |
| [Docker](https://www.docker.com/) | 20.10+ | Optional — required only for `make image-build` / `make image-smoke-test` |

`make deps` bootstraps mise (no root required, installs to `~/.local/bin`), then runs `mise install` which reads `.mise.toml` and provisions the pinned Java + Maven. Run `make deps-check` afterward to verify the toolchain is on PATH.

## CLI Reference

```text
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

```text
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

> StartTLS is also wired (the server registers a `StartTlsHandler`) and exercised by [`StartTlsTest`](src/test/java/com/github/kwart/ldap/StartTlsTest.java), which negotiates TLSv1.3 + `TLS_AES_128_GCM_SHA256` against AM27's MINA TLS stack. If no `--ssl-keystore-file` is supplied, the server generates a self-signed EC certificate on startup so StartTLS + LDAPS work out of the box for tests and dev.

## Docker

Pre-built images are published to [GHCR](https://ghcr.io) on every `v*` git tag:

```bash
docker pull ghcr.io/andriykalashnykov/ldap-server/apacheds-ad:latest
docker run -it --rm -p 10389:10389 ghcr.io/andriykalashnykov/ldap-server/apacheds-ad:latest
```

Mount your own `.ldif` files to seed custom entries:

```bash
docker run -it --rm \
  -v "$PWD/ldif:/ldap/ldif/" \
  -p 10389:10389 \
  ghcr.io/andriykalashnykov/ldap-server/apacheds-ad:latest
```

Or build locally:

```bash
make image-build         # multi-stage build from src/, tags as $(IMAGE_REF)
make image-smoke-test    # boot the image, wait for HEALTHCHECK = healthy
make image-run           # interactive run with $(LDIF_DIR) bind-mounted
```

The runtime image is `eclipse-temurin:25-jre-alpine`-based (~26 MB `/usr`, Trivy-clean at switch time, no Go binaries), runs as a non-root user (UID 10001), and ships a TCP HEALTHCHECK that probes `localhost:${APP_INTERNAL_PORT}` via busybox `nc -z` — no `curl` / `bash` / `wget` install needed.

## Available Make Targets

Run `make help` to see every target with its description.

### Build & Run

| Target | Description |
|--------|-------------|
| `make deps` | Install Java + Maven via mise (reads `.mise.toml`) |
| `make deps-check` | Show installed toolchain (java / mvn / docker / mise versions) |
| `make check-java-alignment` | Verify Java major matches across `.mise.toml` + `Dockerfile` |
| `make check-maven-alignment` | Verify Maven minor matches across `.mise.toml` + `Dockerfile` build stage |
| `make build` | Compile source (no tests) |
| `make test` | Run JUnit tests |
| `make package` | Build the shaded runnable JAR at `target/ldap-server.jar` |
| `make run-jar` | Run the packaged JAR with the bundled LDIF |
| `make lint` | Validate `pom.xml` + shell-script executable-bit guard |
| `make cve-check` | OWASP dependency-check (transitive deps; ~2 GB NVD download on first run) |
| `make clean` | Remove Maven build artifacts |

### Container

| Target | Description |
|--------|-------------|
| `make image-build` | Multi-stage build from `src/`, tagged as `$(IMAGE_REF)` |
| `make image-run` | Run the image with `$(LDIF_DIR)` bind-mounted into `/ldap/ldif/` |
| `make image-smoke-test` | Boot the image and wait for its HEALTHCHECK to report healthy |
| `make e2e` | End-to-end: boot image + verify LDAP bind + search via the protocol |
| `make docker-login` | Log into `$(DOCKER_REGISTRY)` using `DOCKER_LOGIN` + `$$DOCKER_PWD` (stdin-only) |
| `make image-push` | Push `$(IMAGE_REF)` to `$(DOCKER_REGISTRY)` |

### CI

| Target | Description |
|--------|-------------|
| `make ci` | Full local CI pipeline: `deps → toolchain-alignment → lint → test → package` |
| `make ci-run` | Run the GitHub Actions workflow locally via [act](https://github.com/nektos/act) — exercises `changes` + `build` + `ci-pass` only; the tag-only `docker` + `cve-check` + `release` paths need a real GitHub event context |

## Configuration

Every operator-tunable value is sourced from env vars with `?=` fallbacks in the Makefile. Copy `.env.example` to `.env` and override per host — `make` picks up overrides automatically.

| Variable | Default | Used by |
|----------|---------|---------|
| `DOCKER_REGISTRY` | `ghcr.io` | `docker-login`, `image-push` |
| `DOCKER_LOGIN` | _(unset)_ | tags `${DOCKER_LOGIN}/${IMAGE_NAME}:${IMAGE_TAG}` — set to `<owner>/ldap-server` for the GHCR repo-namespace path |
| `DOCKER_PWD` | _(unset; gitignored `.env` only)_ | piped to `docker login --password-stdin` — NEVER on argv. For GHCR locally, use a GitHub PAT with `write:packages` scope |
| `IMAGE_NAME` | `apacheds-ad` | image-name segment |
| `IMAGE_TAG` | `latest` | image-tag segment |
| `JAR_PATH` | `target/ldap-server.jar` | `run-jar` |
| `LDIF_DIR` | `target/classes/` | bind-mounted into `/ldap/ldif/` for `image-run` |
| `LDAP_PORT` | `10389` | host-side port mapping |
| `LDAPS_PORT` | _(unset)_ | when set, `run-jar` enables `-sp $LDAPS_PORT` |
| `BIND_ADDRESS` | `0.0.0.0` | `run-jar`'s `-b` flag |
| `APP_INTERNAL_PORT` | `10389` | container-internal LDAP port (baked into image via `--build-arg`) |

## CI/CD

GitHub Actions runs on every push to `master`, every `v*` git tag, every pull request, plus a weekly `cron: '0 6 * * 1'` for `cve-check` and `workflow_dispatch` for manual reruns. The workflow ([`build-test-push.yml`](.github/workflows/build-test-push.yml)) is structured as separate jobs with `needs:` dependencies for fail-fast + parallelism; a single `ci-pass` aggregator is the only check the branch-protection ruleset needs to gate.

| Job | Triggers | Purpose |
|-----|----------|---------|
| `changes` | every event | [`dorny/paths-filter`](https://github.com/dorny/paths-filter) — doc-only PRs skip every job below |
| `build` | code-changing events + every tag | Provisions Java 25 + Maven 3.9.16 via `jdx/mise-action`, restores `~/.m2` from `actions/cache`, runs `make ci` (alignment guards + lint + test + package), Trivy filesystem scan (informational), uploads `target/ldap-server.jar` as an artifact |
| `cve-check` | tag pushes + weekly cron + dispatch | OWASP dependency-check via `mvn org.owasp:dependency-check-maven:check` (NVD + Sonatype OSS Index analyzers); NVD DB cached at `~/.m2/repository/org/owasp/dependency-check-data`, keyed on the ISO week so version bumps don't force a cold fetch. **`NVD_API_KEY` strongly recommended** (without it the NVD fetch fails on cold cache); **`OSS_INDEX_USER`/`OSS_INDEX_TOKEN`** enable OSS Index (else it's silently disabled) |
| `release` | push to master OR `v*` tag | Downloads the JAR, recreates the `latest` GitHub Release via `softprops/action-gh-release` |
| `docker` | `v*` tag only | Build image for scan → Trivy CRITICAL/HIGH image scan → `make image-smoke-test` → `make e2e` (LDAP bind + search) → log in to GHCR (`${{ github.actor }}` + auto-provisioned `GITHUB_TOKEN`; job has `packages: write`) → push single-arch `linux/amd64` image to `ghcr.io/<owner>/ldap-server/apacheds-ad` with `flavor: latest=true`. Every gate blocks the push |
| `ci-pass` | always | `if: always() && contains(needs.*.result, 'failure')` — single aggregator for branch protection |

Every action is SHA-pinned (verified via `gh api …/git/refs/tags`). A separate [`cleanup-runs.yml`](.github/workflows/cleanup-runs.yml) prunes old workflow runs and caches from deleted branches weekly via the native `gh` CLI.

### Required secrets

Configure under **Settings → Secrets and variables → Actions**.

| Name | Type | Used by | How to obtain |
|------|------|---------|---------------|
| `NVD_API_KEY` | Secret (**strongly recommended**) | `cve-check` job — without it, the dep-check 12.2.2 plugin's parallel NVD fetcher hits an upstream NPE on cold cache and the job fails | Free API key from [NIST NVD](https://nvd.nist.gov/developers/request-an-api-key); routed via `~/.m2/settings.xml`, never via argv |
| `OSS_INDEX_USER` + `OSS_INDEX_TOKEN` | Secret (**recommended**) | `cve-check` job — enables the Sonatype OSS Index analyzer (second vuln source); without them it's silently disabled (warning only) and coverage drops to NVD-only | Free account at [OSS Index](https://ossindex.sonatype.org/) — user is the account email, token its API token; routed via `~/.m2/settings.xml` (`-DossIndexServerId=ossindex`), never via argv |
| `GITHUB_TOKEN` | _(auto-provisioned)_ | `docker` (GHCR publish, `packages: write`), `release` (GitHub Release, `contents: write`), `cleanup-runs` | GitHub injects automatically |

## License

[Apache License 2.0](LICENSE). Java code derived from [intoolswetrust/ldap-server](https://github.com/intoolswetrust/ldap-server) (Josef Cacek, same license).
