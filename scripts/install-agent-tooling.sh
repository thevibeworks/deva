#!/bin/bash
# install-agent-tooling.sh - Install pinned agent CLIs into the image

set -euo pipefail

: "${DEVA_HOME:?DEVA_HOME is required}"
: "${CLAUDE_CODE_VERSION:?CLAUDE_CODE_VERSION is required}"
: "${CODEX_VERSION:?CODEX_VERSION is required}"
: "${GEMINI_CLI_VERSION:?GEMINI_CLI_VERSION is required}"
: "${GROK_CLI_VERSION:?GROK_CLI_VERSION is required}"

CCTRACE_VERSION="${CCTRACE_VERSION:-0.4.0}"
CCX_VERSION="${CCX_VERSION:-v0.7.0}"
CCX_REPO="${CCX_REPO:-thevibeworks/ccx}"

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

check_npm_registry_dns() {
    local host="${NPM_REGISTRY_HOST:-registry.npmjs.org}"

    if [ "${DEVA_SKIP_NPM_REGISTRY_CHECK:-}" = "1" ]; then
        return 0
    fi

    command -v node >/dev/null 2>&1 || return 0

    log "Checking npm registry DNS: $host"
    if node - "$host" <<'NODE' >/dev/null
const dns = require("dns");
const host = process.argv[2];
dns.lookup(host, { all: true }, (err) => {
  if (err) {
    console.error(`${err.code || "DNS_ERROR"} ${host}: ${err.message}`);
    process.exit(1);
  }
});
NODE
    then
        return 0
    fi

    warn "Cannot resolve $host from this container."
    warn "This is a Docker/VM DNS problem, not an npm package/version problem."
    if [ -f /etc/resolv.conf ]; then
        sed 's/^/resolv.conf: /' /etc/resolv.conf >&2 || true
    fi
    die "npm registry DNS lookup failed"
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
    log "Requested versions: claude=${CLAUDE_CODE_VERSION} codex=${CODEX_VERSION} gemini=${GEMINI_CLI_VERSION} grok=${GROK_CLI_VERSION}"

    mkdir -p "$DEVA_HOME/.npm-global" "$DEVA_HOME/.local/bin"
    npm config set prefix "$DEVA_HOME/.npm-global"
    check_npm_registry_dns

    retry_cmd 3 "npm install agent tooling" \
        npm install -g --verbose --no-audit --no-fund \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "@google/gemini-cli@${GEMINI_CLI_VERSION}" \
        "@xai-official/grok@${GROK_CLI_VERSION}" \
        || die "npm install failed"

    npm cache clean --force

    log "Verifying npm agent tooling"
    "$DEVA_HOME/.npm-global/bin/claude" --version
    "$DEVA_HOME/.npm-global/bin/codex" --version
    "$DEVA_HOME/.npm-global/bin/gemini" --version
    pin_grok_platform_binary
    (npm list -g --depth=0 @anthropic-ai/claude-code @openai/codex @google/gemini-cli @xai-official/grok || true)
}

# grok's npm postinstall puts the real binary in ~/.grok/bin (the CLI's
# self-update dir) and the npm bin is a node trampoline that resolves that
# path FIRST. At runtime a host ~/.grok mounted for auth would shadow the
# image binary (worst case: exec-format error on a host macOS binary).
# Move the binary to ~/.local/bin (first in PATH), repoint the npm bin, and
# drop ~/.grok/bin so the container always runs the image binary no matter
# what is mounted at ~/.grok.
pin_grok_platform_binary() {
    local trampoline="$DEVA_HOME/.npm-global/bin/grok"
    # Also bootstraps the canonical ~/.grok/bin layout from the per-platform
    # package in the rare case npm skipped the postinstall.
    "$trampoline" --version >/dev/null || die "grok install verification failed"

    local real_bin
    real_bin="$(readlink -f "$DEVA_HOME/.grok/bin/grok" 2>/dev/null || true)"
    [ -n "$real_bin" ] && [ -f "$real_bin" ] || die "grok binary not found under $DEVA_HOME/.grok/bin"

    mv "$real_bin" "$DEVA_HOME/.local/bin/grok"
    chmod 755 "$DEVA_HOME/.local/bin/grok"
    ln -sf "$DEVA_HOME/.local/bin/grok" "$trampoline"
    rm -rf "$DEVA_HOME/.grok/bin"

    "$DEVA_HOME/.local/bin/grok" --version
}

ccx_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$arch" in
    x86_64)  arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported architecture: $arch" ;;
    esac
    case "$os" in
    Linux)  os="linux" ;;
    Darwin) os="macOS" ;;
    *) die "Unsupported OS: $os" ;;
    esac
    printf '%s_%s' "$os" "$arch"
}

install_ccx_binary_from_release() {
    local ref="$1"
    local version="${ref#v}"
    local platform tmp_dir archive download_url

    platform="$(ccx_platform)"
    tmp_dir="$(mktemp -d)"
    archive="$tmp_dir/ccx.tar.gz"
    download_url="https://github.com/${CCX_REPO}/releases/download/${ref}/ccx_${version}_${platform}.tar.gz"

    log "Trying ccx release artifact: $download_url"
    if ! retry_cmd 3 "download ccx release artifact" download_to "$download_url" "$archive"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    tar -xzf "$archive" -C "$tmp_dir"
    local binary
    binary=$(find "$tmp_dir" -name ccx -type f | head -1)
    [ -n "$binary" ] || die "ccx archive missing ccx binary"
    install -m 755 "$binary" "$DEVA_HOME/.local/bin/ccx"
    rm -rf "$tmp_dir"
}

go_install_ccx() {
    local ref="$1"
    (
        cd "$DEVA_HOME"
        GOBIN="$DEVA_HOME/.local/bin" go install -x "github.com/${CCX_REPO}@${ref}"
    )
}

install_ccx_skill() {
    local ref="$1"
    local download_url="https://github.com/${CCX_REPO}/releases/download/${ref}/ccx.skill"
    local tmp_dir skill_dir

    tmp_dir="$(mktemp -d)"
    skill_dir="$DEVA_HOME/.skills/ccx"

    retry_cmd 3 "download ccx skill" \
        download_to "$download_url" "$tmp_dir/ccx.skill" \
        || { rm -rf "$tmp_dir"; return 1; }

    rm -rf "$skill_dir"
    mkdir -p "$DEVA_HOME/.skills"
    unzip -qo "$tmp_dir/ccx.skill" -d "$tmp_dir/extracted" 2>/dev/null \
        || { rm -rf "$tmp_dir"; return 1; }
    if [ -d "$tmp_dir/extracted/skills/ccx" ]; then
        mv "$tmp_dir/extracted/skills/ccx" "$DEVA_HOME/.skills/ccx"
    elif [ -d "$tmp_dir/extracted/ccx" ]; then
        mv "$tmp_dir/extracted/ccx" "$DEVA_HOME/.skills/ccx"
    fi
    rm -rf "$tmp_dir"
}

install_ccx() {
    local ccx_ref="$CCX_VERSION"

    ensure_safe_cwd
    mkdir -p "$DEVA_HOME/.local/bin" "$DEVA_HOME/.skills"

    log "Installing ccx pinned to ${ccx_ref}"
    if is_release_ref "$ccx_ref"; then
        if install_ccx_binary_from_release "$ccx_ref"; then
            log "ccx binary installed from release ${ccx_ref}"
        else
            warn "No ccx release artifact for $(ccx_platform); falling back to go install"
            retry_cmd 3 "go install ccx ${ccx_ref}" go_install_ccx "$ccx_ref" \
                || die "ccx go install failed"
        fi
    else
        log "ccx ref ${ccx_ref} is not a release tag; using go install"
        retry_cmd 3 "go install ccx ${ccx_ref}" go_install_ccx "$ccx_ref" \
            || die "ccx go install failed"
    fi

    if ! install_ccx_skill "$ccx_ref"; then
        warn "ccx skill install failed at ref ${ccx_ref}; continuing with binary only"
    fi

    "$DEVA_HOME/.local/bin/ccx" --help >/dev/null 2>&1 || die "ccx verification failed"
    log "ccx installed"
}

# cctrace ships no prebuilt binaries; compile the standalone binary with bun.
# The compiled binary receives argv directly, so `cctrace -- <claude args>`
# works (bun's CLI would eat the leading "--").
install_cctrace() {
    ensure_safe_cwd
    mkdir -p "$DEVA_HOME/.local/bin"

    log "Installing cctrace pinned to ${CCTRACE_VERSION}"
    command -v bun >/dev/null 2>&1 || die "bun is required to build cctrace"

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    (
        cd "$tmp_dir"
        retry_cmd 3 "npm pack cctrace" \
            npm pack "@thevibeworks/cctrace@${CCTRACE_VERSION}" \
            || die "npm pack @thevibeworks/cctrace failed"
        tar -xzf thevibeworks-cctrace-*.tgz
        cd package
        bun build --compile --outfile "$DEVA_HOME/.local/bin/cctrace" src/cli.ts
    )
    rm -rf "$tmp_dir"

    "$DEVA_HOME/.local/bin/cctrace" --help >/dev/null || die "cctrace verification failed"
    log "cctrace installed"
}

main() {
    ensure_safe_cwd
    log "Installing shared agent tooling into $DEVA_HOME"
    install_npm_agent_tooling
    install_ccx
    install_cctrace
}

main "$@"
