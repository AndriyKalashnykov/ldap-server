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
#   make docker-build APP_INTERNAL_PORT=10399
APP_INTERNAL_PORT  ?= 10389

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST) | tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-18s\033[0m - %s\n", $$1, $$2}'

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
run-jar: package
	@args=(-b "$(BIND_ADDRESS)" -p "$(LDAP_PORT)"); \
	if [ -n "$(LDAPS_PORT)" ]; then args+=(-sp "$(LDAPS_PORT)"); fi; \
	java -jar "$(JAR_PATH)" "$${args[@]}" "$(LDIF_DIR)"

#lint: @ Validate pom.xml (heavier checks land in /project-review)
lint: deps
	@mvn -B validate

#clean: @ Remove Maven build artifacts
clean:
	@mvn -B clean -q

#docker-build: @ Build the Docker image as $(IMAGE_REF) (multi-stage, from src/)
docker-build:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }
	@DOCKER_BUILDKIT=1 docker build -f Dockerfile \
		--build-arg APP_INTERNAL_PORT=$(APP_INTERNAL_PORT) \
		-t "$(IMAGE_REF)" .

#docker-run: @ Run the image, mounting $(LDIF_DIR) into /ldap/ldif/
docker-run:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }
	@docker run -it --rm \
		-v "$$PWD/$(LDIF_DIR):/ldap/ldif/" \
		-p "$(LDAP_PORT):$(APP_INTERNAL_PORT)" \
		"$(IMAGE_REF)"

#docker-smoke-test: @ Boot the image and wait for its HEALTHCHECK to report healthy
docker-smoke-test:
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

#docker-login: @ Log into $(DOCKER_REGISTRY) using DOCKER_LOGIN + $$DOCKER_PWD (from env or .env)
docker-login:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }
	@[ -n "$(DOCKER_LOGIN)" ] || { echo "Error: DOCKER_LOGIN must be set in env or .env."; exit 1; }
	@[ -n "$${DOCKER_PWD:-}" ] || { echo "Error: DOCKER_PWD must be set in the environment (NEVER on the command line)."; exit 1; }
	@printf '%s' "$$DOCKER_PWD" | docker login "$(DOCKER_REGISTRY)" --username "$(DOCKER_LOGIN)" --password-stdin

#docker-push: @ Push $(IMAGE_REF) to $(DOCKER_REGISTRY) (run docker-login first if needed)
docker-push: docker-build
	@docker push "$(IMAGE_REF)"

#ci: @ Full local CI pipeline
ci: deps lint test package
	@echo "Local CI pipeline passed."

#ci-run: @ Run the GitHub Actions workflow locally via act
ci-run:
	@command -v act >/dev/null 2>&1 || { echo "Error: act required. Install via https://github.com/nektos/act"; exit 1; }
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker required."; exit 1; }
	@docker container prune -f >/dev/null 2>&1 || true
	@ACT_PORT=$$(shuf -i 40000-59999 -n 1); \
	ARTIFACT_PATH=$$(mktemp -d -t act-artifacts.XXXXXX); \
	act push --container-architecture linux/amd64 --pull=false \
		--artifact-server-port "$$ACT_PORT" \
		--artifact-server-path "$$ARTIFACT_PATH"

.PHONY: help deps deps-check build test package run-jar lint clean \
	docker-build docker-run docker-smoke-test docker-login docker-push ci ci-run
