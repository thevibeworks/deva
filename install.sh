#!/bin/bash
set -e

# deva Multi-Agent Development Environment Installer

SCRIPT_NAME="claude.sh"
YOLO_WRAPPER="claude-yolo"
DEVA_LAUNCHER="deva.sh"
DOCKER_IMAGE="ghcr.io/thevibeworks/deva:latest"
GITHUB_RAW="https://raw.githubusercontent.com/thevibeworks/deva/main"

echo "deva Multi-Agent Environment Installer"
echo "=========================="
echo ""

if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
    INSTALL_DIR="$HOME/.local/bin"
    echo "Installing to: $INSTALL_DIR (user directory)"
elif [ -w "/usr/local/bin" ]; then
    INSTALL_DIR="/usr/local/bin"
    echo "Installing to: $INSTALL_DIR (system directory)"
else
    INSTALL_DIR="$HOME/.local/bin"
    echo "Installing to: $INSTALL_DIR (user directory)"
    echo "Creating $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"

    # Check if ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo "warning: $INSTALL_DIR is not in PATH"
        echo "Add this to your shell profile:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
    fi
fi

# Download claude.sh
echo "Downloading claude.sh script..."
curl -fsSL "$GITHUB_RAW/claude.sh" -o "$INSTALL_DIR/$SCRIPT_NAME"
chmod +x "$INSTALL_DIR/$SCRIPT_NAME"

# Download claude-yolo script
echo "Downloading claude-yolo script..."
curl -fsSL "$GITHUB_RAW/claude-yolo" -o "$INSTALL_DIR/$YOLO_WRAPPER"
chmod +x "$INSTALL_DIR/$YOLO_WRAPPER"

# Download deva.sh dispatcher
echo "Downloading deva.sh multi-agent launcher..."
curl -fsSL "$GITHUB_RAW/deva.sh" -o "$INSTALL_DIR/$DEVA_LAUNCHER"
chmod +x "$INSTALL_DIR/$DEVA_LAUNCHER"

# Download agent modules
echo "Downloading agent modules..."
mkdir -p "$INSTALL_DIR/agents"
curl -fsSL "$GITHUB_RAW/agents/claude.sh" -o "$INSTALL_DIR/agents/claude.sh"
curl -fsSL "$GITHUB_RAW/agents/codex.sh" -o "$INSTALL_DIR/agents/codex.sh"
chmod +x "$INSTALL_DIR/agents/claude.sh"
chmod +x "$INSTALL_DIR/agents/codex.sh"

# Pull Docker image
echo ""
echo "Pulling Docker image..."
if ! docker pull "$DOCKER_IMAGE"; then
    echo "Failed to pull from GitHub Container Registry, trying Docker Hub..."
    DOCKER_IMAGE_FALLBACK="thevibeworks/deva:latest"
    docker pull "$DOCKER_IMAGE_FALLBACK"
    echo ""
    echo -e "\033[93mNOTE: Using Docker Hub fallback image\033[0m"
    echo "To use Docker Hub by default, set: export DEVA_DOCKER_IMAGE=thevibeworks/deva"
    echo "Add this to your shell profile (.bashrc, .zshrc) to make it permanent"
fi

# Success message
echo ""
echo "✓ Installation complete!"
echo ""
echo "Scripts installed to: $INSTALL_DIR"
echo "  - $INSTALL_DIR/deva.sh"
echo "  - $INSTALL_DIR/claude.sh"
echo "  - $INSTALL_DIR/claude-yolo"
echo "  - $INSTALL_DIR/agents/claude.sh"
echo "  - $INSTALL_DIR/agents/codex.sh"
echo ""
echo "Commands available:"
echo "=================="
echo ""
echo "  claude.sh      - Full Claude wrapper with all options"
echo "  claude-yolo    - Quick alias for 'claude.sh --yolo'"
echo "  deva.sh        - Multi-agent Docker launcher (Claude, Codex)"
echo ""
echo "Quick Start:"
echo "============"
echo ""
echo "1. Make sure Docker is running"
echo ""
echo "2. Navigate to your project directory:"
echo "   cd ~/projects/my-project"
echo ""
echo "3. Start with deva.sh or Claude YOLO:"
echo "   claude-yolo                              # Run Claude with full permissions"
echo "   deva.sh run codex -m gpt-5-codex         # Launch Codex agent"
echo ""
echo "4. Claude YOLO still supports Claude-specific flags:"
echo "   claude-yolo --auth-with bedrock          # Use AWS Bedrock"
echo "   claude-yolo --auth-with api-key          # Use API key (may have to rerun \`/login\`)"
echo "   claude-yolo --trace                      # Enable request tracing"
echo "   claude-yolo -v ~/.ssh:/home/deva/.ssh:ro # Mount SSH keys"
echo "   claude-yolo --continue/--resume          # Resume conversation"
echo "   claude.sh --help                         # Advanced options reference"
echo "   deva.sh shell codex                      # Enter the Codex container"
echo ""
echo -e "\033[93mWARNING: Never run --yolo in your home directory or system directories!\033[0m"
echo ""
