#!/usr/bin/env bash
set -euo pipefail

CLAUDE_CHANGELOG_URL=${CLAUDE_CHANGELOG_URL:-https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md}
CODEX_RELEASES_API=${CODEX_RELEASES_API:-https://api.github.com/repos/openai/codex/releases/latest}

section() {
    local title=$1
    echo "$title"
    printf '%*s\n' "${#title}" '' | tr ' ' '-'
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

get_image_version() {
    local image=$1 label=$2
    docker inspect "$image" 2>/dev/null | \
        jq -r --arg k "$label" '.[0].Config.Labels[$k] // ""' 2>/dev/null || echo ""
}

compare_versions() {
    local current=$1 latest=$2 name=$3
    current=$(normalize_version "$current")
    latest=$(normalize_version "$latest")

    if [[ -z $current ]]; then
        echo "  $name: - -> v$latest (not built)"
        return 1
    elif [[ $current == "$latest" ]]; then
        echo "  $name: v$current (up-to-date)"
        return 0
    else
        echo "  $name: v$current -> v$latest (upgrade available)"
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

main() {
    local image=${MAIN_IMAGE:-ghcr.io/thevibeworks/deva:latest}

    section "Version Status"
    echo "Image: $image"

    # Get current versions from built image
    local cur_claude cur_codex image_exists=true
    if docker inspect "$image" >/dev/null 2>&1; then
        cur_claude=$(get_image_version "$image" "org.opencontainers.image.claude_code_version")
        cur_codex=$(get_image_version "$image" "org.opencontainers.image.codex_version")
    else
        echo "  (image not built locally)"
        cur_claude=""
        cur_codex=""
        image_exists=false
    fi

    # Get latest versions
    local lat_claude=${CLAUDE_CODE_VERSION:-$(get_latest_npm_version "@anthropic-ai/claude-code")}
    local lat_codex=${CODEX_VERSION:-$(get_latest_npm_version "@openai/codex")}

    local needs_update=0
    compare_versions "$cur_claude" "$lat_claude" "Claude Code" || needs_update=1
    compare_versions "$cur_codex" "$lat_codex" "Codex" || needs_update=1
    echo

    if [[ $needs_update -eq 1 ]]; then
        if [[ -n $cur_claude ]] && [[ $(normalize_version "$cur_claude") != $(normalize_version "$lat_claude") ]]; then
            section "Claude Code Changes"
            local changes
            changes=$(fetch_changelog_between "$cur_claude" "$lat_claude")
            if [[ -n $changes ]]; then
                echo "$changes" | indent
            else
                echo "  (changelog unavailable)"
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
                echo "  (release notes unavailable)"
            fi
            echo
        fi

        if [[ $image_exists == true ]]; then
            echo "Run 'make versions-up' to upgrade"
        else
            echo "Run 'make build' to build images"
        fi
    else
        echo "All versions up-to-date"
    fi
}

main
