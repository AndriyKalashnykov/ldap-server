# AGENTS.md

This file provides guidance to AI assistants when working with code in this repository.

## Project overview

Single-JAR, in-memory LDAP server built on top of ApacheDS 2.0.0-M24, intended for testing. The shaded jar (`target/ldap-server.jar`) is fully self-contained; data lives only in memory and is wiped on restart.

## Build & test

- Build the shaded jar: `mvn clean package` → produces `target/ldap-server.jar` (uberjar via `maven-shade-plugin`).
- Run all tests: `mvn test`
- Run a single test class: `mvn test -Dtest=LdapServerTest`
- Run a single parameterized test method: `mvn test -Dtest=LdapServerTest#test`
- Run the server from sources: `mvn exec:java` (main class is `com.github.kwart.ldap.LdapServer`, configured via `exec.mainClass` property).
- Run the built jar: `java -jar target/ldap-server.jar [options] [LDIFs...]` — see `--help` for full CLI.
- Release: `mvn -Prelease release:prepare && mvn -Prelease release:perform`. The `release` profile activates GPG signing, source/javadoc jars, the Sonatype `nexus-staging-maven-plugin`, and an enforcer rule that **requires Java 8** (`[1.8,1.9)`).

The project targets Java 1.8 source/target. Don't bump bytecode level without coordinating with the release-profile enforcer rule.

## Architecture

The runtime wiring is small enough to hold in your head, but the ApacheDS plumbing is opaque — these are the pieces worth knowing before changing anything:

- **`LdapServer`** (`src/main/java/.../LdapServer.java`) is both the CLI entry point and the orchestrator. `main` parses args via `ExtCommander` (a JCommander wrapper that adds `setUsageHead`/`setUsageTail` for help-text customization), then constructs `LdapServer(CLIArguments)`. The constructor: builds the `DirectoryService` via `InMemoryDirectoryServiceFactory`, imports LDIFs (default or user-supplied), optionally rewrites the `uid=admin,ou=system` password, then starts ApacheDS' `LdapServer` with one or two `TcpTransport`s (plain + ldaps).

- **`InMemoryDirectoryServiceFactory`** is the heart of the in-memory behavior. It uses `AvlPartitionFactory` (AVL = in-memory tree partitions, no disk persistence), wires an EhCache configured to be effectively a no-op (30s TTL, no overflow-to-disk), loads schemas via `JarLdifSchemaLoader`, and installs **`InMemorySchemaPartition`** as the wrapped schema partition. The instance layout still points at `${java.io.tmpdir}/server-work-<name>` and that directory is deleted at startup — it's a leftover skeleton, not real persistence.

- **LDIF import** in `LdapServer.importLdif` has a deliberate workaround: when reading user-supplied LDIFs it overrides `LdifReader.parseEntry` to reset `containsChanges`/`containsEntries` between entries. This works around an ApacheDS limitation where files mixing change records and plain entries fail to parse. If you touch this method, the corresponding regression is exercised by `src/test/resources/modify_new_entries.ldif`.

- **Dynamic partition creation**: `checkPartition` inspects each LDIF entry's parent DN and, if it doesn't exist, registers a new `AvlPartition` rooted at that entry's DN. This is what lets users import LDIFs with arbitrary suffixes without pre-configuring partitions — but it means the suffix of the *first* entry per branch silently becomes a partition root.

- **Default data**: `src/main/resources/ldap-example.ldif` defines the `dc=ldap,dc=example` partition with `uid=jduke` (password `theduke`) and an `Admin` group. Tests rely on these exact values.

- **Auxiliary main classes**: `Authenticate` (simple bind) and `AuthenticateWithSearch` (admin-bind → search by uid → user-bind) are utility entry points shipped in the same jar. They're not wired into the manifest's `Main-Class` but can be invoked via `java -cp ldap-server.jar com.github.kwart.ldap.Authenticate ...`.

- **`CountLookupInterceptor`** exists but is intentionally not registered (commented out in `LdapServer` constructor). It's a debug aid for counting lookups.

## Test conventions

JUnit 4 with `@RunWith(Parameterized.class)` is used to run the same scenario across `{ipv6, tls}` combinations (see `LdapServerTest`). Each test starts a real LDAP server on `10389` (and `10636` for TLS variants) and connects via JNDI — there are no mocks. Tests bind to all interfaces by default, so port conflicts will manifest as test failures rather than skips.

## Docker

`Dockerfile` uses `gcr.io/distroless/java:8`, copies `target/ldap-server.jar`, and exposes 389/636 with anonymous bind enabled (`-a`). It depends on the jar being built first — `mvn package` before `docker build`.
