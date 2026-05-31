# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-module Maven project that wraps ApacheDS 2.0.0-M24 as a self-contained in-memory LDAP server, shaded into one runnable fat JAR (`target/ldap-server.jar`). No persistence — all directory data lives in memory and is lost on shutdown. CLI parsed via JCommander; default partition root is `dc=jboss,dc=org`; default admin bind is `uid=admin,ou=system` / `secret` on port 10389.

## Build, run, test

JDK 18 + Maven (CI uses Temurin 18; `pom.xml` still sets `maven.compiler.source=1.8`, so don't "fix" that — it's intentional baseline compatibility while the build runs on a newer JDK).

```bash
mvn clean package                                    # produces target/ldap-server.jar (shaded)
java -jar ./target/ldap-server.jar ./target/classes/ # run with bundled LDIFs as seed data
java -jar ./target/ldap-server.jar --help            # full CLI flag list
```

`scripts/local-run.sh` chains `mvn clean install` + run. `scripts/build.sh` / `scripts/run.sh` / `scripts/push.sh` operate on the Docker image and require `DOCKER_LOGIN` / `DOCKER_PWD` env vars (not committed; edit `scripts/set-env.sh` locally).

### "Tests"

There is **no JUnit suite** — `pom.xml` declares no test dependencies and `src/test` does not exist. `mvn test` runs to completion as a no-op. What look like tests are actually executable client smoke tools that live under `src/main/java` and each have their own `main(...)`:

- `LdapTest` — connects, optionally over LDAPS with a no-verification trust manager
- `Authenticate` — simple bind against `<ldapURL> <userDN> <password>`
- `AuthenticateWithSearch` — bind + subtree search by `uid`

Run one via `java -cp target/ldap-server.jar org.jboss.test.ldap.Authenticate ldap://localhost:10389 uid=jduke,ou=Users,dc=jboss,dc=org theduke` (server must be running separately). If a real test suite is added later, the `pom.xml` needs a test-scope JUnit/Surefire setup first.

## Architecture

Entry point is `org.jboss.test.ldap.LdapServer#main`, declared as the shaded JAR's `Main-Class`. The startup sequence (read `LdapServer.java` end-to-end before changing it — these steps are order-sensitive):

1. `InMemoryDirectoryServiceFactory.init("ds")` — builds an ApacheDS `DirectoryService` whose schema partition is `InMemorySchemaPartition` (loads schema entries from classpath rather than disk; this is the load-bearing piece that makes the server "no config files needed").
2. `importLdif(cliArguments.getLdifFiles())` — if no LDIF args, loads bundled `src/main/resources/jboss-org.ldif`; otherwise accepts a mix of `.ldif` files and/or a directory (directory mode filters by `.ldif` extension, case-insensitive). For each entry, `checkPartition` creates a new `AvlPartition` on demand if the entry's parent DN doesn't already exist — this is how arbitrary LDIFs work without pre-declaring partitions.
3. Bind one `TcpTransport` for `ldap://`, optionally a second SSL-enabled transport for `ldaps://` if `--ssl-port` is set, then `ldapServer.start()`.

`CLIArguments` is the single source of truth for flag definitions (JCommander annotations); `ExtCommander` is a thin wrapper that adds custom usage head/tail strings.

## Docker image

`Dockerfile` does **not** build from source. It downloads `ldap-server.jar` from the GitHub Releases `latest` tag of this repo. This means:

- Editing Java code and re-running `docker build` will produce an image with the **previous** released JAR, not your changes. For local end-to-end testing, build the JAR with Maven and bind-mount it, or temporarily rewrite the `Dockerfile` to `COPY target/ldap-server.jar .`.
- The image's `latest` tag is updated by CI on every push to `master` (release-replace), and the image is only pushed to Docker Hub when the workflow runs on a **git tag** (`github.ref_type == 'tag'`) — pushes to `master` build the image but skip the push step.

The `ADD https://www.random.org/...randbyte` line is intentional cache-busting so the next `wget` always re-fetches the released JAR — leave it alone unless replacing the whole download mechanism.

## CI (`.github/workflows/build-test-push.yml`)

Triggers: push to `master`, push to `v*` tags, and PRs. Concurrency group cancels in-flight runs on the same ref. Steps run sequentially: Maven test → Maven package → delete + recreate the `latest` GitHub Release → upload `ldap-server.jar` as the release asset → Buildx image build → Docker Hub push (tag refs only). Secrets used: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, plus the default `GITHUB_TOKEN`.
