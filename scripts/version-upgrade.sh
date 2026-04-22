#!/usr/bin/env bash
# version-upgrade.sh - Upgrade all tools to latest versions
# Shows changelogs first, then builds after confirmation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./release-utils.sh
source "$SCRIPT_DIR/release-utils.sh"

# Snapshot explicit CLI overrides BEFORE version-pins fills defaults from
# versions.env. Makefile VERSION_QUERY_OVERRIDES only forwards vars whose
# $(origin) is command-line/environment/override, so anything already set
# here is a genuine user override — not a pin default.
_CLI_CLAUDE_CODE="${CLAUDE_CODE_VERSION:-}"
_CLI_CLAUDE_TRACE="${CLAUDE_TRACE_VERSION:-}"
_CLI_CODEX="${CODEX_VERSION:-}"
_CLI_GEMINI="${GEMINI_CLI_VERSION:-}"
_CLI_ATLAS="${ATLAS_CLI_VERSION:-}"
_CLI_COPILOT="${COPILOT_API_VERSION:-}"
_CLI_PLAYWRIGHT="${PLAYWRIGHT_VERSION:-}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/version-pins.sh"

# Defaults
CHECK_IMAGE=${MAIN_IMAGE:-ghcr.io/thevibeworks/deva:latest}
BUILD_IMAGE=${BUILD_IMAGE:-ghcr.io/thevibeworks/deva:latest}
RUST_IMAGE=${RUST_IMAGE:-ghcr.io/thevibeworks/deva:rust}
DOCKERFILE=${DOCKERFILE:-Dockerfile}
RUST_DOCKERFILE=${RUST_DOCKERFILE:-Dockerfile.rust}
COUNTDOWN=${COUNTDOWN:-5}
AUTO_YES=${AUTO_YES:-}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -y, --yes       Skip confirmation countdown
  -h, --help      Show this help

Environment:
  MAIN_IMAGE            Main image name (default: ghcr.io/thevibeworks/deva:latest)
  RUST_IMAGE            Rust image name (default: ghcr.io/thevibeworks/deva:rust)
  VERSION_PINS_FILE     Shared version pin file (default: versions.env)
  CLAUDE_CODE_VERSION   Override claude-code version
  CLAUDE_TRACE_VERSION  Override claude-trace version
  CODEX_VERSION         Override codex version
  GEMINI_CLI_VERSION    Override gemini-cli version
  ATLAS_CLI_VERSION     Override atlas-cli version
  COPILOT_API_VERSION   Override copilot-api version
  PLAYWRIGHT_VERSION    Override playwright version (rust image only)
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes) AUTO_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

main() {
    load_version_pins

    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Upgrading to Latest Versions                      ║${RESET}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════╝${RESET}"
    echo -e "${DIM}Time: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo -e "${DIM}Check: ${CHECK_IMAGE}  Build: ${BUILD_IMAGE}${RESET}"
    echo ""

    bash "$SCRIPT_DIR/toolchain-report.sh"

    load_versions "$CHECK_IMAGE"

    if print_version_summary; then
        echo -e "${GREEN}All versions up-to-date. Nothing to upgrade.${RESET}"
        exit 0
    fi

    print_changelogs

    if [[ -z $AUTO_YES ]]; then
        echo -e "${YELLOW}${BOLD}Starting build in ${COUNTDOWN} seconds... Press Ctrl+C to cancel${RESET}"
        echo -e "${DIM}Hint: Override via CLAUDE_CODE_VERSION=... CODEX_VERSION=... etc.${RESET}"
        for i in $(seq "$COUNTDOWN" -1 1); do
            echo -ne "\r${CYAN}${BOLD}$i...${RESET}  "
            sleep 1
        done
        echo -ne "\r\033[K"
    fi

    echo -e "${GREEN}Proceeding with build...${RESET}"
    echo ""

    # CLI override wins; otherwise use whatever load_versions fetched.
    local claude_ver claude_trace_ver codex_ver gemini_ver atlas_ver copilot_ver playwright_ver
    claude_ver="${_CLI_CLAUDE_CODE:-$(get_latest "claude-code")}"
    claude_trace_ver="${_CLI_CLAUDE_TRACE:-$(get_latest "claude-trace")}"
    codex_ver="${_CLI_CODEX:-$(get_latest "codex")}"
    gemini_ver="${_CLI_GEMINI:-$(get_latest "gemini-cli")}"
    atlas_ver="${_CLI_ATLAS:-$(get_latest "atlas-cli")}"
    copilot_ver="${_CLI_COPILOT:-$(get_latest "copilot-api")}"
    playwright_ver="${_CLI_PLAYWRIGHT:-$(get_latest "playwright")}"

    # Verify all required versions are set
    local missing=()
    [[ -z $claude_ver ]] && missing+=("CLAUDE_CODE_VERSION")
    [[ -z $codex_ver ]] && missing+=("CODEX_VERSION")
    [[ -z $gemini_ver ]] && missing+=("GEMINI_CLI_VERSION")
    [[ -z $atlas_ver ]] && missing+=("ATLAS_CLI_VERSION")
    [[ -z $copilot_ver ]] && missing+=("COPILOT_API_VERSION")
    [[ -z $playwright_ver ]] && missing+=("PLAYWRIGHT_VERSION")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Warning: Could not determine versions for: ${missing[*]}${RESET}"
        echo -e "${DIM}Set them manually: ${missing[*]/%/=x.x.x} make versions-up${RESET}"
        echo -e "${DIM}Proceeding with build anyway...${RESET}"
        echo ""
    fi

    section "Building Main Image"
    docker build -f "$DOCKERFILE" \
        --build-arg NODE_MAJOR="$NODE_MAJOR" \
        --build-arg GO_VERSION="$GO_VERSION" \
        --build-arg PYTHON_VERSION="$PYTHON_VERSION" \
        --build-arg DELTA_VERSION="$DELTA_VERSION" \
        --build-arg TMUX_VERSION="$TMUX_VERSION" \
        --build-arg TMUX_SHA256="$TMUX_SHA256" \
        --build-arg CLAUDE_CODE_VERSION="$claude_ver" \
        --build-arg CLAUDE_TRACE_VERSION="$claude_trace_ver" \
        --build-arg CODEX_VERSION="$codex_ver" \
        --build-arg GEMINI_CLI_VERSION="$gemini_ver" \
        --build-arg ATLAS_CLI_VERSION="$atlas_ver" \
        --build-arg COPILOT_API_VERSION="$copilot_ver" \
        -t "$BUILD_IMAGE" .

    echo ""
    section "Building Rust Image"
    docker build -f "$RUST_DOCKERFILE" \
        --build-arg BASE_IMAGE="$BUILD_IMAGE" \
        --build-arg CLAUDE_CODE_VERSION="$claude_ver" \
        --build-arg CLAUDE_TRACE_VERSION="$claude_trace_ver" \
        --build-arg CODEX_VERSION="$codex_ver" \
        --build-arg GEMINI_CLI_VERSION="$gemini_ver" \
        --build-arg ATLAS_CLI_VERSION="$atlas_ver" \
        --build-arg PLAYWRIGHT_VERSION="$playwright_ver" \
        --build-arg RUST_TOOLCHAINS="$RUST_TOOLCHAINS" \
        --build-arg RUST_DEFAULT_TOOLCHAIN="$RUST_DEFAULT_TOOLCHAIN" \
        --build-arg RUST_TARGETS="$RUST_TARGETS" \
        -t "$RUST_IMAGE" .

    echo ""
    echo -e "${GREEN}${BOLD}All images upgraded successfully${RESET}"
    echo -e "${DIM}Completed: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
}

main
