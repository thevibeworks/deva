# tmux-bridge: agent-to-agent comms in deva containers

deva ships two tmux bridge layers. They compose.

    Layer 1  host-tmux               kernel boundary
             (scripts/host-tmux)          container -> host tmux server
             ssh transport                attach/ls direct; `bridge` forwards
                                          host socket to /tmp/host-tmux.sock

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

Access is scoped to ssh key holders and the forwarded socket is 0600 —
unlike the retired socat bridge (TCP 41555, no auth, any local process).
Note: a container with the docker socket mounted already has an equivalent
host write path; `host-tmux setup` uses it once to install your key, and
prints the undo.

## Quick start

Container (inside a deva agent):

    host-tmux setup                       # once: install your pubkey on the host
    host-tmux ls                          # list host sessions
    host-tmux attach [session]            # interactive attach over ssh -t

For a local socket (native tmux client, or Layer 2 against host panes):

    host-tmux bridge                      # ssh -L; creates /tmp/host-tmux.sock
    tmux -S /tmp/host-tmux.sock attach    # optional: attach to host session

Host prerequisite: Remote Login enabled — one-time, System Settings >
General > Sharing > Remote Login, or `sudo systemsetup -setremotelogin on`
in a host terminal. sshd is launchd-managed, so unlike a manual proxy
daemon the transport is alive again right after a reboot. `host-tmux
doctor` diagnoses the path layer by layer. Tip: restrict Remote Login's
"Allow access for" to your own user.

No Remote Login (won't, or can't — MDM-managed Macs)? It cannot be enabled
from inside a container (containers get file access to the host, never
process execution — that is the sandbox working). Two fallbacks:

- Invert the direction: run tmux inside the container and attach from a
  host terminal — `docker exec -it <container> tmux attach`. Zero host
  config; covers the agent-comms use case entirely. Only attaching to
  HOST sessions from the container genuinely needs sshd.
- The retired socat bridge (`deva-bridge-tmux{,-host}`, in git history
  before this doc's revision) still works if started by hand on the host
  each boot — with its unauthenticated-TCP caveats. Not recommended.

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

`scripts/host-tmux` is deva's own work. It replaced the socat TCP pair
`deva-bridge-tmux`/`deva-bridge-tmux-host` (unauthenticated port, manual
host daemon that died on every reboot, tmux client/server version coupling
— see `docs/devlog/20260108-deva-bridge-tmux.org` for the original design
and #405 for the replacement rationale).
