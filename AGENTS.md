This file provides guidance to coding agents working in this repository.

## What This Repo Is

`deva.sh` is a Docker-based multi-agent launcher for:

- OpenAI Codex
- Claude Code
- Google Gemini CLI

The container is the sandbox. Agent-level permission theater is not.

That is the core design. Do not "improve" it by moving trust back into
interactive prompt confirmations.

## Workflow Rules

We use issue-based development.

1. Before any Git or GitHub CLI command, read the matching file in
   `workflows/`:
   - `GITHUB-ISSUE.md`
   - `GIT-COMMIT.md`
   - `GITHUB-PR.md`
   - `RELEASE.md`
2. Keep one branch per issue when practical.
3. PRs should reference and close the relevant issue.

## Release Rules

Release workflow lives in `workflows/RELEASE.md`.

Current release source of truth:

- version comes from `deva.sh`
- changelog comes from `CHANGELOG.md`
- images are published by GitHub Actions

Do not use `claude.sh` as the version source. That is old baggage.

## Project Structure

```text
deva/
├── deva.sh
├── claude.sh
├── claude-yolo
├── agents/
├── Dockerfile
├── Dockerfile.rust
├── docker-entrypoint.sh
├── install.sh
├── .deva.example
├── examples/
├── docs/
├── .github/workflows/
├── workflows/
├── CHANGELOG.md
├── DEV-LOGS.md
└── AGENTS.md
```

Important current roles:

- `deva.sh`: primary entrypoint and container lifecycle manager
- `agents/*.sh`: agent-specific auth and command wiring
- `install.sh`: one-line installer
- `.github/workflows/ci.yml`: lint, docs, and smoke coverage
- `.github/workflows/release.yml`: tagged image + release flow
- `.github/workflows/nightly-images.yml`: scheduled nightly image refresh

Legacy compatibility wrappers still exist:

- `claude.sh`
- `claude-yolo`

They are compatibility shims, not primary branding.

## Security Model

Deva runs agent CLIs inside Docker and disables their built-in permission
prompts:

- Claude: `--dangerously-skip-permissions`
- Gemini: `--yolo`
- Codex: unrestricted mode equivalent

That is deliberate.

The security boundary is:

- the container
- the exact mounts and env vars we pass into it

So the real risks are the host bridges we expose:

- mounted workspace paths
- mounted auth files
- `/var/run/docker.sock`
- `--host-net`
- tmux bridge tooling

Do not document or implement this as if the agent sandbox is protecting the
host. It is not.

## Auth And Config Model

Deva supports multiple auth modes per agent.

Current design:

- default config root is `~/.config/deva`
- per-agent homes live under that root
- `--config-home` isolates auth state
- `-Q` means bare mode: no config loading, no autolink, no host auth mounts
- non-default auth overlays default credential paths instead of moving live
  host files around

If you touch auth code, verify real `--dry-run` output and one live path.
Auth bugs are usually mount bugs wearing a fake auth moustache.

## Container Model

Persistent containers are keyed by workspace plus container shape.

Shape includes things like:

- selected agent
- extra volumes
- explicit config home
- auth mode

So it is not "one container per repo" in the naive sense. Different shapes
must not collide.

For clean repros and CI smoke tests, use:

```bash
deva.sh claude -Q -- --version
deva.sh codex -Q -- --version
deva.sh gemini -Q -- --version
```

Non-interactive launch paths must work without a TTY.

## Common Checks

Run these before claiming things work:

```bash
./deva.sh --help
./deva.sh --version
./claude-yolo --help
./scripts/version-check.sh
```

If you changed container launch, mounts, auth, or the installer, also run:

```bash
./deva.sh claude --debug --dry-run
./deva.sh claude -Q -- --version
./deva.sh codex -Q -- --version
./deva.sh gemini -Q -- --version
```

If you changed docs site plumbing, also run:

```bash
mkdocs build --strict
```

## Bridges

Bridges are deliberate holes from container back to host.

Current ones:

- Docker socket mount
- tmux bridge

Treat bridge changes as security-sensitive. They change the real trust
boundary, not some fake marketing boundary.

## Documentation Rules

Public copy should say `deva.sh` first.

Allowed:

- mention `claude.sh` / `claude-yolo` as compatibility wrappers
- historical notes in changelog/dev logs

Not allowed:

- presenting the project as Claude-only
- using `claude.sh` as the primary interface in current docs
- leaving stale release or workflow prompts centered on old naming

## Issue Hygiene

Do not use the issue queue as a mirror of every upstream vendor changelog.

If upstream version tracking is automated, close the old noise and keep the
real issue queue for:

- bugs in deva
- missing features in deva
- docs gaps in deva
- concrete release/process work in deva
