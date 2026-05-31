# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The fork inherits the upstream Java code from
[intoolswetrust/ldap-server](https://github.com/intoolswetrust/ldap-server); only
fork-owned changes (Docker pipeline, Makefile, hardened CI, Renovate config,
and dependency / source migrations driven by the fork) are recorded below.

## [Unreleased]

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
