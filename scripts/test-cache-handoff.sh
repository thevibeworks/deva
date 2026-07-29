#!/usr/bin/env bash
# Hermetic tests for hooks/cache-handoff.sh gate logic.
# Scratch state dir, zero/short sleeps, no claude involved.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HOOK="$REPO_ROOT/hooks/cache-handoff.sh"

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    echo "PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $1"
}

TMP="$(mktemp -d)"
cleanup() {
    [[ -n "${SLEEPER_PID:-}" ]] && kill "$SLEEPER_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

STATE="$TMP/state"
TRANSCRIPT="$TMP/transcript.jsonl"
printf 'line one\n' >"$TRANSCRIPT"

hook_input() {
    local active="$1" session="$2"
    printf '{"stop_hook_active":%s,"session_id":%s,"transcript_path":"%s"}' \
        "$active" "$session" "$TRANSCRIPT"
}

run_hook() {
    local after="$1" input="$2" rc=0
    printf '%s' "$input" | CC_HANDOFF_AFTER_SEC="$after" \
        CC_HANDOFF_STATE_DIR="$STATE" "$HOOK" 2>"$TMP/stderr" || rc=$?
    echo "$rc"
}

# 1. stop_hook_active=true must not schedule anything (no self-chain)
rc="$(run_hook 0 "$(hook_input true '"s1"')")"
if [[ "$rc" == "0" && ! -f "$STATE/s1.pid" ]]; then
    pass "stop_hook_active skips without writing state"
else
    fail "stop_hook_active: rc=$rc pidfile=$([[ -f "$STATE/s1.pid" ]] && echo yes || echo no)"
fi

# 2. missing session_id must skip
rc="$(run_hook 0 "$(hook_input false null)")"
if [[ "$rc" == "0" ]]; then
    pass "null session_id skips"
else
    fail "null session_id: rc=$rc"
fi

# 3. idle session fires: exit 2, hand-off prompt on stderr, donefile set
rc="$(run_hook 0 "$(hook_input false '"s1"')")"
size="$(wc -c <"$TRANSCRIPT" | tr -d ' ')"
if [[ "$rc" == "2" ]] && grep -q "hand-off" "$TMP/stderr" &&
    [[ "$(cat "$STATE/s1.done")" == "$size" ]]; then
    pass "idle session fires exit 2 with hand-off prompt"
else
    fail "idle fire: rc=$rc done=$(cat "$STATE/s1.done" 2>/dev/null || echo none)"
fi

# 4. same transcript position must not fire twice
rc="$(run_hook 0 "$(hook_input false '"s1"')")"
if [[ "$rc" == "0" ]]; then
    pass "dedup at same transcript position"
else
    fail "dedup: rc=$rc"
fi

# 5. transcript growth during the sleep aborts the wake
rc=0
printf '%s' "$(hook_input false '"s2"')" | CC_HANDOFF_AFTER_SEC=1 \
    CC_HANDOFF_STATE_DIR="$STATE" "$HOOK" 2>/dev/null &
HOOK_PID=$!
# The hook captures the transcript size just before writing its pidfile;
# wait for the pidfile so the append below lands after the baseline read.
for _ in $(seq 1 50); do
    [[ -f "$STATE/s2.pid" ]] && break
    sleep 0.1
done
printf 'a turn started\n' >>"$TRANSCRIPT"
wait "$HOOK_PID" || rc=$?
if [[ "$rc" == "0" && ! -f "$STATE/s2.done" ]]; then
    pass "transcript growth aborts the wake"
else
    fail "growth abort: rc=$rc done=$([[ -f "$STATE/s2.done" ]] && echo yes || echo no)"
fi

# 6. a newer Stop supersedes the older sleeper (kills it via pidfile)
sleep 30 &
SLEEPER_PID=$!
echo "$SLEEPER_PID" >"$STATE/s3.pid"
rc="$(run_hook 0 "$(hook_input false '"s3"')")"
sleep 0.2
if [[ "$rc" == "2" ]] && ! kill -0 "$SLEEPER_PID" 2>/dev/null; then
    pass "newer sleeper kills the superseded one"
else
    fail "supersede: rc=$rc old sleeper alive=$(kill -0 "$SLEEPER_PID" 2>/dev/null && echo yes || echo no)"
fi
SLEEPER_PID=""

echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
