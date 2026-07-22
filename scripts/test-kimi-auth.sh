#!/usr/bin/env bash
# test-kimi-auth.sh - kimi agent auth wiring (oauth mount + api-key env synth)
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

echo "=== kimi oauth (default) ==="
oauth_out="$(run_dry kimi --debug --dry-run || true)"
want "runs kimi --yolo"            "kimi --yolo"           "$oauth_out"
want "auth method is oauth"        "DEVA_AUTH_METHOD=oauth" "$oauth_out"

echo "=== kimi api-key: KIMI_MODEL_* synth, no mount ==="
apikey_out="$(KIMI_CODE_API_KEY=sk-test-kimi-1234 run_dry kimi --auth-with api-key --dry-run -- -p hi || true)"
want "model name defaults to k3"   "KIMI_MODEL_NAME=k3"                        "$apikey_out"
want "api key wired + redacted"    "KIMI_MODEL_API_KEY=<redacted>"             "$apikey_out"
want "key last-4 tags container"   "--api-key-1234--"                          "$apikey_out"
want "provider type kimi"          "KIMI_MODEL_PROVIDER_TYPE=kimi"             "$apikey_out"
want "coding endpoint base url"    "KIMI_MODEL_BASE_URL=https://api.kimi.com/coding/v1" "$apikey_out"
want "passes agent args after --"  "kimi --yolo -p hi"                         "$apikey_out"
want_absent "no ~/.kimi-code mount in api-key mode" ":/home/deva/.kimi-code"   "$apikey_out"

echo "=== kimi api-key: no mount on the hybrid config-root path either ==="
# The centralized mount walk (mount_agent_canonical) is a different code path
# from the legacy \$HOME fallback: seed the autolinked hybrid layout that any
# prior oauth run leaves behind and assert api-key mode still mounts nothing.
mkdir -p "$tmp_home/.config/deva/kimi/.kimi-code"
hybrid_out="$(KIMI_CODE_API_KEY=sk-test-kimi-1234 run_dry kimi --auth-with api-key --dry-run || true)"
want_absent "hybrid layout: no .kimi-code mount in api-key mode" ":/home/deva/.kimi-code" "$hybrid_out"
hybrid_oauth_out="$(run_dry kimi --dry-run || true)"
want "hybrid layout: oauth still mounts .kimi-code" ":/home/deva/.kimi-code" "$hybrid_oauth_out"
rm -rf "$tmp_home/.config/deva/kimi"

echo "=== kimi api-key: DEVA_KIMI_MODEL / DEVA_KIMI_BASE_URL overrides ==="
override_out="$(KIMI_CODE_API_KEY=sk-test-kimi-1234 DEVA_KIMI_MODEL=kimi-for-coding \
    DEVA_KIMI_BASE_URL=https://api.moonshot.ai/v1 \
    run_dry kimi --auth-with api-key --dry-run || true)"
want "model override honored"      "KIMI_MODEL_NAME=kimi-for-coding"           "$override_out"
want "base url override honored"   "KIMI_MODEL_BASE_URL=https://api.moonshot.ai/v1" "$override_out"

echo "=== kimi --trace: cctrace wrapping ==="
trace_out="$(run_dry kimi --trace --dry-run || true)"
want "wraps with cctrace kimi"     "cctrace kimi --no-open --"                "$trace_out"
want "DEVA_TRACE=1 injected"       "DEVA_TRACE=1"                             "$trace_out"
want "--yolo still present"        "--yolo"                                   "$trace_out"

echo "=== kimi --trace after -- is passthrough ==="
trace_pass_out="$(run_dry kimi --dry-run -- --trace || true)"
want_absent "--trace before -- absorbed" "cctrace"                            "$trace_pass_out"
want "--trace passed to agent"     "kimi --yolo --trace"                      "$trace_pass_out"

echo "=== kimi api-key + trace ==="
trace_apikey_out="$(KIMI_CODE_API_KEY=sk-test-kimi-5678 run_dry kimi --auth-with api-key --trace --dry-run || true)"
want "trace + api-key: cctrace"    "cctrace kimi --no-open --"                "$trace_apikey_out"
want "trace + api-key: key wired"  "KIMI_MODEL_API_KEY=<redacted>"            "$trace_apikey_out"

echo "=== kimi api-key: missing key errors ==="
missing_out="$(KIMI_CODE_API_KEY= run_dry kimi --auth-with api-key --dry-run || true)"
want "errors when key unset"       "KIMI_CODE_API_KEY not set"                 "$missing_out"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: kimi auth wiring" >&2
    exit 1
fi
echo "OK: kimi auth wiring"
