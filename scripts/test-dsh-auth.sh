#!/usr/bin/env bash
# test-dsh-auth.sh - dsh agent auth wiring (~/.dsh mount + DEEPSEEK_API_KEY env)
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

echo "=== dsh credentials (default) ==="
cred_out="$(run_dry dsh --debug --dry-run || true)"
want "auth method is credentials"    "DEVA_AUTH_METHOD=credentials"   "$cred_out"
want "permission bypass wired"       "DSH_PERMISSION_MODE=danger-full-access" "$cred_out"
want "home pinned"                   "DSH_HOME=/home/deva/.dsh"       "$cred_out"

echo "=== dsh credentials: hybrid config-root mounts ~/.dsh ==="
# Seed the config-root layout an autolinked run leaves behind and assert
# the centralized walk (mount_agent_canonical) emits the mount.
mkdir -p "$tmp_home/.config/deva/dsh/.dsh"
hybrid_cred_out="$(run_dry dsh --dry-run || true)"
want "dsh home mounted" ":/home/deva/.dsh" "$hybrid_cred_out"

echo "=== dsh api-key: DEEPSEEK_API_KEY as env, no mount ==="
apikey_out="$(DEEPSEEK_API_KEY=sk-ds-test-1234 run_dry dsh --auth-with api-key --dry-run -- --profile headless hi || true)"
want "key wired + redacted"          "DEEPSEEK_API_KEY=<redacted>"    "$apikey_out"
want "key last-4 tags container"     "--api-key-1234--"               "$apikey_out"
want "passes agent args after --"    "dsh --profile headless hi"      "$apikey_out"
want_absent "no ~/.dsh mount in api-key mode" ":/home/deva/.dsh\"" "$apikey_out"

echo "=== dsh api-key: no mount on the hybrid config-root path either ==="
hybrid_apikey_out="$(DEEPSEEK_API_KEY=sk-ds-test-1234 run_dry dsh --auth-with api-key --dry-run || true)"
want_absent "hybrid layout: no ~/.dsh mount in api-key mode" ":/home/deva/.dsh\"" "$hybrid_apikey_out"
rm -rf "$tmp_home/.config/deva/dsh"

echo "=== dsh credentials: host DEEPSEEK_API_KEY must not leak ==="
# dsh resolves inherited env BEFORE ~/.dsh/.credentials.yaml, so a leaked
# host key would silently outrank the mounted credentials.
leak_out="$(DEEPSEEK_API_KEY=sk-host-leak-9999 run_dry dsh -e DEEPSEEK_API_KEY --dry-run || true)"
want_absent "host key filtered in credentials mode" "DEEPSEEK_API_KEY" "$leak_out"

echo "=== dsh --trace: rejected until cctrace ships a profile ==="
trace_out="$(run_dry dsh --trace --dry-run || true)"
want "trace rejected" "--trace is not supported for dsh" "$trace_out"

echo "=== dsh --trace after -- is passthrough ==="
trace_pass_out="$(run_dry dsh --dry-run -- --trace || true)"
want_absent "--trace after -- not absorbed" "--trace is not supported" "$trace_pass_out"
want "--trace passed to agent" "dsh --trace" "$trace_pass_out"

echo "=== dsh api-key: missing key errors ==="
missing_out="$(DEEPSEEK_API_KEY= run_dry dsh --auth-with api-key --dry-run || true)"
want "errors when no key set" "DEEPSEEK_API_KEY not set" "$missing_out"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: dsh auth wiring" >&2
    exit 1
fi
echo "OK: dsh auth wiring"
