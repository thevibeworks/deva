#!/usr/bin/env bash
# test-image-precedence.sh - image/tag resolution precedence
# Contract: environment > .deva config files > -p profile > default,
# with one exception: an explicit CLI -p beats a config-file tag
# (a .deva DEVA_DOCKER_TAG must not turn -p into a silent no-op).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp_home="$(mktemp -d)"
cleanup() { rm -rf "$tmp_home"; }
trap cleanup EXIT

mkdir -p "$tmp_home/.config/deva"
printf 'DEVA_DOCKER_IMAGE=ghcr.io/thevibeworks/deva\nDEVA_DOCKER_TAG=rust\n' \
    > "$tmp_home/.config/deva/.deva"

fail=0
resolved_image() {
    (
        cd "$REPO_ROOT"
        # env -u: the harness itself may run inside a deva container that
        # exports DEVA_DOCKER_TAG/IMAGE; those must not leak into cases
        # that model an unset environment.
        env -u DEVA_DOCKER_IMAGE -u DEVA_DOCKER_TAG \
            HOME="$tmp_home" \
            XDG_CONFIG_HOME="$tmp_home/.config" \
            XDG_CACHE_HOME="$tmp_home/.cache" \
            DEVA_NO_DOCKER=1 \
            ${1+"$@"} ./deva.sh claude --dry-run
    ) 2>&1 | grep -oE 'deva\.image=[^ ]*' | head -1
}

want() {
    local desc="$1" expect="$2" got="$3"
    if [ "$got" = "deva.image=$expect" ]; then
        echo "  PASS $desc"
    else
        echo "  FAIL $desc"
        echo "        expected: deva.image=$expect" >&2
        echo "        got:      $got" >&2
        fail=1
    fi
}

repo="ghcr.io/thevibeworks/deva"

echo "=== image/tag precedence ==="
want "config file alone wins over default" "$repo:rust" \
    "$(resolved_image)"
want "CLI -p beats config-file tag" "$repo:cloak" \
    "$(cd "$REPO_ROOT"; env -u DEVA_DOCKER_IMAGE -u DEVA_DOCKER_TAG \
        HOME="$tmp_home" XDG_CONFIG_HOME="$tmp_home/.config" \
        XDG_CACHE_HOME="$tmp_home/.cache" DEVA_NO_DOCKER=1 \
        ./deva.sh claude -p cloak --dry-run 2>&1 | grep -oE 'deva\.image=[^ ]*' | head -1)"
want "environment beats config file" "$repo:cloak" \
    "$(resolved_image DEVA_DOCKER_TAG=cloak)"
want "environment beats CLI -p" "$repo:latest" \
    "$(cd "$REPO_ROOT"; env -u DEVA_DOCKER_IMAGE \
        DEVA_DOCKER_TAG=latest \
        HOME="$tmp_home" XDG_CONFIG_HOME="$tmp_home/.config" \
        XDG_CACHE_HOME="$tmp_home/.cache" DEVA_NO_DOCKER=1 \
        ./deva.sh claude -p cloak --dry-run 2>&1 | grep -oE 'deva\.image=[^ ]*' | head -1)"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: image precedence" >&2
    exit 1
fi
echo "OK: image precedence"
