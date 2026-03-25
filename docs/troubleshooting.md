# Troubleshooting

The goal here is to stop guessing.

## First Three Commands

Run these before you change code, files, or your worldview:

```bash
deva.sh --show-config
deva.sh claude --debug --dry-run
deva.sh shell
```

Those tell you:

- what config was loaded
- what Docker shape deva is building
- what the live container actually sees

## Docker Is Not Running

Symptom:

- container creation fails immediately

Check:

```bash
docker ps
```

Fix:

- start Docker
- confirm your user can talk to the Docker daemon

This one is not mysterious.

## Wrong Mount Paths After The `/root` -> `/home/deva` Move

Symptom:

- files you expected are missing in the container

Bad:

```bash
-v ~/.ssh:/root/.ssh:ro
```

Good:

```bash
-v ~/.ssh:/home/deva/.ssh:ro
```

Deva warns about `/root/*` mounts, but warnings are easy to ignore when people get overconfident.

## Auth Looks Wrong

Symptom:

- wrong account
- wrong endpoint
- auth falls back to some old session

Check:

```bash
deva.sh claude --auth-with api-key --debug --dry-run
```

Look for:

- expected auth env vars present
- unexpected auth env vars absent
- correct credential file mount
- blank overlay on the default credential file when using non-default auth

If the dry-run shape is correct but the agent still cannot authenticate, the wrapper may be fine and the real problem is the token, endpoint, or upstream CLI behavior.

## Config Home Is Empty

Symptom:

- first run warns that `.claude`, `.codex`, or `.gemini` is empty

Meaning:

- you pointed `--config-home` at a new directory, which is fine
- you now need to authenticate into that isolated home

That is not an error. That is exactly what isolated config homes are for.

## Proxy Weirdness

Deva rewrites `localhost` in `HTTP_PROXY` and `HTTPS_PROXY` to `host.docker.internal` for the container path.

If the agent cannot reach a local proxy:

- check the proxy actually listens on the host
- inspect the translated value in `--dry-run`
- check `NO_PROXY`

For Copilot proxy mode, deva also adds `NO_PROXY` and `no_grpc_proxy` entries for the local proxy hostnames.

## Claude `--chrome` Still Cannot See The Extension

Symptom:

- Claude reports Chrome mode enabled
- extension status still says not detected

What deva now does for `deva.sh claude -- --chrome`:

- mounts either:
  - one configured Chrome profile `Extensions/` dir read-only at `/home/deva/.config/google-chrome/Profile N/Extensions`, or
  - every detected `Default`/`Profile *` `Extensions/` dir under a configured user-data root
- mounts the host Chrome bridge dir at `/deva-host-chrome-bridge`
- inside the patched container entrypoint, creates the socket Claude expects:
  - `<container tmpdir>/claude-mcp-browser-bridge-deva`
  - symlinked to `/deva-host-chrome-bridge`

Check:

```bash
deva.sh claude --debug --dry-run -- --chrome
deva.sh shell
```

Look for:

- `.../Profile 6/Extensions:/home/deva/.config/google-chrome/Profile 6/Extensions:ro`
- or `.../Default/Extensions:/home/deva/.config/google-chrome/Default/Extensions:ro`
- `/deva-host-chrome-bridge`
- inside the container: `ls -l "$(node -p 'require(\"os\").tmpdir()')"/claude-mcp-browser-bridge-deva`

If your extension lives in a non-default Chrome profile, tell deva where it is. Put this in `.deva.local`:

```text
DEVA_CHROME_PROFILE_PATH=/actual/path/to/Profile 6
```

If the source directory is not literally named `Profile 6`, also set:

```text
DEVA_CHROME_PROFILE_NAME=Profile 6
```

If you prefer pointing deva at the browser user-data root instead:

```text
DEVA_CHROME_USER_DATA_DIR=/actual/path/to/Chrome
```

If deva guessed the wrong host bridge directory, override it explicitly:

```text
DEVA_HOST_CHROME_BRIDGE_DIR=/actual/path/to/claude-mcp-browser-bridge-$USER
```

Reality check:

- deva does not install the host native messaging manifest for you
- Chrome on the host still needs a working host-side `claude --chrome-native-host` setup
- if the host socket file is absent, the extension may be installed but not yet connected
- the published image still needs to be rebuilt with the patched `docker-entrypoint.sh`; otherwise the socket symlink is never created

## Dry-Run Looks Fine But Runtime Fails

That is normal in at least three cases:

- bad token
- wrong remote permissions
- agent CLI rejects the auth type at runtime

`--dry-run` validates assembly, not end-to-end auth success.

It also does not start the container. For Copilot mode it now skips starting the local proxy as well, so the output stays a planning tool instead of mutating local state.

Use a real smoke test:

```bash
deva.sh claude --auth-with api-key -- -p "reply with ok"
```

## Too Much State, Need A Clean Repro

Use bare mode:

```bash
deva.sh claude -Q
```

Or remove the project container:

```bash
deva.sh rm
```

If the problem disappears in `-Q`, your usual config or mounts are part of the issue.

## Container Reuse Confuses You

Persistent is the default. That means the next run may attach to an existing container.

Check:

```bash
deva.sh ps
deva.sh status
```

If you want a throwaway run:

```bash
deva.sh claude --rm
```

## Still Stuck

Collect something useful before filing an issue:

- `deva.sh --show-config`
- `deva.sh <agent> --debug --dry-run`
- exact auth mode
- exact config-home path
- whether `docker.sock` or `--host-net` was enabled

Then open the issue without hand-wavy descriptions like "auth broken somehow". That phrase helps nobody.
