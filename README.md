# deva.sh Multi-Agent Wrapper

> **REBRANDED**: Claude Code YOLO → **deva.sh Multi-Agent Wrapper**
> We've evolved from a Claude-specific wrapper into a unified development environment supporting Claude Code, OpenAI Codex, and future coding agents.

deva.sh launches Claude Code, Codex, and future coding agents inside a Docker container with **full control** over mounts, environments, and authentication contexts.

**Key Features**:
- **Advanced Directory Access**: Beyond Claude's `--add-dir` - mount any directories with precise permissions (`-v`)
- **Multiple Config Homes**: Isolated auth contexts with `--config-home` for different accounts/orgs
- **Multi-Auth Support**: OAuth, API keys, Bedrock, Vertex, Copilot - all in one wrapper
- **Safe Dangerous Mode**: Full permissions inside containers, zero host risk

**What Changed**: `claude.sh` → `deva.sh` as the primary interface. Your existing `claude-yolo` commands still work via compatibility shims.

## Quick Start

```bash
# install the CLI wrapper
curl -fsSL https://raw.githubusercontent.com/thevibeworks/claude-code-yolo/main/install.sh | bash

# run from a project directory
cd ~/wrk/my-project

deva.sh               # Claude by default

deva.sh codex -- --help   # Codex CLI passthrough
```

`claude-yolo` simply calls `deva.sh claude` for backwards compatibility.

> **Note**
> The older `claude.sh` / `claudeb.sh` wrappers are deprecated and now print a reminder before forwarding to `deva.sh`.

## Multi-Agent Capabilities

**Supported Agents**:
- **Claude Code** (`deva.sh claude`) - Anthropic's Claude with Code capabilities, auto-adds `--dangerously-skip-permissions`
- **OpenAI Codex** (`deva.sh codex`) - OpenAI's Codex CLI, auto-adds `--dangerously-bypass-approvals-and-sandbox`

**Agent-Specific Features**:
- **Claude**: OAuth/API key auth, mounts `~/.claude`, project-specific `.claude` configs
- **Codex**: OAuth protection (strips conflicting `OPENAI_*` env vars), exposes port 1455, mounts `~/.codex`

**Shared Infrastructure**:
- Project-scoped containers (`deva-<agent>-<project>-<pid>`)
- Unified config system (`.deva*` files)
- Container management (`--ps`, `--inspect`, `shell`)

## Safety Checklist

- Always `cd` into the project root before launching; deva.sh mounts the working directory recursively.
- Never aim `--config-home` at your real `$HOME`; use a dedicated auth directory.
- Use `deva.sh --ps` to confirm which containers are running before attaching.

## Advanced Directory Access (Beyond `--add-dir`)

**Claude's `--add-dir` vs deva.sh's Military-Grade Control**:

```bash
# Claude built-in: Dangerous direct filesystem access
claude --add-dir ~/projects/backend --add-dir ~/shared-libs
# ❌ Claude can read/write EVERYTHING in those directories
# ❌ No permission control
# ❌ Direct access to your real files
# ❌ Can accidentally modify/delete host files

# deva.sh: Fortress-level security with surgical precision
deva.sh claude \
  -v ~/projects/backend:/home/deva/backend:ro \      # READ-ONLY
  -v ~/shared-libs:/home/deva/libs:ro \              # READ-ONLY
  -v ~/api-keys:/home/deva/secrets:ro \              # READ-ONLY SECRETS
  -v /tmp/build-output:/home/deva/output:rw          # ONLY writable area
# ✅ Granular per-directory permissions
# ✅ Container isolation = zero host risk
# ✅ Secrets are read-only, impossible to leak
# ✅ Only designated output dir is writable
```

**Why deva.sh's Volume Mounting is Vastly More Secure & Controllable**:
- **Granular Permissions**: Per-directory read-only (`ro`) vs read-write (`rw`) vs no access
- **Complete Isolation**: Claude never touches your real filesystem - only container copies
- **Selective Exposure**: Choose exactly which files/dirs are visible, hide everything else
- **Path Remapping**: Control exactly where files appear in container (`/home/deva/project` vs `~/my-secret-project`)
- **Zero Host Risk**: Even with `--dangerously-skip-permissions`, your host filesystem is protected
- **Credential Sandboxing**: Mount secrets read-only, impossible for Claude to modify/leak them
- **Audit Trail**: Docker logs every file access, unlike native `--add-dir`
- **Performance**: Docker volume caching + no host filesystem traversal

**Real-World Security Scenarios**:
```bash
# MAXIMUM SECURITY: Code review with zero risk
deva.sh claude \
  -v ~/client-project:/home/deva/code:ro \          # REVIEW ONLY
  -v ~/api-keys:/home/deva/keys:ro \                # SECRETS READ-ONLY
  -v /tmp/review-output:/home/deva/output:rw        # SAFE OUTPUT AREA
# Claude can analyze code but CANNOT modify source or leak secrets

# SURGICAL ACCESS: Database migration with controlled risk
deva.sh claude \
  -v ~/migrations:/home/deva/migrations:ro \        # SCRIPTS READ-ONLY
  -v ~/.db-config:/home/deva/config:ro \            # CONFIG READ-ONLY
  -v /tmp/migration-logs:/home/deva/logs:rw         # LOGS ONLY
# Claude can read configs but CANNOT modify production scripts

# CREDENTIAL FORTRESS: API development with bulletproof secrets
deva.sh claude \
  -v ~/project/src:/home/deva/src:rw \              # CODE ACCESS
  -v ~/.aws:/home/deva/.aws:ro \                    # AWS CREDS READ-ONLY
  -v ~/api-keys:/home/deva/keys:ro \                # API KEYS READ-ONLY
  -v /tmp/build:/home/deva/build:rw                 # BUILD OUTPUT ONLY
# Impossible for Claude to accidentally commit secrets or modify credentials

# Compare with dangerous --add-dir approach:
# claude --add-dir ~/project --add-dir ~/.aws --add-dir ~/api-keys
# ❌ Claude has FULL WRITE ACCESS to ALL your secrets!
```

**XDG Config Home (Per-Agent)**:
```bash
$XDG_CONFIG_HOME defaults to ~/.config

# Default layout (each agent directory under ~/.config/deva mounts into /home/deva):

~/.config/deva/
├── claude/                  # Claude-only auth/config
│   ├── .claude/
│   ├── .claude.json
│   ├── .aws/                # optional: Bedrock creds
│   └── .config/gcloud/      # optional: Vertex AI creds
└── codex/                   # Codex-only auth/config
    └── .codex/              # contains auth.json

# Mount destinations inside container:
# - claude/*  → /home/deva/*
# - codex/*   → /home/deva/*

# Override per invocation
deva.sh claude -c ~/auth-homes/personal
deva.sh codex  -c ~/auth-homes/codex-prod -- -m gpt-5-codex
deva.sh claude -c ~/auth-homes/client-aws --auth-with bedrock
```

Notes:
- By default, we mount all agent homes found under `~/.config/deva/` so you can run multiple agents in the same container.
- If you pass `-c` to a directory that contains `claude/` and/or `codex/`, we treat it as a DEVA ROOT and mount all agent homes found there.
- If `-c` points to a leaf directory with dotfiles directly (e.g., only `.claude*`), we mount only that directory.

Migration from legacy dotfiles:
```bash
# 1) Create the new XDG tree
mkdir -p ~/.config/deva/{claude,codex}

# 2) Move Claude Code OAuth files
if [ -d ~/.claude ]; then mv ~/.claude ~/.config/deva/claude/.claude; fi
if [ -f ~/.claude.json ]; then mv ~/.claude.json ~/.config/deva/claude/.claude.json; fi

# 3) Move Codex OAuth directory
if [ -d ~/.codex ]; then mv ~/.codex ~/.config/deva/codex/.codex; fi

# 4) Optional: Bedrock / Vertex creds (choose one spot)
#    Either keep per-agent:
if [ -d ~/.aws ]; then cp -a ~/.aws ~/.config/deva/claude/.aws; fi
if [ -d ~/.config/gcloud ]; then mkdir -p ~/.config/deva/claude/.config && \
  cp -a ~/.config/gcloud ~/.config/deva/claude/.config/; fi

# 5) Verify
tree -a ~/.config/deva | sed -n '1,200p'

# Done. Now just run
deva.sh claude
deva.sh codex
```

**Symlink Setup**

Prefer links if you don’t want to move files. Docker resolves symlinks at start and binds the target.

```bash
# Link specific files/dirs into deva root
ln -s ~/.claude         ~/.config/deva/claude/.claude
ln -s ~/.claude.json    ~/.config/deva/claude/.claude.json
ln -s ~/.codex          ~/.config/deva/codex/.codex

# Or link whole agent directories (cleaner)
ln -s ~/auth-homes/claude ~/.config/deva/claude
ln -s ~/auth-homes/codex  ~/.config/deva/codex

# Verify symlinks resolve
ls -l ~/.config/deva/claude
readlink -f ~/.config/deva/claude/.claude
```

Notes:
- Use absolute paths for links. Relative is fine if it resolves correctly from the link’s parent.
- The symlink’s target must exist, or the container mount will fail.
- Changing the link after the container starts won’t retarget the running bind; restart to pick up changes.
- macOS: ensure the target paths are allowed under Docker Desktop File Sharing.

Auto-linking (default)
- On first run with the default XDG root (`~/.config/deva`) and no explicit `-c`, we auto-link legacy creds if the deva root is missing them:
  - `~/.claude` → `~/.config/deva/claude/.claude`
  - `~/.claude.json` → `~/.config/deva/claude/.claude.json`
  - `~/.codex` → `~/.config/deva/codex/.codex`
- Disable with any of:
  - CLI: `--no-autolink`
  - Config: add `AUTOLINK=false` to `.deva`
  - Env: `DEVA_NO_AUTOLINK=1` (export and run)

**Container Management**:
```bash
# List all running containers for this project
% deva.sh --ps
NAME                                  AGENT  STATUS         CREATED AT
deva-claude-my-project-12345          claude Up 2 minutes   2025-09-18 18:10:02 +0000 UTC
deva-codex-my-project-67890           codex  Up 5 minutes   2025-09-18 18:07:15 +0000 UTC

# Attach to any container (fzf picker if multiple)
deva.sh --inspect
deva.sh shell        # alias for --inspect

# Remove containers for current project (with confirmation)
deva.sh rm

# Remove ALL deva containers including stopped ones (with confirmation)
deva.sh clean
```

## Multi-Account Auth Architecture

**Config Home Structure** (`--config-home DIR` / `-c DIR`):

deva.sh mounts entire auth directories into `/home/deva`, enabling **isolated authentication contexts** for different accounts, organizations, or projects.

```bash
# Organize by account type
~/auth-homes/
├── personal/           # Personal accounts
│   ├── .claude/
│   ├── .claude.json
│   └── .config/gcloud/
├── work-corp/          # Corporate accounts
│   ├── .claude/        # Work Claude Pro
│   ├── .aws/           # AWS Bedrock access
│   └── .codex/         # OpenAI org license
└── client-proj/        # Client-specific
    ├── .claude/        # Client Claude account
    └── .aws/           # Client AWS Bedrock

# Use different auth contexts seamlessly
deva.sh claude -c ~/auth-homes/personal
deva.sh claude -c ~/auth-homes/work-corp --auth-with bedrock
deva.sh codex -c ~/auth-homes/work-corp
```

**Auth Protection**: When `.codex/auth.json` is mounted, deva.sh strips conflicting `OPENAI_*` env vars to ensure OAuth sessions aren't shadowed by stale API credentials.

## Container Management

- `deva.sh --ps` – list `deva-*` containers scoped to the current project (includes inferred agent column).
- `deva.sh --inspect` / `deva.sh shell` – attach to a running container (`fzf` picker if more than one, otherwise auto-attach).
- `deva.sh rm` – remove all containers (running and stopped) for the current project with confirmation prompt.
- `deva.sh clean` – remove ALL deva containers (including stopped) across all projects with confirmation prompt.

Container naming pattern: `deva-<agent>-<project>-<pid>`.

## Config Files

We load configuration in this order (later wins):

1. `$XDG_CONFIG_HOME/deva/.deva`
2. `$HOME/.deva`
3. `.deva`
4. `.deva.local`
5. Legacy `.claude-yolo*` files (still honoured for compatibility)

Example `.deva` file:

```bash
VOLUME=~/.ssh:/home/deva/.ssh:ro
VOLUME=~/.gitconfig:/home/deva/.gitconfig:ro
ENV=DEBUG=${DEBUG:-development}
ENV=GH_TOKEN
CONFIG_HOME=~/auth-homes/claude-max
DEFAULT_AGENT=claude
PROFILE=rust                  # pick a dev profile (same as -p rust)
HOST_NET=false
```

Supported keys: `VOLUME`, `ENV`, `CONFIG_HOME`, `DEFAULT_AGENT`, `HOST_NET`, plus any valid shell variable names you want exported.

## Flexible Authentication Matrix

**All Authentication Methods Supported**:

| Agent | Auth Method | Command Example | Auth Context |
|-------|-------------|-----------------|--------------|
| **Claude** | OAuth | `deva.sh claude -c ~/auth-homes/personal` | `.claude/`, `.claude.json` |
| **Claude** | API Key | `deva.sh claude --auth-with api-key` | `ANTHROPIC_API_KEY` |
| **Claude** | Bedrock | `deva.sh claude -c ~/auth-homes/aws --auth-with bedrock` | `.aws/` credentials |
| **Claude** | Vertex AI | `deva.sh claude -c ~/auth-homes/gcp --auth-with vertex` | `.config/gcloud/` |
| **Claude** | Copilot | `deva.sh claude --auth-with copilot` | GitHub token via copilot-api |
| **Claude** | OAuth Token | `deva.sh claude -- --auth-with oat -p "task"` | `CLAUDE_CODE_OAUTH_TOKEN` |
| **Codex** | OAuth | `deva.sh codex -c ~/auth-homes/openai` | `.codex/auth.json` |

**Multi-Org Support Examples**:
```bash
# Personal dev work
deva.sh claude -c ~/auth-homes/personal

# Corporate Bedrock account
deva.sh claude -c ~/auth-homes/corp-aws --auth-with bedrock

# Client project with their OpenAI license
deva.sh codex -c ~/auth-homes/client-openai

# Quick API key for testing
ANTHROPIC_API_KEY=sk-... deva.sh claude -- --auth-with api-key -p "test this"
```

## Image Contents

- Languages: Python 3.12, Node.js 22, Go 1.22, Rust.
- Tooling: git, gh, docker CLI, awscli, bun, uv, ripgrep, shellcheck, claude-trace, codex CLI, etc.
- User: non-root `deva` with host UID/GID mirroring.
- Networking: `localhost` → `host.docker.internal` rewrites for HTTP/HTTPS/gRPC.

## Developer Notes

```bash
make build           # build the deva image locally
make shell           # open an interactive shell inside the image
./deva.sh --help     # list all options
```

See `CHANGELOG.md` and `DEV-LOGS.md` in this directory for history and daily notes.

## Image Profiles and Local Dockerfiles

Select a development image profile (deva flags can appear before or after the agent):

```bash
# Use base image (default)
deva.sh claude

# Use rust toolchain image (tries pull, then local Dockerfile.rust if present)
deva.sh -p rust claude
deva.sh claude -p rust   # equivalent

# If the tag isn't available locally and pull fails, build it
make build-rust   # or: docker build -f Dockerfile.rust -t ghcr.io/thevibeworks/deva:rust .
```

Profiles map to images:
- base → `ghcr.io/thevibeworks/deva:latest`
- rust → `ghcr.io/thevibeworks/deva:rust` (falls back to local `Dockerfile.rust` when available)

You can also pin a custom image via env: `DEVA_DOCKER_IMAGE`, `DEVA_DOCKER_TAG`.
