#!/bin/bash
set -euo pipefail

: "${DEVA_HOME:?DEVA_HOME is required}"
: "${CLAUDE_CODE_VERSION:?CLAUDE_CODE_VERSION is required}"
: "${CODEX_VERSION:?CODEX_VERSION is required}"
: "${GEMINI_CLI_VERSION:?GEMINI_CLI_VERSION is required}"

ATLAS_CLI_VERSION="${ATLAS_CLI_VERSION:-v0.1.4}"

npm config set prefix "$DEVA_HOME/.npm-global"
npm install -g --no-audit --no-fund \
    "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    @mariozechner/claude-trace \
    "@openai/codex@${CODEX_VERSION}" \
    "@google/gemini-cli@${GEMINI_CLI_VERSION}"
npm cache clean --force

"$DEVA_HOME/.npm-global/bin/claude" --version
"$DEVA_HOME/.npm-global/bin/codex" --version
"$DEVA_HOME/.npm-global/bin/gemini" --version
"$DEVA_HOME/.npm-global/bin/claude-trace" --help >/dev/null
(npm list -g --depth=0 @anthropic-ai/claude-code @openai/codex @google/gemini-cli || true)

cd "$DEVA_HOME"
curl -fsSL "https://raw.githubusercontent.com/lroolle/atlas-cli/${ATLAS_CLI_VERSION}/install.sh" \
    | bash -s -- --skill-dir "$DEVA_HOME/.skills"
