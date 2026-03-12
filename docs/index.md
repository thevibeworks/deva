# deva.sh

Run Codex, Claude Code, and Gemini inside Docker without pretending the
agent's own sandbox is the thing keeping you safe.

The container is the sandbox. Explicit mounts are the contract.
Persistent project containers keep the workflow fast instead of
rebuilding the same state every run.

## Start Here

- [Live docs site](https://docs.deva.sh)
- [Quick Start](quick-start.md)
- [Authentication Guide](authentication.md)
- [Troubleshooting](troubleshooting.md)

If you want the internals instead of vague hand-waving:

- [How It Works](how-it-works.md)
- [Philosophy](philosophy.md)
- [Advanced Usage](advanced-usage.md)
- [Custom Images](custom-images.md)

## What This Is

- a Docker-based launcher for Codex, Claude, and Gemini
- one warm default container shape per project by default
- explicit mount and env wiring instead of mystery behavior
- per-agent config homes under `~/.config/deva/`
- a shell script, not framework cosplay

## What This Is Not

- Not a real safety boundary if you mount `/var/run/docker.sock`.
- Not a general-purpose devcontainer platform.
- Not magic. If you mount your whole home read-write and hand the agent
  dangerous permissions, the agent can touch your whole home.

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

## Sharp Edges

- `--no-docker` exists for a reason. If you do not need Docker-in-Docker,
  do not mount the socket.
- `--host-net` gives the container broad network visibility.
- `-Q` skips config loading, autolink, and host config mounts.
- `--config-home` is for isolated identities, not your real home.
- The debug `docker run` line is diagnostic output, not guaranteed
  copy-paste shell syntax.

## Repo And Policy

- [Repository](https://github.com/thevibeworks/deva)
- [Contributing](https://github.com/thevibeworks/deva/blob/main/CONTRIBUTING.md)
- [Security Policy](https://github.com/thevibeworks/deva/blob/main/SECURITY.md)
- [MIT License](https://github.com/thevibeworks/deva/blob/main/LICENSE)

## Images

- Stable: `ghcr.io/thevibeworks/deva:latest`, `ghcr.io/thevibeworks/deva:rust`
- Nightly: `ghcr.io/thevibeworks/deva:nightly`, `ghcr.io/thevibeworks/deva:nightly-rust`
