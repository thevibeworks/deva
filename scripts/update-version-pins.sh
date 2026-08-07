#!/usr/bin/env bash
# update-version-pins.sh - Refresh shared version pins from upstream sources
#
# Verbose TUI with real-time fetch progress, grouped version comparison,
# and optional changelog display for updated tools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/version-pins.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/release-utils.sh"

DRY_RUN=0
SHOW_CHANGELOG=0
IS_TTY=0
[[ -t 1 ]] && IS_TTY=1

N_UPDATED=0
N_UNCHANGED=0
N_FAILED=0
UPDATED_VARS=()

usage() {
    cat <<'EOF'
Usage: update-version-pins.sh [OPTIONS]

Refresh shared version pins from upstream sources and rewrite versions.env.

Options:
  --dry-run      Preview changes without writing versions.env
  --changelog    Show changelogs for updated tools
  -h, --help     Show this help
EOF
}

# ── Fetch helpers (soft-fail: empty string on error) ─────────────────────

fetch_npm_version() {
    curl -fsSL --max-time 10 \
        "https://registry.npmjs.org/-/package/$1/dist-tags" 2>/dev/null | \
        sed -n 's/.*"latest":"\([^"]*\)".*/\1/p' || true
}

fetch_latest_git_tag() {
    git ls-remote --tags "$1" 2>/dev/null | \
        awk '{print $2}' | \
        sed 's#refs/tags/##; s/\^{}$//' | \
        grep -E '^v?[0-9]+(\.[0-9]+){1,2}$' | \
        sort -Vu | \
        tail -1
}

fetch_go_version() {
    curl -fsSL https://go.dev/VERSION?m=text 2>/dev/null | \
        head -1 | \
        sed 's/^go//'
}

fetch_latest_commit() {
    git ls-remote "$1" "$2" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

# ── Pin: fetch one version and display result ────────────────────────────
# Usage: pin NAME VAR_NAME FETCH_TYPE [FETCH_ARGS...]

pin() {
    local name=$1 var=$2 fetch_type=$3
    shift 3
    local old_val=${!var:-}
    local pad
    pad=$(printf '%-16s' "$name")

    # Live progress (tty only -- overwritten when done)
    if [[ $IS_TTY -eq 1 ]]; then
        echo -en "  ${CYAN}│${RESET}  ${DIM}⟳  ${pad}  fetching...${RESET}"
    fi

    # Fetch upstream. `|| true` is load-bearing: a failing command
    # substitution in a plain assignment takes its exit status, and under
    # `set -e` that aborts the whole run -- which would make the fetch-failed
    # branch below unreachable and kill the soft-fail contract. One dead
    # registry must degrade to a warning, not end the sweep.
    local new_val=""
    case $fetch_type in
        go)         new_val=$(fetch_go_version) || true ;;
        npm)        new_val=$(fetch_npm_version "$1") || true ;;
        git-tag)    new_val=$(fetch_latest_git_tag "$1") || true ;;
        git-commit) new_val=$(fetch_latest_commit "$1" "$2") || true ;;
        webbridge)  new_val=$(_webbridge_cdn_latest) || true ;;
    esac

    # Clear fetching line
    if [[ $IS_TTY -eq 1 ]]; then
        echo -en "\r\033[K"
    fi

    # Fetch failed -- keep old value, warn
    if [[ -z "$new_val" ]]; then
        echo -e "  ${CYAN}│${RESET}  ${YELLOW}!${RESET}  ${WHITE}${pad}${RESET}  ${DIM}${old_val:-?}${RESET}  ${YELLOW}(fetch failed)${RESET}"
        N_FAILED=$((N_FAILED + 1))
        return
    fi

    # Update variable in caller's scope
    printf -v "$var" '%s' "$new_val"

    # Short hash for commits, semver for everything else
    local old_disp=$old_val new_disp=$new_val
    if [[ $fetch_type == "git-commit" ]]; then
        old_disp="${old_val:0:7}"
        new_disp="${new_val:0:7}"
    fi

    if [[ "$old_val" == "$new_val" ]]; then
        echo -e "  ${CYAN}│${RESET}  ${DIM}·  ${pad}  ${new_disp}  (up-to-date)${RESET}"
        N_UNCHANGED=$((N_UNCHANGED + 1))
    else
        echo -e "  ${CYAN}│${RESET}  ${GREEN}▲${RESET}  ${WHITE}${pad}${RESET}  ${RED}${old_disp:-new}${RESET} ${DIM}->${RESET} ${GREEN}${new_disp}${RESET}"
        N_UPDATED=$((N_UPDATED + 1))
        UPDATED_VARS+=("${var}|${old_val}|${new_val}")
    fi
}

# ── Changelog display ────────────────────────────────────────────────────

registry_tool() {
    case $1 in
        CLAUDE_CODE_VERSION) echo "claude-code" ;;
        CCTRACE_VERSION)     echo "cctrace" ;;
        CODEX_VERSION)       echo "codex" ;;
        GEMINI_CLI_VERSION)  echo "gemini-cli" ;;
        GROK_CLI_VERSION)    echo "grok-cli" ;;
        KIMI_CODE_VERSION)   echo "kimi-code" ;;
        OPENCODE_VERSION)    echo "opencode" ;;
        CCX_VERSION)         echo "ccx" ;;
        COPILOT_API_VERSION) echo "copilot-api" ;;
        PLAYWRIGHT_VERSION)  echo "playwright" ;;
    esac
}

show_changelogs() {
    local shown=0
    for entry in ${UPDATED_VARS[@]+"${UPDATED_VARS[@]}"}; do
        IFS='|' read -r var old new <<< "$entry"

        local tool
        tool=$(registry_tool "$var")
        [[ -z "$tool" ]] && continue

        local changelog_source
        changelog_source=$(get_tool_field "$tool" changelog 2>/dev/null) || true
        [[ -z "$changelog_source" ]] && continue

        local name
        name=$(get_display_name "$tool")

        [[ $shown -eq 0 ]] && echo ""
        shown=1

        section "$name  ${old} -> ${new}"

        if [[ $IS_TTY -eq 1 ]]; then
            echo -en "  ${DIM}fetching changelog...${RESET}"
        fi

        local changes
        changes=$(fetch_changelog "$tool" "$old" "$new")

        if [[ $IS_TTY -eq 1 ]]; then
            echo -en "\r\033[K"
        fi

        if [[ -n "$changes" ]]; then
            echo "$changes" | indent
        else
            echo -e "  ${DIM}(changelog unavailable)${RESET}"
        fi
        echo ""
    done

    if [[ $shown -eq 0 ]]; then
        echo -e "${DIM}No changelogs available for updated tools.${RESET}"
        echo ""
    fi
}

# ── Arg parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)    DRY_RUN=1; shift ;;
        --changelog)  SHOW_CHANGELOG=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ── Main ─────────────────────────────────────────────────────────────────

main() {
    load_version_pins

    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Refreshing Version Pins                         ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
    echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    [[ $DRY_RUN -eq 1 ]] && echo -e "${YELLOW}(dry run)${RESET}"
    echo ""

    # ── Toolchains ───────────────────────────────────────────────────────
    echo -e "  ${CYAN}┌─${BOLD} Toolchains ${RESET}${CYAN}──────────────────────────────────────${RESET}"

    pin "Go"             GO_VERSION       go
    pin "delta"          DELTA_VERSION    git-tag  "https://github.com/dandavison/delta.git"

    # ── Agent CLIs ───────────────────────────────────────────────────────
    echo -e "  ${CYAN}│${RESET}"
    echo -e "  ${CYAN}├─${BOLD} Agent CLIs ${RESET}${CYAN}──────────────────────────────────────${RESET}"

    pin "Claude Code"    CLAUDE_CODE_VERSION   npm  "@anthropic-ai/claude-code"
    pin "cctrace"        CCTRACE_VERSION       npm  "@thevibeworks/cctrace"
    pin "Codex"          CODEX_VERSION         npm  "@openai/codex"
    pin "Gemini CLI"     GEMINI_CLI_VERSION    npm  "@google/gemini-cli"
    pin "Grok CLI"       GROK_CLI_VERSION      npm  "@xai-official/grok"
    pin "Kimi Code"      KIMI_CODE_VERSION     npm  "@moonshot-ai/kimi-code"
    pin "opencode"       OPENCODE_VERSION      npm  "opencode-ai"
    pin "CCX"            CCX_VERSION           git-tag  "https://github.com/thevibeworks/ccx.git"
    pin "Copilot API"    COPILOT_API_VERSION   git-commit  "https://github.com/ericc-ch/copilot-api.git" "refs/heads/master"

    # ── Browser Tools ────────────────────────────────────────────────────
    echo -e "  ${CYAN}│${RESET}"
    echo -e "  ${CYAN}├─${BOLD} Browser Tools ${RESET}${CYAN}───────────────────────────────────${RESET}"

    pin "Playwright"     PLAYWRIGHT_VERSION            npm  "playwright"
    pin "CloakBrowser"   CLOAKBROWSER_WRAPPER_VERSION  npm  "cloakbrowser"
    pin "Kimi WebBridge" KIMI_WEBBRIDGE_VERSION        webbridge

    # ── Summary footer ───────────────────────────────────────────────────
    echo -e "  ${CYAN}│${RESET}"

    local parts=()
    [[ $N_UPDATED -gt 0 ]]   && parts+=("${GREEN}${N_UPDATED} updated${RESET}")
    [[ $N_UNCHANGED -gt 0 ]] && parts+=("${DIM}${N_UNCHANGED} unchanged${RESET}")
    [[ $N_FAILED -gt 0 ]]    && parts+=("${YELLOW}${N_FAILED} failed${RESET}")
    local summary=""
    for i in "${!parts[@]}"; do
        [[ $i -gt 0 ]] && summary+=", "
        summary+="${parts[$i]}"
    done
    echo -e "  ${CYAN}└─${RESET} ${summary} ${CYAN}──────────────────────────────────────${RESET}"
    echo ""

    # ── Changelogs (opt-in) ──────────────────────────────────────────────
    if [[ $SHOW_CHANGELOG -eq 1 ]] && [[ $N_UPDATED -gt 0 ]]; then
        show_changelogs
    fi

    # ── Result ───────────────────────────────────────────────────────────
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "${YELLOW}Dry run — would write:${RESET}"
        echo ""
        emit_version_pins
        return 0
    fi

    # Write even when nothing moved. The heredoc in write_version_pins is a
    # second copy of the file layout, so a rewrite is what proves no pin was
    # dropped from it; skipping the write when N_UPDATED=0 would leave that
    # guard (tests/version-upgrade.sh) unexercised on exactly the runs where
    # every fetch failed.
    write_version_pins
    if [[ $N_UPDATED -eq 0 ]]; then
        if [[ $N_FAILED -gt 0 ]]; then
            echo -e "${YELLOW}No pins moved, but ${N_FAILED} fetch(es) failed -- upstream state unknown for those.${RESET}"
        else
            echo -e "${GREEN}All pins up-to-date.${RESET}"
        fi
        return 0
    fi
    echo -e "${GREEN}Updated ${VERSION_PINS_FILE##*/}${RESET}"
    echo -e "${DIM}Run 'make versions-up' to rebuild images.${RESET}"
}

main "$@"
