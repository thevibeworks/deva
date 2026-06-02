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

eval "$(sed -n '/^parse_ccx_args()/,/^}/p' "$REPO_ROOT/deva.sh")"

run_parse() {
    local mode="$1"; shift
    local -a pre=() post=()
    local in_post=false
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then in_post=true; continue; fi
        if [ "$in_post" = true ]; then post+=("$arg"); else pre+=("$arg"); fi
    done
    MANAGEMENT_MODE="$mode"
    PRE_ARGS=("${pre[@]}")
    POST_ARGS=(${post[@]+"${post[@]}"})
    CCX_ARGS=()
    parse_ccx_args
    echo "${CCX_ARGS[*]}"
}

echo "=== sessions: basic ==="
assert_eq "sessions --all" \
    "sessions --all" \
    "$(run_parse sessions sessions --all)"

assert_eq "sessions --all --limit 5" \
    "sessions --all --limit 5" \
    "$(run_parse sessions sessions --all --limit 5)"

assert_eq "sessions bare" \
    "sessions" \
    "$(run_parse sessions sessions)"

echo ""
echo "=== sessions: deva flags stripped ==="
assert_eq "strip --dry-run" \
    "sessions --all" \
    "$(run_parse sessions sessions --dry-run --all)"

assert_eq "strip --debug" \
    "sessions --all" \
    "$(run_parse sessions sessions --debug --all)"

assert_eq "strip --verbose" \
    "sessions" \
    "$(run_parse sessions sessions --verbose)"

assert_eq "strip -g" \
    "sessions --limit 5" \
    "$(run_parse sessions sessions -g --limit 5)"

assert_eq "strip --global" \
    "sessions --scope today" \
    "$(run_parse sessions sessions --global --scope today)"

echo ""
echo "=== sessions: deva flags before trigger ==="
assert_eq "pre-trigger flags ignored" \
    "sessions --limit 3" \
    "$(run_parse sessions --verbose -g sessions --limit 3)"

echo ""
echo "=== ccx: basic ==="
assert_eq "ccx projects" \
    "projects" \
    "$(run_parse ccx ccx projects)"

assert_eq "ccx search query" \
    "search auth" \
    "$(run_parse ccx ccx search auth)"

assert_eq "ccx view @1" \
    "view @1" \
    "$(run_parse ccx ccx view @1)"

assert_eq "ccx bare (no subcommand)" \
    "" \
    "$(run_parse ccx ccx)"

echo ""
echo "=== POST_ARGS (-- sentinel) ==="
assert_eq "ccx -- sessions --all" \
    "sessions --all" \
    "$(run_parse ccx ccx -- sessions --all)"

assert_eq "sessions -- --all --limit 5" \
    "sessions --all --limit 5" \
    "$(run_parse sessions sessions -- --all --limit 5)"

assert_eq "mixed pre and post" \
    "sessions --scope today --all" \
    "$(run_parse sessions sessions --scope today -- --all)"

echo ""
echo "=== session alias ==="
assert_eq "session (singular)" \
    "sessions --all" \
    "$(run_parse sessions session --all)"

echo ""
echo "=== Results ==="
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    printf '%b\n' "$ERRORS"
    exit 1
fi
