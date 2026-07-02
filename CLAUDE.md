# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-module Maven project that wraps **Apache Directory Server 2.0.0.AM27** as a self-contained, in-memory LDAP server. Maven-shaded into one runnable fat JAR (`target/ldap-server.jar`, ~16 MB). No persistence — all directory data lives in memory and is lost on shutdown. CLI parsed via JCommander 3.0 (`org.jcommander:jcommander` — the maintained coordinate after the `com.beust` groupId rename; Java package stays `com.beust.jcommander`); default partition root is `dc=ldap,dc=example`; default admin bind is `uid=admin,ou=system` / `secret` on port 10389. Logging routed through SLF4J 2.0.x + `slf4j-simple` (ServiceLoader binding).

This repo is a **fork of [intoolswetrust/ldap-server](https://github.com/intoolswetrust/ldap-server)**. Java code is the upstream's; the fork adds the Docker pipeline (`ghcr.io/andriykalashnykov/ldap-server/apacheds-ad` on GitHub Container Registry), Makefile, hardened GitHub Actions workflow, Renovate config, and `.mise.toml` toolchain pinning. The Maven groupId was scrubbed to `io.github.andriykalashnykov` and `<scm>` / `<developers>` point at this fork; everything else in `pom.xml` is upstream's.

**Java package `com.github.kwart.ldap` is intentionally kept aligned with upstream** (not renamed to the fork's identity) so future `git merge upstream/master` runs stay clean diffs. Don't propose renaming it.

## Build, run, test

JDK 25 LTS + Maven 3.9.16, both pinned in [`.mise.toml`](.mise.toml). `make deps` installs mise on first run, then `mise install` provisions the toolchain.

```bash
make deps                                            # one-time mise + Java/Maven bootstrap
make ci                                              # deps + alignment guards + lint + test + package
make e2e                                             # boot image, override CMD, LDAP bind + search
make cve-check                                       # OWASP dependency-check (~2 GB NVD cold start)
java -jar ./target/ldap-server.jar ./target/classes/ # run with bundled LDIFs as seed data
java -jar ./target/ldap-server.jar --help            # full CLI flag list (includes --admin-password, --ssl-*)
```

`make ci` chains `deps → check-java-alignment → check-maven-alignment → lint → test → package`. The two alignment guards fail fast when the Java major in `.mise.toml` drifts from the Dockerfile `FROM` lines, or when the Maven minor drifts from the build-stage tag — silent toolchain desync is otherwise a recurring foot-gun on Renovate split-PR days. Both guards are mutation-tested (proven to go RED on intentional desync). `make lint` runs `mvn validate` + **`hadolint Dockerfile`** (pinned in `.mise.toml` as `aqua:hadolint/hadolint`; intentional ignores in [`.hadolint.yaml`](.hadolint.yaml) — only DL3025, since the runtime CMD is deliberately shell-form for `${APP_INTERNAL_PORT}` expansion) + a shell-script `+x` guard + **`diagrams-check`** (renders the README C4 hero from [`docs/diagrams/c4-context.puml`](docs/diagrams/c4-context.puml) via the pinned `plantuml/plantuml` image and fails if the committed PNG drifts from its source; skips under `act` due to a docker-in-docker bind-mount mismatch, runs on real CI). **`PLANTUML_VERSION` (and the C4-PlantUML `!include` tag in the `.puml`) are deliberately NOT Renovate-tracked**: this repo automerges on green CI, and a renderer/`!include` bump the bot cannot re-render would fail `diagrams-check` and sit as a permanently-RED automerge PR. Bump either by hand, then `make diagrams` and commit the re-rendered PNG in the same change. The `diagrams-check` gate is two-part (`git diff --exit-code` for a stale tracked PNG **plus** `git ls-files --others` for an un-added render) so it stays correct when run pre-commit inside the local `make ci` — a plain `git status --porcelain` would false-RED a legitimately-staged render.

`pom.xml` sets `maven.compiler.source=25` (matches the Dockerfile runtime `eclipse-temurin:25-jre`). AM27 itself ships bytecode 52 (Java 8) but our application can target whatever runtime we deploy on — the dep's floor does not constrain the consumer's target. The `release` profile that enforced `[1.8,1.9)` was removed in this fork; re-add it from upstream if Maven Central publishing is ever wanted.

### Tests

JUnit 5 Jupiter suite (`org.junit:junit-bom:6.1.0`) under `src/test/java/com/github/kwart/ldap/` — **9 tests, all passing on AM27**:

| Class | Notes |
|---|---|
| `LdapServerTest` | 4 tests — `@ParameterizedTest` + `@MethodSource("data")` over `(ipv6, tls)`, basic bind + search |
| `LdapServer2Test` | 1 test — multi-entry LDIF with `changetype: modify` |
| `CustomPasswordTest` | 2 tests — `--admin-password` flag |
| `StartTlsTest` | 1 test — pins `TLSv1.3` + `TLS_AES_128_GCM_SHA256`; passes on AM27's MINA TLS stack (the `@Disabled` was removed in the AM27 migration commit). |
| `AnonymousBindTest` | 1 test — covers the `--allow-anonymous` (-a) flag / `setAllowAnonymousAccess`: an anonymous bind (`SECURITY_AUTHENTICATION=none`) searches the bundled tree and finds `uid=jduke`. Fork-added (additive file; doesn't touch upstream test classes). |

`make test` runs everything. Surefire's built-in JUnit 5 support handles the BOM; no `junit-platform-launcher` dependency needed.

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

**`CLIArguments`** is the single source of truth for flag definitions (JCommander annotations). **Do NOT mark `@Parameter` fields `final`** — JCommander rejects `final` fields at parse time with `Cannot use final field ... as a parameter` (compiler-inlined-constant safety check; this constraint predates and survives the 3.0 migration). `ExtCommander` is a thin wrapper that registers a custom `IUsageFormatter` (`ExtUsageFormatter extends DefaultUsageFormatter`) to inject custom usage head/tail strings — JCommander (since 1.82, unchanged in 3.0) renders usage via `IUsageFormatter`, so `ExtUsageFormatter` overrides the formatter's `usage(StringBuilder, String)` (non-final in 3.0), not any method on `JCommander` itself. Don't conflate `ExtCommander` with the flag definitions in `CLIArguments`.

## Docker image

Multi-stage Dockerfile, builds from source — does NOT download a released JAR.

- **Builder**: `maven:3.9-eclipse-temurin-25` runs `mvn -B -DskipTests clean package` with a BuildKit cache mount on `~/.m2`.
- **Runtime**: `eclipse-temurin:25-jre-alpine` (alpine variant; ~26 MB `/usr`, no Go binaries to drag in stdlib CVEs, Trivy-clean at time of switch). Non-root user UID/GID 10001 (created via busybox `addgroup`/`adduser`, no home, `/sbin/nologin` shell). Owns `/ldap`.
- **`RUN apk --no-cache upgrade`** in the runtime stage (as root, before `USER`) pulls baked-in Alpine OS packages (libcrypto3/libssl3/openssl/...) up to the latest in the pinned branch at build time, so a CVE Alpine has **already** fixed clears the blocking Trivy image gate immediately instead of waiting weeks for the upstream eclipse-temurin base rebuild. Real fix (vulnerable package removed), not a `.trivyignore` waiver; the `FROM` stays digest-pinned for reproducibility of everything else. (At the time it was added the pinned base shipped openssl `3.5.6-r0`; the upgrade pulled `3.5.7-r0`.)
- **HEALTHCHECK**: `nc -z ${HEALTHCHECK_HOST} ${APP_INTERNAL_PORT}` — busybox netcat is bundled with alpine; no extra package install needed. Probes the LDAP TCP listener since ApacheDS exposes only the LDAP protocol (no HTTP `/healthz`). The previous `bash -c 'exec 3<>/dev/tcp/...'` form was Ubuntu-base specific; alpine's busybox sh has no `/dev/tcp`. **No `apk add` in the runtime layer.**
- **`HEALTHCHECK` flag timings are LITERAL** (`--interval=30s --timeout=3s --start-period=20s --retries=3`) because Docker's parser does NOT expand ARG/ENV in those slots. The CMD's `${VAR}` expand at container start, so `HEALTHCHECK_HOST` and `APP_INTERNAL_PORT` honor `docker run -e ...` overrides.
- **CMD**: shell form so `${APP_INTERNAL_PORT}` is honored — `java -jar /ldap/ldap-server.jar -b 0.0.0.0 -p ${APP_INTERNAL_PORT} /ldap/ldif/`.

### Container workflows

```bash
make image-build         # multi-stage build from src/ (uses DOCKER_LOGIN/IMAGE_NAME/IMAGE_TAG env)
make image-smoke-test    # boot the container, poll docker inspect until Health.Status == "healthy" (90s timeout)
make image-run           # interactive run with $(LDIF_DIR) bind-mounted into /ldap/ldif/
make e2e                 # boot image + AuthenticateWithSearch: correct-password bind+search (PASS) AND wrong-password rejection (negative case)
```

The runtime image ships **pre-seeded**: the Dockerfile `COPY`s `src/main/resources/ldap-example.ldif` into `/ldap/ldif/`, so a bare `docker run` (default CMD `… /ldap/ldif/`) starts with the example tree (`uid=jduke`/`theduke` + Admin group). Bind-mounting a directory over `/ldap/ldif/` **replaces** the baked-in seed — every `.ldif` inside is imported; mounting an *empty* directory shadows the seed and starts with no entries (the server does NOT fall back to bundled defaults on an empty-but-present directory arg). **The `e2e` target overrides the entrypoint** (`--entrypoint java -jar /ldap/ldap-server.jar -b 0.0.0.0 -p ${APP_INTERNAL_PORT}` with no LDIF arg) so the server loads the JAR-bundled `ldap-example.ldif` — equivalent data, exercising the no-arg path. (Both the baked `/ldap/ldif/` seed and the JAR-bundled default come from the same `src/main/resources/ldap-example.ldif`.)

## CI (`.github/workflows/build-test-push.yml`)

Seven jobs, every action SHA-pinned:

| Job | Triggers | Notes |
|---|---|---|
| `changes` | every event | `dorny/paths-filter` — doc-only PRs (anything matching `**.md`, `docs/**`, `LICENSE`, etc., except `CLAUDE.md` which is re-included) skip every job below. `base: ${{ github.event_name == 'push' && 'master' \|\| '' }}` to handle act + PR-event annotation cases. `docs/diagrams/**/*.puml` + `docs/diagrams/out/**` are also re-included as `code` so a C4 diagram-source edit triggers `build` (→ `make diagrams-check` catches an un-regenerated PNG). |
| `build` | code-changing events + every tag | `jdx/mise-action` provisions Java + Maven from `.mise.toml`; `actions/cache` keyed on `hashFiles('pom.xml')` for `~/.m2/repository`. Runs `make ci` (alignment guards + lint incl. C4 diagram drift check + test + package). Trivy filesystem scan (informational). Uploads `target/ldap-server.jar` as artifact. |
| `cve-check` | tag pushes + weekly cron + dispatch | OWASP dependency-check via **[`scripts/cve-check.sh`](scripts/cve-check.sh)** (`mvn org.owasp:dependency-check-maven:check`, NVD + Sonatype OSS Index analyzers). NVD DB cached at `~/.m2/repository/org/owasp/dependency-check-data` keyed on the **ISO week** (the DB is independent of `pom.xml`, so a version bump must not evict it). **`NVD_API_KEY` is strongly recommended** — without it, anonymous NVD rate-limiting exhausts the plugin's parallel connection pool and the job fails with `commons-dbcp2.BasicDataSource.getConnection() — connectionPool is null` on cold fetches (empirically verified 2026-05-31 across multiple tag runs). Free API key from <https://nvd.nist.gov/developers/request-an-api-key>; routed via `~/.m2/settings.xml`, never argv. **Transient-NVD-outage resilience (added 2026-06-22 after the weekly cron red-failed on an NVD `503`):** dependency-check 12.x treats a failed NVD *update* as fatal and has no "use cached DB on update failure" flag, so a pure upstream `503` would otherwise red the build even with a fresh DB in cache. The wrapper classifies the failure: a real CVE finding (`failBuildOnCVSS=7`) still fails; an NVD/datasource **update** failure re-scans against the cached DB (`-DautoUpdate=false`, still blocking on CVSS≥7) with a `::warning::` and a green build (only failing if no cached DB exists). The classifier's two signature regexes are single-sourced and guarded by `scripts/cve-check.sh --self-test`, wired into `make lint` (mutation-proven RED). `nvdValidForHours` is deliberately left at its 4h default — raising it above the 168h cron interval would stop the cron from ever refreshing the DB. |
| `release` | `v*` tag only | Downloads the shaded JAR and publishes an **immutable per-version** GitHub Release for the pushed tag (`tag_name: ${{ github.ref_name }}`, auto-generated notes) via `softprops/action-gh-release`; GitHub marks the newest semver as "Latest" (`make_latest`). The asset URL is stable per version (`releases/download/<tag>/ldap-server.jar`) so downstream consumers pin a version + SHA. `contents: write` scoped to this job. (Was a single rolling `latest` release until v1.2.4; switched to per-version releases — the `latest` asset was mutable and broke a downstream SHA pin.) |
| `docker` | `v*` tag only | Build image for scan (load: true, amd64) → Trivy CRITICAL/HIGH image scan → `make image-smoke-test IMAGE_REF=apacheds-ad:scan` → `make e2e IMAGE_REF=apacheds-ad:scan` → log in to **GHCR** (`${{ github.actor }}` + auto-provisioned `GITHUB_TOKEN`; the docker job has `packages: write`) → push single-arch `linux/amd64` image to `ghcr.io/${{ github.repository }}/apacheds-ad` with `provenance: false` + `sbom: false` and `flavor: latest=true` (only retags `:latest` for the highest-precedence semver) → **cosign keyless-sign the pushed digest (OIDC; job has `id-token: write`) + attach an SPDX SBOM attestation** (`anchore/sbom-action` → `cosign attest`). Each gate blocks the push. `provenance`/`sbom` stay **false on the image index deliberately** (keeps the GHCR "OS/Arch" tab clean — in-manifest attestations add `unknown/unknown` entries); the cosign signature + SBOM are separate `.sig`/`.att` artifacts that don't pollute the index. |
| `ci-pass` | always | Single branch-protection aggregator over all five other jobs. Treats skipped as pass (handles tag-only `docker`/`cve-check`, tag-only `release`, doc-only-PR-skipping everything). |

A separate [`cleanup-runs.yml`](.github/workflows/cleanup-runs.yml) prunes old workflow runs and caches from deleted branches weekly via the native `gh` CLI (the previous `Mattraks/delete-workflow-runs` was migrated off per portfolio policy — single-maintainer third-party action, replaced by built-in tooling).

**`make ci-run` coverage gap.** `act push` exercises `changes` + `build` + `ci-pass` end-to-end. The tag-only `docker` + `cve-check` + `release` jobs need a real GitHub event context (tag ref, Releases API, GHCR / `GITHUB_TOKEN` with `packages: write`) and won't run cleanly under `act` — validate those via a real push or `gh workflow run`.

**Security stack: OWASP dependency-check + Trivy only — do NOT propose re-adding Snyk.** Maven dep CVEs are covered by OWASP DC (`cve-check` job, weekly cron + tag pushes, NVD-backed). Source/config vulns + secrets are covered by Trivy filesystem scan (`build` job, informational). Built-image vulns are covered by Trivy image scan (`docker` job, CRITICAL/HIGH blocking gate). The Snyk GitHub App was intentionally removed — it was account-level (read access to source), gated nothing, and 100% overlapped OWASP DC on Maven deps. If a future analysis suggests adding Snyk, decline with this reasoning.

**`actions/upload-artifact` tracks latest; its upload steps are skipped under `act` via `if: ${{ !env.ACT }}` — do NOT remove that guard.** `act`'s built-in `--artifact-server-path` server implements only GitHub's **v4** artifact blob-upload protocol, so `upload-artifact` v5+ breaks the local `make ci-run` mirror — empirically (2026-05-31): v6.0.0 fails the `Upload shaded JAR` step with `Error unauthorized`, v7.0.1 with `CreateArtifact: unknown field "mime_type"`. The action itself is fine on real GitHub Actions; this is purely an `act` gap. Rather than pin the repo to v4.x forever (which also strands it on the Node-20-deprecated v4 runtime), the two `upload-artifact` steps — `build`'s "Upload shaded JAR" and `cve-check`'s "Upload CVE report" — gate on `!env.ACT`, so `act` skips them while real CI runs them normally. The upload is GitHub-platform plumbing (`make ci`/package already proves the JAR exists), so `make ci-run` loses nothing meaningful, and Renovate is free to bump the action with no version cap. History: pinned at v4.6.2 until the `!env.ACT` decouple landed (PR #21), after Renovate PR #18 auto-merged a v7 bump that broke the mirror. `download-artifact` (release job, real-CI-only) is unaffected and tracks latest too.

**`jdx/mise-action`'s `version:` input pins the mise BINARY (not the tools `.mise.toml` pins) — do NOT drop it to auto-latest.** mise-action defaults to installing the latest mise release, but mise publishes a release **tag** before its release **assets** finish uploading. During that window auto-latest resolves to a version whose `mise-vX-linux-x64.tar.zst` 404s, failing the `mise install` step on **every** CI run (PR and master alike) regardless of repo changes — the same tag-before-asset-publish race the `.mise.toml` aqua-tool Renovate buffer guards, here one level down at mise's own binary. Both mise-action steps (`build` + `cve-check`) therefore pin `version: <X>` (bare, no `v` — the action prepends it). The pin is **NOT** Renovate-tracked: the `github-releases` datasource surfaces a tag the instant its release object exists (assets may still be missing), so auto-bumping could re-propose the 404'ing version. Bump it by hand when `gh api repos/jdx/mise/releases/tags/v<X> --jq '[.assets[].name]|map(select(test("linux-x64.tar.zst")))|length'` returns ≥1. History: master's `build` job went red 2026-06-14 when mise `v2026.6.7` tagged with no linux-x64 asset; pinning to the last-good `2026.6.6` unblocked CI without waiting on the upstream asset publish.

### Required secrets

- **`GITHUB_TOKEN`** — auto-provisioned by GitHub Actions; used by the `docker` job (GHCR publish, scoped via `permissions: packages: write`) and the `release` job (GitHub Release upload, scoped via `permissions: contents: write`). No manual configuration needed.
- **`NVD_API_KEY`** — **strongly recommended** secret (Settings → Secrets and variables → Actions). The OWASP dependency-check 12.2.2 plugin's parallel NVD fetcher hits an upstream NPE (`commons-dbcp2.BasicDataSource.getConnection() — connectionPool is null`) under anonymous rate-limiting; in practice the `cve-check` job fails on every cold-cache run without the key. The key is free at <https://nvd.nist.gov/developers/request-an-api-key>. Routed via `~/.m2/settings.xml` (see the Makefile `cve-check` recipe), never argv.
- **`OSS_INDEX_USER` + `OSS_INDEX_TOKEN`** — **recommended** pair enabling dependency-check's **Sonatype OSS Index** analyzer (a second vuln source beside NVD). Token auth is now mandatory for OSS Index; without these the analyzer is **silently disabled** (`[WARNING] Sonatype OSS Index Analyzer disabled due to missing credentials`) and coverage drops to NVD-only — the job still exits 0, so the gap is easy to miss. `OSS_INDEX_USER` is the OSS account email, `OSS_INDEX_TOKEN` its API token (free at <https://ossindex.sonatype.org/>). Both routed via `~/.m2/settings.xml` `<server id=ossindex>` and passed with `-DossIndexServerId=ossindex` — never argv. Wire OSS Index whenever `NVD_API_KEY` is set up; don't configure one without the other.

The legacy `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` pair is no longer needed — the project publishes to GHCR (`ghcr.io/<owner>/<repo>/apacheds-ad`) via `GITHUB_TOKEN`. Delete those secrets from the repo if they're still set.

## Upgrade Backlog

Renovate handles routine dep bumps automatically. Add items here only when a genuinely-deferred, upstream-blocked task surfaces. See [CHANGELOG.md](CHANGELOG.md) for resolved items.

- **`caffeine` 2.9.3 calls terminally-deprecated `sun.misc.Unsafe` memory methods (LOW priority, upstream-blocked).** Caffeine arrives *transitively via ApacheDS AM27* (`DefaultDnFactory`'s cache), and JDK 24+ warns on `sun.misc.Unsafe::objectFieldOffset` (`A terminally deprecated method in sun.misc.Unsafe has been called`). It's harmless today (build + tests green on JDK 25), but a future JDK that *removes* those methods would break ApacheDS — and thus the server — at boot. **Trigger to act:** a JDK release flipping `sun.misc.Unsafe` to deny-by-default/removed (the lifecycle is warn → deny → remove, several releases apart — not imminent). **Action:** watch for AM27 bumping its transitive Caffeine to 3.x (which dropped `Unsafe`); Renovate will surface the AM27 bump. Do **not** force a `dependencyManagement` override to Caffeine 3.x without verifying AM27 compatibility — AM27 is compiled against 2.x and the 2.x→3.x API changed. Interim escape hatch if a JDK denies `Unsafe` before AM27 updates: launch with `--sun-misc-unsafe-memory-access=allow`.

### AM27 migration cheat-sheet (recorded so a future bump doesn't redo the research)

AM27 (and presumably newer) introduces four breaking changes vs M24 that an in-memory wrapper must handle:

1. **EhCache removed from `DirectoryService`.** `setCacheService(...)` is gone; `DefaultDnFactory` now uses an internal Caffeine cache. Delete the EhCache block in `InMemoryDirectoryServiceFactory.init()`.
2. **`Dn.apply(SchemaManager)` removed.** Use `suffixDn = new Dn(schemaManager, suffixDn)` instead (api-ldap-model 2.1.x ctor at line 190 of `Dn.java`).
3. **`AbstractLdifPartition.doInit()` signature tightened to `throws LdapException`.** Drop `InvalidNameException` and bare `Exception`; catch `IOException` inside and wrap in `LdapOtherException`.
4. **Transactional partition writes (the load-bearing change).** `AbstractBTreePartition.add()` asserts a `PartitionWriteTxn` on the `OperationContext` (see `AbstractBTreePartition.java:765-770`). The canonical pattern lives in `DefaultOperationManager.java:421-429`:
   ```java
   PartitionWriteTxn writeTxn = partition.beginWriteTransaction();
   try {
       addContext.setTransaction(writeTxn);
       partition.add(addContext);
       writeTxn.commit();
   } catch (LdapException le) {
       writeTxn.abort();
       throw le;
   } catch (IOException ioe) {
       writeTxn.abort();
       throw new LdapOtherException(ioe.getMessage(), ioe);
   }
   ```
   Wrap the schema-load loop in `InMemorySchemaPartition.doInit()` with one such transaction. `LdapServer.importLdif()` goes through `directoryService.getAdminSession().add()`, which routes through `DefaultOperationManager` and handles the transaction internally — no change needed there.
5. **M24's CoreKeyStoreSpi fallback is gone.** AM27's `CertificateUtil.loadKeyStore(null, null)` returns `null`, so `LdapServer.start()` leaves `keyManagerFactory` null and `StartTlsHandler.setLdapServer()` NPEs. Generate a self-signed temp keystore when none is supplied: `CertificateUtil.createTempKeyStore("ldap-server-", "secret".toCharArray())`.

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
