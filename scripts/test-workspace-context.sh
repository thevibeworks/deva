#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
ERRORS=""

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  FAIL: $1"; echo "  FAIL: $1" >&2; }

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

source_inject() {
    eval "$(sed -n '/^inject_workspace_context()/,/^}/p' "$REPO_ROOT/deva.sh")"
}

source_inject

echo "=== Both files created from empty workspace ==="

ws1="$tmp_root/ws-fresh"
mkdir -p "$ws1"
(cd "$ws1" && EPHEMERAL_MODE=false DEVA_NO_DOCKER="" inject_workspace_context)

if [ -f "$ws1/.claude/CLAUDE.md" ]; then pass "CLAUDE.md created"; else fail "CLAUDE.md not created"; fi
if [ -f "$ws1/AGENTS.md" ]; then pass "AGENTS.md created"; else fail "AGENTS.md not created"; fi

echo ""
echo "=== Content is correct ==="

if grep -qF "Ubuntu Linux" "$ws1/AGENTS.md"; then pass "has container context"; else fail "missing context"; fi
if grep -qF "Docker is available" "$ws1/AGENTS.md"; then pass "docker detected"; else fail "missing docker"; fi
if grep -qF "persist across sessions" "$ws1/AGENTS.md"; then pass "persistent mode"; else fail "missing persist"; fi
if grep -qF "DEVA_* environment" "$ws1/AGENTS.md"; then pass "env var pointer"; else fail "missing pointer"; fi
if ! grep -qF "macOS" "$ws1/AGENTS.md"; then pass "no hardcoded macOS"; else fail "hardcoded macOS"; fi
if grep -qF "Ubuntu Linux 24.04 LTS" "$ws1/AGENTS.md"; then pass "Ubuntu version"; else fail "missing Ubuntu version"; fi
if grep -qF "No display server" "$ws1/AGENTS.md"; then pass "no-display warning"; else fail "missing display warning"; fi
if grep -qF "sudo works without password" "$ws1/AGENTS.md"; then pass "sudo hint"; else fail "missing sudo hint"; fi
if grep -qF "uv" "$ws1/AGENTS.md"; then pass "uv mentioned"; else fail "missing uv"; fi
if grep -qF "pip is NOT in PATH" "$ws1/AGENTS.md"; then pass "pip warning"; else fail "missing pip warning"; fi

echo ""
echo "=== Dynamic: ephemeral + no docker ==="

ws2="$tmp_root/ws-ephemeral"
mkdir -p "$ws2"
(cd "$ws2" && EPHEMERAL_MODE=true DEVA_NO_DOCKER=1 inject_workspace_context)

if grep -qF "Ephemeral container" "$ws2/AGENTS.md"; then pass "ephemeral shown"; else fail "ephemeral missing"; fi
if ! grep -qF "Docker is available" "$ws2/AGENTS.md"; then pass "docker hidden"; else fail "docker shown when disabled"; fi

echo ""
echo "=== No leading blank line on fresh files ==="

first_char=$(head -c1 "$ws1/AGENTS.md")
if [ "$first_char" != "" ]; then pass "no leading blank"; else fail "leading blank"; fi

echo ""
echo "=== Appends to existing content ==="

ws3="$tmp_root/ws-existing"
mkdir -p "$ws3/.claude"
echo "# My Claude Instructions" > "$ws3/.claude/CLAUDE.md"
printf '# Project Rules\n\nUse Go 1.22.\n' > "$ws3/AGENTS.md"

(cd "$ws3" && EPHEMERAL_MODE=false DEVA_NO_DOCKER="" inject_workspace_context)

if grep -qF "My Claude Instructions" "$ws3/.claude/CLAUDE.md"; then pass "CLAUDE.md original preserved"; else fail "original lost"; fi
if grep -qF "Project Rules" "$ws3/AGENTS.md"; then pass "AGENTS.md original preserved"; else fail "original lost"; fi
if grep -qF "Ubuntu Linux" "$ws3/.claude/CLAUDE.md"; then pass "context in CLAUDE.md"; else fail "missing in CLAUDE.md"; fi
if grep -qF "Ubuntu Linux" "$ws3/AGENTS.md"; then pass "context in AGENTS.md"; else fail "missing in AGENTS.md"; fi

echo ""
echo "=== Replace on re-run (not duplicate) ==="

(cd "$ws3" && EPHEMERAL_MODE=false DEVA_NO_DOCKER="" inject_workspace_context)
(cd "$ws3" && EPHEMERAL_MODE=false DEVA_NO_DOCKER="" inject_workspace_context)

claude_m=$(grep -cF "<!-- deva:container-context -->" "$ws3/.claude/CLAUDE.md")
agents_m=$(grep -cF "<!-- deva:container-context -->" "$ws3/AGENTS.md")

if [ "$claude_m" = "1" ]; then pass "CLAUDE.md one block after 3 runs"; else fail "CLAUDE.md has $claude_m blocks"; fi
if [ "$agents_m" = "1" ]; then pass "AGENTS.md one block after 3 runs"; else fail "AGENTS.md has $agents_m blocks"; fi
if grep -qF "My Claude Instructions" "$ws3/.claude/CLAUDE.md"; then pass "original survives replace"; else fail "original lost on replace"; fi

echo ""
echo "=== Content updates on re-run ==="

ws4="$tmp_root/ws-update"
mkdir -p "$ws4"
(cd "$ws4" && EPHEMERAL_MODE=false DEVA_NO_DOCKER=1 inject_workspace_context)
if ! grep -qF "Docker is available" "$ws4/AGENTS.md"; then pass "first run: no docker"; else fail "docker shown"; fi

(cd "$ws4" && EPHEMERAL_MODE=false DEVA_NO_DOCKER="" inject_workspace_context)
if grep -qF "Docker is available" "$ws4/AGENTS.md"; then pass "second run: docker added"; else fail "docker not updated"; fi

echo ""
echo "=== Markers recoverable ==="

block=$(sed -n '/<!-- deva:container-context -->/,/<!-- \/deva:container-context -->/p' "$ws3/AGENTS.md")
if [ -n "$block" ]; then pass "block extractable via sed"; else fail "not extractable"; fi

echo ""
echo "=== Results ==="
echo "  $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    printf '%b\n' "$ERRORS"
    exit 1
fi
