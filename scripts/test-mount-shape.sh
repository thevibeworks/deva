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
    "$hybrid_root/xdg/deva/grok" \
    "$hybrid_root/host/.claude" \
    "$hybrid_root/host/.codex" \
    "$hybrid_root/host/.gemini" \
    "$hybrid_root/host/.grok" \
    "$hybrid_root/cli/.codex"
touch "$hybrid_root/host/.claude.json"

ln -sf "$hybrid_root/host/.claude"      "$hybrid_root/xdg/deva/claude/.claude"
ln -sf "$hybrid_root/host/.claude.json" "$hybrid_root/xdg/deva/claude/.claude.json"
ln -sf "$hybrid_root/host/.codex"       "$hybrid_root/xdg/deva/codex/.codex"
ln -sf "$hybrid_root/host/.gemini"      "$hybrid_root/xdg/deva/gemini/.gemini"
ln -sf "$hybrid_root/host/.grok"        "$hybrid_root/xdg/deva/grok/.grok"

cat > "$hybrid_root/xdg/deva/.deva" <<EOF
VOLUME=$hybrid_root/host/.codex:/home/deva/.codex
VOLUME=$hybrid_root/host/.gemini:/home/deva/.gemini
VOLUME=$hybrid_root/host/.grok:/home/deva/.grok
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

for agent in claude codex gemini grok; do
    out="$(run_hybrid "$agent" --dry-run || true)"
    if grep -F -- 'duplicate bind mount target detected' <<<"$out" >/dev/null; then
        echo "hybrid recipe triggered duplicate-target error for $agent" >&2
        echo "$out" >&2
        exit 1
    fi
    for tgt in /home/deva/.claude /home/deva/.claude.json /home/deva/.codex /home/deva/.gemini /home/deva/.grok; do
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

mkdir -p "$hybrid_root/home/.agents" "$hybrid_root/cli/.agents"
agents_out="$(run_hybrid claude --dry-run -v "$hybrid_root/cli/.agents/:/home/deva/.agents" || true)"
if grep -F -- 'duplicate bind mount target detected' <<<"$agents_out" >/dev/null; then
    echo "CLI -v override for /home/deva/.agents triggered duplicate-target error" >&2
    echo "$agents_out" >&2
    exit 1
fi
agents_count="$(count_target /home/deva/.agents "$agents_out")"
if [[ "$agents_count" -ne 1 ]]; then
    echo "CLI -v override for /home/deva/.agents emitted $agents_count times (want 1)" >&2
    echo "$agents_out" >&2
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
    "$default_root/xdg/deva/gemini/.gemini" \
    "$default_root/xdg/deva/grok/.grok"
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

for agent in claude codex gemini grok; do
    out="$(run_default "$agent" --dry-run || true)"
    for tgt in /home/deva/.claude /home/deva/.claude.json /home/deva/.codex /home/deva/.gemini /home/deva/.grok; do
        c="$(count_target "$tgt" "$out")"
        if [[ "$c" -ne 1 ]]; then
            echo "hybrid-default $agent: target $tgt emitted $c times (want 1)" >&2
            echo "$out" >&2
            exit 1
        fi
    done
done

# ───── grok update-guard + api-key no-mount coverage ─────
# A mounted /home/deva/.grok must come with tmpfs overlays for the
# self-updater dirs (bin/, downloads/) so in-container `grok update`
# cannot write into the host mount.
grok_out="$(run_default grok --dry-run || true)"
for guard in "--tmpfs /home/deva/.grok/bin:" "--tmpfs /home/deva/.grok/downloads:"; do
    if ! grep -F -- "$guard" <<<"$grok_out" >/dev/null; then
        echo "grok oauth: missing update guard $guard" >&2
        echo "$grok_out" >&2
        exit 1
    fi
done

# api-key mode (#403): XAI_API_KEY only, no ~/.grok mount, no guard needed.
apikey_out="$(XAI_API_KEY=test-key run_default grok --auth-with api-key --dry-run || true)"
apikey_grok="$(count_target /home/deva/.grok "$apikey_out")"
if [[ "$apikey_grok" -ne 0 ]]; then
    echo "grok api-key: target /home/deva/.grok emitted $apikey_grok times (want 0)" >&2
    echo "$apikey_out" >&2
    exit 1
fi
if grep -F -- "--tmpfs /home/deva/.grok/bin:" <<<"$apikey_out" >/dev/null; then
    echo "grok api-key: update guard emitted without a .grok mount" >&2
    echo "$apikey_out" >&2
    exit 1
fi

# ───── --host-tmux provisioning coverage ─────
# Container->host tmux is opt-in: no flag, no ~/.ssh mount, no host user env.
# With the flag: ~/.ssh rides in read-only exactly once (user -v wins), and
# DEVA_HOST_USER is passed for the in-container deva-tmux CLI.

mkdir -p "$default_root/home/.ssh"

plain_out="$(run_default claude --dry-run || true)"
if [[ "$(count_target /home/deva/.ssh "$plain_out")" -ne 0 ]]; then
    echo "host-tmux off: /home/deva/.ssh mounted without --host-tmux" >&2
    echo "$plain_out" >&2
    exit 1
fi
if grep -F -- "DEVA_HOST_USER=" <<<"$plain_out" >/dev/null; then
    echo "host-tmux off: DEVA_HOST_USER passed without --host-tmux" >&2
    echo "$plain_out" >&2
    exit 1
fi

tmuxon_out="$(run_default claude --host-tmux --dry-run || true)"
if [[ "$(count_target /home/deva/.ssh "$tmuxon_out")" -ne 1 ]]; then
    echo "host-tmux on: /home/deva/.ssh not mounted exactly once" >&2
    echo "$tmuxon_out" >&2
    exit 1
fi
if ! grep -F -- "$default_root/home/.ssh:/home/deva/.ssh:ro" <<<"$tmuxon_out" >/dev/null; then
    echo "host-tmux on: ~/.ssh mount is not read-only" >&2
    echo "$tmuxon_out" >&2
    exit 1
fi
if ! grep -F -- "DEVA_HOST_USER=" <<<"$tmuxon_out" >/dev/null; then
    echo "host-tmux on: DEVA_HOST_USER not passed" >&2
    echo "$tmuxon_out" >&2
    exit 1
fi

mkdir -p "$default_root/cli-ssh"
tmuxdedup_out="$(run_default claude --host-tmux --dry-run -v "$default_root/cli-ssh:/home/deva/.ssh" || true)"
if [[ "$(count_target /home/deva/.ssh "$tmuxdedup_out")" -ne 1 ]]; then
    echo "host-tmux dedup: /home/deva/.ssh emitted more than once with user -v" >&2
    echo "$tmuxdedup_out" >&2
    exit 1
fi
if ! grep -F -- "-v $default_root/cli-ssh:/home/deva/.ssh" <<<"$tmuxdedup_out" >/dev/null; then
    echo "host-tmux dedup: user -v for /home/deva/.ssh did not win" >&2
    echo "$tmuxdedup_out" >&2
    exit 1
fi

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
