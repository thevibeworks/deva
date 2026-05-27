#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
ERRORS=""

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  FAIL: $1"; echo "  FAIL: $1" >&2; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label: expected='$expected' actual='$actual'"
    fi
}

source_helpers() {
    eval "$(sed -n '/^format_uptime()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^categorize_mount()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^shorten_path()/,/^}/p' "$REPO_ROOT/deva.sh")"
}

source_helpers

echo "=== format_uptime ==="

now=$(date +%s)
ts_30s=$(date -d "@$((now - 30))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
         date -r "$((now - 30))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
if [ -n "$ts_30s" ]; then
    assert_eq "30 seconds ago" "30s" "$(format_uptime "$ts_30s")"
fi

ts_5m=$(date -d "@$((now - 300))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
        date -r "$((now - 300))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
if [ -n "$ts_5m" ]; then
    assert_eq "5 minutes ago" "5m" "$(format_uptime "$ts_5m")"
fi

ts_3h=$(date -d "@$((now - 10800))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
        date -r "$((now - 10800))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
if [ -n "$ts_3h" ]; then
    assert_eq "3 hours ago" "3h" "$(format_uptime "$ts_3h")"
fi

ts_3h30m=$(date -d "@$((now - 12600))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
           date -r "$((now - 12600))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
if [ -n "$ts_3h30m" ]; then
    assert_eq "3h 30m ago" "3h 30m" "$(format_uptime "$ts_3h30m")"
fi

ts_2d=$(date -d "@$((now - 172800))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
        date -r "$((now - 172800))" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
if [ -n "$ts_2d" ]; then
    assert_eq "2 days ago" "2d" "$(format_uptime "$ts_2d")"
fi

assert_eq "unparseable fallback" "2025-01-01" "$(format_uptime "2025-01-01Tgarbage")"

echo ""
echo "=== categorize_mount ==="

assert_eq "workspace mount" "workspace" \
    "$(categorize_mount "/Users/eric/project" "/Users/eric/project")"

assert_eq "docker socket" "bridge" \
    "$(categorize_mount "/var/run/docker.sock" "/any")"

assert_eq "chrome bridge" "bridge" \
    "$(categorize_mount "/deva-host-chrome-bridge" "/any")"

assert_eq "chrome bridge subpath" "bridge" \
    "$(categorize_mount "/deva-host-chrome-bridge/sock" "/any")"

assert_eq ".claude config" "config" \
    "$(categorize_mount "/home/deva/.claude" "/any")"

assert_eq ".claude.json config" "config" \
    "$(categorize_mount "/home/deva/.claude.json" "/any")"

assert_eq ".codex config" "config" \
    "$(categorize_mount "/home/deva/.codex" "/any")"

assert_eq ".gemini config" "config" \
    "$(categorize_mount "/home/deva/.gemini" "/any")"

assert_eq ".agents config" "config" \
    "$(categorize_mount "/home/deva/.agents" "/any")"

assert_eq "user ssh mount" "user" \
    "$(categorize_mount "/home/deva/.ssh" "/any")"

assert_eq "user aws mount" "user" \
    "$(categorize_mount "/home/deva/.aws" "/any")"

assert_eq "non-workspace project dir" "user" \
    "$(categorize_mount "/Users/eric/other-project" "/Users/eric/project")"

echo ""
echo "=== shorten_path ==="

OLD_HOME="$HOME"
export HOME="/Users/testuser"

assert_eq "home subpath" "~/.config/deva" \
    "$(shorten_path "/Users/testuser/.config/deva")"

assert_eq "home itself" "~" \
    "$(shorten_path "/Users/testuser")"

assert_eq "non-home path" "/var/run/docker.sock" \
    "$(shorten_path "/var/run/docker.sock")"

assert_eq "similar prefix not shortened" "/Users/testuser2/foo" \
    "$(shorten_path "/Users/testuser2/foo")"

export HOME="$OLD_HOME"

echo ""
echo "=== Results ==="
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    printf '%b\n' "$ERRORS"
    exit 1
fi
