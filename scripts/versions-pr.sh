#!/usr/bin/env bash
# versions-pr.sh - Commit the versions.env bump and open the pin PR
#
# Builds the commit in a temp worktree detached at REMOTE/BASE_BRANCH so
# the caller's checkout, branch, and staged files are never touched. The
# push targets refs/heads/PR_BRANCH directly from detached HEAD — no
# local branch is created, so repeat runs cannot collide with one.
#
# The bump branch is throwaway by contract: a force-push replacing a
# stale unmerged sweep is the intended behavior, not data loss.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/version-pins.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/release-utils.sh"

REPO_ROOT=${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}
REMOTE=${REMOTE:-origin}
BASE_BRANCH=${BASE_BRANCH:-main}
PR_BRANCH=${PR_BRANCH:-chore/version-pins-refresh}
PINS_NAME=versions.env

usage() {
    cat <<'EOF'
Usage: versions-pr.sh [-h|--help]

Commit the local versions.env bump on a fresh branch off REMOTE/BASE_BRANCH
and open (or update) the pin pull request. No-op when the local pins
already match the remote base branch.

Environment:
  REMOTE       Git remote to push to (default: origin)
  BASE_BRANCH  PR base branch (default: main)
  PR_BRANCH    Head branch, force-pushed (default: chore/version-pins-refresh)
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
esac

for cmd in git gh; do
    command -v "$cmd" >/dev/null || { echo "error: $cmd not found" >&2; exit 1; }
done

# Human-facing pin names for commit/PR bodies (grok, not GROK_CLI_VERSION).
pin_label() {
    case $1 in
        NODE_MAJOR)                   echo "node" ;;
        GO_VERSION)                   echo "go" ;;
        PYTHON_VERSION)               echo "python" ;;
        DELTA_VERSION)                echo "delta" ;;
        TMUX_VERSION)                 echo "tmux" ;;
        TMUX_SHA256)                  echo "tmux-sha256" ;;
        CLAUDE_CODE_VERSION)          echo "claude-code" ;;
        CCTRACE_VERSION)              echo "cctrace" ;;
        CODEX_VERSION)                echo "codex" ;;
        GEMINI_CLI_VERSION)           echo "gemini-cli" ;;
        GROK_CLI_VERSION)             echo "grok" ;;
        KIMI_CODE_VERSION)            echo "kimi-code" ;;
        OPENCODE_VERSION)             echo "opencode" ;;
        CCX_VERSION)                  echo "ccx" ;;
        COPILOT_API_VERSION)          echo "copilot-api" ;;
        PLAYWRIGHT_VERSION)           echo "playwright" ;;
        CLOAKBROWSER_WRAPPER_VERSION) echo "cloakbrowser" ;;
        KIMI_WEBBRIDGE_VERSION)       echo "kimi-webbridge" ;;
        *) echo "$1" | tr '[:upper:]_' '[:lower:]-' ;;
    esac
}

# Commit hashes read better short; semvers pass through unchanged.
short_val() {
    if [[ $1 =~ ^[0-9a-f]{40}$ ]]; then
        echo "${1:0:7}"
    else
        echo "$1"
    fi
}

main() {
    cd "$REPO_ROOT"

    git fetch --quiet "$REMOTE" "$BASE_BRANCH"
    local base_ref="refs/remotes/$REMOTE/$BASE_BRANCH"

    if git diff --quiet "$base_ref" -- "$PINS_NAME"; then
        echo -e "${GREEN}Pins already match ${REMOTE}/${BASE_BRANCH}. Nothing to PR.${RESET}"
        return 0
    fi

    # Bump list: compare each pin var between the base branch and the
    # working copy. Drives both the commit body and the PR body.
    local old_pins bumps=()
    old_pins=$(git show "$base_ref:$PINS_NAME")
    local var old new
    for var in "${VERSION_PIN_VARS[@]}"; do
        old=$(sed -n "s/^$var=//p" <<< "$old_pins")
        new=$(sed -n "s/^$var=//p" < "$PINS_NAME")
        if [[ -n $new && $old != "$new" ]]; then
            bumps+=("- $(pin_label "$var") $(short_val "${old:-none}") -> $(short_val "$new")")
        fi
    done

    if [[ ${#bumps[@]} -eq 0 ]]; then
        # File differs but no pin moved: comments/layout drift. A pin PR
        # for that would be noise — leave it to a deliberate commit.
        echo -e "${YELLOW}versions.env differs from ${REMOTE}/${BASE_BRANCH} but no pin changed; skipping PR.${RESET}"
        return 0
    fi

    local bump_list
    bump_list=$(printf '%s\n' "${bumps[@]}")
    echo -e "${CYAN}Pin bump vs ${REMOTE}/${BASE_BRANCH}:${RESET}"
    echo "$bump_list"

    # Deliberately not local: the EXIT trap runs after main() returns,
    # when locals are already gone.
    tmp=$(mktemp -d)
    wt="$tmp/wt"
    cleanup() {
        git worktree remove --force "$wt" 2>/dev/null || true
        rm -rf "$tmp"
    }
    trap cleanup EXIT

    git worktree add --quiet --detach "$wt" "$base_ref"
    cp "$PINS_NAME" "$wt/$PINS_NAME"
    git -C "$wt" add "$PINS_NAME"
    git -C "$wt" commit --quiet -m "$(printf 'chore(versions): refresh agent CLI pins\n\n%s' "$bump_list")"
    git -C "$wt" push --quiet --force "$REMOTE" "HEAD:refs/heads/$PR_BRANCH"
    echo -e "${GREEN}Pushed ${PR_BRANCH} to ${REMOTE}${RESET}"

    local pr_url
    pr_url=$(gh pr list --head "$PR_BRANCH" --base "$BASE_BRANCH" --state open --json url --jq '.[0].url // empty')
    if [[ -n $pr_url ]]; then
        echo -e "${GREEN}Pin PR already open, branch updated: ${pr_url}${RESET}"
        return 0
    fi

    pr_url=$(gh pr create \
        --base "$BASE_BRANCH" \
        --head "$PR_BRANCH" \
        --title "chore(versions): refresh agent CLI pins" \
        --body "$(printf 'Automated pin sweep from make versions-up. Images (core, main,\nrust, cloak) were built locally at these exact versions before\npinning:\n\n%s' "$bump_list")")
    echo -e "${GREEN}Opened pin PR: ${pr_url}${RESET}"
}

main
