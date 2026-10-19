# shellcheck shell=bash

# shellcheck disable=SC1091
if [ -f "$(dirname "${BASH_SOURCE[0]}")/shared_auth.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/shared_auth.sh"
fi

# dsh web serves loopback only: --host takes 127.0.0.1 or 0.0.0.0, and
# 0.0.0.0 is refused at the CLI ("intentionally not supported yet for
# safety"). docker -p cannot reach a container-loopback bind, so bridge
# runs get a socat sidecar inside the container netns bridging
# 0.0.0.0:DSH_WEB_PROXY_PORT -> 127.0.0.1:DSH_WEB_PORT, published to the
# host loopback only. The /api trust fence accepts any loopback Host, so
# no --trusted-host is needed for 127.0.0.1:<port> URLs.
DSH_WEB_PORT=3080
DSH_WEB_PROXY_PORT=3081

agent_prepare() {
    local -a args
    if [ $# -gt 0 ]; then
        args=("$@")
    else
        args=()
    fi

    parse_auth_args "dsh" "${args[@]+"${args[@]}"}"
    AUTH_METHOD="$PARSED_AUTH_METHOD"
    local -a remaining_args=("${PARSED_REMAINING_ARGS[@]+"${PARSED_REMAINING_ARGS[@]}"}")

    filter_trace_flag "${remaining_args[@]+"${remaining_args[@]}"}"
    local use_trace="$TRACE_FLAG_PRESENT"
    remaining_args=("${TRACE_FILTERED_ARGS[@]+"${TRACE_FILTERED_ARGS[@]}"}")

    if [ "$use_trace" = true ]; then
        auth_error "--trace is not supported for dsh yet" \
                   "cctrace has no dsh profile"
    fi

    # Container is the sandbox: dsh's own sandbox/approval subsystem
    # defaults to workspace-write + ask. danger-full-access turns both
    # off so unattended runs never stall on a prompt. Env is the only
    # switch (no CLI flag), and dsh scrubs DSH_* from project-discovered
    # env (.env, BASH_ENV) -- only this invoking-process env counts.
    DOCKER_ARGS+=("-e" "DSH_PERMISSION_MODE=danger-full-access")
    # dsh defaults its home to ~/.dsh today, but it is a developer
    # preview with promised breaking changes; pin the location so a
    # future default flip cannot strand mounted state.
    DOCKER_ARGS+=("-e" "DSH_HOME=/home/deva/.dsh")

    # Every dsh run ensures the web service (official recommendation;
    # bare `dsh` does not even start: `--profile <name> is required`).
    # Bare `deva.sh dsh` follows the service log; args after -- run
    # that dsh invocation in the foreground with the service ensured
    # behind it. DEVA_DSH_WEB=0 skips the service entirely.
    setup_dsh_web "${remaining_args[@]+"${remaining_args[@]}"}"

    setup_dsh_auth "$AUTH_METHOD"
}

setup_dsh_web() {
    local web_url=""

    if _trace_host_network_args; then
        # Host networking: the container loopback IS the host loopback,
        # so dsh web is host-reachable with no publish and no sidecar
        # (which would otherwise bind 0.0.0.0 in the HOST netns). But
        # ALL host-net dsh containers share that one loopback, so each
        # container must own a distinct web port: probe a free one here
        # and pin it into the container env. Without this, the second
        # dsh container sees the first one's server on 3080, never
        # starts its own, and the UI serves the WRONG container.
        local free_port="" port="${DEVA_DSH_WEB_PORT:-$DSH_WEB_PORT}" tries=0
        while [ "$tries" -lt 12 ]; do
            if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
                free_port="$port"
                break
            fi
            port=$((port + 1))
            tries=$((tries + 1))
        done
        if [ -z "$free_port" ]; then
            echo "warning: no free port from ${DEVA_DSH_WEB_PORT:-$DSH_WEB_PORT} on the host loopback; dsh web may collide with another container" >&2
            free_port="$DSH_WEB_PORT"
        fi
        DOCKER_ARGS+=("-e" "DEVA_DSH_WEB_PORT_CONTAINER=${free_port}")
        web_url="http://127.0.0.1:${free_port}"
    else
        # Probe a free host port from DEVA_DSH_WEB_PORT (default 3080)
        # so concurrent dsh containers land on predictable neighbors --
        # same scheme as the cctrace UI publish. The mapping is fixed at
        # container create; DEVA_DSH_WEB_URL travels as container env so
        # a later exec into a reused container announces the port that
        # was actually published, not this run's re-probe.
        local free_port="" port="${DEVA_DSH_WEB_PORT:-$DSH_WEB_PORT}" tries=0
        while [ "$tries" -lt 12 ]; do
            if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
                free_port="$port"
                break
            fi
            port=$((port + 1))
            tries=$((tries + 1))
        done
        if [ -n "$free_port" ]; then
            DOCKER_ARGS+=("-p" "127.0.0.1:${free_port}:${DSH_WEB_PROXY_PORT}")
            DOCKER_ARGS+=("-e" "DEVA_DSH_PROXY_PORT=${DSH_WEB_PROXY_PORT}")
            web_url="http://127.0.0.1:${free_port}"
        else
            echo "warning: no free host port from ${DEVA_DSH_WEB_PORT:-$DSH_WEB_PORT}; dsh web UI will not be reachable from the host" >&2
        fi
    fi
    if [ -n "$web_url" ]; then
        DOCKER_ARGS+=("-e" "DEVA_DSH_WEB_URL=${web_url}")
    fi

    # In-container boot wrapper, three duties on EVERY dsh run:
    #   1. register the workspace in dsh's registry (all modes, so tui/
    #      headless sessions land pre-grouped in the web UI);
    #   2. ensure the web service: daemonize `dsh web` + the socat
    #      loopback bridge if not already listening -- idempotent, so
    #      exec into a running container never EADDRINUSEs, and the
    #      service survives the exec session ending;
    #   3. run the user's dsh args in the foreground, or follow the
    #      service log when there are none.
    # The workspace seed follows @deepseek-ai/dsh-workspace's durable
    # schema (storages/workspace.json, domain version 2) byte-for-byte:
    # realpath canon, uuid id, basename title, prepend to order. It
    # backs off from anything it does not own outright -- foreign
    # schema version, pending mutation marker, an uninitialized
    # registry with session history (dsh's one-time header bootstrap
    # must group that history first; the seed retries next launch).
    # DEVA_DSH_WORKSPACE_AUTO=0 disables. Eligible: the deva workspace
    # mount itself (DEVA_WORKSPACE/WORKDIR create-time env -- the dir
    # the user pointed deva at IS the workspace, git repo or not), or
    # any dir with a .git entry (dir or worktree file). Skips and
    # backoffs say why -- a silent no-op here is undebuggable.
    local wrapper=""
    read -r -d '' wrapper <<'WRAPPER' || true
if [ "${DEVA_DSH_WORKSPACE_AUTO:-1}" = "1" ]; then
if [ -e .git ] || [ "$PWD" = "${DEVA_WORKSPACE:-}" ] || [ "$PWD" = "${WORKDIR:-}" ]; then
    node --input-type=commonjs <<'SEED' || echo "deva: dsh workspace auto-add failed (non-fatal)" >&2
const fs = require('fs'), path = require('path'), os = require('os'), crypto = require('crypto');
const home = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
const file = path.join(home, 'storages', 'workspace.json');
const cwd = fs.realpathSync(process.cwd());
const skip = why => { console.error('deva: dsh workspace auto-add skipped: ' + why); process.exit(0); };
let state;
if (fs.existsSync(file)) {
  state = JSON.parse(fs.readFileSync(file, 'utf8'));
  // Foreign shape or an in-flight registry mutation: hands off, dsh owns it.
  if (!state || !state.unit || state.unit.name !== 'workspace' || state.unit.version !== 2)
    skip('unknown registry schema, leaving it to dsh');
  if (!state.global || state.global.initialized !== true)
    skip('registry not initialized (dsh bootstrap runs first; retries next launch)');
  if (state.global.pendingMutation)
    skip('registry mutation in flight (dsh recovers it; retries next launch)');
} else {
  // First boot: pre-initialize only an EMPTY registry. With session
  // history on disk, dsh's own header bootstrap must group it first
  // (the initialized marker is written last on purpose) -- the seed
  // gets another chance on the next launch.
  try {
    if (fs.readdirSync(path.join(home, 'sessions')).length > 0)
      skip('no registry but session history exists (dsh bootstrap runs first; retries next launch)');
  } catch {}
  state = { unit: { name: 'workspace', version: 2 },
            global: { initialized: true, workspaceIds: [], archivedSessionIds: [] },
            tables: { workspaces: {} } };
}
if (!state.tables) state.tables = {};
if (!state.tables.workspaces) state.tables.workspaces = {};
const table = state.tables.workspaces;
if (Object.values(table).some(r => r && r.path === cwd)) process.exit(0);
const id = crypto.randomUUID();
const now = new Date().toISOString();
table[id] = { path: cwd, title: path.basename(cwd), sessionIds: [], createdAt: now, updatedAt: now };
state.global.workspaceIds = [id].concat(state.global.workspaceIds || []);
fs.mkdirSync(path.dirname(file), { recursive: true });
const tmp = file + '.deva-seed';
fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
fs.renameSync(tmp, file);
console.error('deva: registered workspace ' + cwd + ' in dsh');
SEED
else
    echo "deva: dsh workspace auto-add skipped: $PWD is not the deva workspace and has no .git" >&2
fi
fi
_dsh_port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
# Our own server, in THIS container's pid namespace. An open port is
# NOT proof of ours: under host networking another dsh container's
# server answers the same loopback. (The pgrep pattern cannot match
# this wrapper itself -- here the port is an unexpanded variable.)
_dsh_web_ours() { pgrep -f "dsh web --port ${1}" >/dev/null 2>&1; }

if [ "${DEVA_DSH_WEB:-1}" = "1" ]; then
    dsh_web_port="${DEVA_DSH_WEB_PORT_CONTAINER:-3080}"
    web_log="${DSH_HOME:-$HOME/.dsh}/web.log"
    mkdir -p "$(dirname "$web_log")"
    if _dsh_web_ours "$dsh_web_port"; then
        : # already serving
    elif _dsh_port_open "$dsh_web_port"; then
        echo "deva: 127.0.0.1:${dsh_web_port} is bound outside this container (another host-net dsh container?) -- not starting dsh web; recreate this container to allocate a fresh port" >&2
    else
        setsid nohup dsh web --port "$dsh_web_port" </dev/null >>"$web_log" 2>&1 &
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            _dsh_port_open "$dsh_web_port" && break
            sleep 1
        done
        if ! _dsh_port_open "$dsh_web_port"; then
            echo "deva: dsh web failed to start; last log lines:" >&2
            tail -n 20 "$web_log" >&2 || true
        fi
    fi
    if [ -n "${DEVA_DSH_PROXY_PORT:-}" ] && ! _dsh_port_open "$DEVA_DSH_PROXY_PORT"; then
        setsid nohup socat "TCP-LISTEN:${DEVA_DSH_PROXY_PORT},fork,reuseaddr" "TCP:127.0.0.1:${dsh_web_port}" </dev/null >>"$web_log" 2>&1 &
    fi
    if _dsh_web_ours "$dsh_web_port"; then
        if [ -n "${DEVA_DSH_WEB_URL:-}" ]; then
            echo "deva: dsh web UI: ${DEVA_DSH_WEB_URL}" >&2
        else
            echo "deva: dsh web running on container loopback only (container predates the web publish; recreate it for host access)" >&2
        fi
    fi
fi
if [ $# -gt 0 ]; then
    exec dsh "$@"
fi
if [ "${DEVA_DSH_WEB:-1}" != "1" ]; then
    echo "deva: DEVA_DSH_WEB=0 and no dsh args given; nothing to run" >&2
    exit 2
fi
exec tail -n 20 -f "${DSH_HOME:-$HOME/.dsh}/web.log"
WRAPPER
    AGENT_COMMAND=("bash" "-c" "$wrapper" "dsh-web")
    if [ $# -gt 0 ]; then
        AGENT_COMMAND+=("$@")
    fi
}

setup_dsh_auth() {
    local method="$1"

    case "$method" in
        credentials)
            AUTH_DETAILS="credentials (~/.dsh)"
            # Everything dsh persists lives under ~/.dsh ($DSH_HOME):
            # .credentials.yaml, settings.yaml, profiles/ (incl. pnpm
            # node_modules -- container-built, so the mount must stay
            # writable), skills/, attachments/. Only mount the host dir
            # directly when no config-home mechanism is active. -Q bare
            # mode: no mounts. Explicit/auto config-home: centralized
            # mount handles it.
            if [ "${QUICK_MODE:-false}" = false ] && [ "${CONFIG_HOME_FROM_CLI:-false}" = false ] && [ "${CONFIG_HOME_AUTO:-false}" = false ]; then
                if [ ! -d "$HOME/.dsh" ]; then
                    echo "Warning: ~/.dsh directory not found, creating it" >&2
                    mkdir -p "$HOME/.dsh"
                fi
                DOCKER_ARGS+=("-v" "$HOME/.dsh:/home/deva/.dsh")
            fi
            ;;
        api-key)
            # DEEPSEEK_API_KEY travels as env only. No mount: dsh
            # resolves inherited env BEFORE ~/.dsh/.credentials.yaml,
            # so the env key alone decides billing; leaving the home
            # out keeps profiles/node_modules (host-arch pnpm trees)
            # from crossing the boundary (same no-mount contract as
            # grok/kimi/opencode/pi api-key).
            if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
                auth_error "DEEPSEEK_API_KEY not set for --auth-with api-key" \
                           "Set DEEPSEEK_API_KEY or use credentials mode (default)"
            fi
            DOCKER_ARGS+=("-e" "DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}")
            AUTH_DETAILS="api-key (DEEPSEEK_API_KEY)"
            ;;
        *)
            auth_error "auth method '$method' not implemented for dsh"
            ;;
    esac
}
