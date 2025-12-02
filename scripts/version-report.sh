#!/usr/bin/env bash
set -euo pipefail

CLAUDE_CHANGELOG_URL=${CLAUDE_CHANGELOG_URL:-https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md}
CODEX_RELEASES_API=${CODEX_RELEASES_API:-https://api.github.com/repos/openai/codex/releases/latest}

# Color codes
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[0;90m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'

section() {
    local title=$1
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}${BOLD}$title${RESET}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

indent() { sed 's/^/  /'; }

normalize_version() {
    local v=$1
    v=${v#v}
    echo "$v"
}

get_latest_npm_version() {
    local pkg=$1
    npm view "$pkg" version 2>/dev/null || echo ""
}

get_npm_version_date() {
    local pkg=$1 version=$2
    if [[ -n $version ]]; then
        # Get the publish date for the specific version
        local v_norm=$(normalize_version "$version")
        npm view "$pkg@$v_norm" time --json 2>/dev/null | \
            jq -r --arg ver "$v_norm" '.[$ver] // .' 2>/dev/null | \
            sed 's/["{},]//g' | head -1 || echo ""
    else
        npm view "$pkg" time.modified --json 2>/dev/null | sed 's/["{},]//g' || echo ""
    fi
}

get_atlas_commit_date() {
    local sha=$1
    if [[ -n $sha ]] && [[ $sha != "-" ]]; then
        gh api "repos/lroolle/atlas-cli/commits/$sha" --jq '.commit.committer.date' 2>/dev/null || echo ""
    else
        echo ""
    fi
}

get_copilot_api_commit_date() {
    local sha=$1
    if [[ -n $sha ]] && [[ $sha != "-" ]]; then
        gh api "repos/ericc-ch/copilot-api/commits/$sha" --jq '.commit.committer.date' 2>/dev/null || echo ""
    else
        echo ""
    fi
}

get_image_version() {
    local image=$1 label=$2
    docker inspect "$image" 2>/dev/null | \
        jq -r --arg k "$label" '.[0].Config.Labels[$k] // ""' 2>/dev/null || echo ""
}

format_datetime() {
    local datetime=$1
    if [[ -z $datetime ]]; then
        echo ""
        return
    fi
    # Convert ISO 8601 to readable format: 2025-11-24T19:07:34Z -> Nov 24, 2025 19:07
    date -d "$datetime" '+%b %d, %Y %H:%M' 2>/dev/null || date -jf '%Y-%m-%dT%H:%M:%SZ' "$datetime" '+%b %d, %Y %H:%M' 2>/dev/null || echo "$datetime"
}

compare_versions() {
    local current=$1 latest=$2 name=$3 latest_date=$4 url=$5
    current=$(normalize_version "$current")
    latest=$(normalize_version "$latest")

    local date_str=""
    if [[ -n $latest_date ]]; then
        local formatted_date=$(format_datetime "$latest_date")
        date_str=" ${DIM}(${formatted_date})${RESET}"
    fi

    local link_str=""
    if [[ -n $url ]]; then
        link_str=" ${DIM}${url}${RESET}"
    fi

    if [[ -z $current ]]; then
        echo -e "  ${WHITE}${name}:${RESET} ${DIM}-${RESET} → ${GREEN}v${latest}${RESET}${date_str}${link_str} ${YELLOW}(not built)${RESET}"
        return 1
    elif [[ $current == "$latest" ]]; then
        echo -e "  ${DIM}${name}: v${current}${RESET}${date_str}${link_str} ${GREEN}✓ up-to-date${RESET}"
        return 0
    else
        echo -e "  ${WHITE}${name}:${RESET} ${RED}v${current}${RESET} → ${GREEN}v${latest}${RESET}${date_str}${link_str} ${YELLOW}(upgrade available)${RESET}"
        return 1
    fi
}

compare_git_commits() {
    local current=$1 latest=$2 name=$3 latest_date=$4 url=$5
    # Truncate to 7 chars for display
    local cur_short="${current:0:7}"
    local lat_short="${latest:0:7}"

    local date_str=""
    if [[ -n $latest_date ]]; then
        local formatted_date=$(format_datetime "$latest_date")
        date_str=" ${DIM}(${formatted_date})${RESET}"
    fi

    local link_str=""
    if [[ -n $url ]]; then
        link_str=" ${DIM}${url}${RESET}"
    fi

    if [[ -z $current ]] || [[ $current == "-" ]]; then
        echo -e "  ${WHITE}${name}:${RESET} ${DIM}-${RESET} → ${GREEN}${lat_short}${RESET}${date_str}${link_str} ${YELLOW}(not built)${RESET}"
        return 1
    elif [[ $current == "$latest" ]]; then
        echo -e "  ${DIM}${name}: ${cur_short}${RESET}${date_str}${link_str} ${GREEN}✓ up-to-date${RESET}"
        return 0
    else
        echo -e "  ${WHITE}${name}:${RESET} ${RED}${cur_short}${RESET} → ${GREEN}${lat_short}${RESET}${date_str}${link_str} ${YELLOW}(upgrade available)${RESET}"
        return 1
    fi
}

fetch_changelog_between() {
    local current=$1 latest=$2
    current=$(normalize_version "$current")
    latest=$(normalize_version "$latest")

    if [[ -z $current ]] || [[ $current == "$latest" ]]; then
        return
    fi

    local data
    if ! data=$(curl -fsSL --max-time 10 --retry 2 "$CLAUDE_CHANGELOG_URL" 2>/dev/null); then
        return
    fi

    python3 -c 'import re, sys

def parse_version(v):
    """Parse version string to tuple of ints for comparison"""
    parts = re.findall(r"\d+", v)
    return tuple(int(p) for p in parts) if parts else (0,)

current = sys.argv[1]
latest = sys.argv[2]
text = sys.stdin.read()

try:
    cur_v = parse_version(current)
    lat_v = parse_version(latest)
except:
    sys.exit(0)

# Match entire sections: ## heading followed by content until next ## or end
sections = re.split(r"(?=^## )", text, flags=re.M)
changes = []

for section in sections:
    if not section.strip():
        continue

    # Extract version from heading
    match = re.match(r"^##\s+.*?(\d+\.\d+\.\d+)", section, re.M)
    if not match:
        continue

    try:
        v = parse_version(match.group(1))
        if cur_v < v <= lat_v:
            # Clean up section: remove heading marker, limit lines
            lines = section.strip().split("\n")
            if lines:
                # Keep version heading and first 10 content lines
                output = [lines[0].replace("## ", "")]
                content_lines = [l for l in lines[1:] if l.strip()][:10]
                output.extend(content_lines)
                changes.append("\n".join(output))
    except:
        continue

if changes:
    for change in reversed(changes[-3:]):
        print(change)
        print()
' "$current" "$latest" <<< "$data" 2>/dev/null || true
}

fetch_github_releases_between() {
    local current=$1 latest=$2
    current=$(normalize_version "$current")
    latest=$(normalize_version "$latest")

    if [[ -z $current ]] || [[ $current == "$latest" ]]; then
        return
    fi

    local json
    if ! json=$(curl -fsSL --max-time 10 --retry 2 \
        "https://api.github.com/repos/openai/codex/releases" 2>/dev/null); then
        return
    fi

    python3 -c 'import json, sys, re

def parse_version(v):
    """Parse version string to tuple of ints for comparison"""
    # Extract pure version numbers, ignore prefixes and suffixes
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", v)
    if not match:
        return (0, 0, 0)
    return tuple(int(x) for x in match.groups())

current = sys.argv[1]
latest = sys.argv[2]
releases = json.load(sys.stdin)

try:
    cur_v = parse_version(current)
    lat_v = parse_version(latest)
except:
    sys.exit(0)

changes = []
seen_versions = set()

for rel in releases:
    # Skip prereleases (alpha, beta, rc)
    if rel.get("prerelease", False):
        continue

    tag = rel.get("tag_name") or ""
    if not tag:
        continue

    try:
        v = parse_version(tag)

        # Skip duplicates and check version range
        if v in seen_versions or not (cur_v < v <= lat_v):
            continue

        seen_versions.add(v)

        # Extract clean version string
        ver_match = re.search(r"(\d+\.\d+\.\d+)", tag)
        ver = ver_match.group(1) if ver_match else tag

        name = rel.get("name") or ver
        body = (rel.get("body") or "").strip()
        # Convert \r\n to \n
        body = body.replace("\r\n", "\n")

        changes.append((v, ver, name, body))
    except Exception:
        continue

# Sort by version tuple (newest first) and show up to 3
for v, ver, name, body in sorted(changes, key=lambda x: x[0], reverse=True)[:3]:
    print(f"{ver}")
    if body:
        lines = [l.rstrip() for l in body.split("\n") if l.strip()][:15]
        for line in lines:
            print(f"  {line}")
    print()
' "$current" "$latest" <<< "$json" 2>/dev/null || true
}

get_latest_atlas_commit() {
    gh api repos/lroolle/atlas-cli/commits/main --jq '.sha' 2>/dev/null || echo "789eefa650d66e97dd8fddceabf9e09f2a5d04a4"
}

get_latest_copilot_api_commit() {
    gh api repos/ericc-ch/copilot-api/branches/master --jq '.commit.sha' 2>/dev/null || echo "83cdfde17d7d3be36bd2493cc7592ff13be4928d"
}

main() {
    local image=${MAIN_IMAGE:-ghcr.io/thevibeworks/deva:latest}
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    section "Version Status"
    echo -e "${DIM}⏰ Time: ${timestamp}${RESET}"
    echo -e "${DIM}Image: ${image}${RESET}"
    echo ""

    # Get current versions from built image
    local cur_claude cur_codex cur_gemini cur_atlas cur_copilot image_exists=true
    if docker inspect "$image" >/dev/null 2>&1; then
        cur_claude=$(get_image_version "$image" "org.opencontainers.image.claude_code_version")
        cur_codex=$(get_image_version "$image" "org.opencontainers.image.codex_version")
        cur_gemini=$(get_image_version "$image" "org.opencontainers.image.gemini_cli_version")
        cur_atlas=$(get_image_version "$image" "org.opencontainers.image.atlas_cli_version")
        cur_copilot=$(get_image_version "$image" "org.opencontainers.image.copilot_api_version")
    else
        echo -e "  ${YELLOW}(image not built locally)${RESET}"
        cur_claude=""
        cur_codex=""
        cur_gemini=""
        cur_atlas=""
        cur_copilot=""
        image_exists=false
    fi

    # Get latest versions
    local lat_claude=${CLAUDE_CODE_VERSION:-$(get_latest_npm_version "@anthropic-ai/claude-code")}
    local lat_codex=${CODEX_VERSION:-$(get_latest_npm_version "@openai/codex")}
    local lat_gemini=${GEMINI_CLI_VERSION:-$(get_latest_npm_version "@google/gemini-cli")}
    local lat_atlas=${ATLAS_CLI_VERSION:-$(get_latest_atlas_commit)}
    local lat_copilot=${COPILOT_API_VERSION:-$(get_latest_copilot_api_commit)}

    # Get release dates
    echo -e "${DIM}Fetching release dates...${RESET}"
    local date_claude=$(get_npm_version_date "@anthropic-ai/claude-code" "$lat_claude")
    local date_codex=$(get_npm_version_date "@openai/codex" "$lat_codex")
    local date_gemini=$(get_npm_version_date "@google/gemini-cli" "$lat_gemini")
    local date_atlas=$(get_atlas_commit_date "$lat_atlas")
    local date_copilot=$(get_copilot_api_commit_date "$lat_copilot")
    echo ""

    local needs_update=0
    compare_versions "$cur_claude" "$lat_claude" "Claude Code" "$date_claude" \
        "https://www.npmjs.com/package/@anthropic-ai/claude-code" || needs_update=1
    compare_versions "$cur_codex" "$lat_codex" "Codex" "$date_codex" \
        "https://www.npmjs.com/package/@openai/codex" || needs_update=1
    compare_versions "$cur_gemini" "$lat_gemini" "Gemini CLI" "$date_gemini" \
        "https://www.npmjs.com/package/@google/gemini-cli" || needs_update=1
    compare_git_commits "$cur_atlas" "$lat_atlas" "Atlas CLI" "$date_atlas" \
        "https://github.com/lroolle/atlas-cli" || needs_update=1
    compare_git_commits "$cur_copilot" "$lat_copilot" "Copilot API" "$date_copilot" \
        "https://github.com/ericc-ch/copilot-api" || needs_update=1
    echo

    if [[ $needs_update -eq 1 ]]; then
        if [[ -n $cur_claude ]] && [[ $(normalize_version "$cur_claude") != $(normalize_version "$lat_claude") ]]; then
            section "Claude Code Changes"
            local changes
            changes=$(fetch_changelog_between "$cur_claude" "$lat_claude")
            if [[ -n $changes ]]; then
                echo "$changes" | indent
            else
                echo -e "  ${DIM}(changelog unavailable)${RESET}"
            fi
            echo
        fi

        if [[ -n $cur_codex ]] && [[ $(normalize_version "$cur_codex") != $(normalize_version "$lat_codex") ]]; then
            section "Codex Changes"
            local changes
            changes=$(fetch_github_releases_between "$cur_codex" "$lat_codex")
            if [[ -n $changes ]]; then
                echo "$changes" | indent
            else
                echo -e "  ${DIM}(release notes unavailable)${RESET}"
            fi
            echo
        fi

        if [[ $image_exists == true ]]; then
            echo -e "${YELLOW}💡 Run 'make versions-up' to upgrade${RESET}"
        else
            echo -e "${YELLOW}💡 Run 'make build' to build images${RESET}"
        fi
    else
        echo -e "${GREEN}✓ All versions up-to-date${RESET}"
    fi
}

main
