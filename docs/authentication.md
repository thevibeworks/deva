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

## Config Homes And Auth Isolation

Default homes live under:

```text
~/.config/deva/claude
~/.config/deva/codex
~/.config/deva/gemini
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
