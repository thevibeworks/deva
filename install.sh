#!/bin/bash
set -euo pipefail

DEVA_LAUNCHER="deva.sh"
LEGACY_WRAPPER="claude.sh"
YOLO_WRAPPER="claude-yolo"
DOCKER_IMAGE="ghcr.io/thevibeworks/deva:latest"
DOCKER_IMAGE_FALLBACK="thevibeworks/deva:latest"
INSTALL_BASE_URL="${DEVA_INSTALL_BASE_URL:-https://raw.githubusercontent.com/thevibeworks/deva/main}"

agent_files=(
    "claude.sh"
    "codex.sh"
    "gemini.sh"
    "shared_auth.sh"
)

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
echo "Pulling Docker image..."
if ! docker pull "$DOCKER_IMAGE"; then
    echo "GHCR pull failed. Trying Docker Hub..."
    docker pull "$DOCKER_IMAGE_FALLBACK"
    echo ""
    echo "warning: using Docker Hub fallback image"
    echo "set this if you want Docker Hub by default:"
    echo "  export DEVA_DOCKER_IMAGE=thevibeworks/deva"
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
