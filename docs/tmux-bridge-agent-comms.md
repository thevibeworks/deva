# tmux in deva: watching agents, and the host escape hatch

The container is the sandbox. The default tmux story keeps it that way; one
optional bridge deliberately breaks it, and is off unless you ask for it.

    Direction              tool              sandbox
    ---------              ----              -------
    host  -> container     deva.sh shell     intact — default, recommended
    (attach INTO an agent) (docker exec)     host reaches in, container gains nothing

    agent <-> agent        tmux-bridge       intact — inside one container
    (drive each other)     (scripts/...)     scoped to the container tmux server

    container -> host      host-tmux         BROKEN — opt-in only
    (reach host tmux)      (ssh, --host-tmux)  agent can run commands on the host

## Default: watch agents from the host (sandbox intact)

You rarely need the container to reach out. To watch or drive an agent, go
the safe direction — from a host terminal, reach into the container:

    deva.sh shell                         # zsh into the container (pick if many)
    docker exec -it <container> tmux attach   # if the agent runs under tmux

The host already has full privilege, so reaching in grants the container
nothing. No sshd, no keys, no host config. This is the recommended path and
survives reboots for free (host terminal is back after login).

## Agent-to-agent: tmux-bridge (Layer 2, sandboxed)

`tmux-bridge` lets agents read/drive each other's panes on the container's
own tmux server. It never leaves the container, so it does not touch the
sandbox boundary. Baked into the image.

## Opt-in: reach host tmux from the container (host-tmux)

This one dissolves the sandbox: an authenticated ssh key lets the agent run
arbitrary commands on the host (`send-keys`, `run-shell`, scrollback). So it
is NOT installed in the image — it ships at `scripts/host-tmux` and you turn
it on per run:

    deva.sh --host-tmux claude            # mount host-tmux + your ssh key, PATH-linked

Then, inside that container:

    host-tmux setup                       # once: install your pubkey on the host
    host-tmux ls                          # list host sessions
    host-tmux attach [session]            # interactive attach over ssh -t
    host-tmux bridge                      # ssh -L; creates /tmp/host-tmux.sock
                                          # (native client + tmux-bridge vs host panes)

Only enable this for trusted workflows on your own machine. Because it needs
a key on the host, the hardened `--no-docker` config stays sealed unless you
pass `--host-tmux` — that is the whole point of keeping it opt-in.

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
