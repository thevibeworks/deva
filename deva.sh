#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$SCRIPT_DIR/agents"

DEVA_DOCKER_IMAGE_ENV_SET=false
if [ -n "${DEVA_DOCKER_IMAGE+x}" ]; then
    DEVA_DOCKER_IMAGE_ENV_SET=true
fi
DEVA_DOCKER_TAG_ENV_SET=false
if [ -n "${DEVA_DOCKER_TAG+x}" ]; then
    DEVA_DOCKER_TAG_ENV_SET=true
fi

VERSION="0.14.1"
DEVA_DOCKER_IMAGE="${DEVA_DOCKER_IMAGE:-ghcr.io/thevibeworks/deva}"
DEVA_DOCKER_TAG="${DEVA_DOCKER_TAG:-latest}"
DEVA_CONTAINER_PREFIX="${DEVA_CONTAINER_PREFIX:-deva}"
DEFAULT_AGENT="${DEVA_DEFAULT_AGENT:-claude}"
DEVA_CODEX_BROWSER_MCP_PACKAGE="${DEVA_CODEX_BROWSER_MCP_PACKAGE:-${DEVA_PLAYWRIGHT_MCP_PACKAGE:-@playwright/mcp@0.0.75}}"
DEVA_PLAYWRIGHT_MCP_PACKAGE="${DEVA_PLAYWRIGHT_MCP_PACKAGE:-$DEVA_CODEX_BROWSER_MCP_PACKAGE}"

PROFILE="${DEVA_PROFILE:-${DEVA_IMAGE_PROFILE:-}}"

CONFIG_ROOT=""

USER_VOLUMES=()
USER_ENVS=()
CODEX_CONFIG_OVERRIDES=()
EXTRA_DOCKER_ARGS=()
DOCKER_TERMINAL_ARGS=()
CONFIG_HOME=""
CONFIG_HOME_AUTO=false
CONFIG_HOME_FROM_CLI=false
AUTOLINK=true
_WS_HASH_CACHE=""
if [ -n "${DEVA_NO_AUTOLINK:-}" ]; then AUTOLINK=false; fi
SKIP_CONFIG=false
CONFIG_ERRORS=()
LOADED_CONFIGS=()
AGENT_ARGS=()
AGENT_EXPLICIT=false

normalize_docker_image_parts() {
    local tail="${DEVA_DOCKER_IMAGE##*/}"

    if [[ "$DEVA_DOCKER_IMAGE" == *@* ]]; then
        DEVA_DOCKER_TAG=""
        DEVA_DOCKER_TAG_ENV_SET=true
        return
    fi

    if [[ "$tail" == *:* ]]; then
        local embedded_tag="${tail##*:}"
        DEVA_DOCKER_IMAGE="${DEVA_DOCKER_IMAGE%:*}"
        if [ "$DEVA_DOCKER_TAG_ENV_SET" = false ]; then
            DEVA_DOCKER_TAG="$embedded_tag"
            DEVA_DOCKER_TAG_ENV_SET=true
        fi
    fi
}

docker_image_ref() {
    if [[ "$DEVA_DOCKER_IMAGE" == *@* ]]; then
        printf '%s' "$DEVA_DOCKER_IMAGE"
    elif [ -n "${DEVA_DOCKER_TAG:-}" ]; then
        printf '%s:%s' "$DEVA_DOCKER_IMAGE" "$DEVA_DOCKER_TAG"
    else
        printf '%s' "$DEVA_DOCKER_IMAGE"
    fi
}

normalize_docker_image_parts

EPHEMERAL_MODE=false
QUICK_MODE=false
GLOBAL_MODE=false
DEBUG_MODE=false
DRY_RUN=false
CODEX_BROWSER_MCP=false

if [ -t 0 ] && [ -t 1 ]; then
    DOCKER_TERMINAL_ARGS=(-it)
elif [ ! -t 0 ]; then
    DOCKER_TERMINAL_ARGS=(-i)
fi

# Progressive breadcrumbs for --debug: prints phase name + seconds elapsed
# since the previous breadcrumb. Users can eyeball which phase is the hot
# one without firing a profiler.
_DEVA_STEP_LAST=$SECONDS
_step() {
    [ "$DEBUG_MODE" = true ] || return 0
    local now=$SECONDS
    local elapsed=$((now - _DEVA_STEP_LAST))
    _DEVA_STEP_LAST=$now
    printf '[deva:step +%3ds] %s\n' "$elapsed" "$*" >&2
}

usage() {
    cat <<'USAGE'
deva.sh - Docker-based multi-agent launcher (Claude, Codex, Gemini, Grok)

Usage:
  deva.sh [deva flags] [agent] [-- agent-flags]
  deva.sh [agent] [deva flags] [-- agent-flags]
  deva.sh <command>

Container management commands (docker/tmux-style):
  deva.sh ps [-g]            List containers (current project or --all)
  deva.sh status [-g] [--verbose]
                              Inspect workspace: containers, mounts, agent homes, health
  deva.sh shell [-g]         Open zsh shell for inspection (pick if multiple)
  deva.sh stop [-g]          Stop container (pick if multiple)
  deva.sh rm [-g] [--all]    Remove container (pick if multiple), or all for this workspace
  deva.sh clean [-g]         Remove all stopped containers
  deva.sh sessions [-g] [args]
                              Browse agent sessions (ccx sessions pass-through)
  deva.sh insight [args]      Generate data report (ccx insight pass-through)
  deva.sh ccx [-g] [cmd] [args]
                              Run any ccx command inside a container

Advanced:
  deva.sh --show-config      Show resolved configuration (debug)

Deva flags:
  --rm                    Ephemeral mode: remove container after exit
  -g, --global            Global mode: access containers from all projects
  -v SRC:DEST[:OPT]       Mount additional volumes inside the container
  -c DIR, --config-home   DIR
                          Mount an alternate auth/config home into /home/deva
  -e VAR[=VALUE]          Pass environment variable into the container (pulls from host when VALUE omitted)
  -p NAME, --profile      NAME
                          Select profile: base (default), rust. Pulls tag, falls back to Dockerfile.<profile>
  -Q, --quick             Bare mode: no host config mounts, no .deva loading, no autolink,
                          implies --rm. Like emacs -Q. Mutually exclusive with -c.
  --host-net              Use host networking for the agent container
  --browser-mcp           Codex only: wire Playwright MCP through Codex config overrides.
                          Uses the rust profile because browser runtime deps live there.
                          Alias: --with-browser
  --no-docker             Disable auto-mount of Docker socket (default: auto-mount if present)
  --dry-run               Show docker command without executing the container (implies --debug)
  --verbose, --debug      Print full docker command before execution
  --                      Everything after this sentinel is passed to the agent unchanged

Chrome integration for `claude -- --chrome`:
  Set one of these in `.deva.local` or pass with `-e`:
  DEVA_CHROME_PROFILE_PATH=/path/to/Profile 6
                          Mount that profile's `Extensions/` tree for detection
  DEVA_CHROME_PROFILE_NAME=Profile 6
                          Override target profile name when source basename differs
  DEVA_CHROME_USER_DATA_DIR=/path/to/Chrome user data
                          Scan `Default`/`Profile *` and mount only `Extensions/`
  DEVA_HOST_CHROME_BRIDGE_DIR=/path/to/claude-mcp-browser-bridge-$USER
                          Override the exact host bridge directory if needed

Browser MCP for `codex --browser-mcp`:
  CODEX_BROWSER_MCP=true
                          Enable the injected Playwright MCP entry from .deva config
  CODEX_CONFIG=features.apps=false
                          Repeatable Codex CLI --config override for this session
  DEVA_CODEX_BROWSER_MCP_PACKAGE=@playwright/mcp@0.0.75
                          Override the Playwright MCP package used by the injected Codex MCP entry

Container Behavior (NEW in v0.8.0):
  Default (persistent):   Shared per project by default, but split when container shape changes
                          (image/profile, extra volumes, explicit config-home, auth mode).
                          Preserves state (npm packages, builds, etc).
                          Faster startup, and default-auth runs can share one warm container.

  With --rm (ephemeral):  Create new container, auto-remove after exit.
                          Agent-specific naming for parallel runs.

Container Naming (NEW):
  Persistent:  deva-<parent>-<project>[..shape]     # shape may encode image/volumes/config/auth
  Ephemeral:   deva-<parent>-<project>-<agent>-<pid>  # Agent-specific

  Example:
    /Users/eric/work/myapp  → deva-work-myapp
    /Users/eric/home/myapp  → deva-home-myapp

Examples:
  # Launch agents (persistent by default)
  deva.sh                             # Launch claude in persistent container
  deva.sh claude                      # Same
  deva.sh codex                       # Launch codex in the same default container shape
  deva.sh gemini                      # Launch gemini in the same default container shape
  deva.sh grok                        # Launch grok in the same default container shape
  deva.sh claude --rm                 # Ephemeral: deva-work-myapp-claude-12345

  # Container management (current project)
  deva.sh ps                          # List containers for this project
  deva.sh shell                       # Open zsh for inspection
  deva.sh stop                        # Stop container
  deva.sh rm                          # Remove container
  deva.sh clean                       # Clean stopped containers

  # Global mode (all projects)
  deva.sh ps -g                       # List ALL deva containers
  deva.sh shell -g                    # Open shell in any container
  deva.sh stop -g                     # Stop any container

Advanced:
  deva.sh codex -v ~/.ssh:/home/deva/.ssh:ro -- -m gpt-5-codex
  deva.sh claude -- --trace --continue   # Trace requests with cctrace
  deva.sh --show-config                  # Debug configuration
  deva.sh --no-docker claude             # Disable Docker-in-Docker auto-mount
USAGE
}

expand_tilde() {
    local path="$1"
    if [[ "$path" == ~* ]]; then
        path="${path/#~/$HOME}"
    fi
    printf '%s' "$path"
}

# Pure-bash path ops. Previously shelled out to python3 per call, which cost
# ~100-150ms of cold-start per invocation on macOS — validate_bind_mount_shape
# alone could fork 30+ python processes for a single --dry-run. These
# replacements are filesystem-touch-free (except canonical_path) and keep the
# exact semantics the python versions implemented: abspath, normpath, relpath,
# and commonpath-based descendancy.

_normalize_path() {
    # os.path.normpath-equivalent: collapse '.', '..', and '//' without hitting
    # the filesystem. Absolute-ness is preserved; '..' that would escape '/'
    # is dropped (matches python).
    local input="$1"
    # POSIX: exactly-two leading slashes are implementation-defined and
    # preserved by python. Three or more collapse to one.
    local prefix=""
    if [ "$input" = "//" ] || [[ "$input" == //[!/]* ]]; then
        prefix="//"
        input="${input#//}"
    fi
    local absolute=0
    case "$input" in /*) absolute=1 ;; esac

    while [[ "$input" == *//* ]]; do
        input="${input//\/\//\/}"
    done

    local -a stack=()
    local IFS=/
    local -a parts
    # shellcheck disable=SC2206
    parts=($input)
    IFS=$' \t\n'

    local seg len top
    for seg in "${parts[@]}"; do
        case "$seg" in
            '' | '.') ;;
            '..')
                len=${#stack[@]}
                if [ "$len" -gt 0 ]; then
                    top="${stack[$((len - 1))]}"
                    if [ "$top" = '..' ]; then
                        stack+=("..")
                    elif [ "$len" -eq 1 ]; then
                        stack=()
                    else
                        stack=("${stack[@]:0:$((len - 1))}")
                    fi
                elif [ "$absolute" = 0 ]; then
                    stack+=("..")
                fi
                ;;
            *)
                stack+=("$seg")
                ;;
        esac
    done

    IFS=/
    local joined="${stack[*]-}"
    IFS=$' \t\n'

    if [ -n "$prefix" ]; then
        printf '%s%s\n' "$prefix" "$joined"
    elif [ "$absolute" = 1 ]; then
        printf '/%s\n' "$joined"
    elif [ -n "$joined" ]; then
        printf '%s\n' "$joined"
    else
        printf '.\n'
    fi
}

absolute_path() {
    # os.path.abspath-equivalent: absolute + normalized, no symlink resolution.
    local p="$1"
    case "$p" in
        /*) _normalize_path "$p" ;;
        *) _normalize_path "$PWD/$p" ;;
    esac
}

canonical_path() {
    # os.path.realpath-equivalent: resolve symlinks, absolute, normalized.
    # Prefers coreutils `realpath` when present (covers Linux, macOS ≥ 12.3).
    # Falls back to `cd -P && pwd -P` which works on every POSIX shell.
    local p="$1"
    [ -z "$p" ] && return

    if command -v realpath >/dev/null 2>&1; then
        local out
        if out="$(realpath "$p" 2>/dev/null)"; then
            printf '%s\n' "$out"
            return
        fi
    fi

    if [ -d "$p" ]; then
        local out
        if out="$(cd -P "$p" 2>/dev/null && pwd -P)"; then
            printf '%s\n' "$out"
            return
        fi
    elif [ -e "$p" ] || [ -L "$p" ]; then
        local dir base d
        dir="$(dirname -- "$p")"
        base="$(basename -- "$p")"
        if [ -d "$dir" ] && d="$(cd -P "$dir" 2>/dev/null && pwd -P)"; then
            if [ -L "$d/$base" ]; then
                local tgt
                tgt="$(readlink "$d/$base" 2>/dev/null || true)"
                if [ -n "$tgt" ]; then
                    case "$tgt" in
                        /*) canonical_path "$tgt" ;;
                        *) canonical_path "$d/$tgt" ;;
                    esac
                    return
                fi
            fi
            printf '%s\n' "$d/$base"
            return
        fi
    fi

    absolute_path "$p"
}

default_config_home_for_agent() {
    local agent="$1"
    local xdg_home
    xdg_home="${XDG_CONFIG_HOME:-$HOME/.config}"
    printf '%s' "$xdg_home/deva/$agent"
}

validate_profile() {
    case "$1" in
    base | rust | "") return 0 ;;
    *) return 1 ;;
    esac
}

set_config_home_value() {
    local raw="$1"
    raw="$(expand_tilde "$raw")"
    CONFIG_HOME="$(absolute_path "$raw")"
}

check_agent() {
    local agent="$1"
    if [ ! -f "$AGENTS_DIR/$agent.sh" ]; then
        local available=""
        local file
        for file in "$AGENTS_DIR"/*.sh; do
            [ -e "$file" ] || continue
            available+="$(basename "$file" .sh) "
        done
        available="${available%% }"
        echo "error: unknown agent '$agent'" >&2
        echo "available agents: ${available}" >&2
        exit 1
    fi
}

check_image() {
    local image_ref
    image_ref="$(docker_image_ref)"

    if docker image inspect "$image_ref" >/dev/null 2>&1; then
        return
    fi

    # Try pulling first
    if docker pull "$image_ref" >/dev/null 2>&1; then
        return
    fi

    # Smart fallback: check for available profile images locally.
    # Digest-pinned refs are exact; tag fallback does not make sense there.
    local available_tags=""
    if [[ "$DEVA_DOCKER_IMAGE" != *@* ]]; then
        # Check common profile tags (prefer rust as it's a superset of base)
        for tag in rust latest; do
            if [ "$tag" = "$DEVA_DOCKER_TAG" ]; then
                continue  # Skip the one we already tried
            fi
            if docker image inspect "${DEVA_DOCKER_IMAGE}:${tag}" >/dev/null 2>&1; then
                available_tags="${available_tags}${tag} "
            fi
        done
    fi

    if [ -n "$available_tags" ]; then
        # Found alternative images - use the first one
        local fallback_tag="${available_tags%% *}"  # Get first tag
        echo "Image $image_ref not found" >&2
        echo "Using available image: ${DEVA_DOCKER_IMAGE}:${fallback_tag}" >&2
        DEVA_DOCKER_TAG="$fallback_tag"
        return
    fi

    # Determine matching local Dockerfile for suggestions (no auto-build)
    local df=""
    case "${PROFILE:-}" in
    rust)
        [ -f "${SCRIPT_DIR}/Dockerfile.rust" ] && df="${SCRIPT_DIR}/Dockerfile.rust" || df=""
        ;;
    esac

    echo "Docker image $image_ref not found locally" >&2
    if [ -n "$df" ]; then
        echo "A matching Dockerfile exists at: $df" >&2
        case "${PROFILE:-}" in
        rust)
            echo "Build with: make build-rust" >&2
            echo "Manual docker builds need explicit build args and BASE_IMAGE; see docs/custom-images.md" >&2
            ;;
        "" | base)
            echo "Build with: make build" >&2
            echo "Manual docker builds need explicit build args; see docs/custom-images.md" >&2
            ;;
        *)
            echo "Build with your Dockerfile and tag appropriately (e.g., :${PROFILE})" >&2
            ;;
        esac
    else
        echo "Pull with: docker pull $image_ref" >&2
    fi
    exit 1
}

dangerous_directory() {
    local dir
    dir="$(pwd)"
    local bad_dirs=("$HOME" "/" "/etc" "/usr" "/var" "/bin" "/sbin" "/lib" "/lib64" "/boot" "/dev" "/proc" "/sys" "/tmp" "/root" "/mnt" "/media" "/srv")
    for item in "${bad_dirs[@]}"; do
        if [ "$dir" = "$item" ]; then
            return 0
        fi
    done
    if [ "$dir" = "$(dirname "$HOME")" ]; then
        return 0
    fi
    return 1
}

warn_dangerous_directory() {
    local current_dir
    current_dir="$(pwd)"
    cat <<EOF
WARNING: Running in a high-risk directory!
Current directory: ${current_dir}

deva.sh will grant full access to this directory and all subdirectories.
Type 'yes' to continue:
EOF
    read -r response
    if [ "$response" != "yes" ]; then
        echo "Aborted. Change to a specific project directory."
        exit 1
    fi
}

translate_localhost() {
    echo "$1" | sed 's/127\.0\.0\.1/host.docker.internal/g' | sed 's/localhost/host.docker.internal/g'
}

claude_args_request_chrome() {
    local arg
    local wants_chrome=false
    local disables_chrome=false

    for arg in "$@"; do
        case "$arg" in
        --chrome)
            wants_chrome=true
            ;;
        --no-chrome)
            disables_chrome=true
            ;;
        esac
    done

    [ "$wants_chrome" = true ] && [ "$disables_chrome" = false ]
}

get_host_tmpdir() {
    # macOS: $TMPDIR is already set to /var/folders/... by launchd.
    # Linux/WSL: $TMPDIR is usually unset, fall through to /tmp.
    # Node/Python probes previously lived here — they cost one cold-start
    # each and told us nothing $TMPDIR couldn't.
    printf '%s' "${TMPDIR:-/tmp}"
}

normalize_host_bind_path() {
    local path="$1"
    path="$(expand_tilde "$path")"

    if [[ "$path" == /* ]]; then
        printf '%s' "$path"
        return 0
    fi

    absolute_path "$path"
}

configured_env_value() {
    local name="$1"
    local spec

    for spec in "${USER_ENVS[@]+"${USER_ENVS[@]}"}"; do
        if [[ "$spec" == "$name="* ]]; then
            printf '%s' "${spec#*=}"
            return 0
        fi
        if [ "$spec" = "$name" ] && [ -n "${!name-}" ]; then
            printf '%s' "${!name}"
            return 0
        fi
    done

    if [ -n "${!name-}" ]; then
        printf '%s' "${!name}"
        return 0
    fi

    return 1
}

set_user_env_value() {
    local name="$1"
    local value="$2"
    local -a retained=()
    local spec spec_name

    for spec in "${USER_ENVS[@]+"${USER_ENVS[@]}"}"; do
        if [[ "$spec" == *"="* ]]; then
            spec_name="${spec%%=*}"
        else
            spec_name="$spec"
        fi
        [ "$spec_name" = "$name" ] && continue
        retained+=("$spec")
    done

    if [ ${#retained[@]} -gt 0 ]; then
        USER_ENVS=("${retained[@]}")
    else
        USER_ENVS=()
    fi
    USER_ENVS+=("$name=$value")
    export "$name=$value"
}

user_volume_mounts_target() {
    local target="$1"
    local spec remainder dest

    target="$(normalize_container_bind_target "$target")"

    for spec in "${USER_VOLUMES[@]+"${USER_VOLUMES[@]}"}"; do
        remainder="${spec#*:}"
        dest="${remainder%%:*}"
        dest="$(normalize_container_bind_target "$dest")"
        if [ "$dest" = "$target" ]; then
            return 0
        fi
    done

    return 1
}

normalize_container_bind_target() {
    local path="$1"

    while [ "$path" != "/" ] && [[ "$path" == */ ]]; do
        path="${path%/}"
    done

    printf '%s' "$path"
}

append_shared_agents_mount() {
    local target="/home/deva/.agents"

    [ "$QUICK_MODE" = false ] || return 0
    [ -d "$HOME/.agents" ] || return 0

    if ! user_volume_mounts_target "$target"; then
        USER_VOLUMES+=("$HOME/.agents:$target")
    fi
}

prepare_claude_chrome_detection_mount() {
    local profile_path=""
    local user_data_dir=""
    local profile_name=""
    local profile_target=""
    local extensions_source=""
    local found_profile=false

    profile_path="$(configured_env_value DEVA_CHROME_PROFILE_PATH || true)"
    user_data_dir="$(configured_env_value DEVA_CHROME_USER_DATA_DIR || true)"

    if [ -n "$profile_path" ]; then
        profile_path="$(normalize_host_bind_path "$profile_path")"
        if [ ! -d "$profile_path" ]; then
            echo "error: DEVA_CHROME_PROFILE_PATH does not exist: $profile_path" >&2
            exit 1
        fi

        profile_name="$(configured_env_value DEVA_CHROME_PROFILE_NAME || true)"
        if [ -z "$profile_name" ]; then
            profile_name="$(basename "$profile_path")"
        fi

        case "$profile_name" in
        Default | "Profile "*)
            ;;
        *)
            echo "error: Chrome profile name must be 'Default' or 'Profile N'; got: $profile_name" >&2
            echo "hint: set DEVA_CHROME_PROFILE_NAME='Profile 6' if the source path basename is different" >&2
            exit 1
            ;;
        esac

        extensions_source="$profile_path/Extensions"
        if [ ! -d "$extensions_source" ]; then
            echo "error: Chrome profile is missing Extensions directory: $extensions_source" >&2
            exit 1
        fi

        profile_target="/home/deva/.config/google-chrome/$profile_name/Extensions"
        if ! user_volume_mounts_target "$profile_target"; then
            USER_VOLUMES+=("$extensions_source:$profile_target:ro")
        fi
        return 0
    fi

    if [ -n "$user_data_dir" ]; then
        user_data_dir="$(normalize_host_bind_path "$user_data_dir")"
        if [ ! -d "$user_data_dir" ]; then
            echo "error: DEVA_CHROME_USER_DATA_DIR does not exist: $user_data_dir" >&2
            exit 1
        fi

        if [ -d "$user_data_dir/Default" ]; then
            extensions_source="$user_data_dir/Default/Extensions"
            if [ -d "$extensions_source" ]; then
                profile_target="/home/deva/.config/google-chrome/Default/Extensions"
                if ! user_volume_mounts_target "$profile_target"; then
                    USER_VOLUMES+=("$extensions_source:$profile_target:ro")
                fi
                found_profile=true
            fi
        fi

        local candidate
        for candidate in "$user_data_dir"/Profile\ *; do
            [ -d "$candidate" ] || continue
            extensions_source="$candidate/Extensions"
            [ -d "$extensions_source" ] || continue

            profile_name="$(basename "$candidate")"
            profile_target="/home/deva/.config/google-chrome/$profile_name/Extensions"
            if ! user_volume_mounts_target "$profile_target"; then
                USER_VOLUMES+=("$extensions_source:$profile_target:ro")
            fi
            found_profile=true
        done

        if [ "$found_profile" = false ]; then
            echo "error: DEVA_CHROME_USER_DATA_DIR has no Default/Profile */Extensions directories: $user_data_dir" >&2
            exit 1
        fi
    fi
}

resolve_claude_chrome_bridge_dir() {
    local host_user="$1"
    local configured_bridge_dir=""
    local host_tmpdir=""
    local host_bridge_dir=""

    configured_bridge_dir="$(configured_env_value DEVA_HOST_CHROME_BRIDGE_DIR || true)"
    if [ -n "$configured_bridge_dir" ]; then
        host_bridge_dir="$(normalize_host_bind_path "$configured_bridge_dir")"
    else
        host_tmpdir="$(get_host_tmpdir)"
        local tmp_bridge_dir="$host_tmpdir/claude-mcp-browser-bridge-$host_user"

        # Claude's native host currently creates the bridge under /tmp, while the
        # client also probes os.tmpdir() as an extra lookup path. Keep /tmp as
        # the default mount target and only prefer os.tmpdir() when it already
        # exists and /tmp does not.
        host_bridge_dir="/tmp/claude-mcp-browser-bridge-$host_user"

        if [ ! -d "$host_bridge_dir" ] && [ "$host_tmpdir" != "/tmp" ] && [ -d "$tmp_bridge_dir" ]; then
            host_bridge_dir="$tmp_bridge_dir"
        fi
    fi

    mkdir -p "$host_bridge_dir"
    chmod 700 "$host_bridge_dir" 2>/dev/null || true
    canonical_path "$host_bridge_dir"
}

prepare_claude_chrome_bridge() {
    [ "$ACTIVE_AGENT" = "claude" ] || return 0

    if ! claude_args_request_chrome "${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"}"; then
        return 0
    fi

    local host_user
    host_user="$(configured_env_value DEVA_CHROME_HOST_USER || true)"
    if [ -z "$host_user" ]; then
        host_user="$(id -un)"
    fi
    local host_bridge_dir
    host_bridge_dir="$(resolve_claude_chrome_bridge_dir "$host_user")"

    prepare_claude_chrome_detection_mount

    local bridge_mount="/deva-host-chrome-bridge"
    if ! user_volume_mounts_target "$bridge_mount"; then
        USER_VOLUMES+=("$host_bridge_dir:$bridge_mount")
    fi
    USER_ENVS+=("DEVA_CHROME_HOST_BRIDGE=1")
    USER_ENVS+=("DEVA_CHROME_HOST_USER=$host_user")
    USER_ENVS+=("DEVA_CHROME_HOST_BRIDGE_DIR=$bridge_mount")
}

prepare_browser_integration() {
    [ "$CODEX_BROWSER_MCP" = true ] || return 0

    if [ "$ACTIVE_AGENT" != "codex" ]; then
        echo "error: --browser-mcp is currently supported for codex only" >&2
        echo "hint: for Claude host Chrome, use: deva.sh claude -- --chrome" >&2
        exit 1
    fi

    case "${PROFILE:-}" in
    "" | base)
        PROFILE="rust"
        ;;
    rust)
        ;;
    *)
        echo "warning: --browser-mcp assumes the selected image contains node/npx and browser runtime deps" >&2
        ;;
    esac

    local mcp_package
    mcp_package="$(configured_env_value DEVA_CODEX_BROWSER_MCP_PACKAGE || true)"
    [ -n "$mcp_package" ] || mcp_package="$(configured_env_value DEVA_PLAYWRIGHT_MCP_PACKAGE || true)"
    [ -n "$mcp_package" ] || mcp_package="$DEVA_CODEX_BROWSER_MCP_PACKAGE"

    set_user_env_value "DEVA_CODEX_BROWSER_MCP" "1"
    set_user_env_value "DEVA_WITH_BROWSER" "1"
    set_user_env_value "DEVA_CODEX_BROWSER_MCP_PACKAGE" "$mcp_package"
    set_user_env_value "DEVA_PLAYWRIGHT_MCP_PACKAGE" "$mcp_package"
}

append_unique_line() {
    local list="$1"
    local item="$2"

    if [ -z "$item" ]; then
        printf '%s' "$list"
        return
    fi

    if [ -n "$list" ] && printf '%s\n' "$list" | grep -F -x -q -- "$item"; then
        printf '%s' "$list"
        return
    fi

    if [ -n "$list" ]; then
        printf '%s\n%s' "$list" "$item"
    else
        printf '%s' "$item"
    fi
}

sanitize_slug_component() {
    printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//'
}

compute_slug_components_for_path() {
    local path="$1"

    local dir_path
    if [ -d "$path" ]; then
        dir_path="$(cd "$path" 2>/dev/null && pwd)"
    else
        dir_path="$(cd "$(dirname "$path")" 2>/dev/null && pwd)"
    fi
    [ -n "$dir_path" ] || dir_path="$(pwd)"

    local project parent
    project="$(basename "$dir_path")"
    parent="$(basename "$(dirname "$dir_path")")"

    case "$parent" in
    src | github.com | gitlab.com | bitbucket.org | repos | projects | work | code | dev)
        parent="$(basename "$(dirname "$(dirname "$dir_path")")")"
        ;;
    esac

    local sanitized_parent sanitized_project
    sanitized_parent="$(sanitize_slug_component "$parent")"
    sanitized_project="$(sanitize_slug_component "$project")"

    printf '%s %s\n' "$sanitized_parent" "$sanitized_project"
}

generate_container_slug_for_path() {
    local path="$1"
    local parent project
    read -r parent project <<<"$(compute_slug_components_for_path "$path")"

    if [ -z "$project" ]; then
        echo "$parent"
        return
    fi

    if [ -n "$parent" ] && [[ "$project" == *"$parent"* ]] && [ ${#parent} -gt 3 ]; then
        echo "$project"
    elif [ -n "$parent" ]; then
        echo "${parent}-${project}"
    else
        echo "$project"
    fi
}

generate_container_slug() {
    generate_container_slug_for_path "$(pwd)"
}

extract_auth_file_stem() {
    local path="$1"
    local base
    base="$(basename "$path")"
    base="${base%.credentials.json}"
    base="${base%.json}"
    base="$(sanitize_slug_component "$base")"
    printf '%s' "${base:0:20}"
}

generate_auth_tag() {
    local agent="$1"
    local auth_method="${2:-}"
    local creds_file="${3:-}"
    local env_override="${4:-false}"

    if [ "$env_override" = true ]; then
        printf '%s' "env"
        return
    fi

    if [ -z "$auth_method" ]; then
        printf '%s' "auth-default"
        return
    fi

    case "$agent:$auth_method" in
        claude:claude|codex:chatgpt|gemini:oauth|gemini:gemini-app-oauth|grok:oauth)
            printf '%s' "auth-default"
            return
            ;;
    esac

    case "$auth_method" in
        credentials-file)
            if [ -n "$creds_file" ]; then
                local stem
                stem="$(extract_auth_file_stem "$creds_file")"
                printf '%s' "auth-file-${stem}"
            else
                printf '%s' "auth-file"
            fi
            ;;
        api-key|gemini-api-key)
            local key_val=""
            case "$agent" in
                claude) key_val="${ANTHROPIC_API_KEY:-}" ;;
                codex)  key_val="${OPENAI_API_KEY:-}" ;;
                gemini) key_val="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" ;;
                grok)   key_val="${XAI_API_KEY:-}" ;;
            esac
            if [ -n "$key_val" ] && [ ${#key_val} -ge 4 ]; then
                printf '%s' "api-key-${key_val: -4}"
            else
                printf '%s' "api-key"
            fi
            ;;
        *)
            printf '%s' "$(sanitize_slug_component "$auth_method")"
            ;;
    esac
}

compute_shape_hash() {
    local image_ref="$1"
    local volume_input="${2:-}"
    local config_input="${3:-}"
    local combined="$image_ref"
    [ -n "$volume_input" ] && combined="${combined}|${volume_input}"
    [ -n "$config_input" ] && combined="${combined}|${config_input}"
    short_hash "$combined" 8
}

build_container_name() {
    local prefix="$1"
    local agent="$2"
    local auth_tag="$3"
    local slug="$4"
    local shape_hash="$5"
    local ephemeral="${6:-false}"
    local pid="${7:-}"

    local name="${prefix}--${agent}--${auth_tag}--${slug}..${shape_hash}"
    if [ "$ephemeral" = true ] && [ -n "$pid" ]; then
        name="${name}--${pid}"
    fi
    printf '%s' "$name"
}

slug_candidates_for_path() {
    local path="$1"
    local parent project
    read -r parent project <<<"$(compute_slug_components_for_path "$path")"

    local variants=""
    if [ -n "$project" ]; then
        variants="$(append_unique_line "$variants" "$project")"

        local trimmed="$project"
        while [ -n "$trimmed" ]; do
            if [[ "$trimmed" =~ -[0-9]+$ ]]; then
                trimmed="${trimmed%-*}"
                if [ -n "$trimmed" ]; then
                    variants="$(append_unique_line "$variants" "$trimmed")"
                    continue
                fi
                continue
            fi
            if [[ "$trimmed" =~ -(copilot|yolo|yolo-mode|share)$ ]]; then
                trimmed="${trimmed%-*}"
                if [ -n "$trimmed" ]; then
                    variants="$(append_unique_line "$variants" "$trimmed")"
                    continue
                fi
                continue
            fi
            break
        done
    fi

    local slugs="$variants"

    if [ -n "$parent" ]; then
        local variant combined
        for variant in $variants; do
            [ -n "$variant" ] || continue
            if [ ${#parent} -gt 3 ] && [[ "$variant" == *"$parent"* ]]; then
                combined="$variant"
            else
                combined="${parent}-${variant}"
            fi
            slugs="$(append_unique_line "$slugs" "$combined")"
        done
        slugs="$(append_unique_line "$slugs" "$parent")"
    fi

    printf '%s\n' "$slugs" | sed '/^$/d'
}

project_container_rows() {
    local rows
    if [ "$GLOBAL_MODE" = true ]; then
        rows=$(docker ps --filter "name=${DEVA_CONTAINER_PREFIX}-" --format '{{.Names}}\t{{.Status}}\t{{.CreatedAt}}')
        [ -n "$rows" ] && printf "%s\n" "$rows"
        return
    fi

    # Prefer workspace label match when available (new containers)
    local ws_hash
    ws_hash=$(workspace_hash)
    rows=$(docker ps --filter "label=deva.workspace_hash=$ws_hash" --format '{{.Names}}\t{{.Status}}\t{{.CreatedAt}}')
    if [ -n "$rows" ]; then
        printf "%s\n" "$rows"
        return
    fi

    # Fallback to slug-based name filtering for legacy containers
    rows=$(docker ps --filter "name=${DEVA_CONTAINER_PREFIX}-" --format '{{.Names}}\t{{.Status}}\t{{.CreatedAt}}')
    if [ -z "$rows" ]; then
        return
    fi
    # Continue to slug filtering below (don't return here!)

    local path="$PWD"
    local slugs=""

    while true; do
        local slug
        for slug in $(slug_candidates_for_path "$path"); do
            [ -n "$slug" ] || continue
            slugs="$(append_unique_line "$slugs" "$slug")"
        done

        local parent_path
        parent_path="$(dirname "$path")"
        if [ "$parent_path" = "$path" ] || [ -z "$parent_path" ]; then
            break
        fi
        path="$parent_path"
    done

    if [ -z "$slugs" ]; then
        printf "%s\n" "$rows"
        return
    fi

    local esc_prefix
    esc_prefix=$(printf '%s' "$DEVA_CONTAINER_PREFIX" | sed -e 's/[.[\\^$*+?{}()|]/\\&/g')
    local pattern=""
    local slug escaped
    for slug in $slugs; do
        [ -n "$slug" ] || continue
        escaped=$(printf '%s' "$slug" | sed -e 's/[.[\\^$*+?{}()|]/\\&/g')
        local new_fmt="^${esc_prefix}--.*--${escaped}([.-]|$)"
        local old_fmt="^${esc_prefix}-${escaped}([.-]|$)"
        if [ -n "$pattern" ]; then
            pattern="${pattern}|(${new_fmt})|(${old_fmt})"
        else
            pattern="(${new_fmt})|(${old_fmt})"
        fi
    done

    if [ -z "$pattern" ]; then
        printf "%s\n" "$rows"
        return
    fi

    local filtered
    filtered=$(printf "%s\n" "$rows" | grep -E -- "$pattern" || true)

    if [ -n "$filtered" ]; then
        printf "%s\n" "$filtered"
    else
        printf "%s\n" "$rows"
    fi
}

extract_agent_from_name() {
    local name="$1"
    local rest="${name#"${DEVA_CONTAINER_PREFIX}"}"

    # New format: deva--<agent>--<auth>--<slug>..<hash>
    if [[ "$rest" =~ ^--([a-z]+)-- ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
    fi

    # Legacy ephemeral: deva-<slug>...-<agent>-<pid>
    if [[ "$rest" =~ -([a-z]+)-([0-9]+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
    fi

    printf 'share'
}

pick_container() {
    local rows
    rows=$(project_container_rows)
    if [ -z "$rows" ]; then
        echo "No running containers found for project $(basename "$(pwd)")" >&2
        return 1
    fi

    local count
    count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    if [ "$count" -eq 1 ]; then
        printf '%s\n' "${rows%%$'\t'*}"
        return 0
    fi

    local formatted
    formatted=$(printf '%s\n' "$rows" | while IFS=$'\t' read -r name status created; do
        printf '%s\t%s\t%s\t%s\n' "$name" "$(extract_agent_from_name "$name")" "$status" "$created"
    done)

    if command -v fzf >/dev/null 2>&1; then
        local selection
        selection=$(printf '%s\n' "$formatted" | fzf --with-nth=1,2,4 --prompt="Select container> " --height=15 --border)
        [ -n "$selection" ] || return 1
        printf '%s\n' "${selection%%$'\t'*}"
        return 0
    fi

    local idx=1
    printf 'Running containers:\n'
    printf '%s\n' "$formatted" | while IFS=$'\t' read -r name agent status created; do
        printf '  %d) %s\t[%s]\t%s\t%s\n' "$idx" "$name" "$agent" "$status" "$created"
        idx=$((idx + 1))
    done
    printf 'Select container (1-%d): ' "$((idx - 1))"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        local selected
        selected=$(printf '%s\n' "$formatted" | sed -n "${choice}p")
        printf '%s\n' "${selected%%$'\t'*}"
        return 0
    fi
    return 1
}

list_containers_pretty() {
    local rows
    rows=$(project_container_rows)
    if [ -z "$rows" ]; then
        echo "No running containers found for project $(basename "$(pwd)")"
        return
    fi

    local output
    output=$(
        {
            printf 'NAME\tAGENT\tSTATUS\tCREATED AT\n'
            printf '%s\n' "$rows" | while IFS=$'\t' read -r name status created; do
                printf '%s\t%s\t%s\t%s\n' "$name" "$(extract_agent_from_name "$name")" "$status" "$created"
            done
        }
    )

    if command -v column >/dev/null 2>&1; then
        printf '%s\n' "$output" | column -t -s $'\t'
    else
        printf '%s\n' "$output"
    fi
}

show_config() {
    echo "=== deva.sh Configuration Debug ==="
    echo ""
    echo "Active Agent: ${ACTIVE_AGENT:-<not set>}"
    echo "Default Agent: $DEFAULT_AGENT"
    echo "Config Home: ${CONFIG_HOME:-<none>}"
    echo "Config Home CLI: $CONFIG_HOME_FROM_CLI"
    echo ""

    if [ ${#LOADED_CONFIGS[@]} -gt 0 ]; then
        echo "Loaded config files (in order):"
        for cfg in "${LOADED_CONFIGS[@]}"; do
            echo "  - $cfg"
        done
    else
        echo "No config files loaded"
    fi
    echo ""

    if [ ${#USER_VOLUMES[@]} -gt 0 ]; then
        echo "Volume mounts:"
        for vol in "${USER_VOLUMES[@]}"; do
            echo "  -v $vol"
        done
    else
        echo "No volume mounts"
    fi
    echo ""

    if [ ${#USER_ENVS[@]} -gt 0 ]; then
        echo "Environment variables:"
        for env in "${USER_ENVS[@]}"; do
            if [[ "$env" =~ (API_KEY|TOKEN|SECRET|PASSWORD)= ]]; then
                echo "  -e ${env%%=*}=<masked>"
            else
                echo "  -e $env"
            fi
        done
    else
        echo "No environment variables"
    fi
    echo ""

    if [ ${#CODEX_CONFIG_OVERRIDES[@]} -gt 0 ]; then
        echo "Codex config overrides:"
        for cfg in "${CODEX_CONFIG_OVERRIDES[@]}"; do
            echo "  --config $cfg"
        done
        echo ""
    fi

    echo "Docker image: $(docker_image_ref)"
    echo "Container prefix: $DEVA_CONTAINER_PREFIX"
}

format_uptime() {
    local started="$1"
    local start_epoch now_epoch diff
    now_epoch=$(date +%s 2>/dev/null) || return 1

    if start_epoch=$(date -d "$started" +%s 2>/dev/null); then
        :
    elif start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${started%%.*}" +%s 2>/dev/null); then
        :
    else
        printf '%s' "${started%%T*}"
        return
    fi

    diff=$((now_epoch - start_epoch))
    [ $diff -ge 0 ] || diff=0

    if [ $diff -lt 60 ]; then
        printf '%ds' "$diff"
    elif [ $diff -lt 3600 ]; then
        printf '%dm' "$((diff / 60))"
    elif [ $diff -lt 86400 ]; then
        local h=$((diff / 3600)) m=$(((diff % 3600) / 60))
        if [ $m -gt 0 ]; then printf '%dh %dm' "$h" "$m"; else printf '%dh' "$h"; fi
    else
        local d=$((diff / 86400)) h=$(((diff % 86400) / 3600))
        if [ $h -gt 0 ]; then printf '%dd %dh' "$d" "$h"; else printf '%dd' "$d"; fi
    fi
}

categorize_mount() {
    local dest="$1" ws="$2"
    if [ "$dest" = "$ws" ]; then printf 'workspace'
    elif [ "$dest" = "/var/run/docker.sock" ]; then printf 'bridge'
    elif [[ "$dest" == /deva-host-chrome-bridge* ]]; then printf 'bridge'
    elif [[ "$dest" == /home/deva/.claude* ]] || [[ "$dest" == /home/deva/.codex* ]] || \
         [[ "$dest" == /home/deva/.gemini* ]] || [[ "$dest" == /home/deva/.grok* ]] || \
         [ "$dest" = "/home/deva/.agents" ]; then
        printf 'config'
    else printf 'user'
    fi
}

shorten_path() {
    local p="$1"
    if [[ "$p" == "$HOME"/* ]]; then
        printf '~/%s' "${p#"$HOME"/}"
    elif [ "$p" = "$HOME" ]; then
        printf '~'
    else
        printf '%s' "$p"
    fi
}

cmd_status() {
    local show_all=false verbose=false

    for tok in "${PRE_ARGS[@]}"; do
        case "$tok" in
            -g|--all|--global) show_all=true ;;
            --verbose) verbose=true ;;
        esac
    done

    if ! docker info >/dev/null 2>&1; then
        echo "[!!] Docker daemon is not running"
        exit 1
    fi

    local ws ws_hash slug
    ws="$(pwd)"
    ws_hash=$(workspace_hash)
    slug="$(generate_container_slug)"

    if [ "$show_all" = true ]; then
        printf 'deva status --global (v%s)\n\n' "$VERSION"
    else
        printf 'Workspace: %s\n' "$ws"
        printf '  hash %s  slug %s\n' "$ws_hash" "$slug"

        local xdg_home="${XDG_CONFIG_HOME:-$HOME/.config}"
        local config_files=(
            "$xdg_home/deva/.deva" "$HOME/.deva" ".deva" ".deva.local"
        )
        local found_configs=()
        for f in "${config_files[@]}"; do
            [ -f "$f" ] && found_configs+=("$(shorten_path "$f")")
        done
        if [ ${#found_configs[@]} -gt 0 ]; then
            printf '  config: %s\n' "${found_configs[*]}"
        fi
        echo ""
    fi

    local containers
    if [ "$show_all" = true ]; then
        containers=$(docker ps -a --filter "name=${DEVA_CONTAINER_PREFIX}--" --format '{{.Names}}' 2>/dev/null | sort)
    else
        containers=$(docker ps -a --filter "label=deva.workspace_hash=$ws_hash" --format '{{.Names}}' 2>/dev/null | sort)
        if [ -z "$containers" ]; then
            local escaped_slug
            escaped_slug=$(printf '%s' "$slug" | sed 's/[.[\\^$*+?{}()|]/\\&/g')
            containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | \
                grep -E "^${DEVA_CONTAINER_PREFIX}(--.*--${escaped_slug})(\\.\\.|-|$)" | sort || true)
        fi
    fi

    if [ -z "$containers" ]; then
        echo "Containers: (none)"
        echo ""
    else
        echo "Containers:"

        local has_jq=false
        command -v jq >/dev/null 2>&1 && has_jq=true

        while IFS= read -r name; do
            [ -n "$name" ] || continue

            if [ "$has_jq" = false ]; then
                local state_simple
                state_simple=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "?")
                printf '  %s  [%s]\n' "$name" "$state_simple"
                continue
            fi

            local inspect_json
            inspect_json=$(docker inspect "$name" 2>/dev/null) || continue

            local state agent shape image_label started_at
            state=$(printf '%s' "$inspect_json" | jq -r '.[0].State.Status')
            agent=$(printf '%s' "$inspect_json" | jq -r '.[0].Config.Labels["deva.agent"] // "?"')
            shape=$(printf '%s' "$inspect_json" | jq -r '.[0].Config.Labels["deva.shape_hash"] // "--"')
            image_label=$(printf '%s' "$inspect_json" | jq -r '.[0].Config.Labels["deva.image"] // .[0].Config.Image')
            started_at=$(printf '%s' "$inspect_json" | jq -r '.[0].State.StartedAt')

            local auth_tag="--"
            local session_dir="${DEVA_CONFIG_HOME:-$HOME/.config/deva}/sessions"
            local session_file="$session_dir/${name}.json"
            if [ -f "$session_file" ]; then
                auth_tag=$(jq -r '.auth.method // "--"' "$session_file" 2>/dev/null)
            else
                # build_container_name format: prefix--agent--auth_tag--slug..hash
                local namerest="${name#"${DEVA_CONTAINER_PREFIX}--"}"
                namerest="${namerest#*--}"
                auth_tag="${namerest%%--*}"
            fi

            local uptime_str="--"
            if [ "$state" = "running" ]; then
                uptime_str=$(format_uptime "$started_at")
            fi

            echo ""
            printf '  %s\n' "$name"
            printf '    agent: %-10s auth: %-16s status: %-8s' "$agent" "$auth_tag" "$state"
            [ "$state" = "running" ] && printf '  up: %s' "$uptime_str"
            echo ""

            if [ "$show_all" = true ]; then
                local ws_label
                ws_label=$(printf '%s' "$inspect_json" | jq -r '.[0].Config.Labels["deva.workspace"] // "--"')
                printf '    workspace: %s\n' "$ws_label"
            fi

            if [ "$state" = "running" ] || [ "$verbose" = true ]; then
                local mount_count
                mount_count=$(printf '%s' "$inspect_json" | jq '.[0].Mounts | length' 2>/dev/null)

                if [ "${mount_count:-0}" -gt 0 ] 2>/dev/null; then
                    local container_ws
                    if [ "$show_all" = true ]; then
                        container_ws=$(printf '%s' "$inspect_json" | jq -r '.[0].Config.Labels["deva.workspace"] // ""')
                    fi
                    : "${container_ws:=$ws}"

                    echo "    mounts:"
                    printf '%s' "$inspect_json" | jq -r '.[0].Mounts[] | "\(.Source)\t\(.Destination)\t\(.RW)"' 2>/dev/null | \
                    while IFS=$'\t' read -r src dest rw; do
                        local mode="rw"
                        [ "$rw" = "true" ] || mode="ro"
                        local category
                        category=$(categorize_mount "$dest" "$container_ws")
                        printf '      %-42s -> %-30s %s  (%s)\n' "$(shorten_path "$src")" "$dest" "$mode" "$category"
                    done | sort -t'(' -k2
                fi

                if [ "$verbose" = true ]; then
                    echo "    env:"
                    printf '%s' "$inspect_json" | jq -r '.[0].Config.Env[]' 2>/dev/null | sort | \
                    while IFS= read -r env_line; do
                        local env_name="${env_line%%=*}"
                        case "$env_name" in
                            *KEY*|*TOKEN*|*SECRET*|*PASSWORD*|*CREDENTIALS*)
                                printf '      %s=<redacted>\n' "$env_name"
                                ;;
                            PATH|HOME|HOSTNAME|TERM|DEBIAN_FRONTEND|SHELL)
                                ;;
                            *)
                                printf '      %s\n' "$env_line"
                                ;;
                        esac
                    done
                fi
            fi
        done <<< "$containers"
        echo ""
    fi

    local config_root
    if [ -n "${CONFIG_ROOT:-}" ]; then
        config_root="$CONFIG_ROOT"
    else
        config_root="${XDG_CONFIG_HOME:-$HOME/.config}/deva"
    fi

    if [ -d "$config_root" ]; then
        echo "Agent Homes ($(shorten_path "$config_root")):"
        for agent_name in claude codex gemini grok; do
            local agent_dir="$config_root/$agent_name"
            if [ -d "$agent_dir" ]; then
                local canonical="" other_count=0 entry is_canonical
                while IFS= read -r entry; do
                    [ -n "$entry" ] || continue
                    is_canonical=false
                    case "$agent_name:$entry" in
                        claude:.claude|claude:.claude.json) is_canonical=true ;;
                        codex:.codex) is_canonical=true ;;
                        gemini:.gemini) is_canonical=true ;;
                        grok:.grok) is_canonical=true ;;
                    esac
                    if [ "$is_canonical" = true ]; then
                        if [ -L "$agent_dir/$entry" ]; then
                            canonical="${canonical} ${entry}@"
                        else
                            canonical="${canonical} ${entry}"
                        fi
                    else
                        other_count=$((other_count + 1))
                    fi
                done < <(ls -1A "$agent_dir" 2>/dev/null)
                local line="${canonical:- (no canonical entries)}"
                [ "$other_count" -gt 0 ] && line="${line}  (+${other_count} other)"
                printf '  %-10s%s\n' "$agent_name" "$line"
            else
                printf '  %-10s--\n' "$agent_name"
            fi
        done
        echo ""
    fi

    echo "Health:"

    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
    printf '  [ok] Docker %s\n' "$docker_version"

    local img_ref
    img_ref="$(docker_image_ref)"
    if docker image inspect "$img_ref" >/dev/null 2>&1; then
        local img_created img_size
        img_created=$(docker image inspect "$img_ref" --format '{{.Created}}' 2>/dev/null)
        img_created="${img_created%%T*}"
        img_size=$(docker image inspect "$img_ref" --format '{{.Size}}' 2>/dev/null)
        if [ -n "$img_size" ] && [ "$img_size" -gt 0 ] 2>/dev/null; then
            img_size="$(( img_size / 1048576 ))MB"
        fi
        printf '  [ok] Image %s (%s' "$img_ref" "$img_created"
        [ -n "${img_size:-}" ] && printf ', %s' "$img_size"
        printf ')\n'
    else
        printf '  [!!] Image %s not found locally\n' "$img_ref"
    fi

    if [ -S /var/run/docker.sock ]; then
        if [ -z "${DEVA_NO_DOCKER:-}" ]; then
            printf '  [ok] Docker socket (auto-mounted)\n'
        else
            printf '  [--] Docker socket (DEVA_NO_DOCKER set)\n'
        fi
    else
        printf '  [--] Docker socket not found\n'
    fi

    local session_dir="${DEVA_CONFIG_HOME:-$HOME/.config/deva}/sessions"
    if [ -d "$session_dir" ]; then
        local session_count
        session_count=$(find "$session_dir" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
        [ "${session_count:-0}" -gt 0 ] && printf '  [ok] %s session file(s)\n' "$session_count"
    fi
}

inject_workspace_context() {
    local ws="$(pwd)"
    local marker="<!-- deva:container-context -->"
    local end_marker="<!-- /deva:container-context -->"
    local docker_line="" persist_line=""

    [ -z "${DEVA_NO_DOCKER:-}" ] && [ -S /var/run/docker.sock ] && \
        docker_line="- Docker is available (socket mounted from host)."
    if [ "$EPHEMERAL_MODE" = true ]; then
        persist_line="- Ephemeral container. Installed packages will not persist."
    else
        persist_line="- System packages and build caches persist across sessions."
    fi

    local context
    context="$(cat <<'CTX'
# Container Environment (deva)

You are inside a Docker container running Ubuntu Linux 24.04 LTS
(Noble Numbat), not on the host machine. The workspace is a
bind-mount from the host at the same absolute path, but the
runtime is Linux.

- This is Linux. Host-only tools (open, pbcopy, pbpaste, sw_vers,
  diskutil, defaults, launchctl) are not available.
- No display server. Browsers and GUI tools will not work.
- Hard links (`ln` without -s) fail across mount boundaries.
  Use `cp` or relative symbolic links (`ln -sr`).
- Prefer relative paths for project-internal references.
  Absolute paths work here but are container-specific.
- $HOME is /home/deva (not /root). sudo works without password.
- Pre-installed: Node.js, Python (use `uv`, not pip), Go, git,
  gh, make, curl. pip is NOT in PATH.
CTX
)"
    [ -n "$docker_line" ] && context="${context}
${docker_line}"
    context="${context}
${persist_line}
- Container details are in DEVA_* environment variables."

    local target
    mkdir -p "$ws/.claude" 2>/dev/null || true
    for target in "$ws/.claude/CLAUDE.md" "$ws/AGENTS.md"; do
        if [ -f "$target" ] && grep -qF "$marker" "$target"; then
            awk -v m="$marker" -v e="$end_marker" \
                '$0==m{skip=1;next} $0==e{skip=0;next} !skip' \
                "$target" > "${target}.deva.tmp" && mv "${target}.deva.tmp" "$target"
        fi
        {
            [ -s "$target" ] && printf '\n'
            printf '%s\n' "$marker"
            printf '%s\n' "$context"
            printf '%s\n' "$end_marker"
        } >> "$target"
    done
}

parse_ccx_args() {
    CCX_ARGS=()
    local found_cmd=false
    for tok in "${PRE_ARGS[@]}"; do
        if [ "$found_cmd" = false ]; then
            case "$tok" in sessions|session|insight|ccx) found_cmd=true ;; esac
            continue
        fi
        case "$tok" in -g|--global|--dry-run|--debug|--verbose) ;; *) CCX_ARGS+=("$tok") ;; esac
    done
    if [ ${#POST_ARGS[@]} -gt 0 ]; then
        CCX_ARGS+=("${POST_ARGS[@]}")
    fi
    if [ "$MANAGEMENT_MODE" = "sessions" ]; then
        CCX_ARGS=("sessions" ${CCX_ARGS[@]+"${CCX_ARGS[@]}"})
    elif [ "$MANAGEMENT_MODE" = "insight" ]; then
        CCX_ARGS=("insight" ${CCX_ARGS[@]+"${CCX_ARGS[@]}"})
    fi
}

prepare_base_docker_args() {
    local container_name
    local slug
    slug="$(generate_container_slug)"

    local volume_input=""
    if [ ${#USER_VOLUMES[@]} -gt 0 ]; then
        volume_input=$(printf '%s\n' "${USER_VOLUMES[@]}" | sort | tr '\n' '|')
    fi

    local config_input=""
    if [ "$CONFIG_HOME_FROM_CLI" = true ]; then
        if [ -n "$CONFIG_HOME" ]; then
            config_input="$CONFIG_HOME"
        elif [ -n "$CONFIG_ROOT" ]; then
            config_input="$CONFIG_ROOT"
        fi
    fi

    local image_ref
    image_ref="$(docker_image_ref)"
    local shape_hash
    shape_hash=$(compute_shape_hash "$image_ref" "$volume_input" "$config_input")

    local auth_tag="auth-default"
    container_name=$(build_container_name \
        "$DEVA_CONTAINER_PREFIX" "$ACTIVE_AGENT" "$auth_tag" \
        "$slug" "$shape_hash" "$EPHEMERAL_MODE" "$$")

    if [ "$EPHEMERAL_MODE" = true ]; then
        DOCKER_ARGS=(run --rm "${DOCKER_TERMINAL_ARGS[@]}")
    else
        DOCKER_ARGS=(run -d)
    fi

    DOCKER_ARGS+=(
        --name "$container_name"
        -v "$(pwd):$(pwd)"
        -w "$(pwd)"
        -e "WORKDIR=$(pwd)"
        -e "DEVA_AGENT=${ACTIVE_AGENT}"
        -e "DEVA_UID=$(id -u)"
        -e "DEVA_GID=$(id -g)"
        --shm-size=2g
        --add-host host.docker.internal:host-gateway
    )

    local ws_hash
    ws_hash=$(workspace_hash)
    DOCKER_ARGS+=(
        --label "deva.prefix=${DEVA_CONTAINER_PREFIX}"
        --label "deva.slug=${slug}"
        --label "deva.workspace=$(pwd)"
        --label "deva.workspace_hash=${ws_hash}"
        --label "deva.agent=${ACTIVE_AGENT}"
        --label "deva.ephemeral=${EPHEMERAL_MODE}"
        --label "deva.image=$image_ref"
        --label "deva.shape_hash=${shape_hash}"
    )

    if [ -n "${LANG:-}" ]; then DOCKER_ARGS+=(-e "LANG=$LANG"); fi
    if [ -n "${LC_ALL:-}" ]; then DOCKER_ARGS+=(-e "LC_ALL=$LC_ALL"); fi
    if [ -n "${TZ:-}" ]; then DOCKER_ARGS+=(-e "TZ=$TZ"); fi

    # Auto-mount Docker socket for DinD workflows (opt-out via --no-docker or DEVA_NO_DOCKER=1)
    if [ -z "${DEVA_NO_DOCKER:-}" ] && [ -S /var/run/docker.sock ]; then
        DOCKER_ARGS+=(-v "/var/run/docker.sock:/var/run/docker.sock")
    fi

    # Fallback: detect host TZ/LANG if not set in env
    if ! docker_args_has_env "TZ"; then
        local host_tz=""
        if command -v timedatectl >/dev/null 2>&1; then
            host_tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
        fi
        if [ -z "$host_tz" ] && [ -L "/etc/localtime" ]; then
            local tz_target
            tz_target=$(readlink "/etc/localtime" 2>/dev/null || true)
            case "$tz_target" in
            */zoneinfo/*)
                host_tz="${tz_target##*/zoneinfo/}"
                ;;
            esac
        fi
        if [ -z "$host_tz" ] && command -v systemsetup >/dev/null 2>&1; then
            host_tz=$(systemsetup -gettimezone 2>/dev/null | awk -F': ' '{print $2}')
        fi
        if [ -n "$host_tz" ]; then DOCKER_ARGS+=(-e "TZ=$host_tz"); fi
    fi

    if ! docker_args_has_env "LANG"; then
        local host_lang
        host_lang=$(locale 2>/dev/null | awk -F= '/^LANG=/{gsub(/"/, ""); print $2}')
        if [ -n "$host_lang" ]; then DOCKER_ARGS+=(-e "LANG=$host_lang"); fi
    fi
    if ! docker_args_has_env "LC_ALL"; then
        local host_lc_all
        host_lc_all=$(locale 2>/dev/null | awk -F= '/^LC_ALL=/{gsub(/"/, ""); print $2}')
        if [ -n "$host_lc_all" ]; then DOCKER_ARGS+=(-e "LC_ALL=$host_lc_all"); fi
    fi
    if [ -n "${GIT_AUTHOR_NAME:-}" ]; then DOCKER_ARGS+=(-e "GIT_AUTHOR_NAME=$GIT_AUTHOR_NAME"); fi
    if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then DOCKER_ARGS+=(-e "GIT_AUTHOR_EMAIL=$GIT_AUTHOR_EMAIL"); fi
    if [ -n "${GIT_COMMITTER_NAME:-}" ]; then DOCKER_ARGS+=(-e "GIT_COMMITTER_NAME=$GIT_COMMITTER_NAME"); fi
    if [ -n "${GIT_COMMITTER_EMAIL:-}" ]; then DOCKER_ARGS+=(-e "GIT_COMMITTER_EMAIL=$GIT_COMMITTER_EMAIL"); fi
    if [ -n "${GH_TOKEN:-}" ]; then DOCKER_ARGS+=(-e "GH_TOKEN=$GH_TOKEN"); fi
    if [ -n "${GITHUB_TOKEN:-}" ]; then DOCKER_ARGS+=(-e "GITHUB_TOKEN=$GITHUB_TOKEN"); fi
    if [ -n "${OPENAI_API_KEY:-}" ]; then USER_ENVS+=("OPENAI_API_KEY=$OPENAI_API_KEY"); fi
    if [ -n "${OPENAI_ORGANIZATION:-}" ]; then USER_ENVS+=("OPENAI_ORGANIZATION=$OPENAI_ORGANIZATION"); fi
    if [ -n "${OPENAI_BASE_URL:-}" ]; then USER_ENVS+=("OPENAI_BASE_URL=$OPENAI_BASE_URL"); fi
    if [ -n "${openai_base_url:-}" ]; then USER_ENVS+=("openai_base_url=${openai_base_url}"); fi

    if [ -n "${HTTP_PROXY:-}" ]; then
        DOCKER_ARGS+=(-e "HTTP_PROXY=$(translate_localhost "$HTTP_PROXY")")
    elif [ -n "${http_proxy:-}" ]; then
        DOCKER_ARGS+=(-e "HTTP_PROXY=$(translate_localhost "$http_proxy")")
    fi
    if [ -n "${HTTPS_PROXY:-}" ]; then
        DOCKER_ARGS+=(-e "HTTPS_PROXY=$(translate_localhost "$HTTPS_PROXY")")
    elif [ -n "${https_proxy:-}" ]; then
        DOCKER_ARGS+=(-e "HTTPS_PROXY=$(translate_localhost "$https_proxy")")
    fi
    if [ -n "${NO_PROXY:-}" ]; then
        DOCKER_ARGS+=(-e "NO_PROXY=$NO_PROXY")
    elif [ -n "${no_proxy:-}" ]; then
        DOCKER_ARGS+=(-e "NO_PROXY=$no_proxy")
    fi
}

volume_spec_target() {
    local spec="$1"
    [[ "$spec" == *:* ]] || return 1
    local remainder="${spec#*:}"
    printf '%s' "${remainder%%:*}"
}

user_volumes_declares_target() {
    local target="$1" spec declared
    for spec in "${USER_VOLUMES[@]+"${USER_VOLUMES[@]}"}"; do
        declared="$(volume_spec_target "$spec")" || continue
        [ "$declared" = "$target" ] && return 0
    done
    return 1
}

# First-writer-wins dedup over USER_VOLUMES by container target.
# parse_wrapper_args (CLI -v) runs before load_config_sources (.deva
# VOLUME=), so CLI entries land at lower indices. Keeping the first
# occurrence per target means CLI overrides .deva at the same path.
dedup_user_volumes() {
    [ ${#USER_VOLUMES[@]} -gt 1 ] || return 0
    local -a result=()
    local i j keep spec_i spec_j tgt_i tgt_j
    for ((i = 0; i < ${#USER_VOLUMES[@]}; i++)); do
        spec_i="${USER_VOLUMES[$i]}"
        tgt_i="$(volume_spec_target "$spec_i")" || { result+=("$spec_i"); continue; }
        keep=1
        for ((j = 0; j < i; j++)); do
            spec_j="${USER_VOLUMES[$j]}"
            tgt_j="$(volume_spec_target "$spec_j")" || continue
            if [ "$tgt_j" = "$tgt_i" ]; then
                keep=0
                break
            fi
        done
        [ "$keep" = 1 ] && result+=("$spec_i")
    done
    USER_VOLUMES=("${result[@]}")
}

append_user_volumes() {
    if [ ${#USER_VOLUMES[@]} -eq 0 ]; then
        return
    fi

    local mount
    local warned=false
    for mount in "${USER_VOLUMES[@]}"; do
        if [[ "$mount" == *:/root/* ]] && [ "$warned" = false ]; then
            echo "WARNING: Detected volume mount to /root/* path" >&2
            echo "  Mount: $mount" >&2
            echo "  Container user changed from /root to /home/deva in v0.7.0" >&2
            echo "  Please update mounts: /root/* → /home/deva/*" >&2
            echo "" >&2
            warned=true
        fi
        DOCKER_ARGS+=(-v "$mount")
    done
}

docker_args_has_env() {
    local name="$1"
    local i
    for ((i = 0; i < ${#DOCKER_ARGS[@]}; i++)); do
        if [ "${DOCKER_ARGS[$i]}" = "-e" ] && [ $((i + 1)) -lt ${#DOCKER_ARGS[@]} ]; then
            local spec="${DOCKER_ARGS[$((i + 1))]}"
            if [ "$spec" = "$name" ] || [[ "$spec" == "$name="* ]]; then
                return 0
            fi
        fi
    done
    return 1
}

should_skip_env_for_auth() {
    local name="$1"

    case "$ACTIVE_AGENT" in
    claude)
        case "${AUTH_METHOD:-claude}" in
        claude)
            case "$name" in
            ANTHROPIC_API_KEY | ANTHROPIC_AUTH_TOKEN | ANTHROPIC_BASE_URL | CLAUDE_CODE_OAUTH_TOKEN | OPENAI_API_KEY | OPENAI_BASE_URL | openai_base_url)
                return 0
                ;;
            esac
            ;;
        api-key | oat)
            case "$name" in
            ANTHROPIC_API_KEY | ANTHROPIC_AUTH_TOKEN | ANTHROPIC_BASE_URL | CLAUDE_CODE_OAUTH_TOKEN | OPENAI_API_KEY | OPENAI_BASE_URL | openai_base_url)
                return 0
                ;;
            esac
            ;;
        copilot)
            case "$name" in
            ANTHROPIC_API_KEY | ANTHROPIC_AUTH_TOKEN | ANTHROPIC_BASE_URL | CLAUDE_CODE_OAUTH_TOKEN)
                return 0
                ;;
            esac
            ;;
        bedrock | vertex | credentials-file)
            case "$name" in
            ANTHROPIC_API_KEY | ANTHROPIC_AUTH_TOKEN | ANTHROPIC_BASE_URL | CLAUDE_CODE_OAUTH_TOKEN | OPENAI_API_KEY | OPENAI_BASE_URL | openai_base_url)
                return 0
                ;;
            esac
            ;;
        esac
        ;;
    codex)
        case "${AUTH_METHOD:-chatgpt}" in
        chatgpt)
            case "$name" in
            OPENAI_API_KEY | OPENAI_BASE_URL | openai_base_url)
                return 0
                ;;
            esac
            ;;
        api-key)
            case "$name" in
            OPENAI_API_KEY | OPENAI_BASE_URL | openai_base_url | ANTHROPIC_API_KEY | ANTHROPIC_BASE_URL)
                return 0
                ;;
            esac
            ;;
        copilot)
            case "$name" in
            OPENAI_API_KEY | OPENAI_BASE_URL | openai_base_url)
                return 0
                ;;
            esac
            ;;
        credentials-file)
            case "$name" in
            OPENAI_API_KEY | OPENAI_BASE_URL | openai_base_url | ANTHROPIC_API_KEY | ANTHROPIC_BASE_URL)
                return 0
                ;;
            esac
            ;;
        esac
        ;;
    gemini)
        case "${AUTH_METHOD:-oauth}" in
        oauth | gemini-app-oauth)
            case "$name" in
            GOOGLE_API_KEY | GEMINI_API_KEY | ANTHROPIC_API_KEY | ANTHROPIC_BASE_URL | OPENAI_API_KEY | OPENAI_BASE_URL)
                return 0
                ;;
            esac
            ;;
        api-key | gemini-api-key)
            case "$name" in
            GOOGLE_API_KEY | GEMINI_API_KEY)
                return 0
                ;;
            esac
            ;;
        vertex)
            case "$name" in
            GOOGLE_API_KEY | GEMINI_API_KEY | ANTHROPIC_API_KEY | OPENAI_API_KEY)
                return 0
                ;;
            esac
            ;;
        compute-adc)
            case "$name" in
            GOOGLE_API_KEY | GEMINI_API_KEY | ANTHROPIC_API_KEY | OPENAI_API_KEY)
                return 0
                ;;
            esac
            ;;
        credentials-file)
            case "$name" in
            GOOGLE_API_KEY | GEMINI_API_KEY | ANTHROPIC_API_KEY | OPENAI_API_KEY)
                return 0
                ;;
            esac
            ;;
        esac
        ;;
    grok)
        case "${AUTH_METHOD:-oauth}" in
        oauth)
            case "$name" in
            XAI_API_KEY | ANTHROPIC_API_KEY | ANTHROPIC_BASE_URL | OPENAI_API_KEY | OPENAI_BASE_URL)
                return 0
                ;;
            esac
            ;;
        api-key)
            case "$name" in
            XAI_API_KEY)
                return 0
                ;;
            esac
            ;;
        esac
        ;;
    esac

    return 1
}

append_user_envs() {
    if [ ${#USER_ENVS[@]} -eq 0 ]; then
        return
    fi

    local env_spec name
    for env_spec in "${USER_ENVS[@]}"; do
        if [[ "$env_spec" == *"="* ]]; then
            name="${env_spec%%=*}"
        else
            name="$env_spec"
        fi

        if [ -z "$name" ]; then
            continue
        fi

        if should_skip_env_for_auth "$name"; then
            continue
        fi

        if docker_args_has_env "$name"; then
            continue
        fi

        DOCKER_ARGS+=(-e "$env_spec")
    done
}

append_extra_docker_args() {
    if [ ${#EXTRA_DOCKER_ARGS[@]} -eq 0 ]; then
        return
    fi

    local arg
    for arg in "${EXTRA_DOCKER_ARGS[@]}"; do
        DOCKER_ARGS+=("$arg")
    done
}

# Canonical dotfile-entries per agent. These are the ONLY items deva should
# rehome into the container from an agent's config subdir. Everything else
# sitting loose under ~/.config/deva/<agent>/ is agent runtime state
# (sessions, statsig, shell snapshots, backup files, stray auth.json
# variants) that belongs to the agent itself — not siblings to surface at
# the container's $HOME root.
agent_canonical_basenames() {
    case "$1" in
    claude) printf '%s\n' '.claude' '.claude.json' ;;
    codex)  printf '%s\n' '.codex' ;;
    gemini) printf '%s\n' '.gemini' ;;
    grok)   printf '%s\n' '.grok' ;;
    *)      return 0 ;;
    esac
}

# grok api-key contract (#403): pass XAI_API_KEY, mount no auth dir.
# grok's credential priority is model.api_key > model.env_key > session
# token > XAI_API_KEY, so anything a mounted ~/.grok carries (config.toml
# per-model keys, auth.json session) can outrank the exported key and
# silently bill another account.
grok_api_key_no_mount() {
    [ "$ACTIVE_AGENT" = "grok" ] && [ "${AUTH_METHOD:-}" = "api-key" ]
}

# grok's self-updater writes Linux binaries into ~/.grok/bin and
# ~/.grok/downloads — inside the auth dir we bind-mount. Verified against
# @xai-official/grok 0.2.93: a mounted config.toml without the npm installer
# marker flips the updater to installer=internal, and `grok update` then
# re-creates both dirs on the mount (worst case: Linux binary shadowing a
# macOS host CLI via the host npm trampoline). Whenever a host dir lands at
# /home/deva/.grok, overlay those two paths with container-local tmpfs so
# updater writes die with the container instead of poisoning the host.
append_grok_update_guard() {
    local arg
    for arg in "${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"}"; do
        case "$arg" in
        *:/home/deva/.grok | *:/home/deva/.grok:*)
            DOCKER_ARGS+=(
                --tmpfs "/home/deva/.grok/bin:uid=$(id -u),gid=$(id -g),mode=0755,size=512m"
                --tmpfs "/home/deva/.grok/downloads:uid=$(id -u),gid=$(id -g),mode=0755,size=512m"
            )
            return 0
            ;;
        esac
    done
    return 0
}

# Mount the canonical entries for one agent from a source directory.
# Host-side CLI -v or .deva VOLUME= at the same container target wins
# (user_volumes_declares_target suppression; first-writer-wins holds).
mount_agent_canonical() {
    local agent="$1"
    local src_dir="$2"
    [ -n "$agent" ] && [ -d "$src_dir" ] || return 0
    if [ "$agent" = "grok" ] && grok_api_key_no_mount; then
        return 0
    fi

    local entry src
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        src="$src_dir/$entry"
        [ -e "$src" ] || continue
        if user_volumes_declares_target "/home/deva/$entry"; then
            continue
        fi
        DOCKER_ARGS+=(-v "$src:/home/deva/$entry")
    done < <(agent_canonical_basenames "$agent")
}

# Return 0 if the subdir name corresponds to a known agent (agents/<name>.sh
# exists). Anything else under CONFIG_ROOT (sessions/, cache/, adhoc dirs)
# is NOT an agent home and must not be walked.
is_known_agent_subdir() {
    local name="$1"
    [ -n "$AGENTS_DIR" ] || return 1
    [ -f "$AGENTS_DIR/$name.sh" ]
}

mount_config_home() {
    # Explicit --config-home DIR: treat DIR as the active agent's home and
    # emit only its canonical entries.
    [ -n "$CONFIG_HOME" ] || return 0
    mount_agent_canonical "$ACTIVE_AGENT" "$CONFIG_HOME"
}

# Effective config base: where agent config dirs (.claude/, .codex/, .gemini/, .grok/) live.
resolve_config_base() {
    if [ -n "$CONFIG_HOME" ]; then
        printf '%s' "$CONFIG_HOME"
    elif [ -n "$CONFIG_ROOT" ]; then
        printf '%s' "$CONFIG_ROOT/$ACTIVE_AGENT"
    else
        printf '%s' "$HOME"
    fi
}

user_envs_has() {
    local name="$1" spec
    for spec in "${USER_ENVS[@]+"${USER_ENVS[@]}"}"; do
        [ "$spec" = "$name" ] || [[ "$spec" == "$name="* ]] && return 0
    done
    return 1
}

# Detect auth override: non-default --auth-with OR auth env vars reaching container.
# Claude Code auth priority: env vars > .credentials.json (file is lowest priority).
# When env-var auth is active, mounting credential files is a leak + corruption risk.
# Only counts env vars that survive should_skip_env_for_auth filtering.
has_auth_override() {
    # Non-default --auth-with
    if [ -n "${AUTH_METHOD:-}" ]; then
        case "${ACTIVE_AGENT}:${AUTH_METHOD}" in
            claude:claude|codex:chatgpt|gemini:oauth|gemini:gemini-app-oauth|grok:oauth) ;;
            *) return 0 ;;
        esac
    fi

    # Auth env vars that override file-based credentials.
    local auth_vars=""
    case "$ACTIVE_AGENT" in
        claude) auth_vars="ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN" ;;
        codex)  auth_vars="OPENAI_API_KEY" ;;
        gemini) auth_vars="GEMINI_API_KEY" ;;
        grok)   auth_vars="XAI_API_KEY" ;;
    esac

    local var
    for var in $auth_vars; do
        # Skip vars that would be blocked by auth-env filtering
        should_skip_env_for_auth "$var" && continue
        docker_args_has_env "$var" && return 0
        user_envs_has "$var" && return 0
    done

    return 1
}

backup_claude_json() {
    local config_base
    config_base=$(resolve_config_base)

    # .claude.json corruption backup: persistent, outside container mount tree.
    if [ "$ACTIVE_AGENT" = "claude" ]; then
        local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/deva/backups"
        local claude_json="$config_base/.claude.json"
        if [ -f "$claude_json" ]; then
            mkdir -p "$state_dir"
            cp "$claude_json" "$state_dir/.claude.json.bak"
        fi
    fi

}

default_credential_target_path() {
    case "$ACTIVE_AGENT" in
    claude)
        printf '%s' "/home/deva/.claude/.credentials.json"
        ;;
    codex)
        printf '%s' "/home/deva/.codex/auth.json"
        ;;
    gemini)
        printf '%s' "/home/deva/.gemini/mcp-oauth-tokens-v2.json"
        ;;
    grok)
        # api-key mode mounts no ~/.grok (grok_api_key_no_mount), but an
        # explicit user -v/.deva VOLUME can still carry one in; grok prefers
        # a session token over XAI_API_KEY, so blank-overlay auth.json anyway.
        printf '%s' "/home/deva/.grok/auth.json"
        ;;
    *)
        return 1
        ;;
    esac
}

append_auth_credential_overlay() {
    if ! has_auth_override; then
        return
    fi

    case "$ACTIVE_AGENT:$AUTH_METHOD" in
    claude:credentials-file | codex:credentials-file)
        # Explicit file mount already overlays the default auth file path.
        return
        ;;
    esac

    local target_path
    if ! target_path=$(default_credential_target_path); then
        return
    fi

    local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/deva/auth-overlays/$ACTIVE_AGENT"
    local overlay_key="${AUTH_METHOD:-default}"
    case "$ACTIVE_AGENT:$AUTH_METHOD" in
    claude:claude | codex:chatgpt | gemini:oauth | gemini:gemini-app-oauth | grok:oauth)
        overlay_key="env"
        ;;
    esac
    local overlay_file
    overlay_file="$state_dir/$(workspace_hash).${overlay_key}.blank"
    if [ "$DRY_RUN" != true ]; then
        mkdir -p "$state_dir"
        printf '{}\n' > "$overlay_file"
    fi
    DOCKER_ARGS+=("-v" "$overlay_file:$target_path")
}

normalize_volume_spec() {
    local spec="$1"
    if [[ "$spec" != *:* ]]; then
        echo "$spec"
        return
    fi

    local src="${spec%%:*}"
    local remainder="${spec#*:}"

    if [[ "$src" == ~* ]]; then
        src="$(expand_tilde "$src")"
    fi

    if [[ "$src" == ./* || "$src" == ../* ]]; then
        src="$(absolute_path "$src")"
    elif [[ "$src" == /* ]]; then
        :
    elif [[ "$src" == .* ]]; then
        src="$(absolute_path "$src")"
    fi

    echo "$src:$remainder"
}

normalize_path_for_comparison() {
    _normalize_path "$1"
}

normalize_bind_source_for_comparison() {
    local path="$1"
    if [ -e "$path" ]; then
        canonical_path "$path"
        return
    fi
    normalize_path_for_comparison "$path"
}

path_is_strict_descendant() {
    # Python os.path.commonpath raises ValueError when mixing absolute and
    # relative inputs. Mirror that here: treat the mix as "not descendant".
    local parent child parent_abs=0 child_abs=0
    parent="$(_normalize_path "$1")"
    child="$(_normalize_path "$2")"
    case "$parent" in /*) parent_abs=1 ;; esac
    case "$child" in /*) child_abs=1 ;; esac

    [ "$parent_abs" = "$child_abs" ] || return 1
    [ "$parent" = "$child" ] && return 1

    if [ "$parent" = "/" ]; then
        case "$child" in /*) return 0 ;; *) return 1 ;; esac
    fi
    case "$child" in
        "$parent"/*) return 0 ;;
        *) return 1 ;;
    esac
}

relative_subpath() {
    # os.path.relpath(to, from) with inputs pre-normalized. Walks the common
    # prefix, emits '..' for each remaining from-segment, then appends what's
    # left of to. Python raises when mixing absolute/relative — we return 'to'
    # unchanged in that case (no current caller passes mixed kinds).
    local from to from_abs=0 to_abs=0
    from="$(_normalize_path "$1")"
    to="$(_normalize_path "$2")"

    case "$from" in /*) from_abs=1 ;; esac
    case "$to" in /*) to_abs=1 ;; esac

    if [ "$from_abs" != "$to_abs" ]; then
        printf '%s\n' "$to"
        return
    fi

    if [ "$from" = "$to" ]; then
        printf '.\n'
        return
    fi

    local fnorm tnorm
    if [ "$from_abs" = 1 ]; then
        fnorm="${from#/}"
        tnorm="${to#/}"
    else
        fnorm="$from"
        tnorm="$to"
    fi

    local IFS=/
    local -a fparts tparts
    # shellcheck disable=SC2206
    fparts=($fnorm)
    # shellcheck disable=SC2206
    tparts=($tnorm)
    IFS=$' \t\n'

    local i=0 max_i
    if [ "${#fparts[@]}" -lt "${#tparts[@]}" ]; then
        max_i="${#fparts[@]}"
    else
        max_i="${#tparts[@]}"
    fi
    while [ "$i" -lt "$max_i" ] && [ "${fparts[$i]}" = "${tparts[$i]}" ]; do
        i=$((i + 1))
    done

    local result="" j
    for ((j = i; j < ${#fparts[@]}; j++)); do
        if [ -z "$result" ]; then
            result=".."
        else
            result="$result/.."
        fi
    done
    for ((j = i; j < ${#tparts[@]}; j++)); do
        if [ -z "$result" ]; then
            result="${tparts[$j]}"
        else
            result="$result/${tparts[$j]}"
        fi
    done

    [ -z "$result" ] && result="."
    printf '%s\n' "$result"
}

is_recursive_bind_rebind() {
    local parent_src="$1"
    local parent_dest="$2"
    local child_src="$3"
    local child_dest="$4"

    if ! path_is_strict_descendant "$parent_src" "$child_src"; then
        return 1
    fi
    if ! path_is_strict_descendant "$parent_dest" "$child_dest"; then
        return 1
    fi

    [ "$(relative_subpath "$parent_src" "$child_src")" = "$(relative_subpath "$parent_dest" "$child_dest")" ]
}

validate_bind_mount_shape() {
    local mount_specs=()
    local mount_sources=()
    local mount_targets=()
    local i spec src remainder dest normalized_src normalized_dest

    for ((i = 0; i < ${#DOCKER_ARGS[@]}; i++)); do
        if [ "${DOCKER_ARGS[$i]}" != "-v" ] || [ $((i + 1)) -ge ${#DOCKER_ARGS[@]} ]; then
            continue
        fi

        spec="${DOCKER_ARGS[$((i + 1))]}"
        src="${spec%%:*}"
        remainder="${spec#*:}"
        dest="${remainder%%:*}"

        if [[ "$src" != /* ]] || [[ "$dest" != /* ]]; then
            continue
        fi

        normalized_src="$(normalize_bind_source_for_comparison "$src")"
        normalized_dest="$(normalize_path_for_comparison "$dest")"

        mount_specs+=("$spec")
        mount_sources+=("$normalized_src")
        mount_targets+=("$normalized_dest")
    done

    local j
    for ((i = 0; i < ${#mount_specs[@]}; i++)); do
        for ((j = i + 1; j < ${#mount_specs[@]}; j++)); do
            if [ "${mount_targets[$i]}" = "${mount_targets[$j]}" ]; then
                echo "error: duplicate bind mount target detected before container start" >&2
                echo "  ${mount_specs[$i]}" >&2
                echo "  ${mount_specs[$j]}" >&2
                exit 1
            fi

            if is_recursive_bind_rebind "${mount_sources[$i]}" "${mount_targets[$i]}" "${mount_sources[$j]}" "${mount_targets[$j]}"; then
                echo "error: recursive bind mount already covered by parent bind mount" >&2
                echo "  parent: ${mount_specs[$i]}" >&2
                echo "  child:  ${mount_specs[$j]}" >&2
                exit 1
            fi

            if is_recursive_bind_rebind "${mount_sources[$j]}" "${mount_targets[$j]}" "${mount_sources[$i]}" "${mount_targets[$i]}"; then
                echo "error: recursive bind mount already covered by parent bind mount" >&2
                echo "  parent: ${mount_specs[$j]}" >&2
                echo "  child:  ${mount_specs[$i]}" >&2
                exit 1
            fi
        done
    done
}

short_hash() {
    local input="$1"
    local length="${2:-8}"

    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$input" | sha256sum | cut -c1-"$length"
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$input" | shasum -a 256 | cut -c1-"$length"
    else
        printf '%s' "$input" | md5sum | cut -c1-"$length"
    fi
}

compute_volume_hash() {
    if [ ${#USER_VOLUMES[@]} -eq 0 ]; then
        return
    fi

    local hash_input=""
    local sorted_vols
    sorted_vols=$(printf '%s\n' "${USER_VOLUMES[@]}" | sort)

    while IFS= read -r vol; do
        [ -n "$vol" ] || continue
        local src="${vol%%:*}"

        if [ -e "$src" ]; then
            local abs_src
            abs_src=$(cd "$(dirname "$src")" 2>/dev/null && pwd)/$(basename "$src") || abs_src="$src"
            src="$abs_src"
        fi

        hash_input="${hash_input}${src}:${vol#*:}|"
    done <<<"$sorted_vols"

    [ -n "$hash_input" ] && short_hash "$hash_input" 8
}

workspace_hash() {
    if [ -n "$_WS_HASH_CACHE" ]; then
        printf '%s' "$_WS_HASH_CACHE"
        return
    fi

    local p
    p="$(pwd)"
    _WS_HASH_CACHE=$(short_hash "$p" 8)
    printf '%s' "$_WS_HASH_CACHE"
}

write_session_file() {
    local session_dir="${DEVA_CONFIG_HOME:-$HOME/.config/deva}/sessions"
    mkdir -p "$session_dir" 2>/dev/null || return 0

    local session_file="$session_dir/${CONTAINER_NAME}.json"
    local tmp_file="${session_file}.tmp.$$"

    # Build auth section with optional credential_file
    local auth_json
    if [ "${AUTH_METHOD:-}" = "credentials-file" ] && [ -n "${CUSTOM_CREDENTIALS_FILE:-}" ]; then
        auth_json=$(cat <<AUTHEOF
    "method": "${AUTH_METHOD:-default}",
    "details": "${AUTH_DETAILS:-}",
    "credential_file": "$CUSTOM_CREDENTIALS_FILE"
AUTHEOF
)
    else
        auth_json=$(cat <<AUTHEOF
    "method": "${AUTH_METHOD:-default}",
    "details": "${AUTH_DETAILS:-}"
AUTHEOF
)
    fi

    cat > "$tmp_file" 2>/dev/null <<EOF
{
  "container": "$CONTAINER_NAME",
  "agent": "$ACTIVE_AGENT",
  "workspace": "$(pwd)",
  "workspace_hash": "$(workspace_hash)",
  "auth": {
$auth_json
  },
  "ephemeral": $EPHEMERAL_MODE,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ)",
  "last_seen": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ)",
  "status": "running",
  "pid": $$
}
EOF
    [ -f "$tmp_file" ] && mv "$tmp_file" "$session_file" 2>/dev/null
}

update_session_file() {
    local session_dir="${DEVA_CONFIG_HOME:-$HOME/.config/deva}/sessions"
    local session_file="$session_dir/${CONTAINER_NAME}.json"

    [ -f "$session_file" ] || return 0

    if command -v jq >/dev/null 2>&1; then
        local ts
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ)
        jq --arg ts "$ts" \
           '.last_seen = $ts | .status = "running"' \
           "$session_file" > "${session_file}.tmp" 2>/dev/null && \
        mv "${session_file}.tmp" "$session_file" 2>/dev/null
    fi
}

remove_session_file() {
    local container_name="$1"
    local session_dir="${DEVA_CONFIG_HOME:-$HOME/.config/deva}/sessions"
    rm -f "$session_dir/${container_name}.json" 2>/dev/null
}

cleanup_stale_sessions() {
    local session_dir="${DEVA_CONFIG_HOME:-$HOME/.config/deva}/sessions"
    [ -d "$session_dir" ] || return 0

    local all_containers
    all_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null)

    for session in "$session_dir"/*.json; do
        [ -f "$session" ] || continue
        local name
        if command -v jq >/dev/null 2>&1; then
            name=$(jq -r '.container // empty' "$session" 2>/dev/null)
        else
            name=$(grep -o '"container"[[:space:]]*:[[:space:]]*"[^"]*"' "$session" | sed 's/.*: *"\([^"]*\)".*/\1/')
        fi

        [ -z "$name" ] && continue

        if ! echo "$all_containers" | grep -q "^${name}$"; then
            rm -f "$session" 2>/dev/null
        fi
    done
}

validate_env_name() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

expand_env_value() {
    local value="$1"
    local expanded="$value"

    while [[ "$expanded" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\} ]]; do
        local full_match="${BASH_REMATCH[0]}"
        local var_name="${BASH_REMATCH[1]}"
        local default_value="${BASH_REMATCH[3]}"
        local replacement="${!var_name:-$default_value}"
        expanded="${expanded//$full_match/$replacement}"
    done

    echo "$expanded"
}

validate_config_value() {
    local key="$1"
    local value="$2"

    case "$value" in
    *$'\x60'*)
        echo "Security violation in $key=$value (backticks not allowed)"
        return 1
        ;;
    esac

    # shellcheck disable=SC2016
    local marker='$('
    if [[ "$value" == *"$marker"* ]] && [[ "$value" == *')'* ]]; then
        local temp="$value"
        while [[ "$temp" == *"$marker"* && "$temp" == *')'* ]]; do
            local after_open="${temp#*"${marker}"}"
            local cmd="${after_open%%)*}"
            if [[ "$cmd" != "pwd" ]]; then
                echo "Security violation in $key=$value (only \$(pwd) allowed)"
                return 1
            fi
            temp="${after_open#*)}"
        done
    fi

    return 0
}

process_volume_config() {
    local value="$1"
    value="${value//\"/}"

    if ! validate_config_value "VOLUME" "$value"; then
        CONFIG_ERRORS+=("Invalid volume: $value")
        return 1
    fi

    value="${value/#\~/$HOME}"
    value="${value//\$(pwd)/$PWD}"
    value="${value//\$PWD/$PWD}"
    value="$(expand_env_value "$value")"

    local normalized
    normalized="$(normalize_volume_spec "$value")"
    if [[ "$normalized" != *:* ]]; then
        CONFIG_ERRORS+=("Invalid volume specification: $value")
        return 1
    fi

    USER_VOLUMES+=("$normalized")
}

process_env_config() {
    local value="$1"
    value="${value//\"/}"

    if ! validate_config_value "ENV" "$value"; then
        CONFIG_ERRORS+=("Invalid env: $value")
        return 1
    fi

    if [[ "$value" == *"="* ]]; then
        local name="${value%%=*}"
        local data="${value#*=}"
        if ! validate_env_name "$name"; then
            CONFIG_ERRORS+=("Invalid env name: $name")
            return 1
        fi
        data="$(expand_env_value "$data")"
        USER_ENVS+=("$name=$data")
    elif [[ "$value" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)$ ]] || [[ "$value" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
        local name
        name="${BASH_REMATCH[1]}"
        if [ -n "${!name-}" ]; then
            USER_ENVS+=("$name=${!name}")
        fi
    elif validate_env_name "$value" && [ -n "${!value-}" ]; then
        USER_ENVS+=("$value=${!value}")
    fi
}

process_var_config() {
    local name="$1"
    local value="$2"
    case "$name" in
    CODEX_CONFIG | CODEX_CLI_CONFIG)
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
            value="${value:1:${#value}-2}"
        fi
        ;;
    *)
        value="${value//\"/}"
        ;;
    esac

    if ! validate_config_value "$name" "$value"; then
        CONFIG_ERRORS+=("Validation failed for $name=$value")
        return 1
    fi

    value="${value/#\~/$HOME}"
    value="$(expand_env_value "$value")"

    case "$name" in
    CONFIG_HOME | CONFIG_DIR)
        if [ "$CONFIG_HOME_FROM_CLI" = false ]; then
            set_config_home_value "$value"
        fi
        ;;
    DEVA_DOCKER_IMAGE)
        DEVA_DOCKER_IMAGE="$value"
        DEVA_DOCKER_IMAGE_ENV_SET=true
        normalize_docker_image_parts
        export DEVA_DOCKER_IMAGE
        USER_ENVS+=("$name=$value")
        ;;
    DEVA_DOCKER_TAG)
        DEVA_DOCKER_TAG="$value"
        DEVA_DOCKER_TAG_ENV_SET=true
        normalize_docker_image_parts
        export DEVA_DOCKER_TAG
        USER_ENVS+=("$name=$value")
        ;;
    DEFAULT_AGENT)
        DEFAULT_AGENT="$value"
        ;;
    PROFILE)
        PROFILE="$value"
        ;;
    IMAGE_PROFILE)
        PROFILE="$value"
        ;;
    CODEX_BROWSER_MCP | CODEX_BROWSER | WITH_BROWSER | DEVA_CODEX_BROWSER_MCP | DEVA_WITH_BROWSER)
        if [[ "$value" =~ ^(true|1|yes)$ ]]; then
            CODEX_BROWSER_MCP=true
        else
            CODEX_BROWSER_MCP=false
        fi
        ;;
    CODEX_CONFIG | CODEX_CLI_CONFIG)
        CODEX_CONFIG_OVERRIDES+=("$value")
        ;;
    AUTOLINK)
        if [[ "$value" =~ ^(false|0|no)$ ]]; then AUTOLINK=false; else AUTOLINK=true; fi
        ;;
    HOST_NET)
        if [[ "$value" =~ ^(true|1|yes)$ ]]; then
            EXTRA_DOCKER_ARGS+=("--net" "host")
        fi
        ;;
    *)
        if validate_env_name "$name"; then
            export "$name"="$value"
            USER_ENVS+=("$name=$value")
        else
            CONFIG_ERRORS+=("Unknown config variable: $name")
        fi
        ;;
    esac
}

load_config_file() {
    local file="$1"
    [ -f "$file" ] || return

    local initial_errs=${#CONFIG_ERRORS[@]}

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        if [[ "$line" =~ ^[[:space:]]*VOLUME[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            process_volume_config "${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*ENV[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            process_env_config "${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            process_var_config "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        else
            CONFIG_ERRORS+=("Invalid line format in $file: $line")
        fi
    done <"$file"

    if [ ${#CONFIG_ERRORS[@]} -gt "$initial_errs" ]; then
        echo "ERROR: Config file $file has $((${#CONFIG_ERRORS[@]} - initial_errs)) issue(s)" >&2
        local idx
        for ((idx = initial_errs; idx < ${#CONFIG_ERRORS[@]}; idx++)); do
            echo "  ${CONFIG_ERRORS[$idx]}" >&2
        done
        exit 1
    fi

    LOADED_CONFIGS+=("$file")
}

load_config_sources() {
    if [ "$SKIP_CONFIG" = true ]; then
        return
    fi

    local xdg_home
    xdg_home="${XDG_CONFIG_HOME:-$HOME/.config}"

    local configs=(
        "$xdg_home/deva/.deva"
        "$HOME/.deva"
        ".deva"
        ".deva.local"
        "$xdg_home/claude-yolo/.claude-yolo"
        "$HOME/.claude-yolo"
        ".claude-yolo"
        ".claude-yolo.local"
    )

    local file
    for file in "${configs[@]}"; do
        [ -f "$file" ] || continue
        load_config_file "$file"
    done
}

parse_wrapper_args() {
    local -a incoming
    incoming=()
    while [ $# -gt 0 ]; do
        incoming+=("$1")
        shift
    done

    local -a remaining
    remaining=()
    local i=0
    while [ $i -lt ${#incoming[@]} ]; do
        local arg
        arg="${incoming[$i]}"
        case "$arg" in
        --)
            for ((j = i + 1; j < ${#incoming[@]}; j++)); do
                remaining+=("${incoming[$j]}")
            done
            break
            ;;
        -v)
            if [ $((i + 1)) -ge ${#incoming[@]} ]; then
                echo "error: -v requires a mount specification" >&2
                exit 1
            fi
            USER_VOLUMES+=("$(normalize_volume_spec "${incoming[$((i + 1))]}")")
            i=$((i + 2))
            continue
            ;;
        -e)
            if [ $((i + 1)) -ge ${#incoming[@]} ]; then
                echo "error: -e requires a variable specification" >&2
                exit 1
            fi
            local env_spec
            env_spec="${incoming[$((i + 1))]}"
            if [[ "$env_spec" == *"="* ]]; then
                USER_ENVS+=("$env_spec")
            else
                if ! validate_env_name "$env_spec"; then
                    echo "warning: invalid env name for -e: $env_spec" >&2
                else
                    local value="${!env_spec-}"
                    if [ -n "$value" ]; then
                        USER_ENVS+=("$env_spec=$value")
                    else
                        echo "warning: environment variable $env_spec not set; skipping" >&2
                    fi
                fi
            fi
            i=$((i + 2))
            continue
            ;;
        -c | --config-home)
            if [ $((i + 1)) -ge ${#incoming[@]} ]; then
                echo "error: --config-home requires a directory path" >&2
                exit 1
            fi
            local raw_dir
            raw_dir="${incoming[$((i + 1))]}"
            set_config_home_value "$raw_dir"
            CONFIG_HOME_FROM_CLI=true
            i=$((i + 2))
            continue
            ;;
        -p | --profile)
            if [ $((i + 1)) -ge ${#incoming[@]} ]; then
                echo "error: $arg requires a profile name" >&2
                exit 1
            fi
            local prof="${incoming[$((i + 1))]}"
            PROFILE="$prof"
            if ! validate_profile "$prof"; then
                echo "error: unknown profile '$prof'. Valid: base, rust." >&2
                echo "hint: if you intended '-p' for the agent, place it after '--' (e.g., deva.sh claude -- -p 'task')" >&2
                exit 1
            fi
            i=$((i + 2))
            continue
            ;;
        --no-autolink)
            AUTOLINK=false
            i=$((i + 1))
            continue
            ;;
        --no-config)
            SKIP_CONFIG=true
            i=$((i + 1))
            continue
            ;;
        --no-docker)
            export DEVA_NO_DOCKER=1
            i=$((i + 1))
            continue
            ;;
        --host-net)
            EXTRA_DOCKER_ARGS+=("--net" "host")
            i=$((i + 1))
            continue
            ;;
        --browser-mcp | --codex-browser-mcp | --with-browser)
            CODEX_BROWSER_MCP=true
            i=$((i + 1))
            continue
            ;;
        --rm)
            EPHEMERAL_MODE=true
            i=$((i + 1))
            continue
            ;;
        -Q | --quick)
            QUICK_MODE=true
            SKIP_CONFIG=true
            AUTOLINK=false
            EPHEMERAL_MODE=true
            i=$((i + 1))
            continue
            ;;
        -g | --global)
            GLOBAL_MODE=true
            i=$((i + 1))
            continue
            ;;
        --verbose | --debug)
            DEBUG_MODE=true
            i=$((i + 1))
            continue
            ;;
        --dry-run)
            DRY_RUN=true
            DEBUG_MODE=true
            i=$((i + 1))
            continue
            ;;
        *)
            remaining+=("$arg")
            i=$((i + 1))
            ;;
        esac
    done

    if [ ${#remaining[@]} -gt 0 ]; then
        AGENT_ARGS=("${remaining[@]}")
    else
        AGENT_ARGS=()
    fi
}

load_agent_module() {
    # shellcheck disable=SC1090
    source "$AGENTS_DIR/${ACTIVE_AGENT}.sh"
    if ! command -v agent_prepare >/dev/null 2>&1; then
        echo "error: agent module $ACTIVE_AGENT missing agent_prepare" >&2
        exit 1
    fi
}

resolve_profile() {
    local default_repo="ghcr.io/thevibeworks/deva"
    case "${PROFILE:-}" in
    "" | base)
        if [ "$DEVA_DOCKER_IMAGE_ENV_SET" = false ]; then
            DEVA_DOCKER_IMAGE="$default_repo"
        fi
        if [ "$DEVA_DOCKER_TAG_ENV_SET" = false ]; then
            DEVA_DOCKER_TAG="latest"
        fi
        ;;
    rust)
        if [ "$DEVA_DOCKER_IMAGE_ENV_SET" = false ]; then
            DEVA_DOCKER_IMAGE="$default_repo"
        fi
        if [ "$DEVA_DOCKER_TAG_ENV_SET" = false ]; then
            DEVA_DOCKER_TAG="rust"
        fi
        ;;
    *)
        if [ "$DEVA_DOCKER_IMAGE_ENV_SET" = false ] && [ -z "${DEVA_DOCKER_IMAGE:-}" ]; then
            DEVA_DOCKER_IMAGE="$default_repo"
        fi
        ;;
    esac
}

is_known_agent() { [ -f "$AGENTS_DIR/$1.sh" ]; }

ACTION="run"
MANAGEMENT_MODE="launch"
RAW_ARGS=("$@")
WRAPPER_ARGS=()
AGENT_ARGV=()
ACTIVE_AGENT=""
SENTINEL_IDX=-1
if [ ${#RAW_ARGS[@]} -gt 0 ]; then
    for i in "${!RAW_ARGS[@]}"; do
        if [ "${RAW_ARGS[$i]}" = "--" ]; then
            SENTINEL_IDX=$i
            break
        fi
    done
fi

PRE_ARGS=()
POST_ARGS=()
if [ "$SENTINEL_IDX" -ge 0 ]; then
    for ((i = 0; i < SENTINEL_IDX; i++)); do PRE_ARGS+=("${RAW_ARGS[$i]}"); done
    for ((i = SENTINEL_IDX + 1; i < ${#RAW_ARGS[@]}; i++)); do POST_ARGS+=("${RAW_ARGS[$i]}"); done
else
    if [ ${#RAW_ARGS[@]} -gt 0 ]; then
        PRE_ARGS=("${RAW_ARGS[@]}")
    else
        PRE_ARGS=()
    fi
fi

if [ ${#PRE_ARGS[@]} -gt 0 ]; then
    for tok in "${PRE_ARGS[@]}"; do
        case "$tok" in
        -g | --global)
            GLOBAL_MODE=true
            ;;
        esac
    done
fi

if [ ${#PRE_ARGS[@]} -gt 0 ]; then
    for tok in "${PRE_ARGS[@]}"; do
        case "$tok" in
        help | --help | -h)
            usage
            exit 0
            ;;
        --version)
            echo "deva.sh v${VERSION}"
            echo "Docker Image: $(docker_image_ref)"
            exit 0
            ;;
        --show-config)
            MANAGEMENT_MODE="show-config"
            ;;
        shell | --inspect)
            MANAGEMENT_MODE="shell"
            ;;
        ps | --ps)
            MANAGEMENT_MODE="ps"
            ;;
        stop)
            MANAGEMENT_MODE="stop"
            ;;
        rm | remove)
            MANAGEMENT_MODE="rm"
            ;;
        clean | prune)
            MANAGEMENT_MODE="clean"
            ;;
        status)
            MANAGEMENT_MODE="status"
            ;;
        sessions | session)
            MANAGEMENT_MODE="sessions"
            ;;
        insight)
            MANAGEMENT_MODE="insight"
            ;;
        ccx)
            MANAGEMENT_MODE="ccx"
            ;;
        esac
    done
fi

if [ "$MANAGEMENT_MODE" != "launch" ]; then
    if [ "$MANAGEMENT_MODE" = "ps" ]; then
        list_containers_pretty
        exit 0
    fi

    if [ "$MANAGEMENT_MODE" = "show-config" ]; then
        if [ ${#RAW_ARGS[@]} -gt 0 ]; then
            parse_wrapper_args "${RAW_ARGS[@]}"
        fi
        load_config_sources
        if [ ${#PRE_ARGS[@]} -gt 0 ]; then
            for tok in "${PRE_ARGS[@]}"; do
                if [[ "$tok" != -* ]] && [[ "$tok" != "help" ]] && [[ "$tok" != "shell" ]] && [[ "$tok" != "--inspect" ]] && [[ "$tok" != "--ps" ]] && [[ "$tok" != "--show-config" ]] && is_known_agent "$tok"; then
                    ACTIVE_AGENT="$tok"
                    break
                fi
            done
        fi
        if [ -z "$ACTIVE_AGENT" ]; then
            ACTIVE_AGENT="$DEFAULT_AGENT"
        fi
        resolve_profile
        show_config
        exit 0
    fi

    if [ "$MANAGEMENT_MODE" = "stop" ]; then
        container_name=$(pick_container) || {
            echo "error: no running containers found" >&2
            exit 1
        }
        echo "Stopping container: $container_name"
        docker stop "$container_name"
        exit 0
    fi

    if [ "$MANAGEMENT_MODE" = "rm" ]; then
        RM_ALL=false
        if [ ${#PRE_ARGS[@]} -gt 0 ]; then
            for tok in "${PRE_ARGS[@]}"; do
                case "$tok" in
                -a | --all | all) RM_ALL=true ;;
                esac
            done
        fi

        # Prefer label-based selection for current workspace
        ws_hash=$(workspace_hash)
        matching_names=$(docker ps -a --filter "label=deva.workspace_hash=$ws_hash" --format '{{.Names}}')
        if [ -z "$matching_names" ]; then
            if [ "$GLOBAL_MODE" = true ]; then
                matching_names=$(docker ps -a --filter "name=${DEVA_CONTAINER_PREFIX}-" --format '{{.Names}}')
            else
                slug="$(generate_container_slug)"
                escaped_slug=$(printf '%s' "$slug" | sed 's/[.[\\^$*+?{}()|]/\\&/g')
                rgx="^${DEVA_CONTAINER_PREFIX}(--.*--${escaped_slug}|-${escaped_slug})(\\.\\.|-|$)"
                all_names=$(docker ps -a --format '{{.Names}}')
                matching_names=$(echo "$all_names" | grep -E -- "$rgx" || true)
            fi
        fi

        if [ -z "$matching_names" ]; then
            echo "No deva containers found for this project"
            exit 0
        fi

        if [ "$RM_ALL" = true ]; then
            echo "Removing all containers for this workspace:"
            printf '%s\n' "$matching_names"
            while IFS= read -r n; do
                [ -n "$n" ] || continue
                if docker rm -f "$n" >/dev/null 2>&1; then
                    echo "  removed: $n"
                    remove_session_file "$n"
                else
                    echo "  failed:  $n" >&2
                fi
            done <<<"$matching_names"
        else
            container_count=$(echo "$matching_names" | wc -l | tr -d ' ')
            if [ "$container_count" -eq 1 ]; then
                container_name="$matching_names"
            else
                if command -v fzf >/dev/null 2>&1; then
                    container_name=$(printf '%s\n' "$matching_names" | fzf --prompt="Select container to remove> " --height=15 --border)
                else
                    i=1
                    mapfile -t _names < <(printf '%s\n' "$matching_names")
                    echo "Matching containers:"
                    for n in "${_names[@]}"; do
                        printf '  %d) %s\n' "$i" "$n"
                        i=$((i + 1))
                    done
                    printf 'Select container (1-%d): ' "${#_names[@]}"
                    read -r choice
                    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#_names[@]}" ]; then
                        container_name="${_names[$((choice - 1))]}"
                    else
                        container_name=""
                    fi
                fi
                if [ -z "${container_name:-}" ]; then
                    echo "error: no container selected" >&2
                    exit 1
                fi
            fi
            echo "Removing container: $container_name"
            docker rm -f "$container_name" && remove_session_file "$container_name"
        fi
        exit 0
    fi

    if [ "$MANAGEMENT_MODE" = "clean" ]; then
        echo "Removing all stopped deva containers..."
        if [ "$GLOBAL_MODE" = true ]; then
            matching_stopped=$(docker ps -a --filter "status=exited" --filter "name=${DEVA_CONTAINER_PREFIX}-" --format '{{.Names}}')
        else
            ws_hash=$(workspace_hash)
            matching_stopped=$(docker ps -a --filter "status=exited" --filter "label=deva.workspace_hash=$ws_hash" --format '{{.Names}}')
            if [ -z "$matching_stopped" ]; then
                slug="$(generate_container_slug)"
                escaped_slug=$(printf '%s' "$slug" | sed 's/[.[\\^$*+?{}()|]/\\&/g')
                rgx="^${DEVA_CONTAINER_PREFIX}(--.*--${escaped_slug}|-${escaped_slug})(\\.\\.|-|$)"
                all_stopped=$(docker ps -a --filter "status=exited" --format '{{.Names}}')
                matching_stopped=$(echo "$all_stopped" | grep -E -- "$rgx" || true)
            fi
        fi

        if [ -n "$matching_stopped" ]; then
            while IFS= read -r n; do
                [ -n "$n" ] || continue
                remove_session_file "$n"
            done <<<"$matching_stopped"
            echo "$matching_stopped" | xargs docker rm
            echo "Cleaned up stopped containers"
        else
            echo "No stopped containers found"
        fi

        # Clean up stale session files
        cleanup_stale_sessions
        exit 0
    fi

    if [ "$MANAGEMENT_MODE" = "status" ]; then
        cmd_status
        exit 0
    fi

    if [ "$MANAGEMENT_MODE" = "sessions" ] || [ "$MANAGEMENT_MODE" = "insight" ] || [ "$MANAGEMENT_MODE" = "ccx" ]; then
        parse_ccx_args

        if [ -n "${DEVA_CONTAINER_NAME:-}" ] && command -v ccx >/dev/null 2>&1; then
            exec ccx ${CCX_ARGS[@]+"${CCX_ARGS[@]}"}
        fi

        ccx_rows=$(project_container_rows)
        if [ -z "$ccx_rows" ]; then
            echo "No running containers. Start one first: deva.sh claude" >&2
            exit 1
        fi
        container_name="${ccx_rows%%$'\t'*}"

        exec docker exec "${DOCKER_TERMINAL_ARGS[@]}" "$container_name" \
            gosu deva env HOME=/home/deva \
            PATH=/home/deva/.local/bin:/home/deva/.npm-global/bin:/usr/local/bin:/usr/bin:/bin \
            ccx ${CCX_ARGS[@]+"${CCX_ARGS[@]}"}
    fi

    if [ "$MANAGEMENT_MODE" = "shell" ]; then
        container_name=$(pick_container) || exit 1
        echo "Opening shell in container: $container_name"
        exec docker exec -it "$container_name" gosu deva /bin/zsh -l
    fi
fi

agent_idx=-1
if [ ${#PRE_ARGS[@]} -gt 0 ]; then
    for i in "${!PRE_ARGS[@]}"; do
        tok="${PRE_ARGS[$i]}"
        if [[ "$tok" != -* ]] && is_known_agent "$tok"; then
            ACTIVE_AGENT="$tok"
            agent_idx=$i
            AGENT_EXPLICIT=true
            break
        fi
    done
fi

if [ -z "$ACTIVE_AGENT" ]; then
    ACTIVE_AGENT="$DEFAULT_AGENT"
    AGENT_EXPLICIT=false
fi

if [ ${#PRE_ARGS[@]} -gt 0 ]; then
    for i in "${!PRE_ARGS[@]}"; do
        if [ "$i" -eq "$agent_idx" ]; then continue; fi
        WRAPPER_ARGS+=("${PRE_ARGS[$i]}")
    done
fi

if [ ${#POST_ARGS[@]} -gt 0 ]; then
    AGENT_ARGV=("${POST_ARGS[@]}")
else
    AGENT_ARGV=()
fi

if [ ${#WRAPPER_ARGS[@]} -gt 0 ]; then
    parse_wrapper_args "${WRAPPER_ARGS[@]}"
else
    parse_wrapper_args
fi

if [ ${#AGENT_ARGS[@]} -gt 0 ]; then
    if [ ${#AGENT_ARGV[@]} -gt 0 ]; then
        AGENT_ARGV=("${AGENT_ARGS[@]}" "${AGENT_ARGV[@]}")
    else
        AGENT_ARGV=("${AGENT_ARGS[@]}")
    fi
fi

_step "start"
load_config_sources
_step "load_config_sources"

if [ "$AGENT_EXPLICIT" = false ]; then
    ACTIVE_AGENT="$DEFAULT_AGENT"
fi

# -Q and -c are mutually exclusive
if [ "$QUICK_MODE" = true ] && [ "$CONFIG_HOME_FROM_CLI" = true ]; then
    echo "error: -Q/--quick and -c/--config-home are mutually exclusive" >&2
    exit 1
fi

# -Q bare mode: skip all config-home resolution and scaffolding
if [ "$QUICK_MODE" = true ]; then
    CONFIG_HOME=""
    CONFIG_ROOT=""
    CONFIG_HOME_AUTO=false
elif [ -z "$CONFIG_HOME" ]; then
    set_config_home_value "$(default_config_home_for_agent "$ACTIVE_AGENT")"
    CONFIG_HOME_AUTO=true
fi

if [ "$CONFIG_HOME_AUTO" = true ]; then
    CONFIG_ROOT="$(dirname "$CONFIG_HOME")"
fi

if [ "$CONFIG_HOME_FROM_CLI" = true ] && [ -n "$CONFIG_HOME" ]; then
    if [ -d "$CONFIG_HOME/claude" ] || [ -d "$CONFIG_HOME/codex" ] || [ -d "$CONFIG_HOME/gemini" ] || [ -d "$CONFIG_HOME/grok" ]; then
        CONFIG_ROOT="$CONFIG_HOME"
        CONFIG_HOME=""
        CONFIG_HOME_AUTO=false
    fi
fi

autolink_legacy_into_deva_root() {
    [ "$AUTOLINK" = true ] || return 0
    [ "$DRY_RUN" != true ] || return 0
    [ "$CONFIG_HOME_FROM_CLI" = false ] || return 0
    [ -n "${CONFIG_ROOT:-}" ] || return 0
    [ -d "$CONFIG_ROOT" ] || mkdir -p "$CONFIG_ROOT"

    if [ -d "$HOME/.claude" ] || [ -f "$HOME/.claude.json" ]; then
        [ -d "$CONFIG_ROOT/claude" ] || mkdir -p "$CONFIG_ROOT/claude"
        if [ -d "$HOME/.claude" ] && [ ! -e "$CONFIG_ROOT/claude/.claude" ] && [ ! -L "$CONFIG_ROOT/claude/.claude" ]; then
            ln -s "$HOME/.claude" "$CONFIG_ROOT/claude/.claude"
            echo "autolink: ~/.claude -> $CONFIG_ROOT/claude/.claude" >&2
        fi
        if [ -f "$HOME/.claude.json" ] && [ ! -e "$CONFIG_ROOT/claude/.claude.json" ] && [ ! -L "$CONFIG_ROOT/claude/.claude.json" ]; then
            ln -s "$HOME/.claude.json" "$CONFIG_ROOT/claude/.claude.json"
            echo "autolink: ~/.claude.json -> $CONFIG_ROOT/claude/.claude.json" >&2
        fi
    fi
    if [ -d "$CONFIG_ROOT/claude" ] && [ ! -e "$CONFIG_ROOT/claude/.claude.json" ] && [ ! -L "$CONFIG_ROOT/claude/.claude.json" ]; then
        echo '{}' >"$CONFIG_ROOT/claude/.claude.json"
        echo "scaffold: created $CONFIG_ROOT/claude/.claude.json" >&2
    fi

    if [ -d "$HOME/.codex" ]; then
        [ -d "$CONFIG_ROOT/codex" ] || mkdir -p "$CONFIG_ROOT/codex"
        if [ ! -e "$CONFIG_ROOT/codex/.codex" ] && [ ! -L "$CONFIG_ROOT/codex/.codex" ]; then
            ln -s "$HOME/.codex" "$CONFIG_ROOT/codex/.codex"
            echo "autolink: ~/.codex -> $CONFIG_ROOT/codex/.codex" >&2
        fi
    fi
    if [ -d "$CONFIG_ROOT" ]; then
        [ -d "$CONFIG_ROOT/codex/.codex" ] || [ -L "$CONFIG_ROOT/codex/.codex" ] || mkdir -p "$CONFIG_ROOT/codex/.codex"
    fi

    if [ -d "$HOME/.gemini" ]; then
        [ -d "$CONFIG_ROOT/gemini" ] || mkdir -p "$CONFIG_ROOT/gemini"
        if [ ! -e "$CONFIG_ROOT/gemini/.gemini" ] && [ ! -L "$CONFIG_ROOT/gemini/.gemini" ]; then
            ln -s "$HOME/.gemini" "$CONFIG_ROOT/gemini/.gemini"
            echo "autolink: ~/.gemini -> $CONFIG_ROOT/gemini/.gemini" >&2
        fi
    fi
    if [ -d "$CONFIG_ROOT" ]; then
        [ -d "$CONFIG_ROOT/gemini/.gemini" ] || [ -L "$CONFIG_ROOT/gemini/.gemini" ] || mkdir -p "$CONFIG_ROOT/gemini/.gemini"
    fi

    if [ -d "$HOME/.grok" ]; then
        [ -d "$CONFIG_ROOT/grok" ] || mkdir -p "$CONFIG_ROOT/grok"
        if [ ! -e "$CONFIG_ROOT/grok/.grok" ] && [ ! -L "$CONFIG_ROOT/grok/.grok" ]; then
            ln -s "$HOME/.grok" "$CONFIG_ROOT/grok/.grok"
            echo "autolink: ~/.grok -> $CONFIG_ROOT/grok/.grok" >&2
        fi
    fi
    if [ -d "$CONFIG_ROOT" ]; then
        [ -d "$CONFIG_ROOT/grok/.grok" ] || [ -L "$CONFIG_ROOT/grok/.grok" ] || mkdir -p "$CONFIG_ROOT/grok/.grok"
    fi
}

check_agent "$ACTIVE_AGENT"
prepare_browser_integration
prepare_claude_chrome_bridge
append_shared_agents_mount

if [ -n "$CONFIG_HOME" ] && [ "$DRY_RUN" != true ]; then
    if [ ! -d "$CONFIG_HOME" ]; then
        mkdir -p "$CONFIG_HOME"
    fi
    case "$ACTIVE_AGENT" in
    claude)
        [ -d "$CONFIG_HOME/.claude" ] || mkdir -p "$CONFIG_HOME/.claude"
        [ -f "$CONFIG_HOME/.claude.json" ] || echo '{}' >"$CONFIG_HOME/.claude.json"
        ;;
    codex)
        [ -d "$CONFIG_HOME/.codex" ] || mkdir -p "$CONFIG_HOME/.codex"
        ;;
    gemini)
        [ -d "$CONFIG_HOME/.gemini" ] || mkdir -p "$CONFIG_HOME/.gemini"
        [ -f "$CONFIG_HOME/.gemini/settings.json" ] || echo '{}' >"$CONFIG_HOME/.gemini/settings.json"
        ;;
    grok)
        [ -d "$CONFIG_HOME/.grok" ] || mkdir -p "$CONFIG_HOME/.grok"
        ;;
    esac
fi

# Warn if explicit --config-home is missing the agent's auth directory.
# Only warn for default OAuth flows — api-key/bedrock/vertex/copilot don't need local auth dirs.
# Peek at AGENT_ARGV + AGENT_ARGS to detect --auth-with before agent_prepare() runs.
_config_home_uses_default_auth=true
for _arg in "${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"}" "${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}"; do
    if [ "$_arg" = "--auth-with" ]; then
        _config_home_uses_default_auth=false
        break
    fi
done
if [ "$CONFIG_HOME_FROM_CLI" = true ] && [ -n "$CONFIG_HOME" ] && [ "$_config_home_uses_default_auth" = true ]; then
    case "$ACTIVE_AGENT" in
    claude)
        if [ ! -d "$CONFIG_HOME/.claude" ] || [ -z "$(ls -A "$CONFIG_HOME/.claude" 2>/dev/null)" ]; then
            echo "warning: $CONFIG_HOME/.claude is empty; OAuth credentials will need to be set up" >&2
        fi
        ;;
    codex)
        if [ ! -d "$CONFIG_HOME/.codex" ] || [ -z "$(ls -A "$CONFIG_HOME/.codex" 2>/dev/null)" ]; then
            echo "warning: $CONFIG_HOME/.codex is empty; authentication will need to be set up" >&2
        fi
        ;;
    gemini)
        if [ ! -d "$CONFIG_HOME/.gemini" ] || [ -z "$(ls -A "$CONFIG_HOME/.gemini" 2>/dev/null)" ]; then
            echo "warning: $CONFIG_HOME/.gemini is empty; authentication will need to be set up" >&2
        fi
        ;;
    grok)
        if [ ! -d "$CONFIG_HOME/.grok" ] || [ -z "$(ls -A "$CONFIG_HOME/.grok" 2>/dev/null)" ]; then
            echo "warning: $CONFIG_HOME/.grok is empty; authentication will need to be set up" >&2
        fi
        ;;
    esac
fi

if dangerous_directory; then
    warn_dangerous_directory
fi

resolve_profile
check_image
prepare_base_docker_args
dedup_user_volumes
append_user_volumes
append_extra_docker_args
_step "base docker args + user volumes"

autolink_legacy_into_deva_root
_step "autolink"
load_agent_module
AGENT_COMMAND=()
if [ ${#AGENT_ARGV[@]} -gt 0 ]; then
    agent_prepare "${AGENT_ARGV[@]}"
else
    agent_prepare
fi
_step "agent_prepare"

# Rewrite container name now that AUTH_METHOD is known from agent_prepare().
# prepare_base_docker_args used auth-default; update if auth is non-default.
{
    _needs_rewrite=false
    _env_auth_override=false

    if [ -n "${AUTH_METHOD:-}" ]; then
        case "${ACTIVE_AGENT}:${AUTH_METHOD}" in
            claude:claude|codex:chatgpt|gemini:oauth|gemini:gemini-app-oauth|grok:oauth) ;;
            *) _needs_rewrite=true ;;
        esac

        if [ "$_needs_rewrite" = false ] && has_auth_override; then
            _needs_rewrite=true
            _env_auth_override=true
        fi
    fi

    if [ "$_needs_rewrite" = true ]; then
        _rw_slug="$(generate_container_slug)"

        _rw_vol_input=""
        if [ ${#USER_VOLUMES[@]} -gt 0 ]; then
            _rw_vol_input=$(printf '%s\n' "${USER_VOLUMES[@]}" | sort | tr '\n' '|')
        fi
        _rw_cfg_input=""
        if [ "$CONFIG_HOME_FROM_CLI" = true ]; then
            [ -n "$CONFIG_HOME" ] && _rw_cfg_input="$CONFIG_HOME"
            [ -z "$_rw_cfg_input" ] && [ -n "$CONFIG_ROOT" ] && _rw_cfg_input="$CONFIG_ROOT"
        fi

        _rw_shape=$(compute_shape_hash "$(docker_image_ref)" "$_rw_vol_input" "$_rw_cfg_input")
        _rw_auth_tag=$(generate_auth_tag "$ACTIVE_AGENT" "$AUTH_METHOD" "${CUSTOM_CREDENTIALS_FILE:-}" "$_env_auth_override")

        _rw_name=$(build_container_name \
            "$DEVA_CONTAINER_PREFIX" "$ACTIVE_AGENT" "$_rw_auth_tag" \
            "$_rw_slug" "$_rw_shape" "$EPHEMERAL_MODE" "$$")

        for ((i = 0; i < ${#DOCKER_ARGS[@]}; i++)); do
            if [ "${DOCKER_ARGS[$i]}" = "--name" ] && [ $((i + 1)) -lt ${#DOCKER_ARGS[@]} ]; then
                DOCKER_ARGS[i + 1]="$_rw_name"
                break
            fi
        done

        DOCKER_ARGS+=(--label "deva.auth_tag=${_rw_auth_tag}")
    fi

    if [ -n "${AUTH_METHOD:-}" ]; then
        DOCKER_ARGS+=(--label "deva.auth=${AUTH_METHOD}")
        DOCKER_ARGS+=(-e "DEVA_AUTH_METHOD=${AUTH_METHOD}")
        [ -n "${AUTH_DETAILS:-}" ] && DOCKER_ARGS+=(-e "DEVA_AUTH_DETAILS=${AUTH_DETAILS}")
    fi
}

# Determine container name early for env injection
CONTAINER_NAME=""
for ((i = 0; i < ${#DOCKER_ARGS[@]}; i++)); do
    if [ "${DOCKER_ARGS[$i]}" = "--name" ] && [ $((i + 1)) -lt ${#DOCKER_ARGS[@]} ]; then
        CONTAINER_NAME="${DOCKER_ARGS[$((i + 1))]}"
        break
    fi
done

# Always export container context (regardless of auth method)
# Note: DEVA_AGENT already set in prepare_base_docker_args (line 636)
DOCKER_ARGS+=(-e "DEVA_CONTAINER_NAME=${CONTAINER_NAME}")
DOCKER_ARGS+=(-e "DEVA_WORKSPACE=$(pwd)")
DOCKER_ARGS+=(-e "DEVA_EPHEMERAL=${EPHEMERAL_MODE}")

# Back up .claude.json before mounting, without touching live credential files.
if [ "$QUICK_MODE" != true ] && [ "$DRY_RUN" != true ]; then
    backup_claude_json
fi

# Centralized mounting logic.
# -Q bare mode: skip all config/auth mounts entirely.
# Explicit --config-home DIR: isolate to that single home (no sibling agents).
# Default: walk CONFIG_ROOT but only for KNOWN AGENT subdirs, and within each
# mount only the CANONICAL entries (.claude/.claude.json/.codex/.gemini/.grok).
# Non-agent subdirs (sessions/, cache/, adhoc state) are skipped. This keeps the
# mount count bounded at ~4 regardless of how much state agents accumulate
# under their home dirs — the old unfiltered walk could emit 200+ mounts and
# turn validate_bind_mount_shape's O(N²) into a several-minute stall.
_step "mount dispatch: begin"
if [ "$QUICK_MODE" = true ]; then
    : # bare mode: no config mounts
elif [ "$CONFIG_HOME_FROM_CLI" = true ] && [ -n "$CONFIG_HOME" ]; then
    mount_config_home
else
    if [ -n "$CONFIG_ROOT" ] && [ -d "$CONFIG_ROOT" ]; then
        _d_name=""
        for _d in "$CONFIG_ROOT"/*; do
            [ -d "$_d" ] || continue
            _d_name="$(basename "$_d")"
            is_known_agent_subdir "$_d_name" || continue
            mount_agent_canonical "$_d_name" "$_d"
        done
        unset _d _d_name
    else
        # Fallback: direct mount from $HOME (CONFIG_ROOT should always be set)
        [ -d "$HOME/.claude" ] && DOCKER_ARGS+=("-v" "$HOME/.claude:/home/deva/.claude")
        [ -f "$HOME/.claude.json" ] && DOCKER_ARGS+=("-v" "$HOME/.claude.json:/home/deva/.claude.json")
        [ -d "$HOME/.codex" ] && DOCKER_ARGS+=("-v" "$HOME/.codex:/home/deva/.codex")
        [ -d "$HOME/.gemini" ] && DOCKER_ARGS+=("-v" "$HOME/.gemini:/home/deva/.gemini")
        if [ -d "$HOME/.grok" ] && ! grok_api_key_no_mount; then
            DOCKER_ARGS+=("-v" "$HOME/.grok:/home/deva/.grok")
        fi
    fi
fi
_step "mount dispatch: done"

# Hide default OAuth credential files for non-default auth modes.
# For credentials-file auth on Claude/Codex, the agent-specific file mount already overlays the path.
if [ "$QUICK_MODE" = false ]; then
    append_auth_credential_overlay
fi

# Statusline state intentionally NOT redirected: it defaults to
# ~/.claude/statusline inside the mounted ~/.claude, so the host and every
# container share one quota cache and one log dir. Hard-coding
# CLAUDE_DATA_DIR/CLAUDE_CACHE_DIR here split state from the host and from
# the logs (#388).

# Mount deva config and cache directories (auth credential files etc.)
# Skip when --config-home is explicit or -Q bare mode to preserve isolation
if [ "$CONFIG_HOME_FROM_CLI" = false ] && [ "$QUICK_MODE" = false ]; then
    if [ -d "$HOME/.config/deva" ]; then
        DOCKER_ARGS+=("-v" "$HOME/.config/deva:/home/deva/.config/deva")
    fi
    if [ -d "$HOME/.cache/deva" ]; then
        DOCKER_ARGS+=("-v" "$HOME/.cache/deva:/home/deva/.cache/deva")
    fi
fi

append_grok_update_guard
_step "append_grok_update_guard"

append_user_envs
_step "append_user_envs"
validate_bind_mount_shape
_step "validate_bind_mount_shape"

DOCKER_ARGS+=("$(docker_image_ref)")

if [ "$ACTION" = "shell" ]; then
    AGENT_COMMAND=("/bin/zsh")
fi

if [ ${#AGENT_COMMAND[@]} -eq 0 ]; then
    echo "error: agent $ACTIVE_AGENT did not provide a launch command" >&2
    exit 1
fi

CONTAINER_NAME=""
for ((i = 0; i < ${#DOCKER_ARGS[@]}; i++)); do
    if [ "${DOCKER_ARGS[$i]}" = "--name" ] && [ $((i + 1)) -lt ${#DOCKER_ARGS[@]} ]; then
        CONTAINER_NAME="${DOCKER_ARGS[$((i + 1))]}"
        break
    fi
done

mask_secrets_in_args() {
    local arg
    for arg in "$@"; do
        if [[ "$arg" =~ ^-e$ ]]; then
            printf '%s ' "$arg"
        elif [[ "$arg" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
            local name="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            case "$name" in
                *TOKEN*|*KEY*|*SECRET*|*PASSWORD*|*CREDENTIALS*)
                    printf '%s=<redacted> ' "$name"
                    ;;
                *)
                    printf '%s ' "$arg"
                    ;;
            esac
        else
            printf '%s ' "$arg"
        fi
    done
}

if [ "$DEBUG_MODE" = true ]; then
    echo "=== DEBUG: Docker command ===" >&2
    echo "Container name: $CONTAINER_NAME" >&2
    echo "USER_VOLUMES (${#USER_VOLUMES[@]}): ${USER_VOLUMES[*]-}" >&2
    echo "Ephemeral mode: $EPHEMERAL_MODE" >&2
    echo "" >&2
    if [ "$EPHEMERAL_MODE" = false ]; then
        echo "docker run -d $(mask_secrets_in_args "${DOCKER_ARGS[@]:2}") tail -f /dev/null" >&2
        echo "docker exec ${DOCKER_TERMINAL_ARGS[*]} $CONTAINER_NAME /usr/local/bin/docker-entrypoint.sh ${AGENT_COMMAND[*]}" >&2
    else
        echo "docker $(mask_secrets_in_args "${DOCKER_ARGS[@]}") ${AGENT_COMMAND[*]}" >&2
    fi
    echo "===========================" >&2
    echo "" >&2
fi

if [ "$DRY_RUN" = true ]; then
    exit 0
fi

inject_workspace_context

if [ "$EPHEMERAL_MODE" = false ]; then
    # Check if container is running
    container_action="attach"
    if docker ps -q --filter "name=^${CONTAINER_NAME}$" | grep -q .; then
        echo "Attaching to existing container: $CONTAINER_NAME"
        container_action="attach"
    elif docker ps -aq --filter "name=^${CONTAINER_NAME}$" | grep -q .; then
        # Container exists but stopped
        echo "Starting stopped container: $CONTAINER_NAME"
        if ! docker start "$CONTAINER_NAME" >/dev/null 2>&1; then
            echo "error: failed to start container $CONTAINER_NAME" >&2
            exit 1
        fi
        container_action="start"
    else
        # Container doesn't exist - try to create it
        echo "Creating persistent container: $CONTAINER_NAME"
        error_output=$(docker "${DOCKER_ARGS[@]}" tail -f /dev/null 2>&1)
        docker_exit=$?
        if [ $docker_exit -ne 0 ]; then
            # Check if specifically a name collision (concurrent run)
            if echo "$error_output" | grep -qE 'already in use|Conflict'; then
                echo "Container name in use, waiting for initialization..."
                attempts=20  # 20 * 0.5s = 10s total
                while [ $attempts -gt 0 ]; do
                    if docker ps -q --filter "name=^${CONTAINER_NAME}$" 2>/dev/null | grep -q .; then
                        echo "Container ready, attaching..."
                        break
                    fi
                    sleep 0.5
                    attempts=$((attempts - 1))
                done
                if [ $attempts -eq 0 ]; then
                    echo "error: timed out waiting for container $CONTAINER_NAME" >&2
                    exit 1
                fi
                container_action="attach"
            else
                # Real error - surface immediately
                echo "error: failed to create container $CONTAINER_NAME:" >&2
                echo "$error_output" >&2
                exit 1
            fi
        else
            sleep 0.3
            container_action="create"
        fi
    fi

    # Write or update session file
    if [ "$container_action" = "create" ] || [ "$container_action" = "start" ]; then
        write_session_file
    else
        update_session_file
    fi

    # docker exec env overrides the container's creation-time env: pass the
    # trace state explicitly so --trace works on an existing container and a
    # non-traced attach un-trusts the CA installed by an earlier traced run.
    _trace_env="DEVA_TRACE=0"
    [ "${DEVA_TRACE_ACTIVE:-false}" = true ] && _trace_env="DEVA_TRACE=1"

    if [ "$AUTH_PROVISION_MODE" = true ]; then
        docker exec -e "$_trace_env" "${DOCKER_TERMINAL_ARGS[@]}" "$CONTAINER_NAME" /usr/local/bin/docker-entrypoint.sh "${AGENT_COMMAND[@]}" || true
        finish_auth_provision
    else
        exec docker exec -e "$_trace_env" "${DOCKER_TERMINAL_ARGS[@]}" "$CONTAINER_NAME" /usr/local/bin/docker-entrypoint.sh "${AGENT_COMMAND[@]}"
    fi
else
    echo "Launching ${ACTIVE_AGENT} (ephemeral mode) via $(docker_image_ref)"
    write_session_file
    if [ "$AUTH_PROVISION_MODE" = true ]; then
        docker "${DOCKER_ARGS[@]}" "${AGENT_COMMAND[@]}" || true
        finish_auth_provision
    else
        if ! docker "${DOCKER_ARGS[@]}" "${AGENT_COMMAND[@]}"; then
            echo "error: failed to launch ephemeral container" >&2
            exit 1
        fi
    fi
fi
