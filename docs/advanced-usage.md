# Advanced Usage

This is where the sharp tools live.

## Use `.deva` Instead Of Giant Commands

If you keep typing the same mounts and env vars, stop doing that.

Put them in `.deva`:

```text
VOLUME=$HOME/.ssh:/home/deva/.ssh:ro
VOLUME=$HOME/.config/git:/home/deva/.config/git:ro
ENV=EDITOR=nvim
PROFILE=rust
```

Local override that should not be committed:

```text
# .deva.local
ENV=GH_TOKEN=${GH_TOKEN}
```

Load order is:

1. `$XDG_CONFIG_HOME/deva/.deva`
2. `$HOME/.deva`
3. `./.deva`
4. `./.deva.local`

See [`.deva.example`](https://github.com/thevibeworks/deva/blob/main/.deva.example).

## Separate Identities With `--config-home`

This is the clean way to keep work and personal auth apart.

Leaf layout:

```bash
deva.sh claude -c ~/auth-homes/work
```

Deva-root layout:

```text
~/auth-roots/team-a/
├── claude/
├── codex/
└── gemini/
```

```bash
deva.sh claude -c ~/auth-roots/team-a
deva.sh codex -c ~/auth-roots/team-a
```

If you pass an explicit config home, deva does not also mount your default `~/.config/deva`. That is deliberate isolation.

## Bare Mode With `-Q`

`-Q` is the clean-room mode:

- implies `--rm`
- no `.deva` loading
- no autolink
- no config-home mounts

Use it when you need a repro that is not contaminated by your local habits.

```bash
deva.sh claude -Q
deva.sh claude -Q -v "$PWD:/workspace" -- -p "summarize this repo"
```

`-Q` and `--config-home` are mutually exclusive. They solve opposite problems.

## Read-Only Review Mode

If you want the agent to inspect more than it edits, mount most of the world read-only and give it one scratch path.

```bash
deva.sh claude \
  -v "$PWD:/workspace:ro" \
  -v "$HOME/.ssh:/home/deva/.ssh:ro" \
  -v /tmp/deva-out:/home/deva/out
```

That is still not "safe" in some absolute sense. It is just a saner blast radius than handing over your laptop.

## Profiles

Supported profiles:

- `base` -> `ghcr.io/thevibeworks/deva:latest`
- `rust` -> `ghcr.io/thevibeworks/deva:rust`

Use them like this:

```bash
deva.sh claude -p rust
deva.sh codex -p rust
```

If the image tag is missing locally, deva pulls it. If that fails and a matching Dockerfile exists, it points you at the build command.

## Multi-Agent Workflow

One default container shape can serve all supported agents in the same project:

```bash
deva.sh claude
deva.sh codex
deva.sh gemini
```

That keeps package installs, build output, and scratch files hot between agents.

If you change volumes, config-home, or auth mode, deva intentionally uses a different persistent container instead of reusing one with the wrong mounts or env.

## Container Management

Current project:

```bash
deva.sh ps
deva.sh status
deva.sh shell
deva.sh stop
deva.sh rm
deva.sh clean
```

All projects:

```bash
deva.sh ps -g
deva.sh shell -g
deva.sh stop -g
```

## Debugging

These are the three commands that matter:

```bash
deva.sh --show-config
deva.sh claude --debug --dry-run
deva.sh shell
```

Use them in that order:

1. inspect config resolution
2. inspect Docker shape
3. inspect the live container

The printed `docker run` line is diagnostic output. It masks secrets and may contain unquoted values. Read it. Do not blindly paste it back into a shell and then complain when your shell parses spaces like spaces.

## Risk Knobs

### Docker Socket

Default behavior auto-mounts `/var/run/docker.sock` when it exists.

That means the container can control Docker on the host. Translation: host-root in practice.

Disable it:

```bash
deva.sh claude --no-docker
```

Or:

```bash
export DEVA_NO_DOCKER=1
```

### Host Networking

Use only when you need direct host networking behavior:

```bash
deva.sh claude --host-net
```

Again, this is not a subtle switch. It broadens what the container can see.

## Custom Auth Files

If you have a separate JSON credential file, pass the file itself:

```bash
deva.sh claude --auth-with ~/work/claude-prod.credentials.json
deva.sh codex --auth-with ~/work/codex-auth.json
deva.sh gemini --auth-with ~/keys/gcp-service-account.json
```

Deva mounts the file onto the agent's expected credential path. It does not need to dump a directory full of backup junk into the container to make that work.
