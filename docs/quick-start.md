# Quick Start

This is the shortest path from zero to a working `deva.sh` container.

## Prerequisites

You need:

- Docker
- a project directory you trust
- one agent auth path that actually works

If your plan is "mount my whole laptop and see what happens", that is not a prerequisite. That is a mistake.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/thevibeworks/deva/main/install.sh | bash
```

That installs:

- `deva.sh`
- `claude.sh` (legacy compatibility wrapper)
- `claude-yolo` (legacy compatibility wrapper)
- `agents/claude.sh`
- `agents/codex.sh`
- `agents/gemini.sh`
- `agents/shared_auth.sh`

It also pulls `ghcr.io/thevibeworks/deva:latest`, with Docker Hub as fallback.

## First Run

```bash
cd ~/work/my-project
deva.sh codex
```

By default, deva:

- mounts the current project at the same absolute path inside the container
- creates or reuses one persistent container for that project
- uses the per-agent config home under `~/.config/deva/`
- auto-links legacy local auth homes into that config root unless you disable autolink

If you already have local agent auth, first run is usually boring. Good. Boring is the point.

## First Useful Commands

```bash
# See the container for this project
deva.sh ps

# Open a shell inside it
deva.sh shell

# Show the resolved wrapper config
deva.sh --show-config

# Show the docker command without running it
deva.sh claude --debug --dry-run

# Stop or remove the project container
deva.sh stop
deva.sh rm
```

## Use Another Agent

Same project, same default container shape:

```bash
deva.sh claude
deva.sh gemini
```

That is one of the main reasons this wrapper exists. You do not need a separate pet workflow for every vendor.

If you change mounts, explicit config-home, or auth mode, deva will split into a different persistent container shape instead of pretending those runs are equivalent.

## Quick Auth Examples

Codex with OpenAI API key:

```bash
export OPENAI_API_KEY=sk-...
deva.sh codex --auth-with api-key
```

Claude with a direct Anthropic-style key or token:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
deva.sh claude --auth-with api-key
```

Claude with a custom endpoint:

```bash
export ANTHROPIC_BASE_URL=https://example.net/api
export ANTHROPIC_AUTH_TOKEN=token
deva.sh claude --auth-with api-key
```

Gemini with API key:

```bash
export GEMINI_API_KEY=...
deva.sh gemini --auth-with api-key
```

More auth details live in [Authentication Guide](authentication.md).

## Useful Modes

Throwaway container:

```bash
deva.sh claude --rm
```

Bare mode with no config loading or host auth mounts:

```bash
deva.sh claude -Q
```

Isolated auth home:

```bash
deva.sh claude -c ~/auth-homes/work
```

## If Something Looks Wrong

Use these before you start editing code out of frustration:

```bash
deva.sh --show-config
deva.sh claude --debug --dry-run
deva.sh shell
```

Then read [Troubleshooting](troubleshooting.md).
