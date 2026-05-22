#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/version-pins.sh"
load_version_pins

tmp_root="$(mktemp -d)"
cleanup() {
    chmod 700 "$tmp_root/deny" 2>/dev/null || true
    rm -rf "$tmp_root"
}
trap cleanup EXIT

fake_bin="$tmp_root/fake-bin"
fake_home="$tmp_root/home"
mkdir -p "$fake_bin" "$fake_home"

cat >"$fake_bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prefix_file="${DEVA_HOME}/.npm-prefix"
cmd="${1:-}"
shift || true

case "$cmd" in
config)
    [ "${1:-}" = "set" ] || exit 1
    [ "${2:-}" = "prefix" ] || exit 1
    printf '%s\n' "${3:-}" >"$prefix_file"
    ;;
install)
    mkdir -p "$DEVA_HOME/.npm-global/bin"
    for bin in claude codex gemini claude-trace; do
        cat >"$DEVA_HOME/.npm-global/bin/$bin" <<'BIN'
#!/usr/bin/env bash
case "$(basename "$0")" in
  claude) echo "__CLAUDE_CODE_VERSION__ (Claude Code)" ;;
  codex) echo "codex-cli __CODEX_VERSION__" ;;
  gemini) echo "__GEMINI_CLI_VERSION__" ;;
  claude-trace) exit 0 ;;
esac
BIN
        chmod +x "$DEVA_HOME/.npm-global/bin/$bin"
    done
    ;;
cache)
    ;;
list)
    echo "fake npm list"
    ;;
*)
    echo "unexpected npm invocation: $cmd $*" >&2
    exit 1
    ;;
esac
EOF

sed -i \
    -e "s#__CLAUDE_CODE_VERSION__#$CLAUDE_CODE_VERSION#g" \
    -e "s#__CODEX_VERSION__#$CODEX_VERSION#g" \
    -e "s#__GEMINI_CLI_VERSION__#$GEMINI_CLI_VERSION#g" \
    "$fake_bin/npm"

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

out=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
    -o)
        out="$2"
        shift 2
        ;;
    http*)
        url="$1"
        shift
        ;;
    *)
        shift
        ;;
    esac
done

case "$url" in
    *"/releases/download/"*)
        exit 22
        ;;
    *"/skills/atl-cli/SKILL.md")
        printf '%s\n' '# fake atlas skill' >"$out"
        ;;
    *"/skills/atl-cli/references/confluence-guidelines.md")
        printf '%s\n' 'fake confluence guidelines' >"$out"
        ;;
    *)
        echo "unexpected curl url: $url" >&2
        exit 1
        ;;
esac
EOF

cat >"$fake_bin/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import os
os.stat(".")
PY

mkdir -p "${GOBIN:?GOBIN is required}"
cat >"$GOBIN/atl" <<'BIN'
#!/usr/bin/env bash
echo "atl fake"
BIN
chmod +x "$GOBIN/atl"
EOF

chmod +x "$fake_bin/npm" "$fake_bin/curl" "$fake_bin/go"

mkdir -p "$tmp_root/deny"
(
    cd "$tmp_root/deny"
    chmod 000 "$tmp_root/deny"

    output="$(
        PATH="$fake_bin:/usr/bin:/bin" \
        HOME="$fake_home" \
        DEVA_HOME="$fake_home" \
        CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
        CLAUDE_TRACE_VERSION="$CLAUDE_TRACE_VERSION" \
        CODEX_VERSION="$CODEX_VERSION" \
        GEMINI_CLI_VERSION="$GEMINI_CLI_VERSION" \
        ATLAS_CLI_VERSION="$ATLAS_CLI_VERSION" \
        bash "$REPO_ROOT/scripts/install-agent-tooling.sh" 2>&1
    )"

    grep -F "Current working directory is not accessible; switching to $fake_home" <<<"$output" >/dev/null
    grep -F "Installing npm agent tooling" <<<"$output" >/dev/null
    grep -F "claude-trace=$CLAUDE_TRACE_VERSION" <<<"$output" >/dev/null
    grep -F "Installing atlas-cli pinned to $ATLAS_CLI_VERSION" <<<"$output" >/dev/null
    grep -F "falling back to pinned go install" <<<"$output" >/dev/null
    grep -F "atlas-cli installed" <<<"$output" >/dev/null
    test -x "$fake_home/.local/bin/atl"
)
