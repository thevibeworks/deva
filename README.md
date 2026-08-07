English | [简体中文](README.zh-CN.md)

<img src="docs/assets/deva-hero.svg" alt="deva.sh" width="640">

[![CI](https://img.shields.io/github/actions/workflow/status/thevibeworks/deva/ci.yml?branch=main&label=ci)](https://github.com/thevibeworks/deva/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/thevibeworks/deva?sort=semver)](https://github.com/thevibeworks/deva/releases)
[![Docs](https://img.shields.io/badge/docs-docs.deva.sh-111111)](https://docs.deva.sh)
[![License](https://img.shields.io/github/license/thevibeworks/deva)](LICENSE)

Run Claude Code, Codex, Gemini, Grok, Kimi, and opencode inside Docker without pretending the agents' own permission prompts are the thing keeping you safe.

The container is the sandbox, mounts are the contract. What that buys you:

- Full-speed agents. Permission prompts exist because the blast radius is your host. Make the blast radius a container and YOLO stops being reckless — all six agents run with their permission systems off (`claude --dangerously-skip-permissions`, `codex --dangerously-bypass-approvals-and-sandbox`, `gemini --yolo`, `grok --always-approve`, `kimi --yolo`, opencode via `OPENCODE_PERMISSION` allow-all). Worst case dies with the container.
- The vendor's code never sees your host. Agent CLIs are fast-moving npm trees with auto-updaters. Here they are born inside the image: no `~/.ssh`, no `~/.aws`, no shell env soup, no browser profiles. Nothing to harvest.
- Everything that crosses the boundary is explicit. Files: mounts. Secrets: the env you pass. Network: the posture you pick — default bridge, your proxy, `--host-net`, or nothing. If you didn't wire it, the agent doesn't have it.
- Identity is a launch flag, not a global singleton. Per-agent config homes under `~/.config/deva/`, `--auth-with` / `--config-home` for the second account or API-key billing. Switch accounts per run; project, sessions, and container state stay put.
- Official CLIs, stock. No protocol shims, no knockoff clients, no proxy MITM on your credentials. The compatibility layer is the container, not a translation layer — the best model always comes with its own best harness.
- Feels like the naked CLI. Same cwd, same TTY, same OAuth flow. One warm container per project keeps packages and build caches hot. It's a bash script, not a framework.

## Quick Start

60 seconds:

```bash
curl -fsSL https://raw.githubusercontent.com/thevibeworks/deva/main/install.sh | bash

cd ~/work/my-project
deva.sh codex
```

If you already use these agents locally, deva auto-links their auth homes into per-agent config homes under `~/.config/deva/` by default. If not, first run asks you to authenticate inside the container.

## Common Commands

```bash
deva.sh                  # default agent is Claude
deva.sh codex            # same container, different agent
deva.sh gemini
deva.sh grok
deva.sh kimi
deva.sh opencode

deva.sh claude --rm      # throwaway container
deva.sh claude --debug --dry-run   # inspect the docker run before trusting it
deva.sh shell            # shell into the project container
deva.sh ps               # list containers
deva.sh stop             # stop it
deva.sh --show-config    # read resolved config
```

## What This Is Not

- Not safety magic. Mounting `/var/run/docker.sock` is host root with extra steps — deva will tell you so. If you don't need Docker-in-Docker, use `--no-docker`.
- Mount your whole home read-write and hand the agent dangerous permissions, and the agent can touch your whole home. Amazing how that works.
- `--host-net` gives the container broad network visibility. Use it when you mean it.
- Not a general-purpose devcontainer platform.

The full security boundary is in [SECURITY.md](SECURITY.md).

## Images

Stable:

- `ghcr.io/thevibeworks/deva:latest`
- `ghcr.io/thevibeworks/deva:rust`
- `ghcr.io/thevibeworks/deva:cloak` (CloakBrowser stealth Chromium, headed; `deva.sh -p cloak`)

Nightly refresh: `ghcr.io/thevibeworks/deva:nightly`, `ghcr.io/thevibeworks/deva:nightly-rust`

## Docs

Everything lives at [docs.deva.sh](https://docs.deva.sh): quick start, authentication, how it works, advanced usage, troubleshooting, philosophy.

AI agents / LLMs: read [llms.txt](llms.txt) — the whole product in one fetch.

## License

MIT. See [LICENSE](LICENSE).
