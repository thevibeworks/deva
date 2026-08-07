#!/usr/bin/env bash
# test-opencode-auth.sh - opencode agent auth wiring (XDG-trio mounts + api-key env)
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

echo "=== opencode oauth (default) ==="
oauth_out="$(run_dry opencode --debug --dry-run || true)"
want "runs opencode"                 "opencode"                       "$oauth_out"
want "auth method is oauth"          "DEVA_AUTH_METHOD=oauth"         "$oauth_out"
want "sandbox permission override"   'OPENCODE_PERMISSION={"doom_loop":"allow"' "$oauth_out"
want "autoupdate disabled"           "OPENCODE_DISABLE_AUTOUPDATE=1"  "$oauth_out"

echo "=== opencode oauth: hybrid config-root mounts the XDG trio ==="
# Seed the config-root layout an autolinked oauth run leaves behind and
# assert the centralized walk (mount_agent_canonical) emits nested mounts.
mkdir -p "$tmp_home/.config/deva/opencode/.config/opencode" \
         "$tmp_home/.config/deva/opencode/.local/share/opencode" \
         "$tmp_home/.config/deva/opencode/.local/state/opencode"
hybrid_oauth_out="$(run_dry opencode --dry-run || true)"
want "config dir mounted"  ":/home/deva/.config/opencode"      "$hybrid_oauth_out"
want "data dir mounted"    ":/home/deva/.local/share/opencode" "$hybrid_oauth_out"
want "state dir mounted"   ":/home/deva/.local/state/opencode" "$hybrid_oauth_out"
want_absent "cache dir never mounted" ":/home/deva/.cache/opencode" "$hybrid_oauth_out"

echo "=== opencode api-key: OPENCODE_API_KEY env, no mount ==="
apikey_out="$(OPENCODE_API_KEY=sk-test-opencode-1234 run_dry opencode --auth-with api-key --dry-run -- run hi || true)"
want "api key wired + redacted"    "OPENCODE_API_KEY=<redacted>"     "$apikey_out"
want "key last-4 tags container"   "--api-key-1234--"                "$apikey_out"
want "passes agent args after --"  "opencode run hi"                 "$apikey_out"
want_absent "no config dir mount in api-key mode" ":/home/deva/.config/opencode"      "$apikey_out"
want_absent "no state dir mount in api-key mode"  ":/home/deva/.local/state/opencode" "$apikey_out"
# The data dir itself must not ride in; the blank overlay at auth.json is
# expected (a user -v could still carry a data dir with auth.json in it).
want "auth.json blank-overlayed"   ".blank:/home/deva/.local/share/opencode/auth.json" "$apikey_out"

echo "=== opencode api-key: no mount on the hybrid config-root path either ==="
hybrid_apikey_out="$(OPENCODE_API_KEY=sk-test-opencode-1234 run_dry opencode --auth-with api-key --dry-run || true)"
want_absent "hybrid layout: no config dir mount in api-key mode" ":/home/deva/.config/opencode" "$hybrid_apikey_out"
rm -rf "$tmp_home/.config/deva/opencode"

echo "=== opencode oauth: host OPENCODE_API_KEY must not leak ==="
leak_out="$(OPENCODE_API_KEY=sk-host-leak-9999 run_dry opencode -e OPENCODE_API_KEY --dry-run || true)"
want_absent "host key filtered in oauth mode" "OPENCODE_API_KEY" "$leak_out"

echo "=== opencode --trace: rejected until cctrace ships a profile ==="
trace_out="$(run_dry opencode --trace --dry-run || true)"
want "trace rejected"          "--trace is not supported for opencode" "$trace_out"
want "points at cctrace issue" "thevibeworks/cctrace#89"               "$trace_out"

echo "=== opencode --trace after -- is passthrough ==="
trace_pass_out="$(run_dry opencode --dry-run -- --trace || true)"
want_absent "--trace after -- not absorbed" "--trace is not supported" "$trace_pass_out"
want "--trace passed to agent"     "opencode --trace"                  "$trace_pass_out"

echo "=== opencode api-key: missing key errors ==="
missing_out="$(OPENCODE_API_KEY= run_dry opencode --auth-with api-key --dry-run || true)"
want "errors when key unset"       "OPENCODE_API_KEY not set"          "$missing_out"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: opencode auth wiring" >&2
    exit 1
fi
echo "OK: opencode auth wiring"
