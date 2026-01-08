#!/usr/bin/env bash
# release-utils.sh - Unified utilities for version/changelog management
# Provides extensible tool registry and common functions for version checking

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Colors
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[0;90m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Tool Registry
# Each tool: NAME|TYPE|SOURCE|LABEL|URL|CHANGELOG_URL
# TYPE: npm, github-release, github-commit
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TOOL_REGISTRY=(
    "claude-code|npm|@anthropic-ai/claude-code|org.opencontainers.image.claude_code_version|https://www.npmjs.com/package/@anthropic-ai/claude-code|https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"
    "codex|npm|@openai/codex|org.opencontainers.image.codex_version|https://www.npmjs.com/package/@openai/codex|github:openai/codex"
    "gemini-cli|npm|@google/gemini-cli|org.opencontainers.image.gemini_cli_version|https://www.npmjs.com/package/@google/gemini-cli|"
    "atlas-cli|github-release|lroolle/atlas-cli|org.opencontainers.image.atlas_cli_version|https://github.com/lroolle/atlas-cli|github:lroolle/atlas-cli"
    "copilot-api|github-commit|ericc-ch/copilot-api|org.opencontainers.image.copilot_api_version|https://github.com/ericc-ch/copilot-api|"
)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Tool Registry Helpers
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
get_tool_field() {
    local tool=$1 field=$2
    for entry in "${TOOL_REGISTRY[@]}"; do
        IFS='|' read -r name type source label url changelog <<< "$entry"
        if [[ $name == "$tool" ]]; then
            case $field in
                name) echo "$name" ;;
                type) echo "$type" ;;
                source) echo "$source" ;;
                label) echo "$label" ;;
                url) echo "$url" ;;
                changelog) echo "$changelog" ;;
            esac
            return 0
        fi
    done
    return 1
}

get_all_tools() {
    for entry in "${TOOL_REGISTRY[@]}"; do
        IFS='|' read -r name _ <<< "$entry"
        echo "$name"
    done
}

get_display_name() {
    local tool=$1
    case $tool in
        claude-code) echo "Claude Code" ;;
        codex) echo "Codex" ;;
        gemini-cli) echo "Gemini CLI" ;;
        atlas-cli) echo "Atlas CLI" ;;
        copilot-api) echo "Copilot API" ;;
        *) echo "$tool" ;;
    esac
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Version Utilities
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
normalize_version() {
    local v=$1
    v=${v#v}
    echo "$v"
}

format_version() {
    local v=$1
    if [[ -z $v ]] || [[ $v == "<no value>" ]]; then
        echo "-"
    elif [[ $v == v* ]]; then
        echo "$v"
    else
        echo "v$v"
    fi
}

format_datetime() {
    local datetime=$1
    [[ -z $datetime ]] && return
    date -d "$datetime" '+%b %d, %Y %H:%M' 2>/dev/null || \
    date -jf '%Y-%m-%dT%H:%M:%SZ' "$datetime" '+%b %d, %Y %H:%M' 2>/dev/null || \
    date -jf '%Y-%m-%dT%H:%M:%S' "${datetime%.*}" '+%b %d, %Y %H:%M' 2>/dev/null || \
    echo "$datetime"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Version Fetching (by type)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
fetch_latest_version() {
    local tool=$1
    local type=$(get_tool_field "$tool" type)
    local source=$(get_tool_field "$tool" source)

    case $type in
        npm)
            npm view "$source" version 2>/dev/null || echo ""
            ;;
        github-release)
            gh api "repos/$source/releases/latest" --jq '.tag_name' 2>/dev/null || echo ""
            ;;
        github-commit)
            local branch="master"
            [[ $source == "lroolle/atlas-cli" ]] && branch="main"
            gh api "repos/$source/branches/$branch" --jq '.commit.sha' 2>/dev/null || echo ""
            ;;
    esac
}

fetch_version_date() {
    local tool=$1 version=$2
    local type=$(get_tool_field "$tool" type)
    local source=$(get_tool_field "$tool" source)

    case $type in
        npm)
            local v=$(normalize_version "$version")
            npm view "$source@$v" time --json 2>/dev/null | \
                jq -r --arg ver "$v" '.[$ver] // .' 2>/dev/null | head -1 || echo ""
            ;;
        github-release)
            gh api "repos/$source/releases/tags/$version" --jq '.published_at' 2>/dev/null || echo ""
            ;;
        github-commit)
            gh api "repos/$source/commits/$version" --jq '.commit.committer.date' 2>/dev/null || echo ""
            ;;
    esac
}

get_image_version() {
    local image=$1 label=$2
    docker inspect "$image" 2>/dev/null | \
        jq -r --arg k "$label" '.[0].Config.Labels[$k] // ""' 2>/dev/null || echo ""
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Changelog Fetching
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
fetch_changelog() {
    local tool=$1 current=$2 latest=$3
    local changelog_source=$(get_tool_field "$tool" changelog)

    [[ -z $changelog_source ]] && return
    [[ -z $current ]] || [[ $current == "-" ]] && return

    current=$(normalize_version "$current")
    latest=$(normalize_version "$latest")
    [[ $current == "$latest" ]] && return

    if [[ $changelog_source == github:* ]]; then
        fetch_github_releases "${changelog_source#github:}" "$current" "$latest"
    else
        fetch_markdown_changelog "$changelog_source" "$current" "$latest"
    fi
}

fetch_markdown_changelog() {
    local url=$1 current=$2 latest=$3
    local data
    data=$(curl -fsSL --max-time 10 --retry 2 "$url" 2>/dev/null) || { echo "(fetch failed)"; return 0; }

    python3 -c '
import re, sys

def parse_version(v):
    parts = re.findall(r"\d+", v)
    return tuple(int(p) for p in parts) if parts else (0,)

current, latest = sys.argv[1], sys.argv[2]
text = sys.stdin.read()

try:
    cur_v, lat_v = parse_version(current), parse_version(latest)
except:
    sys.exit(0)

sections = re.split(r"(?=^## )", text, flags=re.M)
changes = []

for section in sections:
    if not section.strip():
        continue
    match = re.match(r"^##\s+.*?(\d+\.\d+\.\d+)", section, re.M)
    if not match:
        continue
    try:
        v = parse_version(match.group(1))
        if cur_v < v <= lat_v:
            lines = section.strip().split("\n")
            output = [lines[0].replace("## ", "")]
            content_lines = [l for l in lines[1:] if l.strip()][:10]
            output.extend(content_lines)
            changes.append("\n".join(output))
    except:
        continue

for change in reversed(changes[-3:]):
    print(change)
    print()
' "$current" "$latest" <<< "$data" 2>/dev/null || true
}

fetch_github_releases() {
    local repo=$1 current=$2 latest=$3
    local json
    json=$(gh api "repos/$repo/releases" 2>/dev/null) || { echo "(fetch failed)"; return 0; }

    python3 -c '
import json, sys, re

def parse_version(v):
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", v)
    return tuple(int(x) for x in match.groups()) if match else (0, 0, 0)

current, latest = sys.argv[1], sys.argv[2]
releases = json.load(sys.stdin)

try:
    cur_v, lat_v = parse_version(current), parse_version(latest)
except:
    sys.exit(0)

changes = []
seen = set()

for rel in releases:
    if rel.get("prerelease"):
        continue
    tag = rel.get("tag_name", "")
    if not tag:
        continue
    try:
        v = parse_version(tag)
        if v in seen or not (cur_v < v <= lat_v):
            continue
        seen.add(v)
        ver = re.search(r"(\d+\.\d+\.\d+)", tag)
        ver = ver.group(1) if ver else tag
        body = (rel.get("body") or "").replace("\r\n", "\n").strip()
        changes.append((v, ver, body))
    except:
        continue

for v, ver, body in sorted(changes, key=lambda x: x[0], reverse=True)[:3]:
    print(f"{ver}")
    if body:
        for line in [l.rstrip() for l in body.split("\n") if l.strip()][:15]:
            print(f"  {line}")
    print()
' "$current" "$latest" <<< "$json" 2>/dev/null || true
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Display Helpers
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section() {
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}${BOLD}$1${RESET}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

indent() { sed 's/^/  /'; }

print_version_line() {
    local tool=$1 current=$2 latest=$3 date=$4
    local name=$(get_display_name "$tool")
    local url=$(get_tool_field "$tool" url)
    local type=$(get_tool_field "$tool" type)

    local cur_fmt lat_fmt
    if [[ $type == "github-commit" ]]; then
        cur_fmt="${current:0:7}"
        lat_fmt="${latest:0:7}"
        [[ -z $current ]] || [[ $current == "-" ]] && cur_fmt="-"
    else
        cur_fmt=$(format_version "$current")
        lat_fmt=$(format_version "$latest")
    fi

    local date_str=""
    [[ -n $date ]] && date_str=" ${DIM}($(format_datetime "$date"))${RESET}"

    local link_str=""
    [[ -n $url ]] && link_str=" ${DIM}${url}${RESET}"

    local pad=$(printf "%-12s" "$name:")

    if [[ -z $current ]] || [[ $current == "-" ]]; then
        echo -e "  ${WHITE}${pad}${RESET} ${DIM}-${RESET} -> ${GREEN}${lat_fmt}${RESET}${date_str}${link_str} ${YELLOW}(not built)${RESET}"
        return 1
    elif [[ $(normalize_version "$current") == $(normalize_version "$latest") ]] || [[ $current == "$latest" ]]; then
        echo -e "  ${DIM}${pad} ${lat_fmt}${RESET}${date_str}${link_str} ${GREEN}(up-to-date)${RESET}"
        return 0
    else
        echo -e "  ${WHITE}${pad}${RESET} ${RED}${cur_fmt}${RESET} -> ${GREEN}${lat_fmt}${RESET}${date_str}${link_str}"
        return 1
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Version Storage (bash 3.2 compatible - no associative arrays)
# Uses naming convention: _VER_{CURRENT,LATEST,DATE}_{tool_key}
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
tool_key() {
    echo "$1" | tr '-' '_'
}

set_current() { eval "_VER_CURRENT_$(tool_key "$1")=\"$2\""; }
set_latest()  { eval "_VER_LATEST_$(tool_key "$1")=\"$2\""; }
set_date()    { eval "_VER_DATE_$(tool_key "$1")=\"$2\""; }

get_current() { eval "echo \"\${_VER_CURRENT_$(tool_key "$1"):-}\""; }
get_latest()  { eval "echo \"\${_VER_LATEST_$(tool_key "$1"):-}\""; }
get_date()    { eval "echo \"\${_VER_DATE_$(tool_key "$1"):-}\""; }

load_versions() {
    local image=$1

    echo -e "${DIM}Fetching versions...${RESET}"

    for tool in $(get_all_tools); do
        local label=$(get_tool_field "$tool" label)

        # Current from image
        if docker inspect "$image" >/dev/null 2>&1; then
            set_current "$tool" "$(get_image_version "$image" "$label")"
        else
            set_current "$tool" ""
        fi

        # Latest from source (respect env overrides)
        local env_var latest_val
        case $tool in
            claude-code) env_var="CLAUDE_CODE_VERSION" ;;
            codex) env_var="CODEX_VERSION" ;;
            gemini-cli) env_var="GEMINI_CLI_VERSION" ;;
            atlas-cli) env_var="ATLAS_CLI_VERSION" ;;
            copilot-api) env_var="COPILOT_API_VERSION" ;;
        esac

        eval "latest_val=\"\${$env_var:-}\""
        if [[ -n $latest_val ]]; then
            set_latest "$tool" "$latest_val"
        else
            local fetched
            fetched=$(fetch_latest_version "$tool")
            if [[ -n $fetched ]]; then
                set_latest "$tool" "$fetched"
            else
                # Network failure - fallback to current image version
                local current=$(get_current "$tool")
                if [[ -n $current ]]; then
                    echo -e "${YELLOW}Warning: Failed to fetch latest $tool, using current: $current${RESET}" >&2
                    set_latest "$tool" "$current"
                else
                    echo -e "${RED}Error: Cannot determine version for $tool${RESET}" >&2
                fi
            fi
        fi

        set_date "$tool" "$(fetch_version_date "$tool" "$(get_latest "$tool")")"
    done
}

print_version_summary() {
    echo ""
    echo -e "${YELLOW}${BOLD}Version Status${RESET}"
    echo ""

    local needs_update=0
    for tool in $(get_all_tools); do
        print_version_line "$tool" "$(get_current "$tool")" "$(get_latest "$tool")" "$(get_date "$tool")" || needs_update=1
    done
    echo ""

    return $needs_update
}

print_changelogs() {
    for tool in $(get_all_tools); do
        local current=$(get_current "$tool")
        local latest=$(get_latest "$tool")
        local changelog_source=$(get_tool_field "$tool" changelog)

        [[ -z $changelog_source ]] && continue
        [[ -z $current ]] || [[ $current == "-" ]] && continue

        local cur_norm=$(normalize_version "$current")
        local lat_norm=$(normalize_version "$latest")
        [[ $cur_norm == "$lat_norm" ]] && continue

        local name=$(get_display_name "$tool")
        section "$name Changelog"
        local changes
        changes=$(fetch_changelog "$tool" "$current" "$latest")
        if [[ -n $changes ]]; then
            echo "$changes" | indent
        else
            echo -e "  ${DIM}(changelog unavailable)${RESET}"
        fi
        echo ""
    done
}

# Show recent changelogs for all tools (regardless of update status)
print_recent_changelogs() {
    local depth=${CHANGELOG_DEPTH:-3}

    for tool in $(get_all_tools); do
        local changelog_source=$(get_tool_field "$tool" changelog)
        [[ -z $changelog_source ]] && continue

        local name=$(get_display_name "$tool")
        local latest=$(get_latest "$tool")

        section "$name (latest: $latest)"

        local changes=""
        if [[ $changelog_source == github:* ]]; then
            changes=$(fetch_recent_github_releases "${changelog_source#github:}" "$depth")
        else
            changes=$(fetch_recent_markdown_changelog "$changelog_source" "$depth")
        fi

        if [[ -n $changes ]]; then
            echo "$changes" | indent
        else
            echo -e "  ${DIM}(changelog unavailable)${RESET}"
        fi
        echo ""
    done
}

fetch_recent_markdown_changelog() {
    local url=$1 count=${2:-3}
    local data
    data=$(curl -fsSL --max-time 10 --retry 2 "$url" 2>/dev/null) || { echo "(fetch failed)"; return 0; }

    python3 -c '
import re, sys

count = int(sys.argv[1])
text = sys.stdin.read()
sections = re.split(r"(?=^## )", text, flags=re.M)
printed = 0

for section in sections:
    if not section.strip() or printed >= count:
        continue
    match = re.match(r"^##\s+.*?(\d+\.\d+\.\d+)", section, re.M)
    if not match:
        continue
    lines = section.strip().split("\n")
    print(lines[0].replace("## ", ""))
    for line in [l for l in lines[1:] if l.strip()][:8]:
        print(line)
    print()
    printed += 1
' "$count" <<< "$data" 2>/dev/null || true
}

fetch_recent_github_releases() {
    local repo=$1 count=${2:-3}
    local json
    json=$(gh api "repos/$repo/releases?per_page=$count" 2>/dev/null) || { echo "(fetch failed)"; return 0; }

    python3 -c '
import json, sys, re

count = int(sys.argv[1])
releases = json.load(sys.stdin)
printed = 0

for rel in releases:
    if rel.get("prerelease") or printed >= count:
        continue
    tag = rel.get("tag_name", "")
    if not tag:
        continue
    ver = re.search(r"(\d+\.\d+\.\d+)", tag)
    ver = ver.group(1) if ver else tag
    body = (rel.get("body") or "").replace("\r\n", "\n").strip()
    print(ver)
    if body:
        for line in [l.rstrip() for l in body.split("\n") if l.strip()][:12]:
            print(f"  {line}")
    print()
    printed += 1
' "$count" <<< "$json" 2>/dev/null || true
}
