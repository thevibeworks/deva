#!/usr/bin/env bash
# Unit tests for scripts/release-utils.sh TOOL_REGISTRY helpers.
#
# Runs without network — exercises schema parsing, field lookup, and the
# filter_tools scope logic. Fetch-the-internet bits (fetch_latest_version,
# gh api) are NOT covered here; those live in CI smoke and nightly.
#
# Usage:   bash tests/test_release_utils.sh
# Exits 0 on success, 1 on failure. Prints one line per assertion.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# release-utils.sh sets `set -euo pipefail`, which would abort this harness
# on the first non-zero rc from an assert_exit subject. Source it, then
# deliberately disable -e so we can capture exit codes ourselves.
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/release-utils.sh"
set +e

FAIL=0
PASS=0

red()   { printf '\033[0;31m%s\033[0m' "$*"; }
green() { printf '\033[0;32m%s\033[0m' "$*"; }

assert_eq() {
    local label=$1 expected=$2 actual=$3
    if [[ "$expected" == "$actual" ]]; then
        printf '  %s %s\n' "$(green PASS)" "$label"
        PASS=$((PASS + 1))
    else
        printf '  %s %s\n' "$(red FAIL)" "$label"
        printf '       expected: %q\n' "$expected"
        printf '       actual:   %q\n' "$actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit() {
    local label=$1 expected_rc=$2
    shift 2
    local actual_rc=0
    # `|| actual_rc=$?` keeps this command in a checked context so `set -e`
    # (if inherited from a sourced lib) cannot abort the harness before
    # we capture the rc.
    "$@" >/dev/null 2>&1 || actual_rc=$?
    if [[ "$actual_rc" == "$expected_rc" ]]; then
        printf '  %s %s\n' "$(green PASS)" "$label"
        PASS=$((PASS + 1))
    else
        printf '  %s %s\n' "$(red FAIL)" "$label"
        printf '       expected rc: %s\n' "$expected_rc"
        printf '       actual rc:   %s\n' "$actual_rc"
        FAIL=$((FAIL + 1))
    fi
}

section() {
    printf '\n=== %s ===\n' "$*"
}

# ───── schema sanity ─────
section "schema: every row parses to 8 fields"
for entry in "${TOOL_REGISTRY[@]}"; do
    IFS='|' read -ra fields <<< "$entry"
    name="${fields[0]}"
    assert_eq "row has 8 fields: $name" "8" "${#fields[@]}"
done

section "schema: group values are in enum"
for tool in $(get_all_tools); do
    group="$(get_tool_field "$tool" group)"
    case "$group" in
        agent|browser|toolchain|runtime)
            assert_eq "group enum: $tool" "$group" "$group"
            ;;
        *)
            assert_eq "group enum: $tool" "agent|browser|toolchain|runtime" "$group"
            ;;
    esac
done

section "schema: image values are in enum"
for tool in $(get_all_tools); do
    image="$(get_tool_field "$tool" image)"
    case "$image" in
        base|main|rust)
            assert_eq "image enum: $tool" "$image" "$image"
            ;;
        *)
            assert_eq "image enum: $tool" "base|main|rust" "$image"
            ;;
    esac
done

# ───── get_tool_field new fields ─────
section "get_tool_field: new field retrieval"
assert_eq "claude-code group"    "agent"   "$(get_tool_field claude-code group)"
assert_eq "claude-code image"    "main"    "$(get_tool_field claude-code image)"
assert_eq "playwright group"     "browser" "$(get_tool_field playwright  group)"
assert_eq "playwright image"     "rust"    "$(get_tool_field playwright  image)"
assert_eq "atlas-cli group"      "agent"   "$(get_tool_field atlas-cli   group)"
assert_eq "copilot-api image"    "main"    "$(get_tool_field copilot-api image)"

section "get_tool_field: existing fields still work"
assert_eq "claude-code type"     "npm"                         "$(get_tool_field claude-code type)"
assert_eq "atlas-cli type"       "github-release"              "$(get_tool_field atlas-cli  type)"
assert_eq "playwright source"    "playwright"                  "$(get_tool_field playwright source)"
assert_eq "copilot-api label"    "org.opencontainers.image.copilot_api_version" "$(get_tool_field copilot-api label)"

section "get_tool_field: unknown tool returns nonzero"
assert_exit "unknown tool" 1 get_tool_field nonexistent-tool name

section "get_tool_field: does not leak loop vars into caller scope"
# Regression: `read -r` inside the function must not clobber same-named
# vars in the caller's frame (bash dynamic scoping). Regression test:
# set a caller-local `label`, call get_tool_field, confirm it survives.
leak_test() {
    local label="i-own-this" name="caller-name" image="caller-image"
    get_tool_field playwright label >/dev/null  # discard output
    echo "$label|$name|$image"
}
leak_after="$(leak_test)"
assert_eq "caller 'label' not clobbered"  "i-own-this"   "${leak_after%%|*}"
assert_eq "caller 'name' not clobbered"   "caller-name"  "$(echo "$leak_after" | cut -d'|' -f2)"
assert_eq "caller 'image' not clobbered"  "caller-image" "${leak_after##*|}"

# ───── get_tools_by_group ─────
section "get_tools_by_group"
agent_tools="$(get_tools_by_group agent | sort | tr '\n' ' ' | sed 's/ $//')"
expected_agent="atlas-cli claude-code codex copilot-api gemini-cli"
assert_eq "group=agent" "$expected_agent" "$agent_tools"

browser_tools="$(get_tools_by_group browser | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "group=browser" "playwright" "$browser_tools"

toolchain_tools="$(get_tools_by_group toolchain | tr '\n' ' ' | sed 's/ $//')"
assert_eq "group=toolchain (empty until Step 3)" "" "$toolchain_tools"

nonexistent_group="$(get_tools_by_group does-not-exist | tr '\n' ' ' | sed 's/ $//')"
assert_eq "group=does-not-exist" "" "$nonexistent_group"

# ───── get_tools_by_image ─────
section "get_tools_by_image"
main_tools="$(get_tools_by_image main | sort | tr '\n' ' ' | sed 's/ $//')"
expected_main="atlas-cli claude-code codex copilot-api gemini-cli"
assert_eq "image=main" "$expected_main" "$main_tools"

rust_tools="$(get_tools_by_image rust | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "image=rust" "playwright" "$rust_tools"

base_tools="$(get_tools_by_image base | tr '\n' ' ' | sed 's/ $//')"
assert_eq "image=base (empty until Step 3)" "" "$base_tools"

# ───── filter_tools: scope resolution ─────
section "filter_tools: default (no scope)"
default_all="$(unset GROUP TOOL IMAGE; filter_tools | sort | tr '\n' ' ' | sed 's/ $//')"
expected_all="atlas-cli claude-code codex copilot-api gemini-cli playwright"
assert_eq "default returns all 6" "$expected_all" "$default_all"

section "filter_tools: TOOL= scope"
single="$(TOOL=claude-code GROUP= IMAGE= filter_tools)"
assert_eq "TOOL=claude-code" "claude-code" "$single"

section "filter_tools: GROUP= scope"
grouped="$(GROUP=browser TOOL= IMAGE= filter_tools)"
assert_eq "GROUP=browser" "playwright" "$grouped"

section "filter_tools: IMAGE= scope"
imaged="$(IMAGE=rust GROUP= TOOL= filter_tools)"
assert_eq "IMAGE=rust" "playwright" "$imaged"

section "filter_tools: two scopes set → error (rc=2)"
assert_exit "GROUP + TOOL set"  2 bash -c "source '$REPO_ROOT/scripts/release-utils.sh'; GROUP=agent TOOL=claude-code filter_tools"
assert_exit "GROUP + IMAGE set" 2 bash -c "source '$REPO_ROOT/scripts/release-utils.sh'; GROUP=agent IMAGE=main filter_tools"
assert_exit "TOOL + IMAGE set"  2 bash -c "source '$REPO_ROOT/scripts/release-utils.sh'; TOOL=claude-code IMAGE=main filter_tools"

section "filter_tools: three scopes set → error (rc=2)"
assert_exit "all three set" 2 bash -c "source '$REPO_ROOT/scripts/release-utils.sh'; GROUP=agent TOOL=claude-code IMAGE=main filter_tools"

section "filter_tools: unknown TOOL → error (rc=2)"
assert_exit "TOOL=nonexistent" 2 bash -c "source '$REPO_ROOT/scripts/release-utils.sh'; TOOL=nonexistent filter_tools"

# ───── images_for_tools ─────
section "images_for_tools: single tool"
img="$(echo "claude-code" | images_for_tools)"
assert_eq "claude-code → main" "main" "$img"

img="$(echo "playwright" | images_for_tools)"
assert_eq "playwright → rust" "rust" "$img"

section "images_for_tools: mixed tools dedupe"
mixed="$(printf '%s\n' "claude-code" "codex" "playwright" | images_for_tools | tr '\n' ' ' | sed 's/ $//')"
assert_eq "mixed dedupes to main + rust" "main rust" "$mixed"

section "images_for_tools: empty input → empty output"
empty="$(printf '' | images_for_tools)"
assert_eq "empty input" "" "$empty"

# ───── summary ─────
section "summary"
total=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
    printf '%s  %d/%d assertions\n' "$(green OK)" "$PASS" "$total"
    exit 0
else
    printf '%s  %d/%d assertions (%d failed)\n' "$(red FAIL)" "$PASS" "$total" "$FAIL"
    exit 1
fi
