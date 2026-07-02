SHELL := /bin/bash
.DEFAULT_GOAL := help

# Make recipes run in `$(SHELL) -c '...'` sub-shells that do NOT source
# the user's shell rc files. Put mise's shims dir (and ~/.local/bin for
# any hand-installed tools) on PATH explicitly so every recipe resolves
# mise-managed binaries (java, mvn, act).
export PATH := $(HOME)/.local/share/mise/shims:$(HOME)/.local/bin:$(PATH)

APP_NAME           := ldap-server
CURRENTTAG         := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# === Docker image coordinates (mirror .env.example) ===
# Default registry: ghcr.io. DOCKER_LOGIN is your GitHub username; the
# canonical GHCR path for this project is
# `ghcr.io/<owner>/ldap-server/apacheds-ad` (repo-namespace) — set
# DOCKER_LOGIN=<owner>/ldap-server for a local `make image-push` that
# matches what CI publishes. The bare-namespace form
# `ghcr.io/<owner>/apacheds-ad` requires a PAT with `write:packages`
# scope (GITHUB_TOKEN cannot publish to user-namespace).
DOCKER_REGISTRY    ?= ghcr.io
DOCKER_LOGIN       ?=
IMAGE_NAME         ?= apacheds-ad
IMAGE_TAG          ?= latest
IMAGE_REF          := $(if $(DOCKER_LOGIN),$(DOCKER_LOGIN)/,)$(IMAGE_NAME):$(IMAGE_TAG)

# === Build + runtime tunables ===
JAR_PATH           ?= target/ldap-server.jar
LDIF_DIR           ?= target/classes/
LDAP_PORT          ?= 10389
LDAPS_PORT         ?=
BIND_ADDRESS       ?= 0.0.0.0

# Container-internal port (matches the Dockerfile's APP_INTERNAL_PORT ARG default).
# Override to bake a different default into the image at build time:
#   make image-build APP_INTERNAL_PORT=10399
APP_INTERNAL_PORT  ?= 10389

# PlantUML renderer image for `make diagrams` (renders the README C4 hero from
# docs/diagrams/*.puml). Deliberately NOT Renovate-tracked: this repo automerges
# on green CI, and a renderer bump the bot cannot re-render would fail the
# `diagrams-check` drift gate and sit as a permanently-RED automerge PR. Bump by
# hand, then `make diagrams` and commit the re-rendered PNG.
PLANTUML_VERSION   ?= 1.2024.8

DIAGRAM_DIR   := docs/diagrams
DIAGRAM_SRC   := $(wildcard $(DIAGRAM_DIR)/*.puml)
DIAGRAM_OUT   := $(patsubst $(DIAGRAM_DIR)/%.puml,$(DIAGRAM_DIR)/out/%.png,$(DIAGRAM_SRC))
# Version-stamped sentinel: its NAME encodes PLANTUML_VERSION, so a renderer
# bump invalidates this prereq and forces a full re-render — the drift gate
# alone can't catch "renderer bumped but PNG not regenerated". Gitignored.
DIAGRAM_STAMP := $(DIAGRAM_DIR)/out/.plantuml-$(PLANTUML_VERSION).stamp

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST) | tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-24s\033[0m - %s\n", $$1, $$2}'

#deps: @ Install Java + Maven via mise (reads .mise.toml)
deps:
	@if [ -z "$${CI:-}" ] && ! command -v mise >/dev/null 2>&1; then \
		echo "Installing mise (no root required, installs to ~/.local/bin)..."; \
		curl -fsSL https://mise.run | sh; \
		echo ""; \
		echo "mise installed. Activate it in your shell, then re-run 'make deps':"; \
		echo "  bash: echo 'eval \"\$$(~/.local/bin/mise activate bash)\"' >> ~/.bashrc"; \
		echo "  zsh:  echo 'eval \"\$$(~/.local/bin/mise activate zsh)\"'  >> ~/.zshrc"; \
		exit 0; \
	fi
	@if command -v mise >/dev/null 2>&1; then mise install --yes; fi
	@command -v java >/dev/null 2>&1 || { echo "Error: java not on PATH after 'mise install'. Activate mise in your shell."; exit 1; }
	@command -v mvn  >/dev/null 2>&1 || { echo "Error: mvn not on PATH after 'mise install'. Activate mise in your shell."; exit 1; }

#deps-check: @ Show installed toolchain
deps-check:
	@printf "  %-12s " "java:"; command -v java >/dev/null 2>&1 && java -version 2>&1 | head -1 || echo "NOT installed"
	@printf "  %-12s " "mvn:";  command -v mvn  >/dev/null 2>&1 && mvn --version | head -1 || echo "NOT installed"
	@printf "  %-12s " "docker:"; command -v docker >/dev/null 2>&1 && docker --version || echo "NOT installed"
	@printf "  %-12s " "mise:"; command -v mise >/dev/null 2>&1 && mise --version || echo "NOT installed"

# ---------------------------------------------------------------------------
# Toolchain alignment guards — Java + Maven majors are mirrored across
# `.mise.toml` (canonical) and `Dockerfile` (build/runtime base images).
# A hand-edit or Renovate split that desyncs them silently produces a stale
# image. These fast greppers fail the build before mvn/docker ever runs.
# ---------------------------------------------------------------------------

#check-java-alignment: @ Verify Java major matches across .mise.toml + Dockerfile
check-java-alignment:
	@set -e; \
	mise_major=$$(grep -oP '^java\s*=\s*"temurin-\K[0-9]+' .mise.toml); \
	build_major=$$(grep -oP 'FROM\s+maven:[0-9.]+-eclipse-temurin-\K[0-9]+' Dockerfile); \
	runtime_major=$$(grep -oP 'FROM\s+eclipse-temurin:\K[0-9]+' Dockerfile); \
	if [ "$$mise_major" != "$$build_major" ] || [ "$$mise_major" != "$$runtime_major" ]; then \
		echo "ERROR: Java major versions disagree:"; \
		printf "  %-22s %s\n" ".mise.toml (java)"          "$$mise_major"   \
		                       "Dockerfile (build base)"   "$$build_major"  \
		                       "Dockerfile (runtime base)" "$$runtime_major"; \
		exit 1; \
	fi

#check-maven-alignment: @ Verify Maven minor matches across .mise.toml + Dockerfile build stage
check-maven-alignment:
	@set -e; \
	mise_minor=$$(grep -oP '^maven\s*=\s*"\K[0-9]+\.[0-9]+' .mise.toml); \
	build_minor=$$(grep -oP 'FROM\s+maven:\K[0-9]+\.[0-9]+' Dockerfile); \
	if [ "$$mise_minor" != "$$build_minor" ]; then \
		echo "ERROR: Maven minor versions disagree:"; \
		printf "  %-22s %s\n" ".mise.toml (maven)"         "$$mise_minor" \
		                       "Dockerfile (build base)"   "$$build_minor"; \
		exit 1; \
	fi

#build: @ Compile source (no tests)
build: deps
	@mvn -B compile

#test: @ Run JUnit tests
test: deps
	@mvn -B test

#package: @ Build shaded runnable JAR ($(JAR_PATH))
package: deps
	@mvn -B clean package

#run-jar: @ Run server from the packaged JAR with the bundled LDIF
# Note: this recipe uses bash array syntax — `SHELL := /bin/bash` at the top of
# the Makefile is load-bearing. The `args+=(...)` form fails under POSIX /bin/sh.
run-jar: package
	@args=(-b "$(BIND_ADDRESS)" -p "$(LDAP_PORT)"); \
	if [ -n "$(LDAPS_PORT)" ]; then args+=(-sp "$(LDAPS_PORT)"); fi; \
	java -jar "$(JAR_PATH)" "$${args[@]}" "$(LDIF_DIR)"

#lint: @ Validate pom.xml + Dockerfile (hadolint) + shell-script executable-bit guard + diagram drift
lint: deps diagrams-check
	@mvn -B validate
	@# hadolint (pinned in .mise.toml, installed by `make deps`) lints the
	@# Dockerfile; intentional ignores live in .hadolint.yaml.
	@hadolint Dockerfile
	@# Safety check rule #8: any committed shell script must be +x or CI fails with exit 126.
	@NONEXEC=$$(find . -maxdepth 3 -name '*.sh' -not -executable -not -path './target/*' -not -path './.git/*' 2>/dev/null); \
	if [ -n "$$NONEXEC" ]; then \
		echo "Error: shell scripts missing +x bit:"; echo "$$NONEXEC" | sed 's/^/  /'; \
		exit 1; \
	fi
	@# Contract: the cve-check NVD-outage failure classifier must keep matching
	@# the real-world log shapes. Goes RED if either signature regex is broken.
	@./scripts/cve-check.sh --self-test

#diagrams: @ Render PlantUML C4 diagrams (docs/diagrams/*.puml) to committed PNGs
diagrams: $(DIAGRAM_OUT)

# Per-file render: only re-renders a PNG whose .puml (or the version stamp) changed.
# --user keeps output host-owned; HOME/_JAVA_OPTIONS avoid the user.home='?'
# font-cache footgun when the container UID has no /etc/passwd entry.
$(DIAGRAM_DIR)/out/%.png: $(DIAGRAM_DIR)/%.puml $(DIAGRAM_STAMP)
	@command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required for make diagrams"; exit 1; }
	docker run --rm -v "$(CURDIR)/$(DIAGRAM_DIR):/work" -w /work \
		--user $$(id -u):$$(id -g) \
		-e HOME=/tmp -e _JAVA_OPTIONS=-Duser.home=/tmp \
		plantuml/plantuml:$(PLANTUML_VERSION) \
		-tpng -o out $(notdir $<)

# The stamp's NAME encodes PLANTUML_VERSION; a bump makes the old stamp stop
# satisfying the prereq, so the render rule re-fires for every diagram.
$(DIAGRAM_STAMP):
	@mkdir -p $(DIAGRAM_DIR)/out
	@rm -f $(DIAGRAM_DIR)/out/.plantuml-*.stamp
	@touch $@

#diagrams-clean: @ Remove rendered diagram artefacts
diagrams-clean:
	rm -rf $(DIAGRAM_DIR)/out

#diagrams-check: @ Verify committed diagrams match current source (CI drift gate)
diagrams-check:
	@if [ -n "$${ACT:-}" ]; then echo "diagrams-check: skipped under act (docker-in-docker bind-mount path mismatch); runs on real CI."; exit 0; fi
	@$(MAKE) --no-print-directory diagrams
	@# Two-part gate. A bare `git diff --exit-code` misses UNTRACKED output (a new
	@# .puml whose rendered PNG was never `git add`ed passes green) — so we also
	@# check `git ls-files --others`. But `git status --porcelain` over-fires: it
	@# flags a legitimately STAGED-but-uncommitted render as dirty, which false-REDs
	@# the normal edit→render→add→`make ci`→commit flow (this gate runs inside the
	@# local `make ci`, not just CI). This decomposition avoids both:
	@#   (1) re-render MODIFIED a tracked PNG        -> stale committed output
	@#   (2) UNTRACKED output left behind            -> rendered-but-not-added
	@# A staged render that matches the fresh output is invisible to both -> passes.
	@if ! git diff --exit-code -- $(DIAGRAM_DIR)/out >/dev/null 2>&1; then \
		echo "ERROR: Committed diagram PNG is stale — re-render changed it. Run 'make diagrams' and commit."; \
		git --no-pager diff --stat -- $(DIAGRAM_DIR)/out; exit 1; \
	fi
	@UNTRACKED=$$(git ls-files --others --exclude-standard -- $(DIAGRAM_DIR)/out); \
	if [ -n "$$UNTRACKED" ]; then \
		echo "ERROR: Rendered diagram output is not committed/staged. Run 'make diagrams' and 'git add':"; \
		echo "$$UNTRACKED" | sed 's/^/  /'; exit 1; \
	fi
	@echo "diagrams-check: rendered output matches committed source."

#cve-check: @ OWASP dependency-check (Maven + transitive deps)
# Delegated to scripts/cve-check.sh, which:
#   * uses the fully-qualified `org.owasp:dependency-check-maven:check` coordinate
#     so the version pinned in pom.xml `<pluginManagement>` is the only source of
#     truth (no Makefile/CLI version literal to drift);
#   * writes NVD_API_KEY / OSS_INDEX_USER / OSS_INDEX_TOKEN into ~/.m2/settings.xml
#     (umask 077, printf builtin) and references them by server id — NEVER argv
#     (a value in argv leaks via `ps -ef` / /proc/<pid>/cmdline for the plugin's
#     whole lifetime);
#   * degrades gracefully on a transient NVD-API outage (HTTP 503): a failed NVD
#     *update* re-scans against the cached NVD DB (-DautoUpdate=false, still
#     blocking on CVSS>=7) with a warning, instead of reddening the build — while
#     a real CVE finding still fails. See the script header for the full rationale.
# Cold start downloads ~2GB NVD DB (~30-45 min); cached runs take 2-5 min.
cve-check: deps
	@./scripts/cve-check.sh

#clean: @ Remove Maven build artifacts
clean:
	@mvn -B clean -q

#require-docker: @ Fail fast if the Docker CLI is not on PATH (shared guard for image/e2e targets)
require-docker:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }

#image-build: @ Build the Docker image as $(IMAGE_REF) (multi-stage, from src/)
image-build: require-docker
	@DOCKER_BUILDKIT=1 docker build -f Dockerfile \
		--build-arg APP_INTERNAL_PORT=$(APP_INTERNAL_PORT) \
		-t "$(IMAGE_REF)" .

#image-run: @ Run the image, mounting $(LDIF_DIR) into /ldap/ldif/
image-run: require-docker
	@docker run -it --rm \
		-v "$$PWD/$(LDIF_DIR):/ldap/ldif/" \
		-p "$(LDAP_PORT):$(APP_INTERNAL_PORT)" \
		"$(IMAGE_REF)"

#image-smoke-test: @ Boot the image and wait for its HEALTHCHECK to report healthy
image-smoke-test: require-docker
	@set -eu; \
	CONTAINER=ldap-server-smoke; \
	docker rm -f "$$CONTAINER" >/dev/null 2>&1 || true; \
	trap 'docker rm -f "'"$$CONTAINER"'" >/dev/null 2>&1 || true' EXIT INT TERM; \
	docker run -d --name="$$CONTAINER" "$(IMAGE_REF)" >/dev/null; \
	echo "Waiting up to 90s for HEALTHCHECK to report healthy..."; \
	end=$$(( $$(date +%s) + 90 )); status=""; \
	while [ "$$(date +%s)" -lt "$$end" ]; do \
		status=$$(docker inspect -f '{{.State.Health.Status}}' "$$CONTAINER" 2>/dev/null || echo unknown); \
		if [ "$$status" = "healthy" ]; then \
			echo "PASS: $$CONTAINER reports healthy"; \
			exit 0; \
		fi; \
		if [ "$$(docker inspect -f '{{.State.Running}}' "$$CONTAINER" 2>/dev/null)" != "true" ]; then \
			echo "FAIL: $$CONTAINER exited before becoming healthy"; \
			docker logs "$$CONTAINER" 2>&1 | tail -30; \
			exit 1; \
		fi; \
		sleep 2; \
	done; \
	echo "FAIL: $$CONTAINER did not become healthy within 90s (last status: $$status)"; \
	docker logs "$$CONTAINER" 2>&1 | tail -30; \
	exit 1

#e2e: @ End-to-end: boot image + verify LDAP bind + search via the protocol
# Uses AuthenticateWithSearch from the SAME shaded JAR (built into $(IMAGE_REF))
# as the client — no external LDAP utility dependency. The shaded JAR ships
# both the server and the client test tool; we invoke `--entrypoint java` to
# override the server CMD and run the client class instead. Both containers
# attach to a temp network so the client can dial the server by container name.
e2e: require-docker
	@set -eu; \
	NET=ldap-server-e2e-net; \
	SERVER=ldap-server-e2e; \
	docker network create "$$NET" >/dev/null 2>&1 || true; \
	docker rm -f "$$SERVER" >/dev/null 2>&1 || true; \
	trap 'docker rm -f "'"$$SERVER"'" >/dev/null 2>&1 || true; docker network rm "'"$$NET"'" >/dev/null 2>&1 || true' EXIT INT TERM; \
	docker run -d --name="$$SERVER" --network="$$NET" \
		--entrypoint java \
		--health-cmd "nc -z localhost $(APP_INTERNAL_PORT)" \
		--health-interval=2s --health-timeout=2s --health-start-period=5s --health-retries=10 \
		"$(IMAGE_REF)" \
		-jar /ldap/ldap-server.jar -b 0.0.0.0 -p $(APP_INTERNAL_PORT) >/dev/null; \
	echo "Waiting up to 90s for $$SERVER HEALTHCHECK = healthy..."; \
	end=$$(( $$(date +%s) + 90 )); status=""; \
	while [ "$$(date +%s)" -lt "$$end" ]; do \
		status=$$(docker inspect -f '{{.State.Health.Status}}' "$$SERVER" 2>/dev/null || echo unknown); \
		[ "$$status" = "healthy" ] && break; \
		sleep 2; \
	done; \
	[ "$$status" = "healthy" ] || { echo "FAIL: $$SERVER not healthy within 90s"; docker logs "$$SERVER" 2>&1 | tail -30; exit 1; }; \
	echo "Running AuthenticateWithSearch against $$SERVER (correct password)..."; \
	docker run --rm --network="$$NET" --entrypoint java "$(IMAGE_REF)" \
		-cp /ldap/ldap-server.jar com.github.kwart.ldap.AuthenticateWithSearch \
		"ldap://$$SERVER:$(APP_INTERNAL_PORT)" jduke theduke \
		|| { echo "FAIL: AuthenticateWithSearch did not bind + search successfully"; docker logs "$$SERVER" 2>&1 | tail -30; exit 1; }; \
	echo "PASS: end-to-end LDAP bind + search against $$SERVER"; \
	echo "Running AuthenticateWithSearch against $$SERVER (WRONG password — expect rejection)..."; \
	if docker run --rm --network="$$NET" --entrypoint java "$(IMAGE_REF)" \
		-cp /ldap/ldap-server.jar com.github.kwart.ldap.AuthenticateWithSearch \
		"ldap://$$SERVER:$(APP_INTERNAL_PORT)" jduke wrong-password >/dev/null 2>&1; then \
		echo "FAIL: AuthenticateWithSearch unexpectedly SUCCEEDED with a wrong password"; docker logs "$$SERVER" 2>&1 | tail -30; exit 1; \
	fi; \
	echo "PASS: wrong-password bind correctly rejected (negative case)"

#docker-login: @ Log into $(DOCKER_REGISTRY) using DOCKER_LOGIN + $$DOCKER_PWD (from env or .env)
docker-login: require-docker
	@[ -n "$(DOCKER_LOGIN)" ] || { echo "Error: DOCKER_LOGIN must be set in env or .env."; exit 1; }
	@[ -n "$${DOCKER_PWD:-}" ] || { echo "Error: DOCKER_PWD must be set in the environment (NEVER on the command line)."; exit 1; }
	@printf '%s' "$$DOCKER_PWD" | docker login "$(DOCKER_REGISTRY)" --username "$(DOCKER_LOGIN)" --password-stdin

#image-push: @ Push $(IMAGE_REF) to $(DOCKER_REGISTRY) (run docker-login first if needed)
image-push: image-build
	@docker push "$(IMAGE_REF)"

#ci: @ Full local CI pipeline (alignment guards + lint + test + package)
ci: deps check-java-alignment check-maven-alignment lint test package
	@echo "Local CI pipeline passed."

#ci-run: @ Run the GitHub Actions workflow locally via act
# NOTE: act exercises the `changes`, `build`, and `ci-pass` jobs cleanly. The
# `release` job needs a real GitHub Releases API context and the `docker` job
# needs GHCR auth + a tag ref — neither is reachable under `act`.
# For tag-only paths, validate via a real push or `gh workflow run`.
ci-run: require-docker
	@command -v act >/dev/null 2>&1 || { echo "Error: act required. Install via https://github.com/nektos/act"; exit 1; }
	@docker container prune -f >/dev/null 2>&1 || true
	@# The build job runs `make ci` -> `mise install`, which now resolves an
	@# aqua tool (hadolint) via the GitHub API. Forward GITHUB_TOKEN (env-only
	@# `--secret KEY`, never `=value` — Safety rule #9) so the aqua lookup is
	@# authenticated under act and doesn't hit the unauthenticated 60-req/hr cap
	@# on a cold runner cache. Auto-derived from the gh CLI when unset.
	@if [ -z "$${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then \
		export GITHUB_TOKEN="$$(gh auth token 2>/dev/null)"; \
	fi; \
	ACT_PORT=$$(shuf -i 40000-59999 -n 1); \
	ARTIFACT_PATH=$$(mktemp -d -t act-artifacts.XXXXXX); \
	secret_args=(); [ -n "$${GITHUB_TOKEN:-}" ] && secret_args+=(--secret GITHUB_TOKEN); \
	act push --container-architecture linux/amd64 --pull=false \
		--artifact-server-port "$$ACT_PORT" \
		--artifact-server-path "$$ARTIFACT_PATH" \
		"$${secret_args[@]}"

#renovate-validate: @ Validate renovate.json against the live Renovate schema (npx --yes renovate@latest)
# `renovate@latest` (NOT bare `renovate`) avoids the npx-cache stale-binary
# trap where a months-old cached package rejects current-schema fields like
# `managerFilePatterns`. Uses the local-platform driver so no GitHub API
# credentials are strictly required — but exporting `GH_ACCESS_TOKEN`
# upgrades anonymous lookups to authenticated and avoids GitHub's 60-req/hr
# anonymous cap when chasing release notes / version metadata.
renovate-validate:
	@command -v npx >/dev/null 2>&1 || { echo "Error: npx (Node.js) required. Install Node 24+ via mise or the Node.js download page."; exit 1; }
	@if [ -n "$$GH_ACCESS_TOKEN" ]; then \
		export GITHUB_COM_TOKEN="$$GH_ACCESS_TOKEN"; \
	else \
		echo "Warning: GH_ACCESS_TOKEN not set; some dependency lookups may be rate-limited or fail"; \
	fi; \
		npx --yes renovate@latest --platform=local

.PHONY: help deps deps-check check-java-alignment check-maven-alignment \
	build test package run-jar lint diagrams diagrams-clean diagrams-check cve-check clean \
	require-docker image-build image-run image-smoke-test e2e docker-login image-push \
	ci ci-run renovate-validate
