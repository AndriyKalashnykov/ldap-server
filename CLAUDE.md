# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-module Maven project that wraps **Apache Directory Server 2.0.0-M24** as a self-contained, in-memory LDAP server. Maven-shaded into one runnable fat JAR (`target/ldap-server.jar`). No persistence — all directory data lives in memory and is lost on shutdown. CLI parsed via JCommander 1.82; default partition root is `dc=ldap,dc=example`; default admin bind is `uid=admin,ou=system` / `secret` on port 10389. Logging routed through SLF4J 2.0.x + `slf4j-simple` (ServiceLoader binding).

This repo is a **fork of [intoolswetrust/ldap-server](https://github.com/intoolswetrust/ldap-server)**. Java code is the upstream's; the fork adds the Docker pipeline (`andriykalashnykov/apacheds-ad` on Docker Hub), Makefile, hardened GitHub Actions workflow, Renovate config, and `.mise.toml` toolchain pinning. The Maven groupId was scrubbed to `io.github.andriykalashnykov` and `<scm>` / `<developers>` point at this fork; everything else in `pom.xml` is upstream's.

**Java package `com.github.kwart.ldap` is intentionally kept aligned with upstream** (not renamed to the fork's identity) so future `git merge upstream/master` runs stay clean diffs. Don't propose renaming it.

## Build, run, test

JDK 21 LTS + Maven 3.9.16, both pinned in [`.mise.toml`](.mise.toml). `make deps` installs mise on first run, then `mise install` provisions the toolchain.

```bash
make deps                                            # one-time mise + Java/Maven bootstrap
make ci                                              # deps + alignment guards + lint + test + package
make e2e                                             # boot image, override CMD, LDAP bind + search
make cve-check                                       # OWASP dependency-check (~2 GB NVD cold start)
java -jar ./target/ldap-server.jar ./target/classes/ # run with bundled LDIFs as seed data
java -jar ./target/ldap-server.jar --help            # full CLI flag list (includes --admin-password, --ssl-*)
```

`make ci` chains `deps → check-java-alignment → check-maven-alignment → lint → test → package`. The two alignment guards fail fast when the Java major in `.mise.toml` drifts from the Dockerfile `FROM` lines, or when the Maven minor drifts from the build-stage tag — silent toolchain desync is otherwise a recurring foot-gun on Renovate split-PR days. Both guards are mutation-tested (proven to go RED on intentional desync).

`pom.xml` keeps `maven.compiler.source=1.8` AND has a `release` profile that enforces `[1.8,1.9)` via the enforcer plugin. **Don't "fix" this** — ApacheDS 2.0.0-M24 ships bytecode targeting 1.8 and the project intentionally preserves that compatibility floor while the build itself runs on JDK 21+. The JDK used to compile can be anything ≥ 1.8.

### Tests

JUnit 5 Jupiter suite (`org.junit:junit-bom:6.1.0`) under `src/test/java/com/github/kwart/ldap/` — **8 tests, 7 pass, 1 `@Disabled`**:

| Class | Notes |
|---|---|
| `LdapServerTest` | 4 tests — `@ParameterizedTest` + `@MethodSource("data")` over `(ipv6, tls)`, basic bind + search |
| `LdapServer2Test` | 1 test — multi-entry LDIF with `changetype: modify` |
| `CustomPasswordTest` | 2 tests — `--admin-password` flag |
| `StartTlsTest` | `@Disabled` — pins `TLSv1.3` + `TLS_AES_128_GCM_SHA256` against ApacheDS 2.0.0-M24's MINA TLS stack which predates TLSv1.3. Reactivates only when ApacheDS is bumped past M24 (a real Major migration — see Upgrade Backlog); un-`@Disable` + the StartTls reactivation comment in the test source drop in the same commit as the ApacheDS bump. |

`make test` runs everything (the `@Disabled` test is skipped, not failed). Surefire's built-in JUnit 5 support handles the BOM; no `junit-platform-launcher` dependency needed.

## Architecture

Entry point is `com.github.kwart.ldap.LdapServer#main`, declared as the shaded JAR's `Main-Class` via `maven-shade-plugin`. The startup sequence is **order-sensitive** — read `LdapServer.java` end-to-end before changing any step:

1. **`InMemoryDirectoryServiceFactory.init("ds")`** — builds an ApacheDS `DirectoryService` whose schema partition is `InMemorySchemaPartition`, loading schema entries from the classpath rather than disk. This is the load-bearing piece that makes the server "no config files needed."
2. **`directoryService.setAllowAnonymousAccess(cliArguments.isAllowAnonymous())`** then **`importLdif(cliArguments.getLdifFiles())`**.
3. **`importLdif(List<String> ldifFiles)`** — combines two upstream features merged in this fork:
   - **No args** → loads bundled `src/main/resources/ldap-example.ldif`.
   - **One or more paths** → for each path, if it's a directory, iterate `*.ldif` files inside (case-insensitive `.ldif` filter, fork-added); if it's a file, import it directly.
   - Each `LdifReader` is constructed via the local `newLdifReader(path)` helper which overrides `parseEntry()` — upstream's workaround for ApacheDS's inability to parse LDIF files that contain BOTH `changetype: add`/no-changetype entries AND `changetype: modify` entries.
   - `checkPartition` creates a new `AvlPartition` on demand if the entry's parent DN doesn't already exist; this is how arbitrary LDIFs work without pre-declaring partitions.
4. **Optional `--admin-password`** → modifies `userPassword` on `uid=admin,ou=system` before the listener comes up.
5. **`ldapServer.addExtendedOperationHandler(new StartTlsHandler())`** is unconditional — StartTLS is wired into the server even when no SSL keystore is supplied. The `StartTlsHandler` simply uses the configured keystore when a client requests StartTLS.
6. Bind one `TcpTransport` for `ldap://`, optionally a second SSL-enabled transport for `ldaps://` when `--ssl-port` is set, then `ldapServer.start()`.

**`CLIArguments`** is the single source of truth for flag definitions (JCommander annotations). **Do NOT mark `@Parameter` fields `final`** — JCommander 1.82 rejects `final` fields at parse time with `Cannot use final field ... as a parameter` (compiler-inlined-constant safety check). `ExtCommander` is a thin wrapper that registers a custom `IUsageFormatter` (`ExtUsageFormatter extends DefaultUsageFormatter`) to inject custom usage head/tail strings — JCommander 1.82 moved usage rendering to `IUsageFormatter`, so the legacy `usage(StringBuilder, String)` override is gone. Don't conflate `ExtCommander` with the flag definitions in `CLIArguments`.

## Docker image

Multi-stage Dockerfile, builds from source — does NOT download a released JAR.

- **Builder**: `maven:3.9-eclipse-temurin-21` runs `mvn -B -DskipTests clean package` with a BuildKit cache mount on `~/.m2`.
- **Runtime**: `eclipse-temurin:21-jre`. Non-root user UID/GID 10001 (created via `useradd`, no home, `/usr/sbin/nologin` shell). Owns `/ldap`.
- **HEALTHCHECK**: `bash -c 'exec 3<>/dev/tcp/${HEALTHCHECK_HOST}/${APP_INTERNAL_PORT}'`. Uses bash's `/dev/tcp` because (a) ApacheDS exposes only the LDAP protocol — no HTTP `/healthz` — and (b) `eclipse-temurin:21-jre` ships bash but not `curl`/`nc`/`wget`. **No apt install in the runtime layer.**
- **`HEALTHCHECK` flag timings are LITERAL** (`--interval=30s --timeout=3s --start-period=20s --retries=3`) because Docker's parser does NOT expand ARG/ENV in those slots. The CMD's `${VAR}` inside the nested `bash -c '...'` ARE expanded at container start, so `HEALTHCHECK_HOST` and `APP_INTERNAL_PORT` honor `docker run -e ...` overrides.
- **CMD**: shell form so `${APP_INTERNAL_PORT}` is honored — `java -jar /ldap/ldap-server.jar -b 0.0.0.0 -p ${APP_INTERNAL_PORT} /ldap/ldif/`.

### Container workflows

```bash
make image-build         # multi-stage build from src/ (uses DOCKER_LOGIN/IMAGE_NAME/IMAGE_TAG env)
make image-smoke-test    # boot the container, poll docker inspect until Health.Status == "healthy" (90s timeout)
make image-run           # interactive run with $(LDIF_DIR) bind-mounted into /ldap/ldif/
make e2e                 # boot image + run AuthenticateWithSearch (LDAP bind + uid search + re-bind)
```

The runtime image's CMD references `/ldap/ldif/` — mount any directory containing `.ldif` files there to seed entries. Empty mount = server starts with no entries (matches legacy behavior; does NOT fall back to bundled defaults when an empty-but-present `--ldifs` arg is supplied). **The `e2e` target overrides the entrypoint** (`--entrypoint java -jar /ldap/ldap-server.jar -b 0.0.0.0 -p ${APP_INTERNAL_PORT}` with no LDIF arg) so the server loads the bundled `ldap-example.ldif` defaults — that's the only way `AuthenticateWithSearch jduke theduke` can find an entry to bind against without a host-side mount.

## CI (`.github/workflows/build-test-push.yml`)

Six jobs, every action SHA-pinned:

| Job | Triggers | Notes |
|---|---|---|
| `changes` | every event | `dorny/paths-filter` — doc-only PRs (anything matching `**.md`, `docs/**`, `LICENSE`, etc., except `CLAUDE.md` which is re-included) skip every job below. `base: ${{ github.event_name == 'push' && 'master' \|\| '' }}` to handle act + PR-event annotation cases. |
| `build` | code-changing events + every tag | `jdx/mise-action` provisions Java + Maven from `.mise.toml`; `actions/cache` keyed on `hashFiles('pom.xml')` for `~/.m2/repository`. Runs `make ci` (alignment guards + lint + test + package). Trivy filesystem scan (informational). Uploads `target/ldap-server.jar` as artifact. |
| `cve-check` | tag pushes + weekly cron + dispatch | OWASP dependency-check via `mvn org.owasp:dependency-check-maven:check`. NVD DB cached at `~/.m2/repository/org/owasp/dependency-check-data` keyed on `pom.xml`. `NVD_API_KEY` optional (routed via `~/.m2/settings.xml`, never argv). |
| `release` | push to `master` OR `v*` tag | Downloads JAR, recreates the `latest` GitHub Release via `softprops/action-gh-release`. `contents: write` scoped to this job only. |
| `docker` | `v*` tag only | Build image for scan (load: true, amd64) → Trivy CRITICAL/HIGH image scan → `make image-smoke-test IMAGE_REF=apacheds-ad:scan` → `make e2e IMAGE_REF=apacheds-ad:scan` → log in to Docker Hub → push single-arch `linux/amd64` image with `provenance: false` + `sbom: false` and `flavor: latest=true` (only retags `:latest` for the highest-precedence semver). Each gate blocks the push. |
| `ci-pass` | always | Single branch-protection aggregator. Treats skipped as pass (handles tag-only `docker`/`cve-check`, master-or-tag-only `release`, doc-only-PR-skipping everything). |

A separate [`cleanup-runs.yml`](.github/workflows/cleanup-runs.yml) prunes old workflow runs and caches from deleted branches weekly via the native `gh` CLI (the previous `Mattraks/delete-workflow-runs` was migrated off per portfolio policy — single-maintainer third-party action, replaced by built-in tooling).

**`make ci-run` coverage gap.** `act push` exercises `changes` + `build` + `ci-pass` end-to-end. The tag-only `docker` + `cve-check` + `release` jobs need a real GitHub event context (tag ref, Releases API, Docker Hub creds) and won't run cleanly under `act` — validate those via a real push or `gh workflow run`.

### Required secrets

`DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` (Settings → Secrets and variables → Actions; used only by the `docker` job). `NVD_API_KEY` is OPTIONAL — without it the `cve-check` job still works but NVD lookups are rate-limited. `GITHUB_TOKEN` is auto-provisioned.

## Upgrade Backlog

Genuinely deferred items waiting on upstream OR coupled to a downstream bump. Renovate handles the routine dep bumps automatically; only items below need human attention.

- [ ] **ApacheDS 2.0.0-M24 → 2.0.0.AM27 (Major migration — NOT a drop-in).** Empirically attempted in this session and rolled back. AM27 introduces three breaking changes that require a ground-up rewrite of `InMemoryDirectoryServiceFactory` + `InMemorySchemaPartition`:
  1. **EhCache integration removed** — `org.apache.directory.server.core.shared.DefaultDnFactory` no longer takes a `CacheService`; `CacheConfiguration` / `CacheService` / `CacheManager` classes are gone from the API.
  2. **`Dn.apply(SchemaManager)` removed** — replaced with re-constructing the DN: `suffixDn = new Dn(schemaManager, suffixDn)`. `InMemorySchemaPartition.doInit()`'s throws clause also tightened (`InvalidNameException` no longer accepted; `IOException` must be caught + wrapped in `LdapOtherException`).
  3. **Transactional partition writes** — `AbstractBTreePartition.add()` asserts a `PartitionWriteTxn` is present in the `OperationContext`. Without it, every LDIF entry import throws `AssertionError` at `AbstractBTreePartition.java:769`. Fixing this requires threading `PartitionTxn` (or its `PartitionWriteTxn` subtype) through `importLdif()` and every `partition.add()` call site — substantial surface change.
  Until upstream rewrites the partition wiring, **stay on M24**. When AM27 lands here, **also attempt to un-`@Disable` `StartTlsTest`** in the same branch — if AM27's MINA TLS stack handles TLSv1.3, the `@Disabled` comes out + the StartTLS reactivation comment in the test source drops.
- [ ] **`maven.compiler.source=1.8` floor.** Tied to ApacheDS-M24's bytecode target. After ApacheDS AM27 lands (whenever the partition rewrite is done), verify whether AM27 still ships bytecode 1.8 before considering a floor bump. The `release` profile's enforcer rule `[1.8,1.9)` would need to move too — and the `release` profile itself was removed in this fork; re-add it from upstream if Maven Central publishing is ever wanted.

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |
| `Dockerfile` | `/harden-image-pipeline` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
