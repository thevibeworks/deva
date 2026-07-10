#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

assert_absent() {
    local needle="$1"
    local haystack="$2"
    if grep -F "$needle" <<<"$haystack" >/dev/null; then
        echo "unexpected output contained: $needle" >&2
        echo "$haystack" >&2
        exit 1
    fi
}

assert_present() {
    local needle="$1"
    local haystack="$2"
    if ! grep -F "$needle" <<<"$haystack" >/dev/null; then
        echo "expected output to contain: $needle" >&2
        echo "$haystack" >&2
        exit 1
    fi
}

cd "$REPO_ROOT"

default_versions_up="$(make -n versions-up)"
assert_absent "CLAUDE_CODE_VERSION=" "$default_versions_up"
assert_absent "CCTRACE_VERSION=" "$default_versions_up"
assert_absent "CODEX_VERSION=" "$default_versions_up"
assert_absent "GEMINI_CLI_VERSION=" "$default_versions_up"
assert_absent "GROK_CLI_VERSION=" "$default_versions_up"
assert_absent "CCX_VERSION=" "$default_versions_up"
assert_absent "COPILOT_API_VERSION=" "$default_versions_up"
assert_absent "PLAYWRIGHT_VERSION=" "$default_versions_up"
assert_present "./scripts/version-upgrade.sh" "$default_versions_up"

default_versions="$(make -n versions)"
assert_absent "CLAUDE_CODE_VERSION=" "$default_versions"
assert_absent "CCTRACE_VERSION=" "$default_versions"
assert_absent "CODEX_VERSION=" "$default_versions"
assert_absent "GEMINI_CLI_VERSION=" "$default_versions"
assert_absent "GROK_CLI_VERSION=" "$default_versions"
assert_absent "CCX_VERSION=" "$default_versions"
assert_absent "COPILOT_API_VERSION=" "$default_versions"
assert_present "./scripts/version-report.sh" "$default_versions"

override_versions_up="$(
    make -n \
        CLAUDE_CODE_VERSION=9.9.9 \
        CCTRACE_VERSION=1.2.3 \
        CODEX_VERSION=8.8.8 \
        GEMINI_CLI_VERSION=7.7.7 \
        GROK_CLI_VERSION=5.5.5 \
        CCX_VERSION=v6.6.6 \
        COPILOT_API_VERSION=deadbeef \
        PLAYWRIGHT_VERSION=1.2.4 \
        versions-up
)"
assert_present "CLAUDE_CODE_VERSION=9.9.9" "$override_versions_up"
assert_present "CCTRACE_VERSION=1.2.3" "$override_versions_up"
assert_present "CODEX_VERSION=8.8.8" "$override_versions_up"
assert_present "GEMINI_CLI_VERSION=7.7.7" "$override_versions_up"
assert_present "GROK_CLI_VERSION=5.5.5" "$override_versions_up"
assert_present "CCX_VERSION=v6.6.6" "$override_versions_up"
assert_present "COPILOT_API_VERSION=deadbeef" "$override_versions_up"
assert_present "PLAYWRIGHT_VERSION=1.2.4" "$override_versions_up"

override_versions="$(
    make -n \
        CLAUDE_CODE_VERSION=9.9.9 \
        CCTRACE_VERSION=1.2.3 \
        CODEX_VERSION=8.8.8 \
        GEMINI_CLI_VERSION=7.7.7 \
        GROK_CLI_VERSION=5.5.5 \
        CCX_VERSION=v6.6.6 \
        COPILOT_API_VERSION=deadbeef \
        versions
)"
assert_present "CLAUDE_CODE_VERSION=9.9.9" "$override_versions"
assert_present "CCTRACE_VERSION=1.2.3" "$override_versions"
assert_present "CODEX_VERSION=8.8.8" "$override_versions"
assert_present "GEMINI_CLI_VERSION=7.7.7" "$override_versions"
assert_present "GROK_CLI_VERSION=5.5.5" "$override_versions"
assert_present "CCX_VERSION=v6.6.6" "$override_versions"
assert_present "COPILOT_API_VERSION=deadbeef" "$override_versions"
