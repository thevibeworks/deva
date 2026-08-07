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
  "org.opencontainers.image.cctrace_version":"0.3.0",
  "org.opencontainers.image.codex_version":"0.116.0",
  "org.opencontainers.image.gemini_cli_version":"0.35.0",
  "org.opencontainers.image.grok_cli_version":"0.2.90",
  "org.opencontainers.image.kimi_code_version":"0.28.0",
  "org.opencontainers.image.opencode_version":"1.18.14",
  "org.opencontainers.image.ccx_version":"v0.7.0",
  "org.opencontainers.image.copilot_api_version":"0ea08febdd7e3e055b03dd298bf57e669500b5c1",
  "org.opencontainers.image.playwright_version":"1.59.0"
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

# npm must never be called: version resolution goes straight to the
# registry via curl. Tripwire catches regressions back to `npm view`
# (which honors .npmrc registry overrides and can serve stale metadata).
cat >"$FAKE_BIN/npm" <<'EOF'
#!/usr/bin/env bash
echo "unexpected npm invocation: $*" >&2
exit 1
EOF

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "api" ]]; then
    echo "unexpected gh invocation: $*" >&2
    exit 1
fi

case "${2:-}" in
repos/thevibeworks/ccx/releases/latest)
    echo "v0.7.0"
    ;;
repos/ericc-ch/copilot-api/branches/master)
    echo "0ea08febdd7e3e055b03dd298bf57e669500b5c1"
    ;;
repos/thevibeworks/ccx/releases/tags/v0.7.0)
    echo "2026-01-16T05:42:00Z"
    ;;
repos/ericc-ch/copilot-api/commits/0ea08febdd7e3e055b03dd298bf57e669500b5c1)
    echo "2025-10-05T03:49:00Z"
    ;;
repos/openai/codex/releases)
    echo '[]'
    ;;
repos/thevibeworks/cctrace/releases)
    echo '[]'
    ;;
repos/microsoft/playwright/releases)
    echo '[]'
    ;;
*)
    echo "unexpected gh api args: $*" >&2
    exit 1
    ;;
esac
EOF

# Realistic registry fixtures: dist-tags for fetch_latest_version,
# packument (.time) for fetch_version_date. Unknown URLs are a hard error
# so new fetch paths cannot silently no-op like the old empty-string stub.
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
case "$url" in
*/-/package/@anthropic-ai/claude-code/dist-tags) echo '{"latest":"2.1.87"}' ;;
*/-/package/@thevibeworks/cctrace/dist-tags)     echo '{"latest":"0.4.0"}' ;;
*/-/package/@openai/codex/dist-tags)             echo '{"latest":"0.117.0"}' ;;
*/-/package/@google/gemini-cli/dist-tags)        echo '{"latest":"0.35.3"}' ;;
*/-/package/@xai-official/grok/dist-tags)        echo '{"latest":"0.2.93"}' ;;
*/-/package/@moonshot-ai/kimi-code/dist-tags)    echo '{"latest":"0.28.0"}' ;;
*/-/package/opencode-ai/dist-tags)               echo '{"latest":"1.18.14"}' ;;
*/-/package/playwright/dist-tags)                echo '{"latest":"1.60.0"}' ;;
*/-/package/cloakbrowser/dist-tags)              echo '{"latest":"0.6.0"}' ;;
*registry.npmjs.org/@anthropic-ai%2fclaude-code) echo '{"time":{"2.1.87":"2026-03-29T01:40:00Z"}}' ;;
*registry.npmjs.org/@thevibeworks%2fcctrace)     echo '{"time":{"0.4.0":"2026-03-29T01:40:00Z"}}' ;;
*registry.npmjs.org/@openai%2fcodex)             echo '{"time":{"0.117.0":"2026-03-26T22:28:00Z"}}' ;;
*registry.npmjs.org/@google%2fgemini-cli)        echo '{"time":{"0.35.3":"2026-03-28T03:17:00Z"}}' ;;
*registry.npmjs.org/@xai-official%2fgrok)        echo '{"time":{"0.2.93":"2026-07-01T00:00:00Z"}}' ;;
*registry.npmjs.org/@moonshot-ai%2fkimi-code)    echo '{"time":{"0.28.0":"2026-07-10T00:00:00Z"}}' ;;
*registry.npmjs.org/opencode-ai)                 echo '{"time":{"1.18.14":"2026-08-01T00:00:00Z"}}' ;;
*registry.npmjs.org/playwright)                  echo '{"time":{"1.60.0":"2026-05-14T08:00:00Z"}}' ;;
*)
    echo "unexpected curl url: $url" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$FAKE_BIN/docker" "$FAKE_BIN/npm" "$FAKE_BIN/gh" "$FAKE_BIN/curl"

# versions-up writes VERSION_PINS_FILE after a successful build — every
# invocation must point it at a scratch copy or the test clobbers the
# repo's real versions.env. PR=0 keeps the git/PR stage out of scope here
# (versions-pr.sh has its own hermetic test).
MAIN_PINS="$TMP_ROOT/pins-main.env"
cp "$REPO_ROOT/versions.env" "$MAIN_PINS"

PATH="$FAKE_BIN:$PATH" \
DOCKER_BUILD_LOG="$DOCKER_BUILD_LOG" \
VERSION_PINS_FILE="$MAIN_PINS" \
PR=0 \
AUTO_YES=1 \
CHECK_IMAGE="ghcr.io/thevibeworks/deva:rust" \
BUILD_IMAGE="ghcr.io/thevibeworks/deva:latest" \
CORE_IMAGE="ghcr.io/thevibeworks/deva:core" \
RUST_IMAGE="ghcr.io/thevibeworks/deva:rust" \
CLOAK_IMAGE="ghcr.io/thevibeworks/deva:cloak" \
GO_VERSION="1.26.2" \
CCTRACE_VERSION="0.4.0" \
PLAYWRIGHT_VERSION="1.60.0" \
"$REPO_ROOT/scripts/version-upgrade.sh" >/dev/null

core_build="$(sed -n '1p' "$DOCKER_BUILD_LOG")"
main_build="$(sed -n '2p' "$DOCKER_BUILD_LOG")"
rust_build="$(sed -n '3p' "$DOCKER_BUILD_LOG")"
cloak_build="$(sed -n '4p' "$DOCKER_BUILD_LOG")"

[[ -n "$core_build" ]] || { echo "missing core build invocation" >&2; exit 1; }
[[ -n "$main_build" ]] || { echo "missing main build invocation" >&2; exit 1; }
[[ -n "$rust_build" ]] || { echo "missing rust build invocation" >&2; exit 1; }
[[ -n "$cloak_build" ]] || { echo "missing cloak build invocation" >&2; exit 1; }

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
    "--build-arg CCTRACE_VERSION=0.4.0" \
    "--build-arg CODEX_VERSION=0.117.0" \
    "--build-arg GEMINI_CLI_VERSION=0.35.3" \
    "--build-arg GROK_CLI_VERSION=0.2.93" \
    "--build-arg KIMI_CODE_VERSION=0.28.0" \
    "--build-arg CCX_VERSION=v0.7.0" \
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
    "--build-arg CCTRACE_VERSION=0.4.0" \
    "--build-arg CODEX_VERSION=0.117.0" \
    "--build-arg GEMINI_CLI_VERSION=0.35.3" \
    "--build-arg GROK_CLI_VERSION=0.2.93" \
    "--build-arg KIMI_CODE_VERSION=0.28.0" \
    "--build-arg CCX_VERSION=v0.7.0" \
    "--build-arg PLAYWRIGHT_VERSION=1.60.0"
do
    [[ "$rust_build" == *"$expected"* ]] || {
        echo "rust build missing expected arg: $expected" >&2
        exit 1
    }
done

for expected in \
    "--build-arg BASE_IMAGE=ghcr.io/thevibeworks/deva:rust" \
    "--build-arg CLOAKBROWSER_WRAPPER_VERSION=0.6.0" \
    "-t ghcr.io/thevibeworks/deva:cloak ."
do
    [[ "$cloak_build" == *"$expected"* ]] || {
        echo "cloak build missing expected arg: $expected" >&2
        exit 1
    }
done

# ───── pins written from the BUILT versions, not a second fetch ─────
for expected in \
    "CLAUDE_CODE_VERSION=2.1.87" \
    "CCTRACE_VERSION=0.4.0" \
    "CODEX_VERSION=0.117.0" \
    "GEMINI_CLI_VERSION=0.35.3" \
    "GROK_CLI_VERSION=0.2.93" \
    "KIMI_CODE_VERSION=0.28.0" \
    "CCX_VERSION=v0.7.0" \
    "COPILOT_API_VERSION=0ea08febdd7e3e055b03dd298bf57e669500b5c1" \
    "PLAYWRIGHT_VERSION=1.60.0" \
    "CLOAKBROWSER_WRAPPER_VERSION=0.6.0" \
    "GO_VERSION=1.26.2"
do
    grep -qx "$expected" "$MAIN_PINS" || {
        echo "pin file missing built version: $expected" >&2
        cat "$MAIN_PINS" >&2
        exit 1
    }
done

# ───── proxied build: localhost rewrite + host-gateway + redacted logs ─────
PROXY_BUILD_LOG="$TMP_ROOT/docker-build-proxy.log"
PROXY_PINS="$TMP_ROOT/pins-proxy.env"
cp "$REPO_ROOT/versions.env" "$PROXY_PINS"
proxy_out="$(PATH="$FAKE_BIN:$PATH" \
DOCKER_BUILD_LOG="$PROXY_BUILD_LOG" \
VERSION_PINS_FILE="$PROXY_PINS" \
PR=0 \
AUTO_YES=1 \
HTTP_PROXY="http://user:secret@127.0.0.1:7890" \
HTTPS_PROXY="http://localhost:7890" \
CHECK_IMAGE="ghcr.io/thevibeworks/deva:rust" \
BUILD_IMAGE="ghcr.io/thevibeworks/deva:latest" \
CORE_IMAGE="ghcr.io/thevibeworks/deva:core" \
RUST_IMAGE="ghcr.io/thevibeworks/deva:rust" \
CLOAK_IMAGE="ghcr.io/thevibeworks/deva:cloak" \
GO_VERSION="1.26.2" \
CCTRACE_VERSION="0.4.0" \
PLAYWRIGHT_VERSION="1.60.0" \
"$REPO_ROOT/scripts/version-upgrade.sh" 2>&1)"

proxy_build="$(sed -n '1p' "$PROXY_BUILD_LOG")"
for expected in \
    "--build-arg HTTP_PROXY=http://user:secret@host.docker.internal:7890" \
    "--build-arg HTTPS_PROXY=http://host.docker.internal:7890" \
    "--add-host host.docker.internal:host-gateway"
do
    [[ "$proxy_build" == *"$expected"* ]] || {
        echo "proxied build missing expected arg: $expected" >&2
        echo "$proxy_build" >&2
        exit 1
    }
done
if grep -F -- "user:secret@" <<<"$proxy_out" >/dev/null; then
    echo "proxy credentials leaked into script output" >&2
    exit 1
fi
if ! grep -F -- "://***@" <<<"$proxy_out" >/dev/null; then
    echo "expected redacted proxy URL in script output" >&2
    exit 1
fi

# ───── registry outage: warn + fall back to current, do not abort ─────
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$FAKE_BIN/curl"

OUTAGE_BUILD_LOG="$TMP_ROOT/docker-build-outage.log"
OUTAGE_PINS="$TMP_ROOT/pins-outage.env"
cp "$REPO_ROOT/versions.env" "$OUTAGE_PINS"
if ! outage_out="$(PATH="$FAKE_BIN:$PATH" \
DOCKER_BUILD_LOG="$OUTAGE_BUILD_LOG" \
VERSION_PINS_FILE="$OUTAGE_PINS" \
PR=0 \
AUTO_YES=1 \
CHECK_IMAGE="ghcr.io/thevibeworks/deva:rust" \
BUILD_IMAGE="ghcr.io/thevibeworks/deva:latest" \
CORE_IMAGE="ghcr.io/thevibeworks/deva:core" \
RUST_IMAGE="ghcr.io/thevibeworks/deva:rust" \
CLOAK_IMAGE="ghcr.io/thevibeworks/deva:cloak" \
GO_VERSION="1.26.2" \
CCTRACE_VERSION="0.4.0" \
PLAYWRIGHT_VERSION="1.60.0" \
"$REPO_ROOT/scripts/version-upgrade.sh" 2>&1)"; then
    echo "registry outage must degrade to warnings, not abort the run" >&2
    echo "$outage_out" >&2
    exit 1
fi
if ! grep -F -- "Failed to fetch latest" <<<"$outage_out" >/dev/null; then
    echo "expected fetch-failure warnings during outage" >&2
    echo "$outage_out" >&2
    exit 1
fi
if ! grep -F -- "All versions up-to-date" <<<"$outage_out" >/dev/null; then
    echo "expected up-to-date fallback conclusion during outage" >&2
    echo "$outage_out" >&2
    exit 1
fi
if [[ -s "$OUTAGE_BUILD_LOG" ]]; then
    echo "no builds should run during a registry outage" >&2
    exit 1
fi
if ! diff -u "$REPO_ROOT/versions.env" "$OUTAGE_PINS" >/dev/null; then
    echo "registry outage must not rewrite the pin file" >&2
    exit 1
fi

# ───── update-version-pins: write_version_pins round-trips versions.env ─────
# The heredoc in write_version_pins is a second copy of the file layout: a
# pin present in versions.env but missing from the heredoc is silently
# deleted on the next `make versions-pin`. With every upstream fetch failing
# (curl still exits 22 from the outage block, git stubbed below), a rewrite
# must reproduce the file byte-for-byte, comments included.
cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/git"

PINS_COPY="$TMP_ROOT/versions.env"
cp "$REPO_ROOT/versions.env" "$PINS_COPY"
if ! PATH="$FAKE_BIN:$PATH" \
    VERSION_PINS_FILE="$PINS_COPY" \
    bash "$REPO_ROOT/scripts/update-version-pins.sh" >/dev/null 2>&1; then
    echo "update-version-pins.sh failed during round-trip check" >&2
    exit 1
fi
if ! diff -u "$REPO_ROOT/versions.env" "$PINS_COPY"; then
    echo "write_version_pins does not round-trip versions.env: pins or comments lost" >&2
    exit 1
fi

# ───── PR stage soft-fails: a dead git must not sink a finished build ─────
# Working curl again, but git still exits 1 (from the round-trip block):
# versions-pr.sh dies on fetch, version-upgrade.sh must warn and exit 0.
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
case "$url" in
*/-/package/@anthropic-ai/claude-code/dist-tags) echo '{"latest":"2.1.87"}' ;;
*/-/package/@thevibeworks/cctrace/dist-tags)     echo '{"latest":"0.4.0"}' ;;
*/-/package/@openai/codex/dist-tags)             echo '{"latest":"0.117.0"}' ;;
*/-/package/@google/gemini-cli/dist-tags)        echo '{"latest":"0.35.3"}' ;;
*/-/package/@xai-official/grok/dist-tags)        echo '{"latest":"0.2.93"}' ;;
*/-/package/@moonshot-ai/kimi-code/dist-tags)    echo '{"latest":"0.28.0"}' ;;
*/-/package/opencode-ai/dist-tags)               echo '{"latest":"1.18.14"}' ;;
*/-/package/playwright/dist-tags)                echo '{"latest":"1.60.0"}' ;;
*/-/package/cloakbrowser/dist-tags)              echo '{"latest":"0.6.0"}' ;;
*registry.npmjs.org/*)                           echo '{"time":{}}' ;;
*)
    echo "unexpected curl url: $url" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/curl"

PRFAIL_BUILD_LOG="$TMP_ROOT/docker-build-prfail.log"
PRFAIL_PINS="$TMP_ROOT/pins-prfail.env"
cp "$REPO_ROOT/versions.env" "$PRFAIL_PINS"
if ! prfail_out="$(PATH="$FAKE_BIN:$PATH" \
DOCKER_BUILD_LOG="$PRFAIL_BUILD_LOG" \
VERSION_PINS_FILE="$PRFAIL_PINS" \
AUTO_YES=1 \
CHECK_IMAGE="ghcr.io/thevibeworks/deva:rust" \
BUILD_IMAGE="ghcr.io/thevibeworks/deva:latest" \
CORE_IMAGE="ghcr.io/thevibeworks/deva:core" \
RUST_IMAGE="ghcr.io/thevibeworks/deva:rust" \
CLOAK_IMAGE="ghcr.io/thevibeworks/deva:cloak" \
GO_VERSION="1.26.2" \
CCTRACE_VERSION="0.4.0" \
PLAYWRIGHT_VERSION="1.60.0" \
"$REPO_ROOT/scripts/version-upgrade.sh" 2>&1)"; then
    echo "a failed PR stage must not fail versions-up after a good build" >&2
    echo "$prfail_out" >&2
    exit 1
fi
if ! grep -F -- "PR creation failed" <<<"$prfail_out" >/dev/null; then
    echo "expected PR soft-fail warning in output" >&2
    echo "$prfail_out" >&2
    exit 1
fi
grep -qx "CLAUDE_CODE_VERSION=2.1.87" "$PRFAIL_PINS" || {
    echo "pins must still be written when the PR stage fails" >&2
    exit 1
}
