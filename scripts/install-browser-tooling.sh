#!/bin/bash
set -euo pipefail

: "${DEVA_HOME:?DEVA_HOME is required}"
: "${PLAYWRIGHT_VERSION:?PLAYWRIGHT_VERSION is required}"
: "${PLAYWRIGHT_MCP_VERSION:?PLAYWRIGHT_MCP_VERSION is required}"
: "${PLAYWRIGHT_BROWSERS_PATH:?PLAYWRIGHT_BROWSERS_PATH is required}"

npm config set prefix "$DEVA_HOME/.npm-global"
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"

npm install -g --no-audit --no-fund \
    "playwright@${PLAYWRIGHT_VERSION}" \
    "@playwright/mcp@${PLAYWRIGHT_MCP_VERSION}"

"$DEVA_HOME/.npm-global/bin/playwright" install --with-deps chromium firefox webkit
"$DEVA_HOME/.npm-global/bin/playwright" --version
"$DEVA_HOME/.npm-global/bin/playwright-mcp" --help >/dev/null

npm cache clean --force
