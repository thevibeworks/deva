#!/usr/bin/env bash
# update-version-pins.sh - Refresh shared version pins from upstream sources
#
# Concurrent fetches (capped background jobs) with a live TUI: each tool
# goes pending -> checking -> done/failed in place. Non-TTY (CI) falls back
# to plain ordered line output. Optional changelog display for updates.

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

# Honor NO_COLOR; keep non-TTY output free of escapes entirely.
if [[ -n ${NO_COLOR:-} || $IS_TTY -eq 0 ]]; then
    RESET='' BOLD='' DIM='' RED='' GREEN='' YELLOW='' CYAN='' WHITE=''
fi

MAX_JOBS=8
SPIN_FRAMES="|/-\\"
DASH_RULE='──────────────────────────────────────────────────'

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

# ── Pin table ────────────────────────────────────────────────────────────
# GROUP|NAME|VAR|FETCH_TYPE[|FETCH_ARGS...]
# Order here is the display and merge order; keep it stable.

PIN_TABLE=(
    "Toolchains|Go|GO_VERSION|go"
    "Toolchains|delta|DELTA_VERSION|git-tag|https://github.com/dandavison/delta.git"
    "Agent CLIs|Claude Code|CLAUDE_CODE_VERSION|npm|@anthropic-ai/claude-code"
    "Agent CLIs|cctrace|CCTRACE_VERSION|npm|@thevibeworks/cctrace"
    "Agent CLIs|Codex|CODEX_VERSION|npm|@openai/codex"
    "Agent CLIs|Gemini CLI|GEMINI_CLI_VERSION|npm|@google/gemini-cli"
    "Agent CLIs|Grok CLI|GROK_CLI_VERSION|npm|@xai-official/grok"
    "Agent CLIs|Kimi Code|KIMI_CODE_VERSION|npm|@moonshot-ai/kimi-code"
    "Agent CLIs|opencode|OPENCODE_VERSION|npm|opencode-ai"
    "Agent CLIs|pi|PI_CODING_AGENT_VERSION|npm|@earendil-works/pi-coding-agent"
    "Agent CLIs|dsh|DSH_VERSION|npm|@deepseek-ai/dsh"
    "Agent CLIs|cursor|CURSOR_CLI_VERSION|cursor"
    "Agent CLIs|CCX|CCX_VERSION|git-tag|https://github.com/thevibeworks/ccx.git"
    "Agent CLIs|Copilot API|COPILOT_API_VERSION|git-commit|https://github.com/ericc-ch/copilot-api.git|refs/heads/master"
    "Browser Tools|Playwright|PLAYWRIGHT_VERSION|npm|playwright"
    "Browser Tools|CloakBrowser|CLOAKBROWSER_WRAPPER_VERSION|npm|cloakbrowser"
    "Browser Tools|Kimi WebBridge|KIMI_WEBBRIDGE_VERSION|webbridge"
)

# Parallel per-tool arrays, filled by init_table.
T_NAME=() T_VAR=() T_TYPE=() T_ARG1=() T_ARG2=()
T_OLD=() T_NEW=() T_STATE=()   # STATE: pending|running|fail|same|bump
LAYOUT=()                      # render items: head1:G, head2:G, gap, tool:i
TOTAL=0
WORK_DIR=""
RENDERED_LINES=0
LAYOUT_POS=0
FRAME=0

init_table() {
    local entry group name var ftype a1 a2 i=0 prev_group=""
    for entry in "${PIN_TABLE[@]}"; do
        IFS='|' read -r group name var ftype a1 a2 <<< "$entry"
        T_NAME[i]=$name
        T_VAR[i]=$var
        T_TYPE[i]=$ftype
        T_ARG1[i]=${a1:-}
        T_ARG2[i]=${a2:-}
        T_OLD[i]=${!var:-}
        T_NEW[i]=""
        T_STATE[i]=pending
        if [[ $group != "$prev_group" ]]; then
            if [[ -n $prev_group ]]; then
                LAYOUT+=("gap" "head2:$group")
            else
                LAYOUT+=("head1:$group")
            fi
            prev_group=$group
        fi
        LAYOUT+=("tool:$i")
        i=$((i + 1))
    done
    TOTAL=$i
}

# ── Background fetch job (always exits 0; empty value = failure) ─────────

fetch_one() {
    local idx=$1 ftype=$2 a1=$3 a2=$4
    local val=""
    case $ftype in
        go)         val=$(fetch_go_version) || true ;;
        npm)        val=$(fetch_npm_version "$a1") || true ;;
        git-tag)    val=$(fetch_latest_git_tag "$a1") || true ;;
        git-commit) val=$(fetch_latest_commit "$a1" "$a2") || true ;;
        webbridge)  val=$(_webbridge_cdn_latest) || true ;;
        cursor)     val=$(_cursor_installer_latest) || true ;;
    esac
    printf '%s' "$val" > "$WORK_DIR/$idx.val"
    : > "$WORK_DIR/$idx.done"   # marker last: .val is complete once this exists
}

classify() {
    local i=$1 val
    val=$(<"$WORK_DIR/$i.val")
    T_NEW[i]=$val
    if [[ -z $val ]]; then
        T_STATE[i]=fail
    elif [[ $val == "${T_OLD[$i]}" ]]; then
        T_STATE[i]=same
    else
        T_STATE[i]=bump
    fi
}

# ── Display ──────────────────────────────────────────────────────────────

tool_line() {
    local i=$1 eol=${2:-}
    local name=${T_NAME[$i]} old=${T_OLD[$i]} new=${T_NEW[$i]}
    local pad
    pad=$(printf '%-16s' "$name")

    local old_disp=$old new_disp=$new
    if [[ ${T_TYPE[$i]} == "git-commit" ]]; then
        old_disp="${old:0:7}"
        new_disp="${new:0:7}"
    fi

    case ${T_STATE[$i]} in
        pending)
            echo -e "  ${CYAN}│${RESET}  ${DIM}.  ${pad}  waiting${RESET}${eol}"
            ;;
        running)
            local spin=${SPIN_FRAMES:FRAME % 4:1}
            echo -e "  ${CYAN}│${RESET}  ${DIM}${spin}  ${pad}  checking...${RESET}${eol}"
            ;;
        fail)
            echo -e "  ${CYAN}│${RESET}  ${YELLOW}!${RESET}  ${WHITE}${pad}${RESET}  ${DIM}${old_disp:-?}${RESET}  ${YELLOW}(check failed)${RESET}${eol}"
            ;;
        same)
            echo -e "  ${CYAN}│${RESET}  ${DIM}·  ${pad}  ${new_disp}  (up-to-date)${RESET}${eol}"
            ;;
        bump)
            echo -e "  ${CYAN}│${RESET}  ${GREEN}▲${RESET}  ${WHITE}${pad}${RESET}  ${RED}${old_disp:-new}${RESET} ${DIM}->${RESET} ${GREEN}${new_disp}${RESET}${eol}"
            ;;
    esac
}

emit_layout_line() {
    local item=$1 eol=${2:-}
    case $item in
        gap)
            echo -e "  ${CYAN}│${RESET}${eol}"
            ;;
        head1:*|head2:*)
            local corner="├─" group=${item#head?:} dashes
            [[ $item == head1:* ]] && corner="┌─"
            dashes=${DASH_RULE:0:48 - ${#group}}
            echo -e "  ${CYAN}${corner}${BOLD} ${group} ${RESET}${CYAN}${dashes}${RESET}${eol}"
            ;;
        tool:*)
            tool_line "${item#tool:}" "$eol"
            ;;
    esac
}

# TTY: redraw the whole block in place (\033[K clears line residue).
render() {
    local item
    if [[ $RENDERED_LINES -gt 0 ]]; then
        printf '\033[%dA' "$RENDERED_LINES"
    fi
    for item in "${LAYOUT[@]}"; do
        emit_layout_line "$item" $'\033[K'
    done
    RENDERED_LINES=${#LAYOUT[@]}
}

# Non-TTY: print finished lines in table order as they become available.
plain_flush() {
    while [[ $LAYOUT_POS -lt ${#LAYOUT[@]} ]]; do
        # Find the tool item this position leads up to; print the run of
        # header/gap/tool items only once that tool has a final state.
        local j=$LAYOUT_POS ti=""
        while [[ $j -lt ${#LAYOUT[@]} ]]; do
            if [[ ${LAYOUT[$j]} == tool:* ]]; then
                ti=${LAYOUT[$j]#tool:}
                break
            fi
            j=$((j + 1))
        done
        [[ -z $ti ]] && break
        case ${T_STATE[$ti]} in
            pending|running) return 0 ;;
        esac
        while [[ $LAYOUT_POS -le $j ]]; do
            emit_layout_line "${LAYOUT[$LAYOUT_POS]}"
            LAYOUT_POS=$((LAYOUT_POS + 1))
        done
    done
}

# ── Concurrent dispatcher ────────────────────────────────────────────────
# Jobs only write per-tool files under WORK_DIR; versions.env is written
# once, from the main shell, after a deterministic ordered merge.

run_fetches() {
    local next=0 running=0 finished=0 i
    while [[ $finished -lt $TOTAL ]]; do
        while [[ $next -lt $TOTAL && $running -lt $MAX_JOBS ]]; do
            T_STATE[next]=running
            fetch_one "$next" "${T_TYPE[$next]}" "${T_ARG1[$next]}" "${T_ARG2[$next]}" &
            next=$((next + 1))
            running=$((running + 1))
        done
        for (( i = 0; i < next; i++ )); do
            if [[ ${T_STATE[$i]} == running && -f "$WORK_DIR/$i.done" ]]; then
                classify "$i"
                running=$((running - 1))
                finished=$((finished + 1))
            fi
        done
        if [[ $IS_TTY -eq 1 ]]; then
            render
            FRAME=$((FRAME + 1))
        else
            plain_flush
        fi
        if [[ $finished -lt $TOTAL ]]; then
            sleep 0.12
        fi
    done
    wait || true
}

# Deterministic ordered merge: counters, UPDATED_VARS, and pin variables
# are applied in table order regardless of job completion order.
tally_results() {
    local i
    for (( i = 0; i < TOTAL; i++ )); do
        case ${T_STATE[$i]} in
            fail)
                N_FAILED=$((N_FAILED + 1))
                ;;
            same)
                N_UNCHANGED=$((N_UNCHANGED + 1))
                ;;
            bump)
                N_UPDATED=$((N_UPDATED + 1))
                printf -v "${T_VAR[$i]}" '%s' "${T_NEW[$i]}"
                UPDATED_VARS+=("${T_VAR[$i]}|${T_OLD[$i]}|${T_NEW[$i]}")
                ;;
        esac
    done
}

cleanup() {
    local pids
    pids=$(jobs -p) || true
    if [[ -n $pids ]]; then
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null || true
    fi
    if [[ -n $WORK_DIR ]]; then
        rm -rf "$WORK_DIR"
    fi
    if [[ $IS_TTY -eq 1 ]]; then
        printf '\033[?25h'
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
        PI_CODING_AGENT_VERSION) echo "pi" ;;
        DSH_VERSION)         echo "dsh" ;;
        CURSOR_CLI_VERSION)  echo "cursor" ;;
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
    init_table
    WORK_DIR=$(mktemp -d)
    trap cleanup EXIT

    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Refreshing Version Pins                         ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
    echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    [[ $DRY_RUN -eq 1 ]] && echo -e "${YELLOW}(dry run)${RESET}"
    echo ""

    if [[ $IS_TTY -eq 1 ]]; then
        printf '\033[?25l'
    fi
    run_fetches
    if [[ $IS_TTY -eq 1 ]]; then
        printf '\033[?25h'
    fi
    tally_results

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
