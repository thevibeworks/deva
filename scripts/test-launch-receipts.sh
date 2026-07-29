#!/usr/bin/env bash
# Round-trip tests for --goal launch receipts (#499) and the ps/status
# goal column (#520): write_launch_receipt -> container_goal.
# Hermetic: scratch XDG_DATA_HOME, docker stubbed.
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
    eval "$(sed -n '/^write_launch_receipt()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^container_goal()/,/^}/p' "$REPO_ROOT/deva.sh")"
}

source_helpers

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export XDG_DATA_HOME="$SCRATCH/data"
LAUNCH_DIR="$XDG_DATA_HOME/ccx/launches"

# docker stub: emits env lines only for the one container the fallback
# test expects; fails for everything else like a missing container would.
docker() {
    if [ "${DOCKER_STUB_NAME:-}" = "${!#}" ]; then
        printf 'PATH=/usr/bin\nDEVA_GOAL=%s\nHOME=/home/deva\n' "$DOCKER_STUB_GOAL"
        return 0
    fi
    return 1
}

echo "=== write_launch_receipt ==="

GOAL=""
ACTIVE_AGENT="claude"
CONTAINER_NAME="deva--claude--auth-default--proj..abcd"
write_launch_receipt
if [ -d "$LAUNCH_DIR" ] && [ -n "$(ls -A "$LAUNCH_DIR" 2>/dev/null)" ]; then
    fail "no goal writes no receipt"
else
    pass "no goal writes no receipt"
fi

GOAL="fix-auth-race"
write_launch_receipt
receipt_file="$LAUNCH_DIR/$(date -u +%Y-%m-%d).jsonl"
if [ -f "$receipt_file" ]; then
    pass "receipt file created"
else
    fail "receipt file created"
fi
assert_eq "receipt line count" "1" "$(wc -l <"$receipt_file" | tr -d ' ')"
assert_eq "receipt goal field" "fix-auth-race" "$(jq -r '.goal' "$receipt_file")"
assert_eq "receipt agent field" "claude" "$(jq -r '.agent' "$receipt_file")"
assert_eq "receipt container field" "$CONTAINER_NAME" "$(jq -r '.container' "$receipt_file")"
assert_eq "receipt source field" "deva" "$(jq -r '.source' "$receipt_file")"

echo "=== container_goal ==="

assert_eq "goal from receipt" "fix-auth-race" "$(container_goal "$CONTAINER_NAME")"

GOAL="ship-ps-column"
write_launch_receipt
assert_eq "last receipt wins" "ship-ps-column" "$(container_goal "$CONTAINER_NAME")"

GOAL="other-goal"
CONTAINER_NAME="deva--codex--auth-default--other..ef01"
write_launch_receipt
assert_eq "receipts keyed per container" "ship-ps-column" "$(container_goal "deva--claude--auth-default--proj..abcd")"

DOCKER_STUB_NAME="deva--grok--auth-default--env..2345"
DOCKER_STUB_GOAL="from-create-env"
assert_eq "env fallback when no receipt" "from-create-env" "$(container_goal "$DOCKER_STUB_NAME")"

assert_eq "no receipt no env is --" "--" "$(container_goal "deva--kimi--auth-default--gone..6789")"

rm -rf "$LAUNCH_DIR"
assert_eq "missing launches dir falls through" "--" "$(container_goal "deva--claude--auth-default--proj..abcd")"

echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d/%d%b\n' "$FAIL" "$((PASS + FAIL))" "$ERRORS" >&2
    exit 1
fi
echo "All $PASS tests passed"
