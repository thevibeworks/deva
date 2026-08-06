#!/usr/bin/env bash
# version-pins.sh - Shared version pin loader for builds and workflows

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_PINS_FILE="${VERSION_PINS_FILE:-$SCRIPT_DIR/../versions.env}"

VERSION_PIN_VARS=(
    NODE_MAJOR
    GO_VERSION
    PYTHON_VERSION
    DELTA_VERSION
    TMUX_VERSION
    TMUX_SHA256
    CLAUDE_CODE_VERSION
    CCTRACE_VERSION
    CODEX_VERSION
    GEMINI_CLI_VERSION
    GROK_CLI_VERSION
    KIMI_CODE_VERSION
    CCX_VERSION
    COPILOT_API_VERSION
    PLAYWRIGHT_VERSION
    CLOAKBROWSER_WRAPPER_VERSION
    RUST_TOOLCHAINS
    RUST_DEFAULT_TOOLCHAIN
    RUST_TARGETS
)

load_version_pins() {
    if [[ ! -f "$VERSION_PINS_FILE" ]]; then
        echo "error: version pin file not found: $VERSION_PINS_FILE" >&2
        return 1
    fi

    local pair var value
    while IFS='=' read -r var value; do
        if [[ -z ${!var+x} ]]; then
            printf -v "$var" '%s' "$value"
            export "$var"
        fi
    done < <(
        bash -lc '
            set -euo pipefail
            set -a
            # shellcheck disable=SC1090
            source "$1"
            set +a
            shift
            for var in "$@"; do
                printf "%s=%s\n" "$var" "${!var}"
            done
        ' bash "$VERSION_PINS_FILE" "${VERSION_PIN_VARS[@]}"
    )
}

emit_version_pins() {
    local var
    for var in "${VERSION_PIN_VARS[@]}"; do
        printf '%s=%s\n' "$var" "${!var}"
    done
}

# Rewrite the pin file from current variable values. The heredoc is a
# second copy of the file layout — a pin missing here is silently deleted
# on the next rewrite, which is why tests/version-upgrade.sh round-trips
# the file byte-for-byte. Every writer must go through this function.
write_version_pins() {
    cat > "$VERSION_PINS_FILE" <<EOF
# Shared image version pins for local and release builds.
# Update this file when we intentionally move default toolchain or CLI versions.

NODE_MAJOR=$NODE_MAJOR
GO_VERSION=$GO_VERSION
PYTHON_VERSION=$PYTHON_VERSION
DELTA_VERSION=$DELTA_VERSION
TMUX_VERSION=$TMUX_VERSION
TMUX_SHA256=$TMUX_SHA256

CLAUDE_CODE_VERSION=$CLAUDE_CODE_VERSION
CCTRACE_VERSION=$CCTRACE_VERSION
CODEX_VERSION=$CODEX_VERSION
GEMINI_CLI_VERSION=$GEMINI_CLI_VERSION
GROK_CLI_VERSION=$GROK_CLI_VERSION
KIMI_CODE_VERSION=$KIMI_CODE_VERSION
CCX_VERSION=$CCX_VERSION
COPILOT_API_VERSION=$COPILOT_API_VERSION
PLAYWRIGHT_VERSION=$PLAYWRIGHT_VERSION
# CloakBrowser npm wrapper version. This also pins the Chromium binary:
# the wrapper hardcodes per-arch free-binary versions (linux-x64 146.x.x.5,
# linux-arm64 146.x.x.3), so bumping the wrapper is what moves Chromium.
CLOAKBROWSER_WRAPPER_VERSION=$CLOAKBROWSER_WRAPPER_VERSION

RUST_TOOLCHAINS=$RUST_TOOLCHAINS
RUST_DEFAULT_TOOLCHAIN=$RUST_DEFAULT_TOOLCHAIN
RUST_TARGETS=$RUST_TARGETS
EOF
}

emit_github_outputs() {
    local output_file=$1
    local var key

    for var in "${VERSION_PIN_VARS[@]}"; do
        key=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')
        printf '%s=%s\n' "$key" "${!var}" >> "$output_file"
    done
}
