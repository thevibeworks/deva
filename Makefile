
IMAGE_NAME := ghcr.io/thevibeworks/deva
TAG := latest
RUST_TAG := rust
DOCKERFILE := Dockerfile
RUST_DOCKERFILE := Dockerfile.rust
MAIN_IMAGE := $(IMAGE_NAME):$(TAG)
RUST_IMAGE := $(IMAGE_NAME):$(RUST_TAG)
CONTAINER_NAME := deva-$(shell basename $(PWD))-$(shell date +%s)
CLAUDE_CODE_VERSION := $(shell npm view @anthropic-ai/claude-code version 2>/dev/null || echo "2.0.1")
CODEX_VERSION := $(shell npm view @openai/codex version 2>/dev/null || echo "0.42.0")

export DOCKER_BUILDKIT := 1

.DEFAULT_GOAL := help

.PHONY: build
build: build-all

.PHONY: build-main
build-main:
	@echo "🔨 Building Docker image with $(DOCKERFILE)..."
	@if command -v npm >/dev/null 2>&1; then \
		echo "🔎 Resolving latest versions from npm..."; \
	else \
		echo "ℹ npm not found; using defaults/fallbacks"; \
	fi
	@# Inspect existing image labels; print direct diff lines
	@prev_claude=$$(docker inspect --format='{{ index .Config.Labels "org.opencontainers.image.claude_code_version" }}' $(MAIN_IMAGE) 2>/dev/null || true); \
	 prev_codex=$$(docker inspect --format='{{ index .Config.Labels "org.opencontainers.image.codex_version" }}' $(MAIN_IMAGE) 2>/dev/null || true); \
	 fmt() { v="$$1"; if [ -z "$$v" ] || [ "$$v" = "<no value>" ]; then echo "-"; else case "$$v" in v*) echo "$$v";; *) echo "v$$v";; esac; fi; }; \
	 curC=$$(fmt "$$prev_claude"); curX=$$(fmt "$$prev_codex"); \
	 tgtC=$$(fmt "$(CLAUDE_CODE_VERSION)"); tgtX=$$(fmt "$(CODEX_VERSION)"); \
		 if [ "$$curC" = "$$tgtC" ] && [ "$$curX" = "$$tgtX" ]; then \
		   echo "Claude: $$tgtC (no change)"; \
		   echo "Codex:  $$tgtX (no change)"; \
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
		 fi
	@echo "Hint: override via CLAUDE_CODE_VERSION=... CODEX_VERSION=... or run 'make bump-versions' to pin"
	docker build -f $(DOCKERFILE) --build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) --build-arg CODEX_VERSION=$(CODEX_VERSION) -t $(MAIN_IMAGE) .
	@echo "✅ Build completed: $(MAIN_IMAGE)"

.PHONY: rebuild
rebuild:
	@echo "🔨 Rebuilding Docker image (no cache) with $(DOCKERFILE)..."
	docker build -f $(DOCKERFILE) --no-cache --build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) --build-arg CODEX_VERSION=$(CODEX_VERSION) -t $(MAIN_IMAGE) .
	@echo "✅ Rebuild completed: $(MAIN_IMAGE)"


.PHONY: build-rust
build-rust:
	@echo "🔨 Building Rust Docker image..."
	docker build -f $(RUST_DOCKERFILE) --build-arg BASE_IMAGE=$(MAIN_IMAGE) -t $(RUST_IMAGE) .
	@echo "✅ Rust build completed: $(RUST_IMAGE)"

.PHONY: build-all
build-all:
	@echo "🔨 Building all images with versions: Claude $(CLAUDE_CODE_VERSION), Codex $(CODEX_VERSION)..."
	@$(MAKE) build-main CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) CODEX_VERSION=$(CODEX_VERSION)
	@$(MAKE) build-rust BASE_IMAGE=$(MAIN_IMAGE)
	@echo "✅ All images built successfully"

.PHONY: buildx
buildx:
	@echo "🔨 Building with docker buildx..."
	docker buildx build -f $(DOCKERFILE) --load --build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) --build-arg CODEX_VERSION=$(CODEX_VERSION) -t $(MAIN_IMAGE) .
	@echo "✅ Buildx completed: $(MAIN_IMAGE)"

.PHONY: buildx-multi
buildx-multi:
	@echo "🔨 Building multi-arch images for amd64 and arm64..."
	docker buildx build -f $(DOCKERFILE) --platform linux/amd64,linux/arm64 \
		--build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) \
		--build-arg CODEX_VERSION=$(CODEX_VERSION) \
		--push -t $(MAIN_IMAGE) .
	@echo "✅ Multi-arch build completed and pushed: $(MAIN_IMAGE)"

.PHONY: buildx-multi-rust
buildx-multi-rust:
	@echo "🔨 Building multi-arch Rust images for amd64 and arm64..."
	docker buildx build -f $(RUST_DOCKERFILE) --platform linux/amd64,linux/arm64 \
		--build-arg BASE_IMAGE=$(MAIN_IMAGE) \
		--push -t $(RUST_IMAGE) .
	@echo "✅ Multi-arch Rust build completed and pushed: $(RUST_IMAGE)"

.PHONY: buildx-multi-local
buildx-multi-local:
	@echo "🔨 Building multi-arch images locally..."
	docker buildx build --platform linux/amd64,linux/arm64 \
		--build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) \
		--build-arg CODEX_VERSION=$(CODEX_VERSION) \
		-t $(MAIN_IMAGE) .
	@echo "✅ Multi-arch build completed locally: $(MAIN_IMAGE)"

.PHONY: bump-versions
bump-versions:
	@./scripts/bump-versions.sh

.PHONY: versions
versions:
	@CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) \
	 CODEX_VERSION=$(CODEX_VERSION) \
	 MAIN_IMAGE=$(MAIN_IMAGE) \
	 ./scripts/version-report.sh

.PHONY: clean
clean:
	@echo "🧹 Cleaning up Docker artifacts..."
	-docker rmi $(MAIN_IMAGE) 2>/dev/null || true
	-docker rmi $(RUST_IMAGE) 2>/dev/null || true
	-docker system prune -f
	@echo "✅ Cleanup completed"

.PHONY: clean-all
clean-all:
	@echo "🧹 Deep cleaning Docker artifacts and build cache..."
	-docker rmi $(MAIN_IMAGE) 2>/dev/null || true
	-docker rmi $(RUST_IMAGE) 2>/dev/null || true
	-docker builder prune -af
	-docker system prune -af --volumes
	@echo "✅ Deep cleanup completed"

.PHONY: shell
shell:
	@echo "🐚 Opening shell in $(MAIN_IMAGE)..."
	docker run --rm -it \
		-v $(PWD):$(PWD) \
		-w $(PWD) \
		--name $(CONTAINER_NAME) \
		$(MAIN_IMAGE) /bin/zsh

.PHONY: test
test:
	@echo "🧪 Testing $(MAIN_IMAGE)..."
	@echo "Testing claude command..."
	docker run --rm $(MAIN_IMAGE) claude --version
	@echo "Testing development tools..."
	docker run --rm $(MAIN_IMAGE) bash -c 'python --version && node --version && go version'
	@echo "✅ All tests passed"

.PHONY: test-rust
test-rust:
	@echo "🧪 Testing $(RUST_IMAGE)..."
	@echo "Testing Rust toolchain..."
	docker run --rm $(RUST_IMAGE) bash -c 'rustc --version && cargo --version && rustfmt --version && clippy-driver --version'
	@echo "Testing Rust tools..."
	docker run --rm $(RUST_IMAGE) bash -c 'cargo-watch --version && wasm-pack --version'
	@echo "✅ Rust tests passed"

.PHONY: test-local
test-local:
	@echo "🧪 Testing $(MAIN_IMAGE) with local directory..."
	docker run --rm -it \
		-v $(PWD):$(PWD) \
		-w $(PWD) \
		$(MAIN_IMAGE) bash -c 'pwd && ls -la && claude --version'

.PHONY: info
info:
	@echo "📊 Image information for $(MAIN_IMAGE):"
	@docker images $(MAIN_IMAGE) --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
	@echo ""
	@echo "🔍 Image layers:"
	@docker history $(MAIN_IMAGE) --no-trunc

.PHONY: push
push:
	@echo "📤 Pushing $(MAIN_IMAGE) to registry..."
	docker push $(MAIN_IMAGE)
	@echo "✅ Push completed"

.PHONY: pull
pull:
	@echo "📥 Pulling $(MAIN_IMAGE) from registry..."
	docker pull $(MAIN_IMAGE)
	@echo "✅ Pull completed"

.PHONY: build-test
build-test: build test
	@echo "✅ Build and test completed successfully"

.PHONY: dev
dev: build shell

.PHONY: context-size
context-size:
	@echo "📏 Build context size:"
	@du -sh . --exclude='.git' --exclude='node_modules' --exclude='.claude-trace'

.PHONY: lint
lint:
	@echo "🔍 Linting Dockerfile..."
	@if command -v hadolint >/dev/null 2>&1; then \
		hadolint Dockerfile; \
		echo "✅ Dockerfile linting completed"; \
	else \
		echo "⚠️  hadolint not found. Install with: brew install hadolint"; \
		echo "   Or run in Docker: docker run --rm -i hadolint/hadolint < Dockerfile"; \
	fi

.PHONY: version-check
version-check:
	@./scripts/version-check.sh

.PHONY: release-patch
release-patch:
	@./claude-yolo "Execute release workflow from @workflows/RELEASE.md for a **patch** release"

.PHONY: release-minor
release-minor:
	@./claude-yolo "Execute release workflow from @workflows/RELEASE.md for a **minor** release"

.PHONY: release-major
release-major:
	@./claude-yolo "Execute release workflow from @workflows/RELEASE.md for a **major** release"

.PHONY: help
help:
	@echo "deva.sh - Docker Build Shortcuts"
	@echo "==============================="
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available targets:"
	@echo "  build                Build all images (auto-detects latest npm versions)"
	@echo "  build-main           Build main Docker image only"
	@echo "  build-rust           Build Rust Docker image"
	@echo "  build-all            Build all images (main + rust)"
	@echo "  rebuild              Rebuild without cache"
	@echo "  buildx               Build with buildx"
	@echo "  buildx-multi         Build multi-arch and push"
	@echo "  buildx-multi-rust    Build multi-arch Rust and push"
		@echo "  versions             Show version status (current/built)"
		@echo "  bump-versions        Pin Makefile to latest npm versions"
	@echo "  test                 Test main image"
	@echo "  test-rust            Test Rust image"
	@echo "  shell                Open shell in container"
	@echo "  clean                Clean up Docker artifacts"
	@echo "  clean-all            Deep clean with build cache"
	@echo "  push                 Push image to registry"
	@echo "  pull                 Pull image from registry"
	@echo "  info                 Show image information"
	@echo "  lint                 Lint Dockerfile"
	@echo ""
	@echo "Environment variables:"
	@echo "  IMAGE_NAME           Main image name (default: $(IMAGE_NAME))"
	@echo "  TAG                  Docker image tag (default: $(TAG))"
	@echo "  RUST_TAG             Rust image tag (default: $(RUST_TAG))"
	@echo "  DOCKERFILE           Dockerfile to use (default: $(DOCKERFILE))"
	@echo "  RUST_DOCKERFILE      Rust Dockerfile path (default: $(RUST_DOCKERFILE))"
	@echo "  CLAUDE_CODE_VERSION  Claude CLI version (default: $(CLAUDE_CODE_VERSION))"
	@echo "  CODEX_VERSION        Codex CLI version (default: $(CODEX_VERSION))"
	@echo ""
	@echo "Examples:"
	@echo "  make build                                    # Build all images with latest versions"
	@echo "  make build-main                               # Build main image only"
	@echo "  make build-rust                               # Build Rust image only"
	@echo "  make TAG=dev build                            # Build all with custom tag"
	@echo "  make CLAUDE_CODE_VERSION=2.0.5 build          # Override with specific version"
	@echo "  make versions                                 # Check current versions"
