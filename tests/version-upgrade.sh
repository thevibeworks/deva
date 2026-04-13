#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT="$(mktemp -d)"
FAKE_BIN="$TMP_ROOT/bin"
DOCKER_BUILD_LOG="$TMP_ROOT/docker-build.log"
mkdir -p "$FAKE_BIN"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat >"$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
inspect)
    cat <<'JSON'
[{"Config":{"Labels":{
  "org.opencontainers.image.claude_code_version":"2.1.81",
  "org.opencontainers.image.codex_version":"0.116.0",
  "org.opencontainers.image.gemini_cli_version":"0.35.0",
  "org.opencontainers.image.atlas_cli_version":"v0.1.4",
  "org.opencontainers.image.copilot_api_version":"0ea08febdd7e3e055b03dd298bf57e669500b5c1"
}}}]
JSON
    ;;
build)
    printf '%s\n' "$*" >>"$DOCKER_BUILD_LOG"
    ;;
*)
    echo "unexpected docker invocation: $*" >&2
    exit 1
    ;;
esac
EOF

cat >"$FAKE_BIN/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "view" ]]; then
    echo "unexpected npm invocation: $*" >&2
    exit 1
fi

case "${2:-}" in
@anthropic-ai/claude-code)
    echo "2.1.87"
    ;;
@anthropic-ai/claude-code@2.1.87)
    echo '{"2.1.87":"2026-03-29T01:40:00Z"}'
    ;;
@openai/codex)
    echo "0.117.0"
    ;;
@openai/codex@0.117.0)
    echo '{"0.117.0":"2026-03-26T22:28:00Z"}'
    ;;
@google/gemini-cli)
    echo "0.35.3"
    ;;
@google/gemini-cli@0.35.3)
    echo '{"0.35.3":"2026-03-28T03:17:00Z"}'
    ;;
*)
    echo "unexpected npm view args: $*" >&2
    exit 1
    ;;
esac
EOF

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "api" ]]; then
    echo "unexpected gh invocation: $*" >&2
    exit 1
fi

case "${2:-}" in
repos/lroolle/atlas-cli/releases/latest)
    echo "v0.1.4"
    ;;
repos/ericc-ch/copilot-api/branches/master)
    echo "0ea08febdd7e3e055b03dd298bf57e669500b5c1"
    ;;
repos/lroolle/atlas-cli/releases/tags/v0.1.4)
    echo "2026-01-16T05:42:00Z"
    ;;
repos/ericc-ch/copilot-api/commits/0ea08febdd7e3e055b03dd298bf57e669500b5c1)
    echo "2025-10-05T03:49:00Z"
    ;;
repos/openai/codex/releases)
    echo '[]'
    ;;
*)
    echo "unexpected gh api args: $*" >&2
    exit 1
    ;;
esac
EOF

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf ''
EOF

chmod +x "$FAKE_BIN/docker" "$FAKE_BIN/npm" "$FAKE_BIN/gh" "$FAKE_BIN/curl"

PATH="$FAKE_BIN:$PATH" \
DOCKER_BUILD_LOG="$DOCKER_BUILD_LOG" \
AUTO_YES=1 \
CHECK_IMAGE="ghcr.io/thevibeworks/deva:rust" \
BUILD_IMAGE="ghcr.io/thevibeworks/deva:latest" \
CORE_IMAGE="ghcr.io/thevibeworks/deva:core" \
RUST_IMAGE="ghcr.io/thevibeworks/deva:rust" \
GO_VERSION="1.26.2" \
PLAYWRIGHT_VERSION="1.59.1" \
PLAYWRIGHT_MCP_VERSION="0.0.70" \
"$REPO_ROOT/scripts/version-upgrade.sh" >/dev/null

core_build="$(sed -n '1p' "$DOCKER_BUILD_LOG")"
main_build="$(sed -n '2p' "$DOCKER_BUILD_LOG")"
rust_build="$(sed -n '3p' "$DOCKER_BUILD_LOG")"

[[ -n "$core_build" ]] || { echo "missing core build invocation" >&2; exit 1; }
[[ -n "$main_build" ]] || { echo "missing main build invocation" >&2; exit 1; }
[[ -n "$rust_build" ]] || { echo "missing rust build invocation" >&2; exit 1; }

for expected in \
    "--target agent-base" \
    "--build-arg COPILOT_API_VERSION=0ea08febdd7e3e055b03dd298bf57e669500b5c1" \
    "--build-arg GO_VERSION=1.26.2" \
    "-t ghcr.io/thevibeworks/deva:core ."
do
    [[ "$core_build" == *"$expected"* ]] || {
        echo "core build missing expected arg: $expected" >&2
        exit 1
    }
done

for expected in \
    "--build-arg CLAUDE_CODE_VERSION=2.1.87" \
    "--build-arg CODEX_VERSION=0.117.0" \
    "--build-arg GEMINI_CLI_VERSION=0.35.3" \
    "--build-arg ATLAS_CLI_VERSION=v0.1.4" \
    "--build-arg COPILOT_API_VERSION=0ea08febdd7e3e055b03dd298bf57e669500b5c1" \
    "--build-arg GO_VERSION=1.26.2"
do
    [[ "$main_build" == *"$expected"* ]] || {
        echo "main build missing expected arg: $expected" >&2
        exit 1
    }
done

for expected in \
    "--build-arg BASE_IMAGE=ghcr.io/thevibeworks/deva:core" \
    "--build-arg CLAUDE_CODE_VERSION=2.1.87" \
    "--build-arg CODEX_VERSION=0.117.0" \
    "--build-arg GEMINI_CLI_VERSION=0.35.3" \
    "--build-arg ATLAS_CLI_VERSION=v0.1.4" \
    "--build-arg PLAYWRIGHT_VERSION=1.59.1" \
    "--build-arg PLAYWRIGHT_MCP_VERSION=0.0.70"
do
    [[ "$rust_build" == *"$expected"* ]] || {
        echo "rust build missing expected arg: $expected" >&2
        exit 1
    }
done
