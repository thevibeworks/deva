#!/bin/bash
# install-agent-tooling.sh - Install pinned agent CLIs into the image

set -euo pipefail

: "${DEVA_HOME:?DEVA_HOME is required}"
: "${CLAUDE_CODE_VERSION:?CLAUDE_CODE_VERSION is required}"
: "${CODEX_VERSION:?CODEX_VERSION is required}"
: "${GEMINI_CLI_VERSION:?GEMINI_CLI_VERSION is required}"

CLAUDE_TRACE_VERSION="${CLAUDE_TRACE_VERSION:-1.0.9}"
ATLAS_CLI_VERSION="${ATLAS_CLI_VERSION:-v0.1.4}"
ATLAS_CLI_REPO="${ATLAS_CLI_REPO:-lroolle/atlas-cli}"
ATLAS_SKILL_NAME="atl-cli"

log() {
    echo "==> $*"
}

warn() {
    echo "WARN: $*" >&2
}

die() {
    echo "ERR: $*" >&2
    exit 1
}

retry_cmd() {
    local attempts="$1"
    local label="$2"
    shift 2

    local attempt=1
    local delay=2
    while true; do
        log "$label (attempt $attempt/$attempts)"
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -ge "$attempts" ]; then
            return 1
        fi
        warn "$label failed; retrying in ${delay}s"
        sleep "$delay"
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
}

ensure_safe_cwd() {
    if stat . >/dev/null 2>&1; then
        return
    fi
    log "Current working directory is not accessible; switching to $DEVA_HOME"
    mkdir -p "$DEVA_HOME"
    cd "$DEVA_HOME"
}

detect_platform() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"

    case "$arch" in
    x86_64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *) die "Unsupported architecture: $arch" ;;
    esac

    case "$os" in
    linux | darwin) ;;
    *) die "Unsupported OS: $os" ;;
    esac

    printf '%s_%s' "$os" "$arch"
}

is_release_ref() {
    [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ]]
}

download_to() {
    local url="$1"
    local dest="$2"
    curl -fsSL "$url" -o "$dest"
}

install_npm_agent_tooling() {
    log "Installing npm agent tooling"
    log "Requested versions: claude=${CLAUDE_CODE_VERSION} claude-trace=${CLAUDE_TRACE_VERSION} codex=${CODEX_VERSION} gemini=${GEMINI_CLI_VERSION}"

    mkdir -p "$DEVA_HOME/.npm-global" "$DEVA_HOME/.local/bin"
    npm config set prefix "$DEVA_HOME/.npm-global"

    retry_cmd 3 "npm install agent tooling" \
        npm install -g --verbose --no-audit --no-fund \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@mariozechner/claude-trace@${CLAUDE_TRACE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "@google/gemini-cli@${GEMINI_CLI_VERSION}" \
        || die "npm install failed"

    npm cache clean --force

    log "Verifying npm agent tooling"
    "$DEVA_HOME/.npm-global/bin/claude" --version
    "$DEVA_HOME/.npm-global/bin/codex" --version
    "$DEVA_HOME/.npm-global/bin/gemini" --version
    "$DEVA_HOME/.npm-global/bin/claude-trace" --help >/dev/null
    (npm list -g --depth=0 @anthropic-ai/claude-code @openai/codex @google/gemini-cli || true)
}

install_atlas_binary_from_release() {
    local ref="$1"
    local platform tmp_dir archive download_url

    platform="$(detect_platform)"
    tmp_dir="$(mktemp -d)"
    archive="$tmp_dir/atl.tar.gz"
    download_url="https://github.com/${ATLAS_CLI_REPO}/releases/download/${ref}/atl_${platform}.tar.gz"

    log "Trying atlas-cli release artifact: $download_url"
    if ! retry_cmd 3 "download atlas-cli release artifact" download_to "$download_url" "$archive"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    tar -xzf "$archive" -C "$tmp_dir"
    [ -f "$tmp_dir/atl" ] || die "atlas-cli archive missing atl binary"
    install -m 755 "$tmp_dir/atl" "$DEVA_HOME/.local/bin/atl"
    rm -rf "$tmp_dir"
}

go_install_atlas() {
    local ref="$1"
    (
        cd "$DEVA_HOME"
        GOBIN="$DEVA_HOME/.local/bin" go install -x "github.com/${ATLAS_CLI_REPO}/cmd/atl@${ref}"
    )
}

install_atlas_skill() {
    local ref="$1"
    local base_url="https://raw.githubusercontent.com/${ATLAS_CLI_REPO}/${ref}/skills/${ATLAS_SKILL_NAME}"
    local staging skill_dir

    staging="$(mktemp -d)"
    skill_dir="$DEVA_HOME/.skills/$ATLAS_SKILL_NAME"
    mkdir -p "$staging/references"

    retry_cmd 3 "download atlas skill" \
        download_to "$base_url/SKILL.md" "$staging/SKILL.md" \
        || { rm -rf "$staging"; return 1; }

    retry_cmd 3 "download atlas skill reference" \
        download_to "$base_url/references/confluence-guidelines.md" "$staging/references/confluence-guidelines.md" \
        || { rm -rf "$staging"; return 1; }

    rm -rf "$skill_dir"
    mkdir -p "$DEVA_HOME/.skills"
    mv "$staging" "$skill_dir"
}

install_atlas_cli() {
    local atlas_ref="$ATLAS_CLI_VERSION"

    ensure_safe_cwd
    mkdir -p "$DEVA_HOME/.local/bin" "$DEVA_HOME/.skills"

    log "Installing atlas-cli pinned to ${atlas_ref}"
    if is_release_ref "$atlas_ref"; then
        if install_atlas_binary_from_release "$atlas_ref"; then
            log "atlas-cli binary installed from release ${atlas_ref}"
        else
            warn "No atlas-cli release artifact for $(detect_platform); falling back to pinned go install"
            retry_cmd 3 "go install atlas-cli ${atlas_ref}" go_install_atlas "$atlas_ref" \
                || die "atlas-cli go install failed"
        fi
    else
        log "atlas-cli ref ${atlas_ref} is not a release tag; using pinned go install"
        retry_cmd 3 "go install atlas-cli ${atlas_ref}" go_install_atlas "$atlas_ref" \
            || die "atlas-cli go install failed"
    fi

    if ! install_atlas_skill "$atlas_ref"; then
        warn "atlas-cli skill install failed at ref ${atlas_ref}; continuing with binary only"
    fi

    "$DEVA_HOME/.local/bin/atl" --help >/dev/null 2>&1 || die "atlas-cli verification failed"
    log "atlas-cli installed"
}

main() {
    ensure_safe_cwd
    log "Installing shared agent tooling into $DEVA_HOME"
    install_npm_agent_tooling
    install_atlas_cli
}

main "$@"
