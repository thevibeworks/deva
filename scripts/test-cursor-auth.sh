#!/usr/bin/env bash
# test-cursor-auth.sh - cursor agent auth wiring (config-home mounts + CURSOR_API_KEY env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp_home="$(mktemp -d)"
cleanup() { rm -rf "$tmp_home"; }
trap cleanup EXIT

fail=0
run_dry() {
    (
        cd "$REPO_ROOT"
        HOME="$tmp_home" \
        XDG_CONFIG_HOME="$tmp_home/.config" \
        XDG_CACHE_HOME="$tmp_home/.cache" \
        DEVA_NO_DOCKER=1 \
        ./deva.sh "$@"
    ) 2>&1
}

want() {
    local desc="$1" needle="$2" hay="$3"
    if grep -F -- "$needle" <<<"$hay" >/dev/null; then
        echo "  PASS $desc"
    else
        echo "  FAIL $desc"
        echo "        expected to find: $needle" >&2
        fail=1
    fi
}
want_absent() {
    local desc="$1" needle="$2" hay="$3"
    if grep -F -- "$needle" <<<"$hay" >/dev/null; then
        echo "  FAIL $desc"
        echo "        expected absent: $needle" >&2
        fail=1
    else
        echo "  PASS $desc"
    fi
}

echo "=== cursor oauth (default) ==="
oauth_out="$(run_dry cursor --debug --dry-run || true)"
want "runs cursor-agent with --force"  "cursor-agent --force"        "$oauth_out"
want "auth method is oauth"            "DEVA_AUTH_METHOD=oauth"      "$oauth_out"
want "login URL printing wired"        "NO_OPEN_BROWSER=1"           "$oauth_out"

echo "=== cursor oauth: no host ~/.cursor mount, ever ==="
# Host ~/.cursor is the Cursor IDE's state dir; seed one and assert the
# legacy fallback does NOT bind it in.
mkdir -p "$tmp_home/.cursor"
ide_out="$(run_dry cursor --dry-run || true)"
want_absent "host IDE dir not mounted" "$tmp_home/.cursor:" "$ide_out"
rm -rf "$tmp_home/.cursor"

echo "=== cursor oauth: hybrid config-root mounts both homes ==="
# Seed the config-root layout the scaffold leaves behind and assert the
# centralized walk emits both canonical mounts (.cursor + .config/cursor).
mkdir -p "$tmp_home/.config/deva/cursor/.cursor"
mkdir -p "$tmp_home/.config/deva/cursor/.config/cursor"
hybrid_out="$(run_dry cursor --dry-run || true)"
want "data home mounted"   ":/home/deva/.cursor"        "$hybrid_out"
want "config home mounted" ":/home/deva/.config/cursor" "$hybrid_out"

echo "=== cursor api-key: CURSOR_API_KEY as env, no mount ==="
apikey_out="$(CURSOR_API_KEY=key_cur_test_1234 run_dry cursor --auth-with api-key --dry-run -- -p hi || true)"
want "key wired + redacted"          "CURSOR_API_KEY=<redacted>"      "$apikey_out"
want "key last-4 tags container"     "--api-key-1234--"               "$apikey_out"
want "passes agent args after --"    "cursor-agent --force -p hi"     "$apikey_out"
want_absent "no .cursor mount in api-key mode" ":/home/deva/.cursor\"" "$apikey_out"
# a user -v could still carry a config dir in; auth.json gets blanked
want "auth.json blank-overlayed"     ".blank:/home/deva/.config/cursor/auth.json" "$apikey_out"
rm -rf "$tmp_home/.config/deva/cursor"

echo "=== cursor oauth: host CURSOR_API_KEY must not leak ==="
leak_out="$(CURSOR_API_KEY=key_host_leak_9999 run_dry cursor -e CURSOR_API_KEY --dry-run || true)"
want_absent "host key filtered in oauth mode" "CURSOR_API_KEY" "$leak_out"

echo "=== cursor --trace: rejected until cctrace ships a profile ==="
trace_out="$(run_dry cursor --trace --dry-run || true)"
want "trace rejected" "--trace is not supported for cursor" "$trace_out"

echo "=== cursor --trace after -- is passthrough ==="
trace_pass_out="$(run_dry cursor --dry-run -- --trace || true)"
want_absent "--trace after -- not absorbed" "--trace is not supported" "$trace_pass_out"
want "--trace passed to agent" "cursor-agent --force --trace" "$trace_pass_out"

echo "=== cursor api-key: missing key errors ==="
missing_out="$(CURSOR_API_KEY= run_dry cursor --auth-with api-key --dry-run || true)"
want "errors when no key set" "CURSOR_API_KEY not set" "$missing_out"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: cursor auth wiring" >&2
    exit 1
fi
echo "OK: cursor auth wiring"
