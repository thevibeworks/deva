# tmux in deva: directions, transports, layers

deva treats tmux interaction as three directions with different trust
shapes. Only one of them crosses the sandbox boundary, and that one is
opt-in.

    Direction           tool             sandbox
    ---------           ----             -------
    host -> container   deva.sh shell    intact — default, recommended
                        (docker exec)    host reaches in, container gains nothing
    agent <-> agent     tmux-bridge      intact — panes inside one server
    container -> host   deva-tmux        OPT-IN (--host-tmux) — container can
                                         run commands on the host

Two layers compose on top of that:

    Layer 1  deva-tmux        transport: gets the container a connection
             (in the image)   to the host tmux server (ssh or socat)

    Layer 2  tmux-bridge      semantics: read/type/keys/label/envelope
             (in the image)   for agents to drive each other's panes

Layer 2 does not care which transport carried the socket. Both transports
land the host server on the same path: `/tmp/host-tmux.sock`.

## Transports

`deva-tmux` speaks two transports and picks automatically (ssh first):

| | ssh (default) | socat (fallback) |
|---|---|---|
| Auth | your ssh key, mounted read-only | **none — any local process connects** |
| Survives host reboot | yes (sshd is launchd-managed) | no (daemon must be restarted) |
| tmux protocol coupling | none for ls/attach/tmux (host client runs) | container client must match host server |
| Host prerequisite | Remote Login enabled + `deva.sh tmux setup` | `deva.sh tmux host-daemon start` |

Force one with `DEVA_TMUX_TRANSPORT=ssh|socat`. The socat transport prints
a loud warning every time — it exists for hosts that cannot enable sshd,
not as a peer of the ssh path.

## Quick start: container -> host

Host side, once:

    deva.sh tmux setup             # authorize your ssh key (prints undo)

Launch with provisioning (this is the opt-in):

    deva.sh --host-tmux claude

Inside the container:

    deva-tmux doctor               # layer-by-layer check of both transports
    deva-tmux ls                   # host sessions (host-side tmux client)
    deva-tmux attach [session]     # interactive attach over ssh
    deva-tmux tmux kill-session -t foo    # host tmux passthrough

Or land the host server on a local socket for native tools and Layer 2:

    deva-tmux bridge start         # /tmp/host-tmux.sock (0600)
    tmux -S /tmp/host-tmux.sock attach
    TMUX_BRIDGE_SOCKET=/tmp/host-tmux.sock tmux-bridge list
    deva-tmux bridge stop

Without `--host-tmux`, `deva-tmux` is inert: the ssh backend has no key to
use and the socat backend has no daemon to reach. That is the point.

## Quick start: agent <-> agent

Inside any tmux server (a container session, or a bridged host server):

    tmux-bridge list                      # see all panes
    tmux-bridge name %1 planner           # label a pane
    tmux-bridge read planner 50           # read last 50 lines
    tmux-bridge message planner "found 3 issues in auth.py"
    tmux-bridge type planner "rerun tests"
    tmux-bridge keys planner Enter

## Security

Container -> host is a privileged direction: whoever holds it can
send-keys, run-shell, and read scrollback on your host tmux server. deva's
posture:

- Off by default. `--host-tmux` is the only thing that provisions it, and
  it mounts your `~/.ssh` read-only — no key ever gets written from inside
  a container. Key authorization happens on the host (`deva.sh tmux
  setup`), where writing your own `authorized_keys` is a normal operation
  instead of a sandbox escape.
- The ssh transport is authenticated and scoped to key holders. The socat
  transport is not: the host daemon exposes tmux over TCP with no auth,
  which is why it is the fallback, warns on every start, and binds
  127.0.0.1 unless you explicitly widen it.
- A container holding the docker socket already has an equivalent write
  path to the host; `--host-tmux` does not mount it and `deva-tmux`
  refuses to use it.

## Socket detection (Layer 2)

`tmux-bridge` auto-detects the tmux server socket in this order:

1. `$TMUX_BRIDGE_SOCKET` env var (explicit override)
2. `$TMUX` (set automatically when you are inside a tmux pane)
3. Scan `/tmp/tmux-<uid>/*` for a server that owns `$TMUX_PANE`
4. Default tmux server

For a bridged host server, set the override:

    export TMUX_BRIDGE_SOCKET=/tmp/host-tmux.sock

## Read-before-act guard (Layer 2)

`tmux-bridge` enforces that agents `read` a pane before they can `type`,
`message`, or `keys` into it. This is the main safety net against "agent
blindly hallucinates into the wrong pane."

The guard is a sentinel at `/tmp/tmux-bridge-read-<pane_id>`. Reading sets
it; any write clears it. So the contract is:

1. `tmux-bridge read <target>` — look at the pane's current state
2. `tmux-bridge type <target> "..."` — act on what you saw
3. To act again, read again.

## Diagnostics

    deva-tmux doctor        # container side: both transports, bridge, Layer 2
    deva.sh tmux doctor     # host side: key, sshd, daemon, sessions
    tmux-bridge doctor      # Layer 2: socket detection, pane visibility

Run the one closest to where things are failing.

## Compatibility

- `deva-bridge-tmux` still works: it is now a shim for
  `deva-tmux bridge start --transport socat --foreground`, preserving the
  old flags and foreground semantics.
- `deva-bridge-tmux-host` is unchanged and managed by
  `deva.sh tmux host-daemon start|stop|status`.
- `DEVA_BRIDGE_HOST/PORT/SOCK` are still honored; new knobs live under
  `DEVA_TMUX_*`.

## Provenance

`scripts/tmux-bridge` is vendored byte-for-byte from upstream smux
(github.com/ShawnPana/smux). See `scripts/tmux-bridge.VENDORED` for the
pinned commit and SHA256. License is MIT, reproduced in
`scripts/THIRD_PARTY_LICENSES/smux-LICENSE`. Improvements we want (e.g. a
TTL on the read guard) go upstream, not into a local fork.

`scripts/deva-tmux`, `scripts/deva-bridge-tmux`, and
`scripts/deva-bridge-tmux-host` are deva's own work (see
`docs/devlog/20260108-deva-bridge-tmux.org` and issue #412 for the design
history, including the ssh transport from #405/#406).
