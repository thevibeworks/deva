#!/usr/bin/env bash
# version-report.sh - Display version status and recent changelogs
# Used by: make versions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/release-utils.sh"

IMAGE=${MAIN_IMAGE:-ghcr.io/thevibeworks/deva:latest}
CHANGELOG_DEPTH=${CHANGELOG_DEPTH:-3}

main() {
    section "Version Status"
    echo -e "${DIM}Time: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo -e "${DIM}Image: ${IMAGE}${RESET}"
    echo ""

    load_versions "$IMAGE"

    local needs_update=0
    print_version_summary || needs_update=1

    print_recent_changelogs

    if [[ $needs_update -eq 1 ]]; then
        echo -e "${YELLOW}Run 'make versions-up' to upgrade${RESET}"
    fi
}

main
