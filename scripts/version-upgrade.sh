#!/usr/bin/env bash
# version-upgrade.sh - Upgrade all tools to latest versions
# Shows changelogs first, then builds after confirmation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release-utils.sh"

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
  CLAUDE_CODE_VERSION   Override claude-code version
  CODEX_VERSION         Override codex version
  GEMINI_CLI_VERSION    Override gemini-cli version
  ATLAS_CLI_VERSION     Override atlas-cli version
  COPILOT_API_VERSION   Override copilot-api version
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
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Upgrading to Latest Versions                      ║${RESET}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════╝${RESET}"
    echo -e "${DIM}Time: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo -e "${DIM}Check: ${CHECK_IMAGE}  Build: ${BUILD_IMAGE}${RESET}"
    echo ""

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

    local claude_ver=$(get_latest "claude-code")
    local codex_ver=$(get_latest "codex")
    local gemini_ver=$(get_latest "gemini-cli")
    local atlas_ver=$(get_latest "atlas-cli")
    local copilot_ver=$(get_latest "copilot-api")

    # Verify all required versions are set
    local missing=()
    [[ -z $claude_ver ]] && missing+=("CLAUDE_CODE_VERSION")
    [[ -z $codex_ver ]] && missing+=("CODEX_VERSION")
    [[ -z $gemini_ver ]] && missing+=("GEMINI_CLI_VERSION")
    [[ -z $atlas_ver ]] && missing+=("ATLAS_CLI_VERSION")
    [[ -z $copilot_ver ]] && missing+=("COPILOT_API_VERSION")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Warning: Could not determine versions for: ${missing[*]}${RESET}"
        echo -e "${DIM}Set them manually: ${missing[*]/%/=x.x.x} make versions-up${RESET}"
        echo -e "${DIM}Proceeding with build anyway...${RESET}"
        echo ""
    fi

    section "Building Main Image"
    docker build -f "$DOCKERFILE" \
        --build-arg CLAUDE_CODE_VERSION="$claude_ver" \
        --build-arg CODEX_VERSION="$codex_ver" \
        --build-arg GEMINI_CLI_VERSION="$gemini_ver" \
        --build-arg ATLAS_CLI_VERSION="$atlas_ver" \
        --build-arg COPILOT_API_VERSION="$copilot_ver" \
        -t "$BUILD_IMAGE" .

    echo ""
    section "Building Rust Image"
    docker build -f "$RUST_DOCKERFILE" \
        --build-arg BASE_IMAGE="$BUILD_IMAGE" \
        -t "$RUST_IMAGE" .

    echo ""
    echo -e "${GREEN}${BOLD}All images upgraded successfully${RESET}"
    echo -e "${DIM}Completed: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
}

main
