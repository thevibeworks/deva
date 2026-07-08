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
_CLI_CCTRACE="${CCTRACE_VERSION:-}"
_CLI_CODEX="${CODEX_VERSION:-}"
_CLI_GEMINI="${GEMINI_CLI_VERSION:-}"
_CLI_CCX="${CCX_VERSION:-}"
_CLI_COPILOT="${COPILOT_API_VERSION:-}"
_CLI_PLAYWRIGHT="${PLAYWRIGHT_VERSION:-}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/version-pins.sh"

# Defaults
CHECK_IMAGE=${MAIN_IMAGE:-ghcr.io/thevibeworks/deva:latest}
BUILD_IMAGE=${BUILD_IMAGE:-ghcr.io/thevibeworks/deva:latest}
CORE_IMAGE=${CORE_IMAGE:-ghcr.io/thevibeworks/deva:core}
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
  CORE_IMAGE            Core image name (default: ghcr.io/thevibeworks/deva:core)
  RUST_IMAGE            Rust image name (default: ghcr.io/thevibeworks/deva:rust)
  VERSION_PINS_FILE     Shared version pin file (default: versions.env)
  CLAUDE_CODE_VERSION   Override claude-code version
  CCTRACE_VERSION       Override cctrace version
  CODEX_VERSION         Override codex version
  GEMINI_CLI_VERSION    Override gemini-cli version
  CCX_VERSION     Override ccx version
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
    echo -e "${DIM}Check: ${CHECK_IMAGE}  Build: ${BUILD_IMAGE}  Core: ${CORE_IMAGE}${RESET}"
    echo ""

    bash "$SCRIPT_DIR/toolchain-report.sh"

    load_versions "$CHECK_IMAGE"

    if print_version_summary; then
        echo -e "${GREEN}All versions up-to-date. Nothing to upgrade.${RESET}"
        exit 0
    fi

    print_changelogs

    # Resolve build versions early so we can show the manifest before countdown.
    # CLI override wins; otherwise use whatever load_versions fetched.
    local claude_ver cctrace_ver codex_ver gemini_ver ccx_ver copilot_ver playwright_ver
    claude_ver="${_CLI_CLAUDE_CODE:-$(get_latest "claude-code")}"
    cctrace_ver="${_CLI_CCTRACE:-$(get_latest "cctrace")}"
    codex_ver="${_CLI_CODEX:-$(get_latest "codex")}"
    gemini_ver="${_CLI_GEMINI:-$(get_latest "gemini-cli")}"
    ccx_ver="${_CLI_CCX:-$(get_latest "ccx")}"
    copilot_ver="${_CLI_COPILOT:-$(get_latest "copilot-api")}"
    playwright_ver="${_CLI_PLAYWRIGHT:-${PLAYWRIGHT_VERSION}}"

    local missing=()
    [[ -z $claude_ver ]] && missing+=("CLAUDE_CODE_VERSION")
    [[ -z $codex_ver ]] && missing+=("CODEX_VERSION")
    [[ -z $gemini_ver ]] && missing+=("GEMINI_CLI_VERSION")
    [[ -z $ccx_ver ]] && missing+=("CCX_VERSION")
    [[ -z $copilot_ver ]] && missing+=("COPILOT_API_VERSION")
    [[ -z $playwright_ver ]] && missing+=("PLAYWRIGHT_VERSION")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Warning: Could not determine versions for: ${missing[*]}${RESET}"
        echo -e "${DIM}Set them manually: ${missing[*]/%/=x.x.x} make versions-up${RESET}"
        echo ""
    fi

    # Print the resolved build manifest so the user sees exactly what will be built.
    # Collect lines by status, then render upgrades first for visibility.
    local _manifest_pairs=(
        "Claude Code|claude_ver|_CLI_CLAUDE_CODE|claude-code"
        "cctrace|cctrace_ver|_CLI_CCTRACE|cctrace"
        "Codex|codex_ver|_CLI_CODEX|codex"
        "CCX|ccx_ver|_CLI_CCX|ccx"
        "Copilot API|copilot_ver|_CLI_COPILOT|copilot-api"
        "Playwright|playwright_ver|_CLI_PLAYWRIGHT|playwright"
    )

    local _lines_upgrade=() _lines_pinned=() _lines_current=() _lines_new=()
    local _n_upgrade=0 _n_pinned=0 _n_current=0 _n_new=0

    for _mp in "${_manifest_pairs[@]}"; do
        IFS='|' read -r _label _var _cli_var _tool <<< "$_mp"
        local _val=${!_var:-}
        local _cli_val=${!_cli_var:-}
        local _cur=$(get_current "$_tool")
        local _type=$(get_tool_field "$_tool" type)
        local _pad=$(printf "%-14s" "$_label")

        local _fmt_val _fmt_cur
        if [[ $_type == "github-commit" ]]; then
            _fmt_val="${_val:0:7}"
            _fmt_cur="${_cur:0:7}"
            [[ -z $_cur ]] && _fmt_cur="-"
        else
            _fmt_val=$(format_version "$_val")
            _fmt_cur=$(format_version "$_cur")
        fi

        if [[ -n $_cli_val ]]; then
            _lines_pinned+=("  ${CYAN}│${RESET}  ${YELLOW}◆${RESET}  ${WHITE}${_pad}${RESET}  ${GREEN}${_fmt_val}${RESET}  ${YELLOW}pinned${RESET}")
            _n_pinned=$((_n_pinned + 1))
        elif [[ -n $_cur ]] && [[ $_cur != "-" ]]; then
            local _cur_norm=$(normalize_version "$_cur")
            local _val_norm=$(normalize_version "$_val")
            if [[ $_cur_norm == "$_val_norm" ]] || [[ $_cur == "$_val" ]]; then
                _lines_current+=("  ${CYAN}│${RESET}  ${DIM}·  ${_pad}  ${_fmt_val}${RESET}")
                _n_current=$((_n_current + 1))
            else
                _lines_upgrade+=("  ${CYAN}│${RESET}  ${GREEN}▲${RESET}  ${WHITE}${_pad}${RESET}  ${RED}${_fmt_cur}${RESET} ${DIM}->${RESET} ${GREEN}${_fmt_val}${RESET}")
                _n_upgrade=$((_n_upgrade + 1))
            fi
        else
            _lines_new+=("  ${CYAN}│${RESET}  ${CYAN}+${RESET}  ${WHITE}${_pad}${RESET}  ${GREEN}${_fmt_val}${RESET}  ${DIM}new${RESET}")
            _n_new=$((_n_new + 1))
        fi
    done

    echo -e "  ${CYAN}┌─${BOLD} Build Manifest ${RESET}${CYAN}──────────────────────────────────${RESET}"
    echo -e "  ${CYAN}│${RESET}"
    for _line in ${_lines_upgrade[@]+"${_lines_upgrade[@]}"}; do echo -e "$_line"; done
    for _line in ${_lines_pinned[@]+"${_lines_pinned[@]}"}; do echo -e "$_line"; done
    for _line in ${_lines_current[@]+"${_lines_current[@]}"}; do echo -e "$_line"; done
    for _line in ${_lines_new[@]+"${_lines_new[@]}"}; do echo -e "$_line"; done
    echo -e "  ${CYAN}│${RESET}"

    local _summary_parts=()
    [[ $_n_upgrade -gt 0 ]] && _summary_parts+=("${GREEN}${_n_upgrade} upgrade${RESET}")
    [[ $_n_pinned -gt 0 ]]  && _summary_parts+=("${YELLOW}${_n_pinned} pinned${RESET}")
    [[ $_n_current -gt 0 ]] && _summary_parts+=("${DIM}${_n_current} unchanged${RESET}")
    [[ $_n_new -gt 0 ]]     && _summary_parts+=("${CYAN}${_n_new} new${RESET}")
    local _summary=""
    for i in "${!_summary_parts[@]}"; do
        [[ $i -gt 0 ]] && _summary+=", "
        _summary+="${_summary_parts[$i]}"
    done
    echo -e "  ${CYAN}└─${RESET} ${_summary} ${CYAN}──────────────────────────────────${RESET}"
    echo ""

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

    section "Building Core Image"
    docker build -f "$DOCKERFILE" \
        --target agent-base \
        --build-arg NODE_MAJOR="$NODE_MAJOR" \
        --build-arg GO_VERSION="$GO_VERSION" \
        --build-arg PYTHON_VERSION="$PYTHON_VERSION" \
        --build-arg DELTA_VERSION="$DELTA_VERSION" \
        --build-arg TMUX_VERSION="$TMUX_VERSION" \
        --build-arg TMUX_SHA256="$TMUX_SHA256" \
        --build-arg COPILOT_API_VERSION="$copilot_ver" \
        -t "$CORE_IMAGE" .

    echo ""
    section "Building Main Image"
    docker build -f "$DOCKERFILE" \
        --build-arg NODE_MAJOR="$NODE_MAJOR" \
        --build-arg GO_VERSION="$GO_VERSION" \
        --build-arg PYTHON_VERSION="$PYTHON_VERSION" \
        --build-arg DELTA_VERSION="$DELTA_VERSION" \
        --build-arg TMUX_VERSION="$TMUX_VERSION" \
        --build-arg TMUX_SHA256="$TMUX_SHA256" \
        --build-arg CLAUDE_CODE_VERSION="$claude_ver" \
        --build-arg CCTRACE_VERSION="$cctrace_ver" \
        --build-arg CODEX_VERSION="$codex_ver" \
        --build-arg GEMINI_CLI_VERSION="$gemini_ver" \
        --build-arg CCX_VERSION="$ccx_ver" \
        --build-arg COPILOT_API_VERSION="$copilot_ver" \
        -t "$BUILD_IMAGE" .

    echo ""
    section "Building Rust Image"
    docker build -f "$RUST_DOCKERFILE" \
        --build-arg BASE_IMAGE="$CORE_IMAGE" \
        --build-arg CLAUDE_CODE_VERSION="$claude_ver" \
        --build-arg CCTRACE_VERSION="$cctrace_ver" \
        --build-arg CODEX_VERSION="$codex_ver" \
        --build-arg GEMINI_CLI_VERSION="$gemini_ver" \
        --build-arg CCX_VERSION="$ccx_ver" \
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
