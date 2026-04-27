#!/usr/bin/env bash
# resolve-tool-versions.sh - Resolve latest upstream agent tool versions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/release-utils.sh"

emit() {
    local key=$1 value=$2
    printf '%s=%s\n' "$key" "$value"
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    fi
}

resolve_tool() {
    local key=$1 tool=$2 value
    value="$(fetch_latest_version "$tool")"
    if [[ -z $value ]]; then
        echo "error: failed to resolve $tool version" >&2
        exit 1
    fi
    emit "$key" "$value"
}

main() {
    emit "stamp" "$(date -u +%Y%m%d)"
    resolve_tool "claude_code_version" "claude-code"
    resolve_tool "codex_version" "codex"
    resolve_tool "gemini_cli_version" "gemini-cli"
    resolve_tool "atlas_cli_version" "atlas-cli"
    resolve_tool "copilot_api_version" "copilot-api"
}

main "$@"
