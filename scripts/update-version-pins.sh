#!/usr/bin/env bash
# update-version-pins.sh - Refresh shared version pins from upstream sources

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/version-pins.sh"

DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: update-version-pins.sh [--dry-run]

Refresh shared version pins from upstream sources and rewrite versions.env.
Only versions we intentionally pin are updated here.
EOF
}

fetch_npm_version() {
    npm view "$1" version 2>/dev/null || true
}

fetch_latest_git_tag() {
    git ls-remote --tags "$1" 2>/dev/null | \
        awk '{print $2}' | \
        sed 's#refs/tags/##; s/\^{}$//' | \
        grep -E '^v?[0-9]+(\.[0-9]+){1,2}$' | \
        sort -Vu | \
        tail -1
}

fetch_go_version() {
    curl -fsSL https://go.dev/VERSION?m=text 2>/dev/null | \
        head -1 | \
        sed 's/^go//'
}

fetch_latest_commit() {
    git ls-remote "$1" "$2" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

refresh_pin() {
    local var_name=$1 fetched=$2
    if [[ -n "$fetched" ]]; then
        printf -v "$var_name" '%s' "$fetched"
    fi
}

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
CLAUDE_TRACE_VERSION=$CLAUDE_TRACE_VERSION
CODEX_VERSION=$CODEX_VERSION
GEMINI_CLI_VERSION=$GEMINI_CLI_VERSION
ATLAS_CLI_VERSION=$ATLAS_CLI_VERSION
COPILOT_API_VERSION=$COPILOT_API_VERSION
PLAYWRIGHT_VERSION=$PLAYWRIGHT_VERSION

RUST_TOOLCHAINS=$RUST_TOOLCHAINS
RUST_DEFAULT_TOOLCHAIN=$RUST_DEFAULT_TOOLCHAIN
RUST_TARGETS=$RUST_TARGETS
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

main() {
    load_version_pins

    refresh_pin GO_VERSION "$(fetch_go_version)"
    refresh_pin DELTA_VERSION "$(fetch_latest_git_tag https://github.com/dandavison/delta.git)"
    refresh_pin CLAUDE_CODE_VERSION "$(fetch_npm_version @anthropic-ai/claude-code)"
    refresh_pin CLAUDE_TRACE_VERSION "$(fetch_npm_version @mariozechner/claude-trace)"
    refresh_pin CODEX_VERSION "$(fetch_npm_version @openai/codex)"
    refresh_pin GEMINI_CLI_VERSION "$(fetch_npm_version @google/gemini-cli)"
    refresh_pin ATLAS_CLI_VERSION "$(fetch_latest_git_tag https://github.com/lroolle/atlas-cli.git)"
    refresh_pin COPILOT_API_VERSION "$(fetch_latest_commit https://github.com/ericc-ch/copilot-api.git refs/heads/master)"
    refresh_pin PLAYWRIGHT_VERSION "$(fetch_npm_version playwright)"

    if [[ $DRY_RUN -eq 1 ]]; then
        emit_version_pins
        return 0
    fi

    write_version_pins
}

main "$@"
