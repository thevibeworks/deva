#!/usr/bin/env bash
# toolchain-report.sh - Print pinned image toolchains and managed build-time tools

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/version-pins.sh"

heading() {
    printf '\n%s\n\n' "$1"
}

line() {
    printf '  %-24s %s\n' "$1" "$2"
}

main() {
    load_version_pins

    heading "Toolchains (pinned — edit versions.env to bump)"
    line "Node.js line:" "${NODE_MAJOR}.x"
    line "Go:" "$GO_VERSION"
    line "Python:" "$PYTHON_VERSION"
    line "Rust toolchains:" "$RUST_TOOLCHAINS"
    line "Rust default:" "$RUST_DEFAULT_TOOLCHAIN"
    line "Rust targets:" "$RUST_TARGETS"
    line "delta:" "$DELTA_VERSION"
    line "tmux:" "$TMUX_VERSION"

    heading "Agent Tools (auto-upgraded by make versions-up)"
    line "Claude Code:" "$CLAUDE_CODE_VERSION"
    line "Claude Trace:" "$CLAUDE_TRACE_VERSION"
    line "Codex:" "$CODEX_VERSION"
    line "Gemini CLI:" "$GEMINI_CLI_VERSION"
    line "Atlas CLI:" "$ATLAS_CLI_VERSION"
    line "Copilot API:" "$COPILOT_API_VERSION"

    heading "Browser Tooling (pinned — edit versions.env to bump)"
    line "Playwright:" "$PLAYWRIGHT_VERSION"

    heading "Floating Build-Time Tools"
    line "Bun:" "latest stable via bun.sh install script"
    line "uv:" "latest stable via astral installer"
    line "npm:" "latest via npm install -g npm@latest"
    line "pnpm:" "latest via npm install -g pnpm"
    line "GitHub CLI:" "latest apt package from cli.github.com"
    line "AWS CLI v2:" "latest bundled installer from awscli.amazonaws.com"
    line "Docker CLI:" "latest apt package from download.docker.com"
    line "Docker Compose:" "latest compose plugin from download.docker.com"
}

main "$@"
