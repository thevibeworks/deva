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
    CLAUDE_TRACE_VERSION
    CODEX_VERSION
    GEMINI_CLI_VERSION
    ATLAS_CLI_VERSION
    COPILOT_API_VERSION
    PLAYWRIGHT_VERSION
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

emit_github_outputs() {
    local output_file=$1
    local var key

    for var in "${VERSION_PIN_VARS[@]}"; do
        key=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')
        printf '%s=%s\n' "$key" "${!var}" >> "$output_file"
    done
}
