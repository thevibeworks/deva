# Authentication Guide

Auth is where wrappers usually become untrustworthy.

This guide documents what `deva.sh` actually supports, what env vars it reads, and how credential files are mounted.

## Rules First

- Every agent has its own default auth home.
- `--auth-with <method>` selects a non-default auth path.
- `--auth-with <file.json>` is treated as an explicit credential file mount.
- Non-default auth masks the agent's default credential file with a blank overlay unless the explicit credential file already occupies that path.
- `--dry-run` is useful for mount and env inspection. It does not prove the credentials work.
- Copilot `--dry-run` no longer starts the local proxy; it only shows the planned wiring.

## Auth Matrix

| Agent | Default auth | Other methods | Main inputs |
| --- | --- | --- | --- |
| Claude | `claude` | `api-key`, `oat`, `bedrock`, `vertex`, `copilot`, credentials file | `.claude`, `.claude.json`, `ANTHROPIC_*`, `CLAUDE_CODE_OAUTH_TOKEN`, `AWS_*`, gcloud, `GH_TOKEN` |
| Codex | `chatgpt` | `api-key`, `copilot`, credentials file | `.codex/auth.json`, `OPENAI_API_KEY`, `GH_TOKEN` |
| Gemini | `oauth` | `api-key`, `gemini-api-key`, `vertex`, `compute-adc`, `gemini-app-oauth`, credentials file | `.gemini`, `GEMINI_API_KEY`, gcloud, service-account JSON |
| Grok | `oauth` | `api-key` | `.grok/auth.json`, `XAI_API_KEY` |
| Kimi | `oauth` | `api-key` | `.kimi-code` (device-code), `KIMI_CODE_API_KEY` -> `KIMI_MODEL_*` |
| opencode | `oauth` | `api-key` | `.local/share/opencode/auth.json` (device-code), `OPENCODE_API_KEY` |
| pi | `oauth` | `api-key` | `.pi/agent/auth.json` (in-app `/login`), provider env keys (`ANTHROPIC_API_KEY`, ...) |
| dsh | `credentials` | `api-key` | `.dsh/.credentials.yaml`, `DEEPSEEK_API_KEY` |
| cursor | `oauth` | `api-key` | `.config/cursor/auth.json` (in-container login), `CURSOR_API_KEY` |

## Claude

### Default: `--auth-with claude`

Default Claude auth uses:

- `/home/deva/.claude`
- `/home/deva/.claude.json`

By default those come from the selected config home.

Example:

```bash
deva.sh claude
deva.sh claude -c ~/auth-homes/work
```

### `--auth-with api-key`

This name is a little muddy because Claude supports more than one token shape here.

Accepted host inputs:

- `ANTHROPIC_API_KEY`
- `ANTHROPIC_AUTH_TOKEN`
- `CLAUDE_CODE_OAUTH_TOKEN`

Optional endpoint override:

- `ANTHROPIC_BASE_URL`

Examples:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
deva.sh claude --auth-with api-key
```

```bash
export ANTHROPIC_BASE_URL=https://example.net/api
export ANTHROPIC_AUTH_TOKEN=token
deva.sh claude --auth-with api-key
```

If `ANTHROPIC_API_KEY` looks like a Claude OAuth token (`sk-ant-oat01-...`), deva auto-routes it as `CLAUDE_CODE_OAUTH_TOKEN`.

### `--auth-with oat`

Requires:

- `CLAUDE_CODE_OAUTH_TOKEN`

Optional:

- `ANTHROPIC_BASE_URL`

Example:

```bash
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
deva.sh claude --auth-with oat
```

### `--auth-with bedrock`

Uses AWS credentials from:

- `~/.aws`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`
- `AWS_REGION`

It also sets `CLAUDE_CODE_USE_BEDROCK=1`.

Example:

```bash
export AWS_REGION=us-west-2
deva.sh claude --auth-with bedrock
```

### `--auth-with vertex`

Uses Google credentials from:

- `~/.config/gcloud`
- `GOOGLE_APPLICATION_CREDENTIALS` when set to a host file path

It also sets `CLAUDE_CODE_USE_VERTEX=1`.

Example:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=$HOME/keys/work-sa.json
deva.sh claude --auth-with vertex
```

### `--auth-with copilot`

Requires either:

- saved `copilot-api` token
- `GH_TOKEN`
- `GITHUB_TOKEN`

Deva starts the local `copilot-api` proxy, points Claude at the Anthropic-compatible endpoint, and injects dummy API key values where the CLI expects them.

Example:

```bash
export GH_TOKEN="$(gh auth token)"
deva.sh claude --auth-with copilot
```

### `--auth-with /path/to/file.json`

Custom credential files are mounted directly to:

```text
/home/deva/.claude/.credentials.json
```

Example:

```bash
deva.sh claude --auth-with ~/work/claude-prod.credentials.json
```

#### Bare names: the credentials store

A bare `*.json` name (no slash) resolves against the agent config home
(`~/.config/deva/claude/` by default) — a named credentials store:

```bash
deva.sh claude --auth-with claude-max.credentials.json
# -> ~/.config/deva/claude/claude-max.credentials.json
```

Resolution order: current directory first (compat), then the store.
With an explicit `--config-home` root, the store is `<root>/<agent>/`.
A missing bare name provisions into the store.

#### Provisioning new credentials

If the file does not exist, deva offers to create it via TUI login:

```bash
deva claude -Q --rm --auth-with ~/creds/xxx-claude-max.credentials.json -- --resume
# -> "Credentials file not found: .../xxx-claude-max.credentials.json"
# -> "Create it via TUI login? [y/N]"
# Log in via /login in the TUI, then exit when done.
# -> "Credentials captured: .../xxx-claude-max.credentials.json"
# -> "  subscription: max, expires in ~365d"
# -> "Reuse: deva claude --auth-with .../xxx-claude-max.credentials.json"
```

Use `-Q` (bare mode) to avoid polluting your default config home with the
new account's identity. The placeholder file is removed automatically if
no credentials are captured.

## Codex

### Default: `--auth-with chatgpt`

Uses:

- `/home/deva/.codex/auth.json`

Usually from the selected config home.

### `--auth-with api-key`

Requires:

- `OPENAI_API_KEY`

Example:

```bash
export OPENAI_API_KEY=sk-...
deva.sh codex --auth-with api-key
```

### `--auth-with copilot`

Requires either:

- saved `copilot-api` token
- `GH_TOKEN`
- `GITHUB_TOKEN`

Deva points Codex at the OpenAI-compatible side of the proxy and defaults the model to `gpt-5-codex` unless you supplied one.

Example:

```bash
export GH_TOKEN="$(gh auth token)"
deva.sh codex --auth-with copilot
```

### `--auth-with /path/to/file.json`

Custom credential files are mounted to:

```text
/home/deva/.codex/auth.json
```

Example:

```bash
deva.sh codex --auth-with ~/work/codex-auth.json
```

## Gemini

### Default: `--auth-with oauth`

Uses:

- `/home/deva/.gemini`

`gemini-app-oauth` is treated as the same app-style OAuth family.

### `--auth-with api-key` or `gemini-api-key`

Requires:

- `GEMINI_API_KEY`

When this mode is active and not running under `--dry-run`, deva makes sure the Gemini settings file in the chosen config home selects API-key auth. Gemini state can include both `.gemini/` content and a top-level `settings.json`, depending on what the CLI has already written there.

Example:

```bash
export GEMINI_API_KEY=...
deva.sh gemini --auth-with api-key
```

### `--auth-with vertex`

Uses:

- `~/.config/gcloud`
- `GOOGLE_APPLICATION_CREDENTIALS`
- `GOOGLE_CLOUD_PROJECT`
- `GOOGLE_CLOUD_LOCATION`

Example:

```bash
export GOOGLE_CLOUD_PROJECT=my-project
export GOOGLE_CLOUD_LOCATION=us-central1
deva.sh gemini --auth-with vertex
```

### `--auth-with compute-adc`

Uses Google Compute Engine application default credentials from the metadata server. That is mostly for workloads already running on GCP.

### `--auth-with /path/to/file.json`

Custom service-account files are mounted to:

```text
/home/deva/.config/gcloud/service-account-key.json
```

And `GOOGLE_APPLICATION_CREDENTIALS` is set to that container path.

Example:

```bash
deva.sh gemini --auth-with ~/keys/gcp-service-account.json
```

## Grok

### Default: `--auth-with oauth`

Uses:

- `/home/deva/.grok`

Grok stores its session token in `.grok/auth.json`. First login opens a
browser, which does not exist inside the container. Two ways in:

- authenticate on the host once; deva auto-links `~/.grok` and the mount
  carries `auth.json` into the container
- run `grok login --device-auth` inside the container: it prints a URL and
  code you complete on any device

### `--auth-with api-key`

Requires:

- `XAI_API_KEY` (from [console.x.ai](https://console.x.ai))

Grok's credential priority puts mounted config above the environment:
`model.api_key` > `model.env_key` > session token > `XAI_API_KEY`. So in
this mode deva mounts no `~/.grok` at all — the exported key is the only
credential in the container, and it is what gets billed. Session state
lives container-local and does not persist across runs in this mode.

If you force a `~/.grok` mount with `-v` anyway, deva still blank-overlays
the default `auth.json`, but per-model keys in a mounted `config.toml`
outrank `XAI_API_KEY` — don't mix the two.

Example:

```bash
export XAI_API_KEY=...
deva.sh grok --auth-with api-key
```

### One more grok-specific wire

Grok keeps its real binary in `~/.grok/bin/` (its self-update dir) and the
npm launcher resolves that path first. Inside the image, deva moves the
binary to `~/.local/bin/grok` and removes `~/.grok/bin`, so a host-mounted
`~/.grok` (which may contain a macOS binary) never shadows it.

The reverse direction is guarded too: grok's self-updater writes into
`~/.grok/bin/` and `~/.grok/downloads/`. A mounted `config.toml` without
the npm installer marker makes the updater treat the install as
self-managed, so `grok update` would drop Linux binaries into the host
mount — breaking a macOS host CLI via its npm launcher. Whenever a host
dir is mounted at `/home/deva/.grok`, deva overlays those two paths with
container-local tmpfs: in-container `grok update` works, its writes die
with the container, and the host install stays intact. The image pin
(`GROK_CLI_VERSION`) is the only version that matters.

## Kimi

### Default: `--auth-with oauth`

Mounts:

- `/home/deva/.kimi-code`

Kimi Code stores config, sessions, and its OAuth token under `~/.kimi-code`
(overridable via `KIMI_CODE_HOME`). First login has no browser, so run
the device-code flow inside the container:

- run `kimi` then `/login` (or `kimi login`): it prints a URL + code; open
  it on any device to authorize, and
- authenticate on the host once; deva auto-links `~/.kimi-code` and the
  mount carries the token in.

### `--auth-with api-key`

Inputs:

- `KIMI_CODE_API_KEY` (from [platform.kimi.com](https://platform.kimi.com));
  `KIMI_API_KEY` is accepted as a fallback when `KIMI_CODE_API_KEY` is unset

Kimi is the odd one out: it reads **no** API key from the shell environment.
Its docs are explicit — `export KIMI_API_KEY=...` gives no provider its key;
credentials come only from `~/.kimi-code/config.toml`. The single exception
is the `KIMI_MODEL_*` family, which reads the shell and synthesizes an
in-memory provider. So deva maps your `KIMI_CODE_API_KEY` onto that channel:

```text
KIMI_MODEL_NAME=k3                                # DEVA_KIMI_MODEL to override
KIMI_MODEL_API_KEY=$KIMI_CODE_API_KEY
KIMI_MODEL_PROVIDER_TYPE=kimi
KIMI_MODEL_BASE_URL=https://api.kimi.com/coding/v1  # DEVA_KIMI_BASE_URL to override
```

The key is never written to `config.toml` (it lives in memory), so this mode
mounts no `~/.kimi-code` and nothing lands on disk. `sk-kim…` keys hit the
Kimi Code coding endpoint above; for a direct Moonshot key
(`platform.moonshot.ai`) set `DEVA_KIMI_BASE_URL=https://api.moonshot.ai/v1`.

```bash
export KIMI_CODE_API_KEY=...
deva.sh kimi --auth-with api-key
# pick a different model:
DEVA_KIMI_MODEL=kimi-for-coding deva.sh kimi --auth-with api-key
```

Unlike grok, kimi's npm bin is a plain symlink to `dist/main.mjs` (no
self-update trampoline, no platform binary), so there is no host-mount
shadowing to guard against. The image pin (`KIMI_CODE_VERSION`) is the only
version that matters.

## opencode

### Default: `--auth-with oauth`

Mounts (opencode is XDG-native — three dirs instead of one dot-dir):

- `/home/deva/.config/opencode` (config, plugins)
- `/home/deva/.local/share/opencode` (auth.json, session db, logs)
- `/home/deva/.local/state/opencode` (model prefs, prompt history)

`~/.cache/opencode` stays container-local on purpose: it only holds the
models.json cache and the self-updater's bin dir, and the image pins the
CLI version (`OPENCODE_DISABLE_AUTOUPDATE=1` is set in the container).

First login has no browser, so use the device-code flow inside the
container: run `opencode auth login` (or `/connect` in the TUI), open the
printed URL on any device. Or authenticate on the host once; deva
auto-links the three XDG dirs and the mount carries `auth.json` in.

opencode's permission model already allows everything inside the workspace;
deva additionally unlocks the interactive asks (outside-workspace access,
doom-loop guard, `.env` reads) via `OPENCODE_PERMISSION` — the container is
the sandbox.

### `--auth-with api-key`

Inputs:

- `OPENCODE_API_KEY` (service-account key from [console.opencode.ai](https://console.opencode.ai))

The key travels as env only and authenticates the opencode gateway
provider. This mode mounts none of the XDG dirs: a mounted `auth.json`
outranks the env key and could silently bill another account (same
no-mount contract as grok/kimi api-key). A blank overlay hides `auth.json`
even if a user `-v` carries a data dir in.

```bash
export OPENCODE_API_KEY=sk-...
deva.sh opencode --auth-with api-key
```

BYO provider keys (Anthropic, OpenAI, OpenRouter, ...) are opencode config,
not deva auth methods — wire them with `-e` / `.deva` `ENV=` entries and
opencode's own `opencode.jsonc`.

## pi

### Default: `--auth-with oauth`

Mounts `~/.pi` — everything pi persists lives under `.pi/agent/`
(auth.json, sessions, settings, trust.json; no XDG dirs). The mount stays
writable on purpose: pi's OAuth tokens auto-refresh and it rewrites
`auth.json` in place.

First login has no browser: run `/login` inside the TUI. Claude Pro/Max
and ChatGPT logins print a URL you open on any device and paste the
redirect back; GitHub Copilot and xAI use device-code flows. Or log in on
the host once; autolink carries `~/.pi` in.

pi has no permission system at all — its own security doc says to run it
in a contained environment, which is exactly what deva does. The only
interactive gate is project trust (loading workspace `.pi/` settings and
extensions); deva passes `--approve` so unattended runs never stall.
`PI_SKIP_VERSION_CHECK=1` is set because the image pins the CLI
(`PI_CODING_AGENT_VERSION`).

### `--auth-with api-key`

Inputs (at least one; all set keys travel — pi is multi-provider):

- `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `XAI_API_KEY`, `OPENROUTER_API_KEY`

The keys travel as env only. This mode mounts nothing: pi's `auth.json`
OUTRANKS env keys, so a mounted `~/.pi` could silently bill another
account (same no-mount contract as grok/kimi/opencode api-key). A blank
overlay hides `auth.json` even if a user `-v` carries a dir in. The
container name is tagged from the first set key in the order above.

```bash
export ANTHROPIC_API_KEY=sk-ant-...
deva.sh pi --auth-with api-key -- --provider anthropic
```

Provider/model selection (`--provider`, `--model`) is pi's own CLI
surface — pass it after `--`.

## dsh

Every `deva.sh dsh` run ensures the web service in its container
(`dsh web`, the official recommendation; bare `dsh` refuses to start
without a profile): if nothing listens on the container's 3080, the
web profile is daemonized (log: `$DSH_HOME/web.log`) and survives the
launch session ending — re-entering a running container never
double-binds. Bare `deva.sh dsh` then follows the service log; args
after `--` run that dsh invocation in the foreground with the service
ensured behind it:

```bash
deva.sh dsh                                  # ensure web UI, follow its log
deva.sh dsh -- --profile headless "run the tests"
deva.sh dsh -- --profile tui
```

dsh serves loopback only and hard-rejects `0.0.0.0`, which docker `-p`
cannot reach — so deva daemonizes a socat sidecar in the container
bridging a publishable port to the loopback bind, published to the
host loopback. Each container gets the first free host port from 3080
(`DEVA_DSH_WEB_PORT` overrides the probe start), so concurrent dsh
containers land on 3080, 3081, ... The mapping is fixed at container
create and travels as container env, so a reused container announces
the port it actually published, not a fresh probe (containers created
before this feature have no publish — recreate them for host access).
Under `--host-net` there is no sidecar and no publish — the container
loopback is the host loopback — but every host-net dsh container
shares that one loopback, so deva probes a free port per container
(first free from 3080) and pins it into the container env. The ensure
check verifies the server is OUR container's process, not just an open
port: another container's server answering our port is reported, never
adopted (its UI serves that container's mounts, not ours). The `/api`
trust fence accepts loopback Hosts, so no `--trusted-host` wiring is
needed. `DEVA_DSH_WEB=0` skips the service entirely.

Caveat: dsh containers sharing one auth home share one
`storages/` (registry, session index). dsh tolerates but does not
coordinate concurrent writers — a live server in another container may
overwrite registry entries seeded after it booted; relaunching re-adds
them. Use `--config-home` for fully isolated dsh state.

Every run (web, tui, headless) also registers the workspace dir in
dsh's workspace registry (`$DSH_HOME/storages/workspace.json`) — the
dir you pointed deva at is the workspace by definition (git repo or
not); other cwds qualify only with a `.git` entry. Sessions from any
profile land pre-grouped in the web UI, and skips log their reason to
the launch output. The seed follows the durable
domain schema exactly, is idempotent per canonical path, and backs off
from state it does not own (foreign schema version, pending mutation,
an uninitialized registry with session history — dsh's own bootstrap
runs first, the seed retries next launch). `DEVA_DSH_WORKSPACE_AUTO=0`
disables it.

### Default: `--auth-with credentials`

Mounts `~/.dsh` (`$DSH_HOME`; deva pins it to `/home/deva/.dsh` because
dsh is a developer preview and defaults can move). Everything dsh
persists lives there: `.credentials.yaml`, `settings.yaml`, `profiles/`
(including container-built pnpm trees — the mount stays writable),
`skills/`, `attachments/`.

There is no login flow — either let dsh prompt for and store the key on
first run, or drop it into `.credentials.yaml` yourself.

dsh's own sandbox/approval subsystem defaults to workspace-write + ask;
deva sets `DSH_PERMISSION_MODE=danger-full-access` so unattended runs
never stall — the container is the sandbox. That env is the only switch
(no CLI flag), and dsh scrubs `DSH_*` from project-discovered env
(`.env`, `BASH_ENV`), so only the injected process env counts.

Skills interop: dsh reads Anthropic SKILL.md-compatible skills from
`~/.agents/skills` and `<project>/.agents/skills` — the same dirs deva
already wires for claude. One skills dir serves both agents in the same
container.

### `--auth-with api-key`

Input (required): `DEEPSEEK_API_KEY`

The key travels as env only; this mode mounts nothing. dsh resolves
inherited env BEFORE `.credentials.yaml`, so the injected key always
decides billing — and for the same reason a host `DEEPSEEK_API_KEY` is
scrubbed from credentials-mode runs, where it would silently outrank the
mounted credentials. No blank overlay is needed (reverse of pi).

```bash
export DEEPSEEK_API_KEY=sk-...
deva.sh dsh --auth-with api-key
```

Held back on purpose: dsh's plugin/marketplace surface is in flux
(developer preview; the manifest format already broke pre-launch), so
deva wires the TUI + skills dirs only.

## Cursor

### Default: `--auth-with oauth`

Cursor state lives in the per-agent config home only
(`~/.config/deva/cursor`): two canonical entries, `.cursor` (cli-config,
per-project chats) and `.config/cursor` (auth.json — the CLI's Linux
file store keeps auth there even when config lands in `.cursor`).

Unlike every other agent there is NO host-dir autolink and no legacy
`~/.cursor` fallback mount: host `~/.cursor` is the Cursor IDE's state
dir (worktrees, per-project chats), not a CLI-only home, and macOS keeps
CLI auth in the keychain — there is nothing portable to carry in.

First login happens in the container: run `cursor-agent login` — deva
sets `NO_OPEN_BROWSER=1` so the URL prints instead of trying to open a
browser; open it anywhere, and auth.json persists in the mounted config
home.

YOLO is `--force` ("Run Everything"; `--yolo` is Cursor's own alias).
The image pins the CLI (`CURSOR_CLI_VERSION`, fetched straight from the
deterministic tarball URL — the installer script has no pin hook) and
strips the write bit from the CLI's versions dir, which starves the
silent startup self-update.

### `--auth-with api-key`

Input (required): `CURSOR_API_KEY`

The key travels as env only; this mode mounts nothing, and a blank
overlay hides `auth.json` even if a user `-v` carries a config dir in.

```bash
export CURSOR_API_KEY=key_...
deva.sh cursor --auth-with api-key -- -p "fix CI"
```

Headless mode (`-p/--print`, `--output-format json|stream-json`) is
Cursor's own CLI surface — pass it after `--`.

## Config Homes And Auth Isolation

Default homes live under:

```text
~/.config/deva/claude
~/.config/deva/codex
~/.config/deva/gemini
~/.config/deva/grok
~/.config/deva/kimi
~/.config/deva/opencode
~/.config/deva/pi
~/.config/deva/dsh
~/.config/deva/cursor
```

Use `--config-home` when you want a separate identity:

```bash
deva.sh claude -c ~/auth-homes/work
deva.sh codex -c ~/auth-homes/personal
```

Good reasons to split auth homes:

- work vs personal accounts
- OAuth vs API-key experiments
- different org endpoints
- reproducing auth bugs without contaminating your default state

## Testing Auth

Three layers, cheapest first. Run them in order — most auth bugs die
before a container ever starts.

### 1. Wiring tests (no Docker, no credentials)

Hermetic per-agent tests run `deva.sh` with a scratch `HOME` and
`DEVA_NO_DOCKER=1`, then assert the planned mounts and env for each
`--auth-with` mode:

```bash
bash scripts/test-kimi-auth.sh
bash scripts/test-opencode-auth.sh
bash scripts/test-pi-auth.sh
bash scripts/test-dsh-auth.sh
bash scripts/test-cursor-auth.sh
```

They prove deva wires the right thing (mount present in credentials
mode, key redacted and no mount in api-key mode, blank overlay when
non-default auth is active). They never touch your real
`~/.config/deva` or credentials.

### 2. Dry-run against your real auth (no container)

```bash
deva.sh dsh --debug --dry-run
deva.sh dsh --auth-with api-key --debug --dry-run
```

Same checklist as Debugging Auth below: auth label, env vars, mounts,
overlay. Still proves nothing about whether the token works.

### 3. Live smoke (spends tokens)

Launch the agent and run one trivial prompt. What "authed" requires
per agent, default mode:

| Agent | Auth lives in | First-run step |
|-------|---------------|----------------|
| Claude | `~/.claude` + `~/.claude.json` | `/login` in TUI |
| Codex | `~/.codex/auth.json` | `codex login` device flow |
| Gemini | `~/.gemini` | browser OAuth |
| Grok | `~/.grok/auth.json` | in-app login |
| Kimi | `~/.kimi-code` | device-code flow |
| opencode | `~/.local/share/opencode/auth.json` | device-code flow |
| pi | `~/.pi/agent/auth.json` | `/login` in TUI |
| dsh | `~/.dsh/.credentials.yaml` | no login flow — dsh prompts for the key on first run, or write the file yourself |
| cursor | config home `.config/cursor/auth.json` | `cursor-agent login` inside the container (deva prints the URL) |

Login-in-container flows persist because the auth home is mounted —
the second run is authed without repeating the step.

To smoke-test without touching your default identity, point the run
at a throwaway config home:

```bash
deva.sh dsh -c "$(mktemp -d)"
```

api-key modes need no first-run step at all — export the key
(`DEEPSEEK_API_KEY`, `CURSOR_API_KEY`, provider keys for pi, ...) and
run with `--auth-with api-key`. See each agent's section above for
which env var decides billing.

## Debugging Auth

Useful commands:

```bash
deva.sh --show-config
deva.sh claude --auth-with api-key --debug --dry-run
deva.sh shell
```

What to check in `--dry-run`:

- the chosen auth label
- expected env vars are present
- unexpected auth env vars are absent
- the explicit credential file mount points at the right container path
- the blank overlay exists when non-default auth is active

What `--dry-run` cannot tell you:

- whether the remote endpoint accepts the token
- whether the agent CLI likes that token shape
- whether your cloud credentials are actually authorized
