
VERSION_PINS_FILE ?= versions.env
-include $(VERSION_PINS_FILE)

IMAGE_NAME := ghcr.io/thevibeworks/deva
TAG := latest
RUST_TAG := rust
CORE_TAG := core
DOCKERFILE := Dockerfile
RUST_DOCKERFILE := Dockerfile.rust
MULTI_ARCH_PLATFORMS := linux/amd64,linux/arm64
MAIN_IMAGE := $(IMAGE_NAME):$(TAG)
RUST_IMAGE := $(IMAGE_NAME):$(RUST_TAG)
CORE_IMAGE := $(IMAGE_NAME):$(CORE_TAG)
CONTAINER_NAME := deva-$(shell basename $(PWD))-$(shell date +%s)

# Smart image detection: auto-detect available image for version checking
# Prefers rust (superset of base) then falls back to latest
DETECTED_IMAGE := $(shell \
	if docker image inspect $(IMAGE_NAME):$(RUST_TAG) >/dev/null 2>&1; then \
		echo "$(IMAGE_NAME):$(RUST_TAG)"; \
	elif docker image inspect $(IMAGE_NAME):$(TAG) >/dev/null 2>&1; then \
		echo "$(IMAGE_NAME):$(TAG)"; \
	else \
		echo "$(IMAGE_NAME):$(TAG)"; \
	fi)
NODE_MAJOR ?= 22
GO_VERSION ?= 1.26.2
PYTHON_VERSION ?= 3.14t
DELTA_VERSION ?= 0.19.2
TMUX_VERSION ?= 3.6a
TMUX_SHA256 ?= b6d8d9c76585db8ef5fa00d4931902fa4b8cbe8166f528f44fc403961a3f3759
CLAUDE_CODE_VERSION ?= 2.1.116
CLAUDE_TRACE_VERSION ?= 1.0.9
CODEX_VERSION ?= 0.122.0
GEMINI_CLI_VERSION ?= 0.38.2
ATLAS_CLI_VERSION ?= v0.1.4
COPILOT_API_VERSION ?= 0ea08febdd7e3e055b03dd298bf57e669500b5c1
PLAYWRIGHT_VERSION ?= 1.59.1
RUST_TOOLCHAINS ?= stable
RUST_DEFAULT_TOOLCHAIN ?= stable
RUST_TARGETS ?= wasm32-unknown-unknown

TOOLCHAIN_BUILD_ARGS := \
	--build-arg NODE_MAJOR=$(NODE_MAJOR) \
	--build-arg GO_VERSION=$(GO_VERSION) \
	--build-arg PYTHON_VERSION=$(PYTHON_VERSION) \
	--build-arg DELTA_VERSION=$(DELTA_VERSION) \
	--build-arg TMUX_VERSION=$(TMUX_VERSION) \
	--build-arg TMUX_SHA256=$(TMUX_SHA256)

CORE_BUILD_ARGS := $(TOOLCHAIN_BUILD_ARGS) \
	--build-arg COPILOT_API_VERSION=$(COPILOT_API_VERSION)

AGENT_BUILD_ARGS := \
	--build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) \
	--build-arg CLAUDE_TRACE_VERSION=$(CLAUDE_TRACE_VERSION) \
	--build-arg CODEX_VERSION=$(CODEX_VERSION) \
	--build-arg GEMINI_CLI_VERSION=$(GEMINI_CLI_VERSION) \
	--build-arg ATLAS_CLI_VERSION=$(ATLAS_CLI_VERSION)

MAIN_BUILD_ARGS := $(TOOLCHAIN_BUILD_ARGS) $(AGENT_BUILD_ARGS) \
	--build-arg COPILOT_API_VERSION=$(COPILOT_API_VERSION)

RUST_BUILD_ARGS := $(AGENT_BUILD_ARGS) \
	--build-arg PLAYWRIGHT_VERSION=$(PLAYWRIGHT_VERSION) \
	--build-arg RUST_TOOLCHAINS=$(RUST_TOOLCHAINS) \
	--build-arg RUST_DEFAULT_TOOLCHAIN=$(RUST_DEFAULT_TOOLCHAIN) \
	--build-arg RUST_TARGETS=$(RUST_TARGETS)

VERSION_QUERY_OVERRIDES := \
	$(if $(filter command line environment environment\ override override,$(origin NODE_MAJOR)),NODE_MAJOR=$(NODE_MAJOR)) \
	$(if $(filter command line environment environment\ override override,$(origin GO_VERSION)),GO_VERSION=$(GO_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin PYTHON_VERSION)),PYTHON_VERSION=$(PYTHON_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin DELTA_VERSION)),DELTA_VERSION=$(DELTA_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin TMUX_VERSION)),TMUX_VERSION=$(TMUX_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin TMUX_SHA256)),TMUX_SHA256=$(TMUX_SHA256)) \
	$(if $(filter command line environment environment\ override override,$(origin CLAUDE_CODE_VERSION)),CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin CLAUDE_TRACE_VERSION)),CLAUDE_TRACE_VERSION=$(CLAUDE_TRACE_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin CODEX_VERSION)),CODEX_VERSION=$(CODEX_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin GEMINI_CLI_VERSION)),GEMINI_CLI_VERSION=$(GEMINI_CLI_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin ATLAS_CLI_VERSION)),ATLAS_CLI_VERSION=$(ATLAS_CLI_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin COPILOT_API_VERSION)),COPILOT_API_VERSION=$(COPILOT_API_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin PLAYWRIGHT_VERSION)),PLAYWRIGHT_VERSION=$(PLAYWRIGHT_VERSION)) \
	$(if $(filter command line environment environment\ override override,$(origin RUST_TOOLCHAINS)),RUST_TOOLCHAINS=$(RUST_TOOLCHAINS)) \
	$(if $(filter command line environment environment\ override override,$(origin RUST_DEFAULT_TOOLCHAIN)),RUST_DEFAULT_TOOLCHAIN=$(RUST_DEFAULT_TOOLCHAIN)) \
	$(if $(filter command line environment environment\ override override,$(origin RUST_TARGETS)),RUST_TARGETS=$(RUST_TARGETS))

export DOCKER_BUILDKIT := 1
export VERSION_PINS_FILE

.DEFAULT_GOAL := help

.PHONY: build build-main rebuild build-core build-rust-image build-rust build-all
.PHONY: buildx buildx-multi buildx-multi-rust buildx-multi-local
.PHONY: versions-up versions versions-pin toolchains scripts commands clean clean-all shell test test-rust test-local
.PHONY: info push pull build-test dev context-size lint version-check
.PHONY: release-patch release-minor release-major help

build: build-all

build-main:
	@echo "🔨 Building Docker image with $(DOCKERFILE)..."
	@if [ -f "$(VERSION_PINS_FILE)" ]; then \
		echo "📌 Using shared defaults from $(VERSION_PINS_FILE)"; \
	else \
		echo "ℹ $(VERSION_PINS_FILE) not found; using Makefile fallbacks"; \
	fi
	@# Inspect existing image labels; print direct diff lines
	@prev_claude=$$(docker inspect --format='{{ index .Config.Labels "org.opencontainers.image.claude_code_version" }}' $(MAIN_IMAGE) 2>/dev/null || true); \
	 prev_codex=$$(docker inspect --format='{{ index .Config.Labels "org.opencontainers.image.codex_version" }}' $(MAIN_IMAGE) 2>/dev/null || true); \
	 prev_gemini=$$(docker inspect --format='{{ index .Config.Labels "org.opencontainers.image.gemini_cli_version" }}' $(MAIN_IMAGE) 2>/dev/null || true); \
	 fmt() { v="$$1"; if [ -z "$$v" ] || [ "$$v" = "<no value>" ]; then echo "-"; else case "$$v" in v*) echo "$$v";; *) echo "v$$v";; esac; fi; }; \
	 curC=$$(fmt "$$prev_claude"); curX=$$(fmt "$$prev_codex"); curG=$$(fmt "$$prev_gemini"); \
	 tgtC=$$(fmt "$(CLAUDE_CODE_VERSION)"); tgtX=$$(fmt "$(CODEX_VERSION)"); tgtG=$$(fmt "$(GEMINI_CLI_VERSION)"); \
		 if [ "$$curC" = "$$tgtC" ] && [ "$$curX" = "$$tgtX" ] && [ "$$curG" = "$$tgtG" ]; then \
		   echo "Claude: $$tgtC (no change)"; \
		   echo "Codex:  $$tgtX (no change)"; \
		   echo "Gemini: $$tgtG (no change)"; \
		   echo "Already up-to-date"; \
		 else \
		   if [ "$$curC" = "$$tgtC" ]; then \
		     echo "Claude: $$tgtC (no change)"; \
		   else \
		     echo "Claude: $$curC -> $$tgtC"; \
		   fi; \
		   if [ "$$curX" = "$$tgtX" ]; then \
		     echo "Codex:  $$tgtX (no change)"; \
		   else \
		     echo "Codex:  $$curX -> $$tgtX"; \
		   fi; \
		   if [ "$$curG" = "$$tgtG" ]; then \
		     echo "Gemini: $$tgtG (no change)"; \
		   else \
		     echo "Gemini: $$curG -> $$tgtG"; \
		   fi; \
		 fi
	@echo "Hint: override via GO_VERSION=... CLAUDE_CODE_VERSION=... or run 'make versions-pin'"
	docker build -f $(DOCKERFILE) $(MAIN_BUILD_ARGS) -t $(MAIN_IMAGE) .
	@echo "✅ Build completed: $(MAIN_IMAGE)"

rebuild:
	@echo "🔨 Rebuilding Docker image (no cache) with $(DOCKERFILE)..."
	docker build -f $(DOCKERFILE) --no-cache $(MAIN_BUILD_ARGS) -t $(MAIN_IMAGE) .
	@echo "✅ Rebuild completed: $(MAIN_IMAGE)"


build-core:
	@echo "🔨 Building stable core image..."
	docker build -f $(DOCKERFILE) --target agent-base $(CORE_BUILD_ARGS) -t $(CORE_IMAGE) .
	@echo "✅ Core build completed: $(CORE_IMAGE)"

build-rust-image:
	@echo "🔨 Building Rust Docker image..."
	docker build -f $(RUST_DOCKERFILE) \
		--build-arg BASE_IMAGE=$(CORE_IMAGE) \
		$(RUST_BUILD_ARGS) \
		-t $(RUST_IMAGE) .
	@echo "✅ Rust build completed: $(RUST_IMAGE)"

build-rust: build-core build-rust-image

build-all:
	@echo "🔨 Building all images with pins from $(VERSION_PINS_FILE)..."
	@$(MAKE) build-core
	@$(MAKE) build-main
	@$(MAKE) build-rust-image
	@echo "✅ All images built successfully"

buildx:
	@echo "🔨 Building with docker buildx..."
	docker buildx build -f $(DOCKERFILE) --load $(MAIN_BUILD_ARGS) -t $(MAIN_IMAGE) .
	@echo "✅ Buildx completed: $(MAIN_IMAGE)"

buildx-multi:
	@echo "🔨 Building multi-arch images for amd64 and arm64..."
	docker buildx build -f $(DOCKERFILE) --platform $(MULTI_ARCH_PLATFORMS) \
		$(MAIN_BUILD_ARGS) \
		--push -t $(MAIN_IMAGE) .
	@echo "✅ Multi-arch build completed and pushed: $(MAIN_IMAGE)"

buildx-multi-rust:
	@echo "🔨 Building multi-arch Rust images for amd64 and arm64..."
	docker buildx build -f $(RUST_DOCKERFILE) --platform $(MULTI_ARCH_PLATFORMS) \
		--build-arg BASE_IMAGE=$(MAIN_IMAGE) \
		$(RUST_BUILD_ARGS) \
		--push -t $(RUST_IMAGE) .
	@echo "✅ Multi-arch Rust build completed and pushed: $(RUST_IMAGE)"

buildx-multi-local:
	@echo "🔨 Building multi-arch images locally..."
	docker buildx build -f $(DOCKERFILE) --platform $(MULTI_ARCH_PLATFORMS) \
		$(MAIN_BUILD_ARGS) \
		-t $(MAIN_IMAGE) .
	@echo "✅ Multi-arch build completed locally: $(MAIN_IMAGE)"

versions-up:
	@MAIN_IMAGE=$(DETECTED_IMAGE) \
	 BUILD_IMAGE=$(MAIN_IMAGE) \
	 RUST_IMAGE=$(RUST_IMAGE) \
	 DOCKERFILE=$(DOCKERFILE) \
	 RUST_DOCKERFILE=$(RUST_DOCKERFILE) \
	 $(VERSION_QUERY_OVERRIDES) \
	 ./scripts/version-upgrade.sh

versions:
	@$(VERSION_QUERY_OVERRIDES) \
	 MAIN_IMAGE=$(DETECTED_IMAGE) \
	 ./scripts/version-report.sh

versions-pin:
	@bash ./scripts/update-version-pins.sh
	@echo "✅ Updated $(VERSION_PINS_FILE)"

toolchains:
	@bash ./scripts/toolchain-report.sh

scripts:
	@bash ./scripts/list-scripts.sh

commands: help

clean:
	@echo "🧹 Aggressive Docker cleanup..."
	@echo "Removing project images..."
	-docker rmi $(MAIN_IMAGE) 2>/dev/null || true
	-docker rmi $(RUST_IMAGE) 2>/dev/null || true
	-docker rmi $(CORE_IMAGE) 2>/dev/null || true
	@echo "Pruning stopped containers..."
	-docker container prune -f
	@echo "Pruning unused images..."
	-docker image prune -f
	@echo "Pruning unused networks..."
	-docker network prune -f
	@echo "Pruning build cache..."
	-docker builder prune -f
	@echo "✅ Cleanup completed"

clean-all:
	@echo "🧹 NUCLEAR: Removing ALL unused Docker resources..."
	@echo "WARNING: This will remove ALL unused containers, images, networks, and volumes"
	@echo "Press Ctrl+C within 3 seconds to cancel..."
	@sleep 3
	@echo "Removing project images..."
	-docker rmi $(MAIN_IMAGE) 2>/dev/null || true
	-docker rmi $(RUST_IMAGE) 2>/dev/null || true
	-docker rmi $(CORE_IMAGE) 2>/dev/null || true
	@echo "Removing ALL stopped containers..."
	-docker container prune -af
	@echo "Removing ALL dangling and unused images..."
	-docker image prune -af
	@echo "Removing ALL unused networks..."
	-docker network prune -f
	@echo "Removing ALL unused volumes..."
	-docker volume prune -af
	@echo "Removing ALL build cache..."
	-docker builder prune -af
	@echo "Final system prune..."
	-docker system prune -af --volumes
	@df -h | grep -E '(Filesystem|/var/lib/docker|overlay)' 2>/dev/null || echo "Docker storage info not available"
	@echo "✅ Nuclear cleanup completed"

shell:
	@echo "🐚 Opening shell in $(MAIN_IMAGE)..."
	docker run --rm -it \
		-v $(PWD):$(PWD) \
		-w $(PWD) \
		--name $(CONTAINER_NAME) \
		$(MAIN_IMAGE) /bin/zsh

test:
	@echo "🧪 Testing $(MAIN_IMAGE)..."
	@echo "Testing claude command..."
	docker run --rm $(MAIN_IMAGE) claude --version
	@echo "Testing development tools..."
	docker run --rm $(MAIN_IMAGE) bash -c 'python --version && node --version && go version'
	@echo "✅ All tests passed"

test-rust:
	@echo "🧪 Testing $(RUST_IMAGE)..."
	@echo "Testing Rust toolchain..."
	docker run --rm $(RUST_IMAGE) bash -c 'rustc --version && cargo --version && rustfmt --version && clippy-driver --version'
	@echo "Testing Rust tools..."
	docker run --rm $(RUST_IMAGE) bash -c 'cargo-watch --version && wasm-pack --version'
	@echo "✅ Rust tests passed"

test-local:
	@echo "🧪 Testing $(MAIN_IMAGE) with local directory..."
	docker run --rm -it \
		-v $(PWD):$(PWD) \
		-w $(PWD) \
		$(MAIN_IMAGE) bash -c 'pwd && ls -la && claude --version'

info:
	@echo "📊 Image information for $(MAIN_IMAGE):"
	@docker images $(MAIN_IMAGE) --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
	@echo ""
	@echo "🔍 Image layers:"
	@docker history $(MAIN_IMAGE) --no-trunc

push:
	@echo "📤 Pushing $(MAIN_IMAGE) to registry..."
	docker push $(MAIN_IMAGE)
	@echo "✅ Push completed"

pull:
	@echo "📥 Pulling $(MAIN_IMAGE) from registry..."
	docker pull $(MAIN_IMAGE)
	@echo "✅ Pull completed"

build-test: build test
	@echo "✅ Build and test completed successfully"

dev: build shell

context-size:
	@echo "📏 Build context size:"
	@du -sh . --exclude='.git' --exclude='node_modules' --exclude='.claude-trace'

lint:
	@echo "🔍 Linting Dockerfile..."
	@if command -v hadolint >/dev/null 2>&1; then \
		hadolint Dockerfile; \
		echo "✅ Dockerfile linting completed"; \
	else \
		echo "⚠️  hadolint not found. Install with: brew install hadolint"; \
		echo "   Or run in Docker: docker run --rm -i hadolint/hadolint < Dockerfile"; \
	fi

version-check:
	@./scripts/version-check.sh

release-patch:
	@./deva.sh claude -Q -- -p "Execute release workflow from @workflows/RELEASE.md for a **patch** release"

release-minor:
	@./deva.sh claude -Q -- -p "Execute release workflow from @workflows/RELEASE.md for a **minor** release"

release-major:
	@./deva.sh claude -Q -- -p "Execute release workflow from @workflows/RELEASE.md for a **major** release"

help:
	@echo "deva.sh - Docker Build Shortcuts"
	@echo "==============================="
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available targets:"
	@echo "  build                Build all images with pinned Makefile defaults"
	@echo "  build-core           Build stable core image only"
	@echo "  build-main           Build main Docker image only"
	@echo "  build-rust           Build Rust Docker image"
	@echo "  build-all            Build all images (main + rust)"
	@echo "  rebuild              Rebuild without cache"
	@echo "  buildx               Build with buildx"
	@echo "  buildx-multi         Build multi-arch and push"
	@echo "  buildx-multi-rust    Build multi-arch Rust and push"
	@echo "  toolchains           List pinned toolchains and managed build tools"
	@echo "  versions             Compare built vs latest versions with changelogs"
	@echo "  versions-up          Build both images with latest upstream agent versions"
	@echo "  versions-pin         Refresh $(VERSION_PINS_FILE) from upstream"
	@echo "  scripts              List repo helper scripts"
	@echo "  commands             Alias for help"
	@echo "  test                 Test main image"
	@echo "  test-rust            Test Rust image"
	@echo "  shell                Open shell in container"
	@echo "  clean                Aggressive cleanup (unused containers/images/networks/cache)"
	@echo "  clean-all            NUCLEAR cleanup (ALL unused Docker resources + volumes)"
	@echo "  push                 Push image to registry"
	@echo "  pull                 Pull image from registry"
	@echo "  info                 Show image information"
	@echo "  lint                 Lint Dockerfile"
	@echo ""
	@echo "Environment variables:"
	@echo "  IMAGE_NAME           Main image name (default: $(IMAGE_NAME))"
	@echo "  TAG                  Docker image tag (default: $(TAG))"
	@echo "  RUST_TAG             Rust image tag (default: $(RUST_TAG))"
	@echo "  CORE_TAG             Stable core image tag (default: $(CORE_TAG))"
	@echo "  DOCKERFILE           Dockerfile to use (default: $(DOCKERFILE))"
	@echo "  RUST_DOCKERFILE      Rust Dockerfile path (default: $(RUST_DOCKERFILE))"
	@echo "  VERSION_PINS_FILE    Shared pin file (default: $(VERSION_PINS_FILE))"
	@echo "  NODE_MAJOR           Node major line (default: $(NODE_MAJOR))"
	@echo "  GO_VERSION           Go toolchain version (default: $(GO_VERSION))"
	@echo "  PYTHON_VERSION       Python toolchain version (default: $(PYTHON_VERSION))"
	@echo "  DELTA_VERSION        delta version (default: $(DELTA_VERSION))"
	@echo "  TMUX_VERSION         tmux version (default: $(TMUX_VERSION))"
	@echo "  CLAUDE_CODE_VERSION  Claude CLI version (default: $(CLAUDE_CODE_VERSION))"
	@echo "  CLAUDE_TRACE_VERSION Claude trace version (default: $(CLAUDE_TRACE_VERSION))"
	@echo "  CODEX_VERSION        Codex CLI version (default: $(CODEX_VERSION))"
	@echo "  GEMINI_CLI_VERSION   Gemini CLI version (default: $(GEMINI_CLI_VERSION))"
	@echo "  ATLAS_CLI_VERSION    Atlas CLI version (default: $(ATLAS_CLI_VERSION))"
	@echo "  PLAYWRIGHT_VERSION   Playwright version (default: $(PLAYWRIGHT_VERSION))"
	@echo "  RUST_TOOLCHAINS      Rust toolchains to install (default: $(RUST_TOOLCHAINS))"
	@echo "  RUST_DEFAULT_TOOLCHAIN Rust default toolchain (default: $(RUST_DEFAULT_TOOLCHAIN))"
	@echo ""
	@echo "Examples:"
	@echo "  make build                                    # Build all images with pinned versions"
	@echo "  make build-core                               # Build stable core image only"
	@echo "  make build-main                               # Build main image only"
	@echo "  make build-rust                               # Build Rust image only"
	@echo "  make TAG=dev build                            # Build all with custom tag"
	@echo "  make CLAUDE_CODE_VERSION=2.0.5 build          # Override with specific version"
	@echo "  make GEMINI_CLI_VERSION=0.18.0 build          # Override gemini version"
	@echo "  make ATLAS_CLI_VERSION=5f6a20c build          # Pin atlas-cli to specific commit"
	@echo "  make GO_VERSION=1.26.2 build                  # Override Go pin"
	@echo "  make toolchains                               # Show pinned toolchain inventory"
	@echo "  make scripts                                  # List helper scripts"
	@echo "  make versions-pin                             # Refresh shared pin file"
	@echo "  make versions                                 # Check current versions"
	@echo "  make PLAYWRIGHT_VERSION=1.59.1 build-rust     # Override rust browser tooling"
	@echo "  make versions-up                              # Upgrade to latest upstream versions"
