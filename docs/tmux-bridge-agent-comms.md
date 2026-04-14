# tmux-bridge: agent-to-agent comms in deva containers

deva ships two tmux bridge layers. They compose.

    Layer 1  deva-bridge-tmux       kernel boundary
             (scripts/deva-bridge-tmux)   container tmux client -> host tmux server
             socat TCP tunnel             via host.docker.internal:41555

    Layer 2  tmux-bridge             semantic CLI
             (scripts/tmux-bridge)         read/type/keys/label/envelope
             vendored from smux           for agents to drive each other's panes

Layer 1 is the plumbing that lets the container see host tmux at all. Layer 2
is what agents actually call.

## Security

Both layers are privileged host bridges. If you run them, the container can
execute arbitrary commands on the host tmux server (send-keys, run-shell,
scrollback). This is deliberate for trusted dev workflows. Do not enable on
untrusted code.

## Quick start

Host (macOS):

    deva-bridge-tmux-host                 # expose host tmux over TCP:41555

Container (inside a deva agent):

    deva-bridge-tmux                      # start socat; creates /tmp/host-tmux.sock
    tmux -S /tmp/host-tmux.sock attach    # optional: attach to host session

From another pane (or the same container, any agent CLI that can shell out):

    tmux-bridge list                      # see all panes
    tmux-bridge name %1 planner           # label a pane
    tmux-bridge read planner 50           # read last 50 lines
    tmux-bridge message planner "found 3 issues in auth.py"
    tmux-bridge type planner "rerun tests"
    tmux-bridge keys planner Enter

## Socket detection

`tmux-bridge` auto-detects the tmux server socket in this order:

1. `$TMUX_BRIDGE_SOCKET` env var (explicit override)
2. `$TMUX` (set automatically when you are inside a tmux pane)
3. Scan `/tmp/tmux-<uid>/*` for a server that owns `$TMUX_PANE`
4. Default tmux server

For deva containers talking to host tmux via the layer-1 bridge, attach to
tmux first (step 2 fires) or set the override:

    export TMUX_BRIDGE_SOCKET=/tmp/host-tmux.sock

## Read-before-act guard

`tmux-bridge` enforces that agents `read` a pane before they can `type`,
`message`, or `keys` into it. This is the main safety net against "agent
blindly hallucinates into the wrong pane."

The guard is a sentinel at `/tmp/tmux-bridge-read-<pane_id>`. Reading sets
it; any write clears it. So the contract is:

1. `tmux-bridge read <target>` — look at the pane's current state
2. `tmux-bridge type <target> "..."` — act on what you saw
3. To act again, read again.

## Diagnostics

    tmux-bridge doctor

Prints env vars, detected socket, visible panes, and a pass/fail summary.
Run this first when things go wrong.

## Provenance

`scripts/tmux-bridge` is vendored byte-for-byte from upstream smux
(github.com/ShawnPana/smux). See `scripts/tmux-bridge.VENDORED` for the
pinned commit and SHA256. License is MIT, reproduced in
`scripts/THIRD_PARTY_LICENSES/smux-LICENSE`.

`scripts/deva-bridge-tmux` and `scripts/deva-bridge-tmux-host` are deva's
own work (see `docs/devlog/20260108-deva-bridge-tmux.org`).
