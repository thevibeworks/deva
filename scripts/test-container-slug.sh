#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
ERRORS=""

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS="${ERRORS}\n  FAIL: $1"; echo "  FAIL: $1" >&2; }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label: expected='$expected' actual='$actual'"
    fi
}

assert_match() {
    local label="$1" pattern="$2" actual="$3"
    if [[ "$actual" =~ $pattern ]]; then
        pass "$label"
    else
        fail "$label: pattern='$pattern' actual='$actual'"
    fi
}

assert_no_match() {
    local label="$1" pattern="$2" actual="$3"
    if [[ "$actual" =~ $pattern ]]; then
        fail "$label: should NOT match pattern='$pattern' actual='$actual'"
    else
        pass "$label"
    fi
}

# ──────────────────────────────────────
# Source the helper functions from deva.sh without running it.
# We extract just the function definitions we need.
# ──────────────────────────────────────
source_helpers() {
    eval "$(sed -n '/^sanitize_slug_component()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^extract_auth_file_stem()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^short_hash()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^compute_shape_hash()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^generate_auth_tag()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^build_container_name()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^generate_container_slug_for_path()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^compute_slug_components_for_path()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^extract_agent_from_name()/,/^}/p' "$REPO_ROOT/deva.sh")"
    eval "$(sed -n '/^agent_version_tag()/,/^}/p' "$REPO_ROOT/deva.sh")"
    AGENT_VERSION_TAG_CACHE_AGENT=""
    AGENT_VERSION_TAG_CACHE=""
    # No image label in unit tests unless a test stubs docker itself
    docker_image_ref() { printf 'deva-test:none'; }
    DEVA_CONTAINER_PREFIX="deva"
}

source_helpers

# ──────────────────────────────────────
echo "=== extract_auth_file_stem ==="
# ──────────────────────────────────────

assert_eq "credentials.json suffix" \
    "fffff" \
    "$(extract_auth_file_stem "/home/user/.config/deva/claude/fffff.credentials.json")"

assert_eq "plain .json suffix" \
    "pianolaauth" \
    "$(extract_auth_file_stem "/home/user/.config/deva/codex/pianolaauth.json")"

assert_eq "no extension" \
    "mytoken" \
    "$(extract_auth_file_stem "/tmp/mytoken")"

assert_eq "dots in stem" \
    "my-auth-v2" \
    "$(extract_auth_file_stem "/tmp/my.auth.v2.credentials.json")"

assert_eq "long stem truncated to 20" \
    "$(printf '%s' "this-is-a-very-long-" | head -c 20)" \
    "$(extract_auth_file_stem "/tmp/this-is-a-very-long-credential-filename.credentials.json")"

# ──────────────────────────────────────
echo "=== generate_auth_tag ==="
# ──────────────────────────────────────

assert_eq "claude default" "auth-default" "$(generate_auth_tag claude claude)"
assert_eq "codex default"  "auth-default" "$(generate_auth_tag codex chatgpt)"
assert_eq "gemini default" "auth-default" "$(generate_auth_tag gemini oauth)"
assert_eq "gemini app-oauth default" "auth-default" "$(generate_auth_tag gemini gemini-app-oauth)"
assert_eq "empty method"   "auth-default" "$(generate_auth_tag claude "")"

assert_eq "claude api-key (no env)" "api-key" "$(generate_auth_tag claude api-key)"
assert_eq "codex api-key (no env)"  "api-key" "$(generate_auth_tag codex api-key)"

assert_eq "claude api-key with env" "api-key-abcd" \
    "$(ANTHROPIC_API_KEY="sk-ant-test1234abcd" generate_auth_tag claude api-key)"

assert_eq "codex api-key with env" "api-key-9876" \
    "$(OPENAI_API_KEY="sk-proj-xyzw9876" generate_auth_tag codex api-key)"

assert_eq "gemini api-key with env" "api-key-end5" \
    "$(GEMINI_API_KEY="AIza-short-key-end5" generate_auth_tag gemini api-key)"

assert_eq "credentials-file with path" \
    "auth-file-fffff" \
    "$(generate_auth_tag claude credentials-file "/home/u/.config/deva/claude/fffff.credentials.json")"

assert_eq "credentials-file with plain json" \
    "auth-file-pianolaauth" \
    "$(generate_auth_tag codex credentials-file "/home/u/.config/deva/codex/pianolaauth.json")"

assert_eq "credentials-file no path" "auth-file" "$(generate_auth_tag claude credentials-file)"

assert_eq "bedrock method" "bedrock" "$(generate_auth_tag claude bedrock)"
assert_eq "vertex method"  "vertex"  "$(generate_auth_tag claude vertex)"
assert_eq "copilot method" "copilot" "$(generate_auth_tag claude copilot)"
assert_eq "oat method"     "oat"     "$(generate_auth_tag claude oat)"

assert_eq "env override"   "env"     "$(generate_auth_tag claude claude "" true)"

assert_eq "gemini-api-key method" "api-key" "$(generate_auth_tag gemini gemini-api-key)"
assert_eq "gemini-api-key with GEMINI_API_KEY" "api-key-xyzw" \
    "$(GEMINI_API_KEY="AIza-test-xyzw" generate_auth_tag gemini gemini-api-key)"
assert_eq "gemini-api-key GOOGLE_API_KEY fallback" "api-key-goog" \
    "$(GOOGLE_API_KEY="AIza-test-goog" generate_auth_tag gemini gemini-api-key)"

assert_eq "compute-adc method" "compute-adc" "$(generate_auth_tag gemini compute-adc)"

assert_eq "api-key 3 char key -> no suffix" "api-key" \
    "$(ANTHROPIC_API_KEY="abc" generate_auth_tag claude api-key)"
assert_eq "api-key exactly 4 chars" "api-key-abcd" \
    "$(ANTHROPIC_API_KEY="abcd" generate_auth_tag claude api-key)"

assert_eq "sanitizes unknown method with special chars" "some-weird-method" \
    "$(generate_auth_tag claude "some.weird/method")"

# ──────────────────────────────────────
echo "=== compute_shape_hash ==="
# ──────────────────────────────────────

raw_hash=$(short_hash "test-input" 8)
assert_match "short_hash produces hex" "^[a-f0-9]{8}$" "$raw_hash"

h1=$(compute_shape_hash "ghcr.io/thevibeworks/deva:latest" "" "")
h2=$(compute_shape_hash "ghcr.io/thevibeworks/deva:latest" "" "")
assert_eq "deterministic" "$h1" "$h2"

h3=$(compute_shape_hash "ghcr.io/thevibeworks/deva:nightly" "" "")
assert_no_match "different image -> different hash" "^${h1}$" "$h3"

h4=$(compute_shape_hash "ghcr.io/thevibeworks/deva:latest" "/vol1:/dst1|" "")
assert_no_match "volumes change hash" "^${h1}$" "$h4"

h5=$(compute_shape_hash "ghcr.io/thevibeworks/deva:latest" "" "/custom/config")
assert_no_match "config changes hash" "^${h1}$" "$h5"

assert_match "hash is 8 chars hex" "^[a-f0-9]{8}$" "$h1"

# ──────────────────────────────────────
echo "=== build_container_name ==="
# ──────────────────────────────────────

name=$(build_container_name "deva" "claude" "auth-default" "lroolle-deploydock" "ab12cd34" "false" "")
assert_eq "persistent default" \
    "deva--claude--auth-default--lroolle-deploydock..ab12cd34" "$name"

name=$(build_container_name "deva" "codex" "auth-file-pianolaauth" "lroolle-deploydock" "ab12cd34" "false" "")
assert_eq "persistent with auth-file" \
    "deva--codex--auth-file-pianolaauth--lroolle-deploydock..ab12cd34" "$name"

name=$(build_container_name "deva" "claude" "api-key-abcd" "myrepo" "ff00ff00" "true" "12345")
assert_eq "ephemeral with api-key" \
    "deva--claude--api-key-abcd--myrepo..ff00ff00--12345" "$name"

name=$(build_container_name "deva" "gemini" "vertex" "big-project" "11223344" "false" "")
assert_eq "persistent vertex auth" \
    "deva--gemini--vertex--big-project..11223344" "$name"

# Versioned agent segment (#420): stub docker to return an image label
docker() {
    if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
        printf '2.1.204\n'
        return 0
    fi
    return 1
}
AGENT_VERSION_TAG_CACHE_AGENT="" AGENT_VERSION_TAG_CACHE=""
name=$(build_container_name "deva" "claude" "auth-file-max" "myrepo" "ab12cd34" "false" "")
assert_eq "persistent with agent version" \
    "deva--claude-v2.1.204--auth-file-max--myrepo..ab12cd34" "$name"

AGENT_VERSION_TAG_CACHE_AGENT="" AGENT_VERSION_TAG_CACHE=""
name=$(build_container_name "deva" "mystery" "auth-default" "myrepo" "ab12cd34" "false" "")
assert_eq "unmapped agent stays bare" \
    "deva--mystery--auth-default--myrepo..ab12cd34" "$name"
unset -f docker
AGENT_VERSION_TAG_CACHE_AGENT="" AGENT_VERSION_TAG_CACHE=""

# ──────────────────────────────────────
echo "=== extract_agent_from_name ==="
# ──────────────────────────────────────

assert_eq "new format claude" "claude" \
    "$(extract_agent_from_name "deva--claude--auth-default--myrepo..ab12cd34")"

assert_eq "new format codex" "codex" \
    "$(extract_agent_from_name "deva--codex--auth-file-foo--myrepo..ab12cd34")"

assert_eq "new format gemini" "gemini" \
    "$(extract_agent_from_name "deva--gemini--vertex--myrepo..ab12cd34")"

assert_eq "new format ephemeral" "claude" \
    "$(extract_agent_from_name "deva--claude--api-key-abcd--myrepo..ab12cd34--99999")"

assert_eq "versioned agent segment" "claude" \
    "$(extract_agent_from_name "deva--claude-v2.1.204--auth-file-max--myrepo..ab12cd34")"

assert_eq "versioned ephemeral" "codex" \
    "$(extract_agent_from_name "deva--codex-v0.131.0--auth-default--myrepo..ab12cd34--4242")"

assert_eq "legacy ephemeral" "claude" \
    "$(extract_agent_from_name "deva-myrepo..i47b207-claude-12345")"

assert_eq "legacy persistent (no agent)" "share" \
    "$(extract_agent_from_name "deva-myrepo..i47b207..va3797701")"

# ──────────────────────────────────────
echo "=== container name format (regex structure) ==="
# ──────────────────────────────────────

name=$(build_container_name "deva" "claude" "auth-default" "lroolle-deploydock" "ab12cd34" "false" "")
assert_match "double-dash field separators" \
    "^deva--[a-z]+--[a-z0-9-]+--[a-zA-Z0-9-]+\.\.[a-f0-9]{8}$" "$name"

name=$(build_container_name "deva" "codex" "auth-file-test" "myrepo" "ab12cd34" "true" "999")
assert_match "ephemeral PID suffix" \
    "--[0-9]+$" "$name"

# ──────────────────────────────────────
echo "=== fallback regex matches both formats ==="
# ──────────────────────────────────────

escaped_slug="lroolle-deploydock"
rgx="^deva(--.*--${escaped_slug}|-${escaped_slug})(\\.\\.|-|$)"

old_name="deva-lroolle-deploydock..i47b207..va3797701"
new_name="deva--claude--auth-default--lroolle-deploydock..ab12cd34"

assert_match "regex matches old format" "$rgx" "$old_name"
assert_match "regex matches new format" "$rgx" "$new_name"
assert_no_match "regex rejects unrelated" "$rgx" "deva-other-project..i47b207"

# ──────────────────────────────────────
echo "=== integration: dry-run container name ==="
# ──────────────────────────────────────

tmp_home="$(mktemp -d)"
cleanup() { rm -rf "$tmp_home"; }
trap cleanup EXIT

run_dry() {
    (
        cd "$REPO_ROOT"
        HOME="$tmp_home" \
        XDG_CONFIG_HOME="$tmp_home/.config" \
        XDG_CACHE_HOME="$tmp_home/.cache" \
        DEVA_NO_DOCKER=1 \
        ./deva.sh "$@"
    ) 2>&1
}

extract_container_name() {
    local output="$1"
    echo "$output" | grep -oE 'Container name: [^ ]+' | head -1 | sed 's/Container name: //'
}

out="$(run_dry claude --debug --dry-run || true)"
cname="$(extract_container_name "$out")"
if [ -n "$cname" ]; then
    assert_match "dry-run: new format structure" \
        "^deva--claude(-v[A-Za-z0-9._-]+)?--auth-default--" "$cname"
    assert_match "dry-run: ends with ..hash" \
        '\.\.[a-f0-9]{8}$' "$cname"
    assert_no_match "dry-run: no old-style ..i prefix" \
        '\.\.i[a-f0-9]' "$cname"
else
    fail "dry-run: could not extract container name from output"
fi

out="$(run_dry codex --debug --dry-run || true)"
cname="$(extract_container_name "$out")"
if [ -n "$cname" ]; then
    assert_match "dry-run codex: agent in name" \
        "^deva--codex(-v[A-Za-z0-9._-]+)?--" "$cname"
else
    fail "dry-run codex: could not extract container name"
fi

out="$(run_dry gemini --debug --dry-run || true)"
cname="$(extract_container_name "$out")"
if [ -n "$cname" ]; then
    assert_match "dry-run gemini: agent in name" \
        "^deva--gemini(-v[A-Za-z0-9._-]+)?--" "$cname"
else
    fail "dry-run gemini: could not extract container name"
fi

# Ephemeral mode
out="$(run_dry claude --rm --debug --dry-run || true)"
cname="$(extract_container_name "$out")"
if [ -n "$cname" ]; then
    assert_match "dry-run ephemeral: has PID suffix" \
        '--[0-9]+$' "$cname"
    assert_match "dry-run ephemeral: agent in name" \
        "^deva--claude(-v[A-Za-z0-9._-]+)?--" "$cname"
else
    fail "dry-run ephemeral: could not extract container name"
fi

# Different agents same workspace -> different container names
out_claude="$(run_dry claude --debug --dry-run || true)"
out_codex="$(run_dry codex --debug --dry-run || true)"
cname_claude="$(extract_container_name "$out_claude")"
cname_codex="$(extract_container_name "$out_codex")"
if [ -n "$cname_claude" ] && [ -n "$cname_codex" ]; then
    if [ "$cname_claude" != "$cname_codex" ]; then
        pass "different agents -> different container names"
    else
        fail "different agents -> different container names: both='$cname_claude'"
    fi
else
    fail "could not extract container names for agent isolation test"
fi

# ──────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    echo -e "$ERRORS"
    exit 1
fi
echo "All tests passed."
