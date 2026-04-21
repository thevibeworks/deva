# How It Works

This is the real startup model. No mythology.

## Short Version

`deva.sh` does five things:

1. resolves wrapper config and agent choice
2. resolves the config home and auth mode
3. builds the Docker mount and env list
4. creates or reuses a project-scoped container
5. `docker exec`s the selected agent inside that container

That is it.

## Startup Flow

### 1. Deva parses wrapper args and agent args separately

Wrapper flags include things like:

- `--rm`
- `-v`
- `-e`
- `-c`, `--config-home`
- `-p`, `--profile`
- `-Q`, `--quick`
- `--host-net`
- `--no-docker`
- `--debug`, `--dry-run`

Everything after `--` goes to the agent unchanged.

### 2. Deva loads config files

Config files load in this order:

1. `$XDG_CONFIG_HOME/deva/.deva`
2. `$HOME/.deva`
3. `./.deva`
4. `./.deva.local`

Supported directives are simple:

- `VOLUME=host:container[:mode]`
- `ENV=NAME=value`
- `AUTH_METHOD=...`
- `PROFILE=...`
- `EPHEMERAL=...`

See [`.deva.example`](https://github.com/thevibeworks/deva/blob/main/.deva.example).

### 3. Deva resolves the config home

Default per-agent homes live under:

```text
~/.config/deva/
├── claude/
├── codex/
└── gemini/
```

`--config-home` supports two layouts:

- leaf home: `DIR/.claude`, `DIR/.claude.json`, `DIR/.codex`, `DIR/.gemini`
- deva root: `DIR/claude`, `DIR/codex`, `DIR/gemini`

`-Q` disables config-home resolution, autolink, and host config mounts entirely.

### 4. Deva resolves auth

Each agent owns its auth modes. The wrapper does not fake a universal auth abstraction because those usually turn into garbage.

Examples:

- Claude default: `.claude` and `.claude.json`
- Claude API-style auth: env vars such as `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, or `CLAUDE_CODE_OAUTH_TOKEN`
- Codex default: `.codex/auth.json`
- Gemini default: `.gemini`

When non-default auth is active, deva mounts a blank overlay over the default credential file path so the agent cannot silently fall back to some unrelated OAuth state. That is the point of the overlay fix.

If `--auth-with /path/to/file.json` is used, that explicit file is mounted directly over the agent's default credential path.

### 5. Deva builds Docker args

The wrapper always mounts:

- the current workspace at the same absolute path
- the current workspace as container working directory
- UID/GID, timezone, locale, and a few useful host envs

It may also mount:

- additional user volumes from `-v` or `.deva`
- config-home contents into `/home/deva`
- `~/.config/deva` and `~/.cache/deva` when using the default config root
- `/var/run/docker.sock` if present and not disabled

Loose credential files, backup files, `.DS_Store`, and VCS junk are intentionally skipped during config-home fan-out.

Deva also rejects redundant recursive bind mounts before startup, so a child path
cannot be rebound over the exact same subtree already covered by a parent mount.

### 6. Deva creates or reuses a container

Persistent is default:

- one default container shape per project
- reused across runs
- same workspace can run Claude, Codex, and Gemini in the same container when mounts, config, and auth line up
- different volumes, explicit config homes, or auth modes create separate persistent containers

Ephemeral with `--rm`:

- new container every time
- removed after exit
- useful for clean repros or one-shot tasks

Container names include the workspace slug and may also include hashes for:

- extra volumes
- explicit config-home
- auth mode

That prevents collisions between materially different container shapes.

### 7. Deva execs the agent

For persistent mode, the runtime shape is:

1. `docker run -d ... tail -f /dev/null`
2. `docker exec -it ... /usr/local/bin/docker-entrypoint.sh <agent>`

For ephemeral mode, it runs the agent directly in `docker run`.

## Agent Defaults

- Claude: injects `--dangerously-skip-permissions` unless you already supplied it
- Codex: injects `--dangerously-bypass-approvals-and-sandbox` and defaults model to `gpt-5-codex`
- Gemini: injects `--yolo`

This is not subtle. The container is the trust boundary, so the agent's internal approval system is intentionally bypassed.

## Proxy and Network Behavior

- `HTTP_PROXY` and `HTTPS_PROXY` are passed through
- `localhost` in those proxy URLs is translated to `host.docker.internal`
- `--host-net` opts into host networking
- `--no-docker` disables Docker socket auto-mount

If you mount the Docker socket, stop pretending the container is isolated from the host.

## Debugging the Runtime Shape

Use:

```bash
deva.sh --show-config
deva.sh claude --debug --dry-run
deva.sh shell
```

`--dry-run` shows the container shape without starting the container. That is good for checking env and mount wiring. It is not a proof that the agent can actually authenticate or complete a request.
