# deva.sh

[![CI](https://img.shields.io/github/actions/workflow/status/thevibeworks/deva/ci.yml?branch=main&label=ci)](https://github.com/thevibeworks/deva/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-docs.deva.sh-111111)](https://docs.deva.sh)
[![Release](https://img.shields.io/github/v/release/thevibeworks/deva?sort=semver)](https://github.com/thevibeworks/deva/releases)
[![License](https://img.shields.io/github/license/thevibeworks/deva)](LICENSE)
[![Container](https://img.shields.io/badge/ghcr.io-thevibeworks%2Fdeva-blue)](https://github.com/thevibeworks/deva/pkgs/container/deva)
[![Agents](https://img.shields.io/badge/agents-codex%20%7C%20claude%20%7C%20gemini-222222)](#what-this-is)

Run Codex, Claude Code, and Gemini inside Docker without pretending the agent's own sandbox is the thing keeping you safe.

The container is the sandbox. Explicit mounts are the contract. Persistent project containers keep the workflow fast instead of rebuilding the same state every run.

This repo is the source of truth for `deva.sh`.

## What This Is

- a Docker-based launcher for Codex, Claude, and Gemini
- one warm default container shape per project by default
- explicit mount and env wiring instead of mystery behavior
- per-agent config homes under `~/.config/deva/`
- a shell script, not framework cosplay

Primary entry point:

- `deva.sh`

Compatibility wrappers still exist:

- `claude.sh`
- `claude-yolo`

## What This Is Not

- Not a real safety boundary if you mount `/var/run/docker.sock`. That is host-root with extra steps.
- Not a general-purpose devcontainer platform.
- Not magic. If you mount your whole home read-write and hand the agent dangerous permissions, the agent can touch your whole home. Amazing how that works.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/thevibeworks/deva/main/install.sh | bash

cd ~/work/my-project
deva.sh codex
```

Then inspect the container if you want:

```bash
deva.sh shell
deva.sh ps
deva.sh stop
```

If you already use Codex, Claude, or Gemini locally, deva will auto-link those auth homes into `~/.config/deva/` by default. If not, first run will ask you to authenticate inside the container.

## Docs

Start here if you want the short path:

- [Quick Start](docs/quick-start.md)
- [Authentication Guide](docs/authentication.md)
- [Troubleshooting](docs/troubleshooting.md)

Read these if you want to understand the machinery instead of cargo-culting commands:

- [How It Works](docs/how-it-works.md)
- [Philosophy](docs/philosophy.md)
- [Advanced Usage](docs/advanced-usage.md)
- [Docs Home](docs/index.md)

Project policy and OSS housekeeping:

- [Contributing](CONTRIBUTING.md)
- [Security Policy](SECURITY.md)
- [MIT License](LICENSE)
- [Live Docs](https://docs.deva.sh)

Examples:

- [Examples](examples/README.md)

Deep research note:

- [UID/GID Handling Research](docs/UID-GID-HANDLING-RESEARCH.md)

## How It Feels

```text
host workspace + auth home
          |
          v
       deva.sh
          |
          v
   docker run / docker exec
          |
          v
   persistent project container
     /home/deva + chosen agent
```

Default mode reuses one persistent container shape per project. Different mounts, explicit config homes, or auth modes split into separate containers. That keeps your packages, build cache, and scratch state warm without pretending every run is identical. `--rm` gives you a throwaway run when you actually want that.

## Common Commands

```bash
# Default agent is Claude
deva.sh

# Same container, different agents
deva.sh codex
deva.sh gemini

# Throwaway run
deva.sh claude --rm

# Inspect what deva would run
deva.sh claude --debug --dry-run

# Open a shell in the project container
deva.sh shell

# Read resolved config state
deva.sh --show-config
```

## Sharp Edges

- `--no-docker` exists for a reason. If you do not need Docker-in-Docker, do not mount the socket.
- `--host-net` gives the container broad network visibility. Use it when you mean it.
- `-Q` is the bare mode. It skips config loading, autolink, and host config mounts. Good for clean repros.
- `--config-home` is for isolated identities. Point it at a dedicated auth home, not your real `$HOME`.
- The debug `docker run` line is for inspection, not guaranteed copy-paste shell syntax.

## Why This Exists

Agent CLIs are useful. Their native permission theater is often not.

deva moves the line:

- give the agent broad power inside a container
- decide exactly what crosses the host boundary
- swap auth methods per project or per run
- reuse the same default container shape across agents when mounts, config, and auth line up

That is a better trade if you are working in a trusted repo and you actually want to get work done.

## Development

Basic checks:

```bash
./deva.sh --help
./deva.sh --version
./claude-yolo --help
./scripts/version-check.sh
```

If you changed auth, mounts, or container lifecycle, run the real path. Do not ship "should work".

## Images

Stable release tags:

- `ghcr.io/thevibeworks/deva:latest`
- `ghcr.io/thevibeworks/deva:rust`

Nightly refresh tags:

- `ghcr.io/thevibeworks/deva:nightly`
- `ghcr.io/thevibeworks/deva:nightly-rust`

## License

MIT. See [LICENSE](LICENSE).
