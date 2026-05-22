#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp_home="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp_home"
}
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

workspace_claude_mount="-v $REPO_ROOT/.claude:$REPO_ROOT/.claude"

default_output="$(run_dry claude --debug --dry-run || true)"
if grep -F -- "$workspace_claude_mount" <<<"$default_output" >/dev/null; then
    echo "unexpected recursive child remount in default workspace shape" >&2
    echo "$default_output" >&2
    exit 1
fi

recursive_output="$(run_dry claude --debug --dry-run -v "$REPO_ROOT/.claude:$REPO_ROOT/.claude" || true)"
if ! grep -F -- "recursive bind mount" <<<"$recursive_output" >/dev/null; then
    echo "expected recursive bind mount validation failure" >&2
    echo "$recursive_output" >&2
    exit 1
fi

# ───── hybrid-mount coverage ─────
# .deva VOLUME= overrides per-agent default mounts at the same target,
# so hybrid setups like `VOLUME=~/.codex:/home/deva/.codex` do not
# collide with validate_bind_mount_shape's duplicate-target guard.

hybrid_root="$(mktemp -d)"
hybrid_cleanup() {
    rm -rf "$hybrid_root"
    cleanup
}
trap hybrid_cleanup EXIT

mkdir -p \
    "$hybrid_root/xdg/deva/claude" \
    "$hybrid_root/xdg/deva/codex" \
    "$hybrid_root/xdg/deva/gemini" \
    "$hybrid_root/host/.claude" \
    "$hybrid_root/host/.codex" \
    "$hybrid_root/host/.gemini" \
    "$hybrid_root/cli/.codex"
touch "$hybrid_root/host/.claude.json"

ln -sf "$hybrid_root/host/.claude"      "$hybrid_root/xdg/deva/claude/.claude"
ln -sf "$hybrid_root/host/.claude.json" "$hybrid_root/xdg/deva/claude/.claude.json"
ln -sf "$hybrid_root/host/.codex"       "$hybrid_root/xdg/deva/codex/.codex"
ln -sf "$hybrid_root/host/.gemini"      "$hybrid_root/xdg/deva/gemini/.gemini"

cat > "$hybrid_root/xdg/deva/.deva" <<EOF
VOLUME=$hybrid_root/host/.codex:/home/deva/.codex
VOLUME=$hybrid_root/host/.gemini:/home/deva/.gemini
VOLUME=$hybrid_root/host/.claude:/home/deva/.claude
VOLUME=$hybrid_root/host/.claude.json:/home/deva/.claude.json
EOF

run_hybrid() {
    (
        cd "$REPO_ROOT"
        HOME="$hybrid_root/home" \
        XDG_CONFIG_HOME="$hybrid_root/xdg" \
        XDG_CACHE_HOME="$hybrid_root/cache" \
        AUTOLINK=false \
        DEVA_NO_DOCKER=1 \
        ./deva.sh "$@"
    ) 2>&1
}

count_target() {
    local target="$1" output="$2" docker_line matches
    docker_line="$(grep '^docker run' <<<"$output" | head -1 || true)"
    matches="$(grep -oE "[[:space:]]-v[[:space:]]+[^[:space:]]+:${target//./\\.}([[:space:]]|:|$)" <<<" $docker_line " || true)"
    if [ -z "$matches" ]; then
        echo 0
    else
        printf '%s\n' "$matches" | wc -l | tr -d ' '
    fi
}

for agent in claude codex gemini; do
    out="$(run_hybrid "$agent" --dry-run || true)"
    if grep -F -- 'duplicate bind mount target detected' <<<"$out" >/dev/null; then
        echo "hybrid recipe triggered duplicate-target error for $agent" >&2
        echo "$out" >&2
        exit 1
    fi
    for tgt in /home/deva/.claude /home/deva/.claude.json /home/deva/.codex /home/deva/.gemini; do
        c="$(count_target "$tgt" "$out")"
        if [[ "$c" -ne 1 ]]; then
            echo "hybrid $agent: target $tgt emitted $c times (want 1)" >&2
            echo "$out" >&2
            exit 1
        fi
    done
done

# CLI -v overrides .deva VOLUME= at the same target (first-writer-wins).
cli_out="$(run_hybrid claude --dry-run -v "$hybrid_root/cli/.codex:/home/deva/.codex" || true)"
if ! grep -F -- "-v $hybrid_root/cli/.codex:/home/deva/.codex" <<<"$cli_out" >/dev/null; then
    echo "CLI -v override for /home/deva/.codex not present" >&2
    echo "$cli_out" >&2
    exit 1
fi
if grep -F -- "-v $hybrid_root/host/.codex:/home/deva/.codex" <<<"$cli_out" >/dev/null; then
    echo ".deva VOLUME= for /home/deva/.codex should have been dropped by CLI override" >&2
    echo "$cli_out" >&2
    exit 1
fi

# ───── hybrid-by-default coverage ─────
# Populated per-agent XDG subdirs trigger hybrid mounts automatically,
# without any .deva VOLUME= entries. --config-home DIR still isolates.

default_root="$(mktemp -d)"
default_cleanup() {
    rm -rf "$default_root"
    hybrid_cleanup
}
trap default_cleanup EXIT

mkdir -p \
    "$default_root/xdg/deva/claude/.claude" \
    "$default_root/xdg/deva/codex/.codex" \
    "$default_root/xdg/deva/gemini/.gemini"
echo '{}' > "$default_root/xdg/deva/claude/.claude.json"

run_default() {
    (
        cd "$REPO_ROOT"
        HOME="$default_root/home" \
        XDG_CONFIG_HOME="$default_root/xdg" \
        XDG_CACHE_HOME="$default_root/cache" \
        AUTOLINK=false \
        DEVA_NO_DOCKER=1 \
        ./deva.sh "$@"
    ) 2>&1
}

for agent in claude codex gemini; do
    out="$(run_default "$agent" --dry-run || true)"
    for tgt in /home/deva/.claude /home/deva/.claude.json /home/deva/.codex /home/deva/.gemini; do
        c="$(count_target "$tgt" "$out")"
        if [[ "$c" -ne 1 ]]; then
            echo "hybrid-default $agent: target $tgt emitted $c times (want 1)" >&2
            echo "$out" >&2
            exit 1
        fi
    done
done

# Explicit --config-home DIR isolates to a single home (no sibling agents).
iso_out="$(run_default claude --config-home "$default_root/xdg/deva/claude" --dry-run || true)"
iso_claude="$(count_target /home/deva/.claude "$iso_out")"
iso_codex="$(count_target /home/deva/.codex "$iso_out")"
if [[ "$iso_claude" -ne 1 ]]; then
    echo "explicit -c: target /home/deva/.claude emitted $iso_claude times (want 1)" >&2
    echo "$iso_out" >&2
    exit 1
fi
if [[ "$iso_codex" -ne 0 ]]; then
    echo "explicit -c: target /home/deva/.codex emitted $iso_codex times (want 0)" >&2
    echo "$iso_out" >&2
    exit 1
fi
