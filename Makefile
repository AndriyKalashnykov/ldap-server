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
DOCKER_REGISTRY    ?= registry-1.docker.io
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

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST) | tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-22s\033[0m - %s\n", $$1, $$2}'

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

#lint: @ Validate pom.xml + shell-script executable-bit guard
lint: deps
	@mvn -B validate
	@# Safety check rule #8: any committed shell script must be +x or CI fails with exit 126.
	@NONEXEC=$$(find . -maxdepth 3 -name '*.sh' -not -executable -not -path './target/*' -not -path './.git/*' 2>/dev/null); \
	if [ -n "$$NONEXEC" ]; then \
		echo "Error: shell scripts missing +x bit:"; echo "$$NONEXEC" | sed 's/^/  /'; \
		exit 1; \
	fi

#cve-check: @ OWASP dependency-check (Maven + transitive deps)
# Uses the fully-qualified `org.owasp:dependency-check-maven:check` coordinate
# so the version pinned in pom.xml `<pluginManagement>` is the only source of
# truth (no Makefile/CLI version literal to drift). Cold start downloads
# ~2GB NVD DB (~30-45 min). Cached runs take 2-5 min.
#
# Optional NVD_API_KEY for higher NVD rate limit — routed through
# ~/.m2/settings.xml (via printf, a bash builtin) so the value never appears
# in argv. NEVER pass `-DnvdApiKey=$$NVD_API_KEY` directly — leaks via
# `ps -ef` / `/proc/<pid>/cmdline` for the entire ~30 min plugin lifetime.
cve-check: deps
	@if [ -n "$${NVD_API_KEY:-}" ]; then \
		mkdir -p "$$HOME/.m2"; \
		( umask 077 && printf '<settings><servers><server><id>nvd</id><password>%s</password></server></servers></settings>\n' "$$NVD_API_KEY" > "$$HOME/.m2/settings.xml" ); \
		mvn -B org.owasp:dependency-check-maven:check -DnvdApiServerId=nvd; \
	else \
		echo "Note: NVD_API_KEY not set — NVD lookups will be rate-limited."; \
		mvn -B org.owasp:dependency-check-maven:check; \
	fi

#clean: @ Remove Maven build artifacts
clean:
	@mvn -B clean -q

#image-build: @ Build the Docker image as $(IMAGE_REF) (multi-stage, from src/)
image-build:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }
	@DOCKER_BUILDKIT=1 docker build -f Dockerfile \
		--build-arg APP_INTERNAL_PORT=$(APP_INTERNAL_PORT) \
		-t "$(IMAGE_REF)" .

#image-run: @ Run the image, mounting $(LDIF_DIR) into /ldap/ldif/
image-run:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }
	@docker run -it --rm \
		-v "$$PWD/$(LDIF_DIR):/ldap/ldif/" \
		-p "$(LDAP_PORT):$(APP_INTERNAL_PORT)" \
		"$(IMAGE_REF)"

#image-smoke-test: @ Boot the image and wait for its HEALTHCHECK to report healthy
image-smoke-test:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }
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
e2e:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }
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
	echo "Running AuthenticateWithSearch against $$SERVER..."; \
	docker run --rm --network="$$NET" --entrypoint java "$(IMAGE_REF)" \
		-cp /ldap/ldap-server.jar com.github.kwart.ldap.AuthenticateWithSearch \
		"ldap://$$SERVER:$(APP_INTERNAL_PORT)" jduke theduke \
		|| { echo "FAIL: AuthenticateWithSearch did not bind + search successfully"; docker logs "$$SERVER" 2>&1 | tail -30; exit 1; }; \
	echo "PASS: end-to-end LDAP bind + search against $$SERVER"

#docker-login: @ Log into $(DOCKER_REGISTRY) using DOCKER_LOGIN + $$DOCKER_PWD (from env or .env)
docker-login:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }
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
# needs Docker Hub credentials + a tag ref — neither is reachable under `act`.
# For tag-only paths, validate via a real push or `gh workflow run`.
ci-run:
	@command -v act >/dev/null 2>&1 || { echo "Error: act required. Install via https://github.com/nektos/act"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }
	@docker container prune -f >/dev/null 2>&1 || true
	@ACT_PORT=$$(shuf -i 40000-59999 -n 1); \
	ARTIFACT_PATH=$$(mktemp -d -t act-artifacts.XXXXXX); \
	act push --container-architecture linux/amd64 --pull=false \
		--artifact-server-port "$$ACT_PORT" \
		--artifact-server-path "$$ARTIFACT_PATH"

.PHONY: help deps deps-check check-java-alignment check-maven-alignment \
	build test package run-jar lint cve-check clean \
	image-build image-run image-smoke-test e2e docker-login image-push ci ci-run
