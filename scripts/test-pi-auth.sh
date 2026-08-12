#!/usr/bin/env bash
# test-pi-auth.sh - pi agent auth wiring (~/.pi mount + provider-key env)
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

echo "=== pi oauth (default) ==="
oauth_out="$(run_dry pi --debug --dry-run || true)"
want "runs pi"                       "pi --approve"                   "$oauth_out"
want "auth method is oauth"          "DEVA_AUTH_METHOD=oauth"         "$oauth_out"
want "version check disabled"        "PI_SKIP_VERSION_CHECK=1"        "$oauth_out"

echo "=== pi oauth: hybrid config-root mounts ~/.pi ==="
# Seed the config-root layout an autolinked oauth run leaves behind and
# assert the centralized walk (mount_agent_canonical) emits the mount.
mkdir -p "$tmp_home/.config/deva/pi/.pi/agent"
hybrid_oauth_out="$(run_dry pi --dry-run || true)"
want "pi home mounted" ":/home/deva/.pi" "$hybrid_oauth_out"

echo "=== pi api-key: provider keys as env, no mount ==="
apikey_out="$(ANTHROPIC_API_KEY=sk-ant-test-1234 XAI_API_KEY=xai-test-5678 run_dry pi --auth-with api-key --dry-run -- -p hi || true)"
want "anthropic key wired + redacted" "ANTHROPIC_API_KEY=<redacted>"  "$apikey_out"
want "second provider key travels too" "XAI_API_KEY=<redacted>"       "$apikey_out"
want "first-key last-4 tags container" "--api-key-1234--"             "$apikey_out"
want "passes agent args after --"    "pi --approve -p hi"             "$apikey_out"
want_absent "no ~/.pi mount in api-key mode" ":/home/deva/.pi\"" "$apikey_out"
# ~/.pi itself must not ride in; the blank overlay at auth.json is
# expected (a user -v could still carry a dir with auth.json in it).
want "auth.json blank-overlayed"     ".blank:/home/deva/.pi/agent/auth.json" "$apikey_out"

echo "=== pi api-key: no mount on the hybrid config-root path either ==="
hybrid_apikey_out="$(ANTHROPIC_API_KEY=sk-ant-test-1234 run_dry pi --auth-with api-key --dry-run || true)"
want_absent "hybrid layout: no ~/.pi mount in api-key mode" ":/home/deva/.pi\"" "$hybrid_apikey_out"
rm -rf "$tmp_home/.config/deva/pi"

echo "=== pi oauth: host provider keys must not leak ==="
leak_out="$(ANTHROPIC_API_KEY=sk-host-leak-9999 run_dry pi -e ANTHROPIC_API_KEY --dry-run || true)"
want_absent "host key filtered in oauth mode" "ANTHROPIC_API_KEY" "$leak_out"

echo "=== pi --trace: rejected until cctrace ships a profile ==="
trace_out="$(run_dry pi --trace --dry-run || true)"
want "trace rejected" "--trace is not supported for pi" "$trace_out"

echo "=== pi --trace after -- is passthrough ==="
trace_pass_out="$(run_dry pi --dry-run -- --trace || true)"
want_absent "--trace after -- not absorbed" "--trace is not supported" "$trace_pass_out"
want "--trace passed to agent" "pi --approve --trace" "$trace_pass_out"

echo "=== pi api-key: missing key errors ==="
missing_out="$(ANTHROPIC_API_KEY= OPENAI_API_KEY= GEMINI_API_KEY= XAI_API_KEY= OPENROUTER_API_KEY= run_dry pi --auth-with api-key --dry-run || true)"
want "errors when no key set" "no provider API key set" "$missing_out"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: pi auth wiring" >&2
    exit 1
fi
echo "OK: pi auth wiring"
