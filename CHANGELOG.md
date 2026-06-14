# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The fork inherits the upstream Java code from
[intoolswetrust/ldap-server](https://github.com/intoolswetrust/ldap-server); only
fork-owned changes (Docker pipeline, Makefile, hardened CI, Renovate config,
and dependency / source migrations driven by the fork) are recorded below.

## [1.2.4] — 2026-06-14

### Changed

- **JCommander migrated to the maintained `org.jcommander` coordinate.** The
  CLI parser was pinned to `com.beust:jcommander:1.82`, a coordinate frozen
  since 2022 (Renovate's `maven` manager reported it "current" because nothing
  newer exists under that groupId — a coordinate-rename blind spot). JCommander
  moved its groupId to `org.jcommander` at 2.0; bumped to
  `org.jcommander:jcommander:3.0`. The Java package stays `com.beust.jcommander`,
  so no import changes — only the `<groupId>`/`<version>` in `pom.xml`. All 9
  tests (which exercise CLI parsing via `ExtCommander`) pass unchanged; the
  `ExtUsageFormatter` override of `DefaultUsageFormatter.usage(StringBuilder, String)`
  (non-final in 3.0) and the non-`final` `@Parameter` fields remain compatible.

## [1.2.3] — 2026-06-14

Security fix + CI/build hardening. The shaded JAR gains a CVE override; the
rest is pipeline and test-coverage hardening.

### Fixed

- **CVE-2026-35563** — override the Apache Directory LDAP API to `2.1.8` (above
  AM27's transitive `2.1.5`) via an `api-parent` BOM import ordered before
  `apacheds-parent` (first-import-wins), plus a CPE-false-positive suppression
  for the AM27 server modules.

### Added

- `AnonymousBindTest` — covers the `--allow-anonymous` (`-a`) flag (9 tests total).
- `make e2e` wrong-password negative case (rejection asserted alongside the
  positive bind+search).
- Dedicated cheap `mermaid-lint` CI job validating the README C4 hero diagram on
  doc-only changes (so a README-only edit, which skips `build`, still gets the
  diagram validated).
- `hadolint` Dockerfile lint in `make lint` (pinned in `.mise.toml`, `.hadolint.yaml`).

### Changed

- `maven-compiler-plugin` `failOnWarning=true` (warnings-as-errors).
- Dockerfile runtime stage runs `apk --no-cache upgrade` to clear base-image OS
  CVEs at build time (real fix, not a `.trivyignore` waiver).
- Pin `jdx/mise-action`'s mise binary to `2026.6.6` to dodge mise's
  tag-before-asset-publish race; `require-docker` Make guard consolidates the
  per-target docker checks.

## [1.2.2] — 2026-06-01

Image-delivery enhancements + supply-chain signing. The shaded JAR is
functionally unchanged from 1.2.1; all changes are to the Docker image, CI,
and docs.

### Added

- **cosign keyless OIDC signing + SPDX SBOM attestation** on every tagged
  image. After the Trivy + smoke + e2e gates and push, the `docker` job signs
  the pushed digest (Sigstore/Fulcio + Rekor; `id-token: write`) and attaches
  an `anchore/sbom-action`-generated SPDX SBOM via `cosign attest`. Both are
  separate `.sig`/`.att` artifacts — `provenance`/`sbom` stay **false** on the
  image index so the GHCR "OS/Arch" tab stays clean. Verify recipe in the
  README CI/CD section.
- **Image pre-seeded with `ldap-example.ldif`.** The Dockerfile `COPY`s the
  bundled example tree into `/ldap/ldif/`, so a bare `docker run` (no mount)
  now starts with data (`uid=jduke`/`theduke` + Admin group). A bind mount
  over `/ldap/ldif/` still replaces it; an empty-dir mount shadows it.
- **README C4Context hero diagram** + a `make mermaid-lint` gate
  (`minlag/mermaid-cli`, Renovate-tracked via a Makefile customManager, wired
  into `make lint`).

### Changed

- README accuracy + usability pass: Tech Stack runtime image corrected to
  `eclipse-temurin:25-jre-alpine`, H1 aligned with the GitHub About field,
  Docker section documents seeding + admin/user credentials + base DN,
  `renovate-validate` target documented. AGENTS.md kept in sync.

## [1.2.1] — 2026-05-31

Security patch over v1.2.0. v1.2.0's `cve-check` passed only because the
scan was incomplete (cold NVD DB) and the Sonatype OSS Index analyzer was
disabled; once both were fixed the now-complete scan surfaced real
BouncyCastle CVEs that v1.2.0 had shipped. No API or runtime-behaviour
change for consumers.

### Security

- **BouncyCastle `bc{prov,pkix,util}-jdk15on:1.70` → `bc*-jdk18on:1.84`.**
  ApacheDS AM27 pulls the `jdk15on:1.70` artifacts transitively; they carry
  **CVE-2024-29857 (7.5)** and **CVE-2024-34447 (7.7)** (both ≥ the
  `failBuildOnCVSS=7` gate). The `jdk15on` line ended at 1.70, so the fix is
  in the renamed `jdk18on` line: all `org.bouncycastle:*` transitives are
  excluded from `apacheds-core-annotations` + `apacheds-protocol-ldap` and
  `bc*-jdk18on:1.84` added directly (`version.org.bouncycastle`,
  Renovate-tracked). Verified: dependency tree carries only jdk18on:1.84; all
  8 tests pass on JDK 25 incl. `StartTlsTest` (BC-backed TLS); image
  smoke + LDAP e2e green. Removable once ApacheDS ships on bc-jdk18on ≥ 1.78.
- **CVE-2010-1151 suppressed** on `org.apache.directory.server:*` — a
  confirmed false positive (ApacheDS CPE-mismatched to `apache_http_server`,
  an Apache HTTP Server mod_auth race condition), pinned to AM27 with a
  re-evaluation trigger.

### Changed

- **`cve-check` now runs the Sonatype OSS Index analyzer** (second vuln
  source beside NVD). Token auth is mandatory for OSS Index; without
  credentials it was silently disabled (warning only). `OSS_INDEX_USER` /
  `OSS_INDEX_TOKEN` are routed through `~/.m2/settings.xml`
  (`-DossIndexServerId=ossindex`), never argv.
- **NVD DB cache decoupled from `pom.xml`.** Re-keyed on the ISO week
  (`date -u +%Y-%V`) instead of `hashFiles('pom.xml')`, so a version bump no
  longer evicts the DB and forces a cold ~30-min fetch.

## [1.2.0] — 2026-05-31

Minor bump (not a patch): the runtime Java baseline moves 21 → 25, a
consumer-visible requirement change — a `maven.compiler.target=25` JAR
will not run on a JVM older than 25.

### Changed

- **Java 21 LTS → 25 LTS (coordinated across every alignment touchpoint).**
  The `check-java-alignment` guard requires `.mise.toml`, the Dockerfile
  build base, and the Dockerfile runtime base to share one Java major,
  so all three moved in lockstep:
  - `.mise.toml` — `temurin-21.0.11+10.0.LTS` → `temurin-25.0.3+9.0.LTS`.
  - `Dockerfile` build base — `maven:3.9-eclipse-temurin-21` → `-25`.
  - `Dockerfile` runtime base — `eclipse-temurin:21.0.11_10-jre-alpine`
    → `25.0.3_9-jre-alpine` (alpine 3.23.4; `/usr` ~26 MB; Trivy
    CRITICAL/HIGH clean on the base and the shaded JAR, verified
    2026-05-31).
  - `pom.xml` — `maven.compiler.source` 21 → 25.
  Verified on Temurin 25.0.3+9: alignment guard green, all 8 JUnit tests
  pass (incl. `StartTlsTest`), and the built image is healthy + passes the
  LDAP bind/search e2e.
- **`actions/upload-artifact` tracks latest instead of being pinned at
  v4.x.** v5+ uses a blob-upload protocol `nektos/act`'s built-in artifact
  server cannot decode (v6 → `Error unauthorized`; v7 → `CreateArtifact:
  unknown field "mime_type"`), which broke `make ci-run`. Instead of
  pinning the action (and stranding the repo on the Node-20-deprecated v4
  runtime), the artifact steps now gate on `if: ${{ !env.ACT }}` — `act`
  skips them, real GitHub Actions runs them.

### Fixed

- **`release` job no longer fails on doc-only pushes.** It was gated on
  `!failure() && !cancelled()`, which treats a *skipped* `build` (doc-only
  push, where the `changes` filter skips it) as OK — so `release` ran with
  no artifact and failed at `download-artifact` (`Artifact not found for
  name: ldap-server-jar`), turning `ci-pass` red on `master`. Now gated on
  `needs.build.result == 'success'`, so it skips cleanly when `build` skips.
- **`ExtCommander` no longer calls a deprecated JCommander constructor.**
  `JCommander(Object, String...)` is deprecated (it parses in the ctor);
  `ExtCommander(Object, String...)` now uses the non-deprecated
  `super(object)` + explicit `parse(args)` — behaviourally identical, no
  deprecation warning under JDK 25.

## [1.1.2] — 2026-05-31

### Changed

- **Image registry: Docker Hub → GHCR.** The `docker` job now publishes
  to `ghcr.io/<owner>/ldap-server/apacheds-ad` using the auto-provisioned
  `GITHUB_TOKEN` (scoped via `permissions: packages: write` on the
  docker job only). Migration touches:
  - `.github/workflows/build-test-push.yml` — `docker/metadata-action`
    images: `ghcr.io/${{ github.repository }}/apacheds-ad`;
    `docker/login-action` registry `ghcr.io`, username
    `${{ github.actor }}`, password `${{ secrets.GITHUB_TOKEN }}`;
    job-level `packages: write` added.
  - `Makefile` — `DOCKER_REGISTRY ?= ghcr.io` (was `registry-1.docker.io`).
  - `.env.example` — `DOCKER_REGISTRY=ghcr.io`.
  - `CLAUDE.md` + `README.md` — every Docker-Hub reference rewritten
    to GHCR; Required-secrets table no longer lists `DOCKERHUB_*`
    secrets (legacy pair can be deleted from the repo); fork-identity
    sentence updated.

  The legacy `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` secrets are no
  longer used by any workflow step and should be removed from the
  repo. The 2021-dated PAT was the immediate trigger for this
  migration — its expiration blocked the v1.1.1 image push despite
  every CVE gate passing.

  The legacy Docker Hub image `andriykalashnykov/apacheds-ad` will
  not receive further updates; consumers should switch to
  `ghcr.io/andriykalashnykov/ldap-server/apacheds-ad` starting at
  v1.1.2.

## [1.1.1] — 2026-05-31 — superseded by 1.1.2

Cut as the patch over the v1.1.0 CVE-blocked release; the v1.1.1
`docker` job passed all gates (Trivy, smoke, e2e) but its `Log in to
Docker Hub` step failed (expired 2021 PAT). No Docker Hub image
landed for v1.1.1; the security content shipped in v1.1.2 along with
the GHCR migration.

### Security

- **mina-core pinned to 2.2.7** via `dependencyManagement` to override
  ApacheDS AM27's transitive mina-core 2.2.3, which carried CVE-2024-52046
  (CRITICAL — unbounded deserialization may allow RCE). Removable once
  upstream ApacheDS ships a release with mina ≥ 2.2.4.
- **Runtime base image switched from `eclipse-temurin:21-jre`
  (Ubuntu) to `eclipse-temurin:21-jre-alpine`.** The Ubuntu variant
  bundled Go binaries whose `stdlib v1.26.2` triggered 8 HIGH Trivy
  findings (CVE-2026-33811 et al.) with no Eclipse-Temurin-published
  fix yet. The alpine variant ships no Go binaries (Trivy-clean at
  switch time, OS layer alpine 3.23.4) and uses busybox `nc` for the
  HEALTHCHECK in place of bash `/dev/tcp`. Dockerfile's `useradd` /
  `groupadd` swapped to busybox `adduser` / `addgroup` (`-S`/`-D`/`-H`
  short flags). `Makefile` `e2e` target's `--health-cmd` override
  swapped to match (`nc -z localhost ${APP_INTERNAL_PORT}`).

## [1.1.0] — superseded by 1.1.1

The `v1.1.0` git tag exists but never published a Docker Hub image: the
`docker` job's Trivy CRITICAL/HIGH gate (working as designed) blocked
the push when it surfaced mina-core CVE-2024-52046 (CRITICAL) and 8
HIGH Go-stdlib CVEs in the Ubuntu-based `eclipse-temurin:21-jre` base.
Both are fixed in 1.1.1. The `Latest` GitHub Release was updated with
the 1.1.0 JAR (the `release` job succeeded independently); the 1.1.1
release supersedes it. The migration content shipped in 1.1.0 is
unchanged in 1.1.1 — see the items below.

### Added

- **ApacheDS 2.0.0.AM27 migration** (real Major migration, formerly deferred).
  AM27 removes M24's EhCache-backed `CacheService`, drops
  `Dn.apply(SchemaManager)`, tightens `AbstractLdifPartition.doInit()` to
  `throws LdapException`, and asserts a `PartitionWriteTxn` on the
  `OperationContext` for every `partition.add()` call. The migration replaces
  the EhCache block in `InMemoryDirectoryServiceFactory` (AM27's
  `DefaultDnFactory` uses an internal Caffeine cache), rebuilds the suffix DN
  via `new Dn(schemaManager, suffixDn)`, and wraps the schema-load loop in
  `InMemorySchemaPartition.doInit()` with `beginWriteTransaction()` /
  `commit()` / `abort()`. AM27 also removes M24's `CoreKeyStoreSpi` fallback,
  so `LdapServer` now generates a self-signed EC keystore via
  `CertificateUtil.createTempKeyStore()` when no `--ssl-keystore-file` is
  supplied — preserving the "just works without config" behavior for tests
  and dev. See [CLAUDE.md Upgrade Backlog cheat-sheet](CLAUDE.md#am27-migration-cheat-sheet-recorded-so-a-future-bump-doesnt-redo-the-research)
  for the full breaking-change list.
- **`StartTlsTest` reactivated.** AM27's MINA TLS stack supports TLSv1.3 +
  `TLS_AES_128_GCM_SHA256`; the `@Disabled` marker that had blocked this test
  since the M24 / MINA-pre-TLSv1.3 era was removed. Test suite is now 8/8.

### Changed

- **`maven.compiler.source` / `maven.compiler.target` bumped from `1.8` to
  `21`.** AM27 still ships bytecode 52 (Java 8), but a dep's bytecode floor
  does not constrain the consumer's target — the application now compiles to
  bytecode 65 (Java 21), matching the `eclipse-temurin:21-jre` runtime in the
  Dockerfile. Eliminates the `[debug target 1.8] / source value 8 is obsolete`
  warnings on every build.
- **Shaded JAR size: ~19.94 MB → ~16 MB.** AM27's removal of the EhCache
  transitive (~9 MB) drops the JAR substantially.

### Documented

- **`actions/upload-artifact` pinned at v4.6.2** until `nektos/act` ships
  support for the v4 blob-storage protocol introduced in upload-artifact
  v5.0.0. v5/v6/v7 all break `make ci-run` with `Error unauthorized` against
  act's `--artifact-server-path`. Node 20 deprecation deadline 2026-06-16 is a
  default-runtime nudge, not a removal; v4 continues to run on Node 24.

## [1.1.0-modernization] — Sync with upstream + modernize toolchain, CI, Dockerfile

Two consolidated PRs (#6 and #7) on 2026-05-30 / 2026-05-31. Squash commits
[513c6dd](https://github.com/AndriyKalashnykov/ldap-server/commit/513c6dd) and
[b0f1833](https://github.com/AndriyKalashnykov/ldap-server/commit/b0f1833).

### Added

- **Maven shade `<artifactSet><excludes>`** for `junit:junit` and
  `org.hamcrest:hamcrest-core` — apacheds-all's M24 POM leaked these
  test-scope deps into compile scope; the production JAR no longer contains
  them.
- **Dockerfile base images digest-pinned**:
  `maven:3.9-eclipse-temurin-21@sha256:1bb51c5e…` and
  `eclipse-temurin:21-jre@sha256:010e0a06…`. Both digests resolved from the
  multi-arch OCI index via the registry HEAD; Renovate's `dockerfile`
  manager maintains them in-place on tag moves.
- **CLAUDE.md note pinning OWASP DC + Trivy as the canonical security stack**;
  Snyk GitHub App was removed (account-level read access, 100% overlap with
  OWASP DC).

### Changed

- **JUnit 4 → JUnit 5 Jupiter** via `org.junit:junit-bom:6.1.0` across 4 test
  files. `@RunWith(Parameterized.class)` → `@ParameterizedTest` +
  `@MethodSource`, `@Before` / `@After` → `@BeforeEach` / `@AfterEach`,
  `@Ignore` → `@Disabled`. Surefire's built-in JUnit 5 provider handles the
  BOM — no `junit-platform-launcher` needed.
- **SLF4J 1.7.36 → 2.0.18** (ServiceLoader binding).
- **JCommander 1.32 → 1.82.** `ExtCommander` rewritten to register a custom
  `IUsageFormatter` (1.82 moved usage rendering out of `JCommander.usage(...)`);
  `CLIArguments.ldifFiles` lost its `final` modifier (1.82 rejects `final`
  `@Parameter` fields).
- **Maven plugin bumps**: shade 3.6.2, compiler 3.15.0, exec 3.6.3,
  bundle 6.0.2. OWASP dependency-check Maven plugin pinned at 12.2.2 in
  `<pluginManagement>` (invoked via fully-qualified coordinate; no version
  argument on the CLI).
- **mise toolchain**: Java `temurin-21.0.11+10.0.LTS`, Maven `3.9.16`.
- **GitHub Actions majors** (all SHA-pinned, all Node 24 runtime drop-ins):
  - `actions/checkout` v5 → v6.0.2
  - `actions/cache` v4.3.0 → v5.0.5
  - `actions/download-artifact` v4.3.0 → v8.0.1
  - `jdx/mise-action` v3.6.0 → v4.0.1
  - `dorny/paths-filter` v3.0.2 → v4.0.1
  - `docker/setup-qemu-action` v3.6.0 → v4.1.0
  - `docker/setup-buildx-action` v3.11.1 → v4.1.0
  - `docker/metadata-action` v5.8.0 → v6.1.0
  - `docker/login-action` v3.5.0 → v4.2.0
  - `docker/build-push-action` v6.18.0 → v7.2.0
  - `softprops/action-gh-release` v2.2.2 → v3.0.0

### Removed

- **`src/main/resources/users.ldif`** — 424 lines, fork-preserved for 12
  years, zero code paths referenced it. Bundled `ldap-example.ldif` is the
  default seed data.
- **`scripts/*.sh`** (`build.sh`, `run.sh`, `push.sh`, `local-run.sh`,
  `set-env.sh`) — functionally superseded by Make targets (`image-build`,
  `image-run`, `docker-login` + `image-push` with stdin-only password,
  `run-jar`, `.env.example`).
- **Snyk GitHub App** — gated nothing, 100% overlapped OWASP DC on Maven dep
  CVE scanning, account-level read access to source.

### Security

- Trivy filesystem scan (`build` job, informational on every PR).
- Trivy image scan (`docker` job, CRITICAL/HIGH blocking gate).
- OWASP dependency-check (`cve-check` job, weekly cron + tag pushes,
  NVD-backed; `NVD_API_KEY` optional and routed via `~/.m2/settings.xml`,
  never argv).

### Internal

- `.github/workflows/build-test-push.yml` — 6 jobs (`changes` →
  `build` → `cve-check` + `release` + `docker` → `ci-pass`), every action
  SHA-pinned, `dorny/paths-filter` doc-only-PR skip, `make ci-run` exercises
  `changes` + `build` + `ci-pass` end-to-end under `act push`.
- `.github/workflows/cleanup-runs.yml` — native `gh` CLI replaces
  `Mattraks/delete-workflow-runs`.
- Alignment guards (`make check-java-alignment`, `make check-maven-alignment`)
  fail fast on `.mise.toml` ↔ Dockerfile toolchain drift.

## Pre-modernization

Releases prior to the modernization sweep are tagged in the GitHub Releases
page; the Java code originates from
[intoolswetrust/ldap-server](https://github.com/intoolswetrust/ldap-server)
and its history is preserved via merges of upstream `master` + `startTls`.
