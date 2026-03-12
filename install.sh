#!/bin/bash
set -euo pipefail

DEVA_LAUNCHER="deva.sh"
LEGACY_WRAPPER="claude.sh"
YOLO_WRAPPER="claude-yolo"
INSTALL_BASE_URL="${DEVA_INSTALL_BASE_URL:-https://raw.githubusercontent.com/thevibeworks/deva/main}"

agent_files=(
    "claude.sh"
    "codex.sh"
    "gemini.sh"
    "shared_auth.sh"
)

image_ref() {
    local repo="$1"
    local tag="${2:-}"
    local default_tag="$3"
    local tail="${repo##*/}"

    if [[ "$repo" == *@* ]]; then
        printf '%s' "$repo"
        return
    fi

    if [ -n "$tag" ]; then
        printf '%s:%s' "$repo" "$tag"
        return
    fi

    if [[ "$tail" == *:* ]]; then
        printf '%s' "$repo"
        return
    fi

    printf '%s:%s' "$repo" "$default_tag"
}

if [ -n "${DEVA_DOCKER_IMAGE+x}" ]; then
    DOCKER_IMAGE="$(image_ref "$DEVA_DOCKER_IMAGE" "${DEVA_DOCKER_TAG:-}" "latest")"
else
    DOCKER_IMAGE="$(image_ref "ghcr.io/thevibeworks/deva" "${DEVA_DOCKER_TAG:-}" "latest")"
fi

if [ -n "${DEVA_DOCKER_IMAGE_FALLBACK+x}" ]; then
    if [ -n "$DEVA_DOCKER_IMAGE_FALLBACK" ]; then
        DOCKER_IMAGE_FALLBACK="$(image_ref "$DEVA_DOCKER_IMAGE_FALLBACK" "${DEVA_DOCKER_IMAGE_FALLBACK_TAG:-${DEVA_DOCKER_TAG:-}}" "latest")"
    else
        DOCKER_IMAGE_FALLBACK=""
    fi
else
    DOCKER_IMAGE_FALLBACK="$(image_ref "thevibeworks/deva" "${DEVA_DOCKER_IMAGE_FALLBACK_TAG:-${DEVA_DOCKER_TAG:-}}" "latest")"
fi

echo "deva installer"
echo "=============="
echo ""

if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
    INSTALL_DIR="$HOME/.local/bin"
elif [ -w "/usr/local/bin" ]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo "warning: $INSTALL_DIR is not in PATH"
        echo "add this to your shell profile:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
    fi
fi

echo "Installing to: $INSTALL_DIR"

download() {
    local path="$1"
    local dest="$2"
    curl -fsSL "$INSTALL_BASE_URL/$path" -o "$dest"
    chmod +x "$dest"
}

echo "Downloading launchers..."
download "$LEGACY_WRAPPER" "$INSTALL_DIR/$LEGACY_WRAPPER"
download "$YOLO_WRAPPER" "$INSTALL_DIR/$YOLO_WRAPPER"
download "$DEVA_LAUNCHER" "$INSTALL_DIR/$DEVA_LAUNCHER"

echo "Downloading agent modules..."
mkdir -p "$INSTALL_DIR/agents"
for file in "${agent_files[@]}"; do
    download "agents/$file" "$INSTALL_DIR/agents/$file"
done

echo ""
if docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    echo "Using local Docker image: $DOCKER_IMAGE"
else
    echo "Pulling Docker image..."
    if ! docker pull "$DOCKER_IMAGE"; then
        if [ -n "$DOCKER_IMAGE_FALLBACK" ] && [ "$DOCKER_IMAGE_FALLBACK" != "$DOCKER_IMAGE" ]; then
            echo "Primary pull failed. Trying fallback image..."
            docker pull "$DOCKER_IMAGE_FALLBACK"
            echo ""
            echo "warning: using fallback image $DOCKER_IMAGE_FALLBACK"
        else
            echo "error: failed to pull Docker image $DOCKER_IMAGE" >&2
            exit 1
        fi
    fi
fi

echo ""
echo "Install complete."
echo ""
echo "Installed:"
echo "  - $INSTALL_DIR/deva.sh"
echo "  - $INSTALL_DIR/claude.sh"
echo "  - $INSTALL_DIR/claude-yolo"
echo "  - $INSTALL_DIR/agents/claude.sh"
echo "  - $INSTALL_DIR/agents/codex.sh"
echo "  - $INSTALL_DIR/agents/gemini.sh"
echo "  - $INSTALL_DIR/agents/shared_auth.sh"
echo ""
echo "Quick start:"
echo "  1. Make sure Docker is running"
echo "  2. cd into a project"
echo "  3. Run one of:"
echo "     deva.sh codex"
echo "     deva.sh claude -- --help"
echo "     deva.sh gemini -- --help"
echo "     deva.sh shell"
echo ""
echo "warning: do not point deva at your real home directory with dangerous permissions enabled"
