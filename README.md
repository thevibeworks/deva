# deva

[![CI](https://img.shields.io/github/actions/workflow/status/thevibeworks/deva/ci.yml?branch=main&label=ci)](https://github.com/thevibeworks/deva/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/thevibeworks/deva?sort=semver)](https://github.com/thevibeworks/deva/releases)
[![License](https://img.shields.io/github/license/thevibeworks/deva)](LICENSE)
[![Container](https://img.shields.io/badge/ghcr.io-thevibeworks%2Fdeva-blue)](https://github.com/thevibeworks/deva/pkgs/container/deva)

Run Claude Code, Codex, and Gemini inside Docker.

The container is the sandbox. That is the whole trick.

## What This Is

`deva.sh` launches coding agents inside a reusable Docker container with:

- explicit volume mounts instead of blind filesystem access
- isolated auth homes with `--config-home`
- persistent per-project containers by default
- support for Claude, Codex, and Gemini in the same wrapper

Legacy commands still exist:

- `deva.sh` is the real entry point
- `claude.sh` and `claude-yolo` are compatibility wrappers

## What This Is Not

- Not a security boundary if you mount `/var/run/docker.sock`. That is root-equivalent on the host.
- Not safe for random untrusted repos just because it says "Docker".
- Not a PaaS, orchestrator, or generic devcontainer manager.

If you point this thing at your real home directory and hand it dangerous permissions, you did not discover a clever workflow. You discovered a foot-gun.

## Why This Exists

Claude Code, Codex, and friends are useful. Their native local security prompts are also annoying in trusted workspaces.

`deva` moves the risk boundary:

- agent gets broad power inside the container
- you decide exactly what is mounted from the host
- auth can be swapped per project or per org
- one warm container can serve multiple agents

That is a better trade when you actually know what you are doing.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/thevibeworks/deva/main/install.sh | bash

cd ~/work/my-project
deva.sh claude
```

A few more sane first commands:

```bash
deva.sh codex -- --help
deva.sh gemini -- --help
deva.sh shell
deva.sh --ps
```

## Install

Requirements:

- Docker
- a supported agent auth method
- a trusted workspace

The installer drops these into your PATH:

- `deva.sh`
- `claude.sh`
- `claude-yolo`
- `agents/claude.sh`
- `agents/codex.sh`
- `agents/gemini.sh`
- `agents/shared_auth.sh`

If Docker pull from GHCR fails, the installer falls back to Docker Hub.

## Common Commands

```bash
# Claude in the persistent project container
deva.sh claude

# One-shot run, auto-remove container
deva.sh claude --rm

# Add a read-only mount
deva.sh claude -v ~/.ssh:/home/deva/.ssh:ro

# Use a separate auth home
deva.sh claude -c ~/auth-homes/work

# Claude with API or token-based auth
deva.sh claude --auth-with api-key -- -p "say hi"

# Claude with Bedrock
deva.sh claude -c ~/auth-homes/aws --auth-with bedrock

# Codex with explicit model
deva.sh codex -- -m gpt-5-codex

# Gemini in the same project container
deva.sh gemini
```

## Auth Modes

| Agent | Default auth | Other auth modes |
| --- | --- | --- |
| Claude | `claude` | `api-key`, `oat`, `bedrock`, `vertex`, `copilot`, credentials file path |
| Codex | `chatgpt` | `api-key`, `copilot`, credentials file path |
| Gemini | `oauth` | `api-key`, `gemini-api-key`, `vertex`, `compute-adc`, credentials file path |

Examples:

```bash
# Claude OAuth from config home
deva.sh claude -c ~/auth-homes/personal

# Claude via custom HTTP endpoint + token
export ANTHROPIC_BASE_URL=https://example.net/api
export ANTHROPIC_AUTH_TOKEN=token
deva.sh claude --auth-with api-key

# Codex via OpenAI API key
export OPENAI_API_KEY=sk-...
deva.sh codex --auth-with api-key

# Gemini via service account file
deva.sh gemini --auth-with ~/keys/gcp-service-account.json
```

## Config Homes

By default, deva uses per-agent homes under `~/.config/deva/`.

```text
~/.config/deva/
├── claude/
│   ├── .claude/
│   ├── .claude.json
│   ├── .aws/              # optional
│   └── .config/gcloud/    # optional
├── codex/
│   └── .codex/
└── gemini/
    └── .gemini/
```

`--config-home DIR` supports two layouts:

- leaf home: `DIR` contains `.claude`, `.claude.json`, `.aws`, `.config`, and so on
- deva root: `DIR` contains `claude/`, `codex/`, `gemini/`

Default runs also auto-link legacy auth dirs into `~/.config/deva/` unless you disable that with `--no-autolink`, `AUTOLINK=false`, or `DEVA_NO_AUTOLINK=1`.

## Container Model

Persistent is the default.

- one container per project
- reused across runs
- faster warm starts
- one workspace can host Claude, Codex, and Gemini together

Ephemeral mode:

- `--rm` creates a throwaway container
- `-Q` is the bare mode: no config loading, no autolink, no host config mounts

Useful management commands:

```bash
deva.sh --ps
deva.sh shell
deva.sh stop
deva.sh rm
deva.sh clean
```

## Profiles

Profiles choose the image tag:

- `base` -> `ghcr.io/thevibeworks/deva:latest`
- `rust` -> `ghcr.io/thevibeworks/deva:rust`

Examples:

```bash
deva.sh claude -p rust
make build
make build-rust
```

## Security Model

Be honest about the sharp edges:

- mounting `docker.sock` is host root by another name
- `--host-net` gives broad network visibility
- `--dangerously-skip-permissions` is still dangerous; Docker just changes where the blast radius lands
- `--config-home` should point to a dedicated auth home, not your real `$HOME`

If you need locked-down review mode, use explicit read-only mounts:

```bash
deva.sh claude \
  -v ~/src/project:/home/deva/project:ro \
  -v ~/.ssh:/home/deva/.ssh:ro \
  -v /tmp/deva-out:/home/deva/out
```

Security policy lives in [SECURITY.md](SECURITY.md).

## Repo Layout

```text
deva.sh              main launcher
agents/              agent-specific auth and command wiring
Dockerfile*          container images
workflows/           issue, commit, PR, release conventions
.github/workflows/   CI and release automation
scripts/             release and helper scripts
```

## Development

Local sanity checks:

```bash
./deva.sh --help
./deva.sh --version
./claude-yolo --help
./scripts/version-check.sh
shellcheck deva.sh agents/*.sh docker-entrypoint.sh install.sh scripts/*.sh
```

Contributing guide: [CONTRIBUTING.md](CONTRIBUTING.md)

Changelog: [CHANGELOG.md](CHANGELOG.md)

Dev notes: [DEV-LOGS.md](DEV-LOGS.md)

## License

MIT. See [LICENSE](LICENSE).
