#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp_home="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp_home"
}
trap cleanup EXIT

run_dry() {
    (
        cd "$REPO_ROOT"
        env -u DEVA_PROFILE -u DEVA_IMAGE_PROFILE -u DEVA_DOCKER_IMAGE -u DEVA_DOCKER_TAG \
            HOME="$tmp_home" \
            XDG_CONFIG_HOME="$tmp_home/.config" \
            XDG_CACHE_HOME="$tmp_home/.cache" \
            DEVA_NO_DOCKER=1 \
            ./deva.sh "$@"
    ) 2>&1
}

assert_present() {
    local needle="$1" output="$2"
    if ! grep -F -- "$needle" <<<"$output" >/dev/null; then
        echo "expected output to contain: $needle" >&2
        echo "$output" >&2
        exit 1
    fi
}

assert_absent() {
    local needle="$1" output="$2"
    if grep -F -- "$needle" <<<"$output" >/dev/null; then
        echo "unexpected output contained: $needle" >&2
        echo "$output" >&2
        exit 1
    fi
}

plain_out="$(run_dry codex --debug --dry-run || true)"
assert_absent "mcp_servers.playwright" "$plain_out"
assert_present "ghcr.io/thevibeworks/deva:latest" "$plain_out"

browser_out="$(run_dry codex --browser-mcp --debug --dry-run || true)"
assert_present "ghcr.io/thevibeworks/deva:rust" "$browser_out"
assert_present "--config mcp_servers.playwright={command=\"npx\",args=[\"-y\",\"@playwright/mcp@" "$browser_out"
assert_present "\"--headless\",\"--browser\",\"chromium\",\"--no-sandbox\",\"--isolated\"" "$browser_out"
assert_present "DEVA_CODEX_BROWSER_MCP=1" "$browser_out"

claude_out="$(run_dry claude --with-browser --debug --dry-run || true)"
assert_present "error: --browser-mcp is currently supported for codex only" "$claude_out"

config_home="$tmp_home/config-case"
mkdir -p "$config_home/.config/deva"
cat >"$config_home/.config/deva/.deva" <<'CONFIG'
CODEX_BROWSER_MCP=true
CODEX_CONFIG=features.apps=false
CODEX_CONFIG=mcp_servers.hn-research={url="https://hn.1lm.io/mcp",enabled=false}
CONFIG

config_out="$(
    (
        cd "$REPO_ROOT"
        env -u DEVA_PROFILE -u DEVA_IMAGE_PROFILE -u DEVA_DOCKER_IMAGE -u DEVA_DOCKER_TAG \
            HOME="$config_home" \
            XDG_CONFIG_HOME="$config_home/.config" \
            XDG_CACHE_HOME="$config_home/.cache" \
            DEVA_NO_DOCKER=1 \
            ./deva.sh codex --debug --dry-run
    ) 2>&1
)"
assert_present "DEVA_CODEX_BROWSER_MCP=1" "$config_out"
assert_present "--config features.apps=false" "$config_out"
assert_present "--config mcp_servers.hn-research={url=\"https://hn.1lm.io/mcp\",enabled=false}" "$config_out"
