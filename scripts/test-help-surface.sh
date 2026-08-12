#!/usr/bin/env bash
# test-help-surface.sh - layered help routing (#554)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp_home="$(mktemp -d)"
cleanup() { rm -rf "$tmp_home"; }
trap cleanup EXIT

fail=0
run() {
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

echo "=== short help: one screen with pointers ==="
short_out="$(run --help)"
short_lines="$(wc -l <<<"$short_out")"
if [ "$short_lines" -lt 50 ]; then
    echo "  PASS short help stays under 50 lines ($short_lines)"
else
    echo "  FAIL short help is $short_lines lines (wall came back?)"
    fail=1
fi
want "lists agents"            "claude (default), codex"  "$short_out"
want "points at help all"      "deva.sh help all"         "$short_out"
want "points at command help"  "<command> --help"         "$short_out"
want_absent "no cloak esoterica in short help" "cloak-vnc" "$short_out"
want_absent "no chrome esoterica in short help" "DEVA_CHROME_PROFILE_PATH" "$short_out"

echo "=== -h and bare help match --help ==="
[ "$(run -h)" = "$short_out" ] && echo "  PASS -h matches" || { echo "  FAIL -h differs"; fail=1; }
[ "$(run help)" = "$short_out" ] && echo "  PASS bare help matches" || { echo "  FAIL bare help differs"; fail=1; }

echo "=== help all: the full reference ==="
full_out="$(run help all)"
want "chrome section present"  "DEVA_CHROME_PROFILE_PATH" "$full_out"
want "cloak flags present"     "--cloak-vnc"              "$full_out"
want "naming section present"  "Container Naming"         "$full_out"
[ "$(run --help all)" = "$full_out" ] && echo "  PASS --help all matches" || { echo "  FAIL --help all differs"; fail=1; }

echo "=== per-command help ==="
ps_out="$(run ps --help)"
want "ps usage"                "Usage: deva.sh ps"        "$ps_out"
want_absent "ps help is not the wall" "Container Naming"  "$ps_out"
[ "$(run --help ps)" = "$ps_out" ] && echo "  PASS token order independent" || { echo "  FAIL --help ps differs"; fail=1; }
[ "$(run help ps)" = "$ps_out" ] && echo "  PASS help ps matches" || { echo "  FAIL help ps differs"; fail=1; }
want "status usage"            "Usage: deva.sh status"    "$(run status --help)"
want "rm knows --all"          "--all"                    "$(run rm --help)"
want "sessions notes passthrough" "ccx sessions"          "$(run sessions --help)"

echo "=== launch-path help stays global ==="
agent_help="$(run claude --help)"
want "agent --help shows global summary" "Common flags"   "$agent_help"
want_absent "agent --help is not a command help" "Usage: deva.sh ps" "$agent_help"

echo "=== sentinel passthrough untouched ==="
pass_out="$(run claude --dry-run -- --help || true)"
want "agent argv keeps --help"  "--help"                  "$pass_out"
want_absent "no usage screen on passthrough" "Common flags" "$pass_out"

echo "=== tmux keeps its own help ==="
want "tmux help intact" "deva.sh tmux setup" "$(run tmux --help)"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: help surface" >&2
    exit 1
fi
echo "OK: help surface"
