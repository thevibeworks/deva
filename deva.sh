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

VERSION="0.8.0"
DEVA_DOCKER_IMAGE="${DEVA_DOCKER_IMAGE:-ghcr.io/thevibeworks/deva}"
DEVA_DOCKER_TAG="${DEVA_DOCKER_TAG:-latest}"
DEVA_CONTAINER_PREFIX="${DEVA_CONTAINER_PREFIX:-deva}"
DEFAULT_AGENT="${DEVA_DEFAULT_AGENT:-claude}"

PROFILE="${DEVA_PROFILE:-${DEVA_IMAGE_PROFILE:-}}"

CONFIG_ROOT=""

USER_VOLUMES=()
USER_ENVS=()
EXTRA_DOCKER_ARGS=()
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

EPHEMERAL_MODE=false
GLOBAL_MODE=false
DEBUG_MODE=false
DRY_RUN=false

usage() {
    cat <<'USAGE'
deva.sh - Docker-based multi-agent launcher (Claude, Codex, Gemini)

Usage:
  deva.sh [deva flags] [agent] [-- agent-flags]
  deva.sh [agent] [deva flags] [-- agent-flags]
  deva.sh <command>

Container management commands (docker/tmux-style):
  deva.sh ps [-g]            List containers (current project or --all)
  deva.sh status [-g]        Show session info (current workspace or --all)
  deva.sh shell [-g]         Open zsh shell for inspection (pick if multiple)
  deva.sh stop [-g]          Stop container (pick if multiple)
  deva.sh rm [-g] [--all]    Remove container (pick if multiple), or all for this workspace
  deva.sh clean [-g]         Remove all stopped containers

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
  --host-net              Use host networking for the agent container
  --no-docker             Disable auto-mount of Docker socket (default: auto-mount if present)
  --dry-run               Show docker command without executing (implies --debug)
  --verbose, --debug      Print full docker command before execution
  --                      Everything after this sentinel is passed to the agent unchanged

Container Behavior (NEW in v0.8.0):
  Default (persistent):   One container per project, reused across runs.
                          Preserves state (npm packages, builds, etc).
                          Faster startup, run any agent (claude/codex/gemini).

  With --rm (ephemeral):  Create new container, auto-remove after exit.
                          Agent-specific naming for parallel runs.

Container Naming (NEW):
  Persistent:  deva-<parent>-<project>              # One per project
  Ephemeral:   deva-<parent>-<project>-<agent>-<pid>  # Agent-specific

  Example:
    /Users/eric/work/myapp  → deva-work-myapp
    /Users/eric/home/myapp  → deva-home-myapp

Examples:
  # Launch agents (persistent by default)
  deva.sh                             # Launch claude in persistent container
  deva.sh claude                      # Same
  deva.sh codex                       # Launch codex in same container
  deva.sh gemini                      # Launch gemini in same container
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
  deva.sh claude -- --trace --continue   # Use claude-trace wrapper for request tracing
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

absolute_path() {
    python3 - "$1" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
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
    if docker image inspect "${DEVA_DOCKER_IMAGE}:${DEVA_DOCKER_TAG}" >/dev/null 2>&1; then
        return
    fi

    # Try pulling first
    if docker pull "${DEVA_DOCKER_IMAGE}:${DEVA_DOCKER_TAG}" >/dev/null 2>&1; then
        return
    fi

    # Smart fallback: check for available profile images locally
    local available_tags=""
    local original_tag="$DEVA_DOCKER_TAG"

    # Check common profile tags (prefer rust as it's a superset of base)
    for tag in rust latest; do
        if [ "$tag" = "$DEVA_DOCKER_TAG" ]; then
            continue  # Skip the one we already tried
        fi
        if docker image inspect "${DEVA_DOCKER_IMAGE}:${tag}" >/dev/null 2>&1; then
            available_tags="${available_tags}${tag} "
        fi
    done

    if [ -n "$available_tags" ]; then
        # Found alternative images - use the first one
        local fallback_tag="${available_tags%% *}"  # Get first tag
        echo "Image ${DEVA_DOCKER_IMAGE}:${original_tag} not found" >&2
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

    echo "Docker image ${DEVA_DOCKER_IMAGE}:${DEVA_DOCKER_TAG} not found locally" >&2
    if [ -n "$df" ]; then
        echo "A matching Dockerfile exists at: $df" >&2
        case "${PROFILE:-}" in
        rust)
            echo "Build with: make build-rust" >&2
            echo "or: docker build -f $df -t ghcr.io/thevibeworks/deva:rust \"$SCRIPT_DIR\"" >&2
            ;;
        "" | base)
            echo "Build with: make build" >&2
            echo "or: docker build -f Dockerfile -t ghcr.io/thevibeworks/deva:latest \"$SCRIPT_DIR\"" >&2
            ;;
        *)
            echo "Build with your Dockerfile and tag appropriately (e.g., :${PROFILE})" >&2
            ;;
        esac
    else
        echo "Pull with: docker pull ${DEVA_DOCKER_IMAGE}:${DEVA_DOCKER_TAG}" >&2
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

    local pattern=""
    local slug escaped
    for slug in $slugs; do
        [ -n "$slug" ] || continue
        escaped=$(printf '%s' "$slug" | sed -e 's/[.[\\^$*+?{}()|]/\\&/g')
        if [ -n "$pattern" ]; then
            pattern="${pattern}|-${escaped}([.-]|$)"
        else
            pattern="-${escaped}([.-]|$)"
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
    local rest="${name#"${DEVA_CONTAINER_PREFIX}"-}"

    # Ephemeral pattern: ends with -<agent>-<pid> where pid is all digits
    if [[ "$rest" =~ -([a-z]+)-([0-9]+)$ ]]; then
        local agent="${BASH_REMATCH[1]}"
        printf '%s' "$agent"
    else
        printf 'share'
    fi
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

    echo "Docker image: ${DEVA_DOCKER_IMAGE}:${DEVA_DOCKER_TAG}"
    echo "Container prefix: $DEVA_CONTAINER_PREFIX"
}

prepare_base_docker_args() {
    local container_name
    local slug
    slug="$(generate_container_slug)"

    local volume_hash=""
    if [ ${#USER_VOLUMES[@]} -gt 0 ]; then
        volume_hash=$(compute_volume_hash)
    fi

    if [ "$EPHEMERAL_MODE" = true ]; then
        if [ -n "$volume_hash" ]; then
            container_name="${DEVA_CONTAINER_PREFIX}-${slug}..v${volume_hash}-${ACTIVE_AGENT}-$$"
        else
            container_name="${DEVA_CONTAINER_PREFIX}-${slug}-${ACTIVE_AGENT}-$$"
        fi
        DOCKER_ARGS=(run --rm -it)
    else
        if [ -n "$volume_hash" ]; then
            container_name="${DEVA_CONTAINER_PREFIX}-${slug}..v${volume_hash}"
        else
            container_name="${DEVA_CONTAINER_PREFIX}-${slug}"
        fi
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
        --add-host host.docker.internal:host-gateway
    )

    # Attach labels to identify workspace and container grouping
    local ws_hash
    ws_hash=$(workspace_hash)
    DOCKER_ARGS+=(
        --label "deva.prefix=${DEVA_CONTAINER_PREFIX}"
        --label "deva.slug=${slug}"
        --label "deva.workspace=$(pwd)"
        --label "deva.workspace_hash=${ws_hash}"
        --label "deva.agent=${ACTIVE_AGENT}"
        --label "deva.ephemeral=${EPHEMERAL_MODE}"
    )
    if [ -n "$volume_hash" ]; then
        DOCKER_ARGS+=(--label "deva.volhash=${volume_hash}")
    fi

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
            ANTHROPIC_API_KEY | ANTHROPIC_BASE_URL | CLAUDE_CODE_OAUTH_TOKEN | OPENAI_API_KEY | OPENAI_BASE_URL | openai_base_url)
                return 0
                ;;
            esac
            ;;
        api-key | oat)
            case "$name" in
            ANTHROPIC_API_KEY | ANTHROPIC_BASE_URL | CLAUDE_CODE_OAUTH_TOKEN | OPENAI_API_KEY | OPENAI_BASE_URL | openai_base_url)
                return 0
                ;;
            esac
            ;;
        copilot)
            case "$name" in
            ANTHROPIC_API_KEY | ANTHROPIC_BASE_URL | CLAUDE_CODE_OAUTH_TOKEN)
                return 0
                ;;
            esac
            ;;
        bedrock | vertex | credentials-file)
            case "$name" in
            ANTHROPIC_API_KEY | ANTHROPIC_BASE_URL | CLAUDE_CODE_OAUTH_TOKEN | OPENAI_API_KEY | OPENAI_BASE_URL | openai_base_url)
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

mount_config_home() {
    if [ -z "$CONFIG_HOME" ]; then
        return
    fi

    local item
    for item in "$CONFIG_HOME"/.* "$CONFIG_HOME"/*; do
        [ -e "$item" ] || continue
        local name
        name="$(basename "$item")"
        if [ "$name" = "." ] || [ "$name" = ".." ]; then
            continue
        fi
        DOCKER_ARGS+=(-v "$item:/home/deva/$name")
    done
}

mount_dir_contents_into_home() {
    local base="$1"
    [ -d "$base" ] || return
    local item
    for item in "$base"/.* "$base"/*; do
        [ -e "$item" ] || continue
        local name
        name="$(basename "$item")"
        if [ "$name" = "." ] || [ "$name" = ".." ]; then
            continue
        fi
        DOCKER_ARGS+=(-v "$item:/home/deva/$name")
    done
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

    if [ -n "$hash_input" ]; then
        if command -v md5sum >/dev/null 2>&1; then
            echo "$hash_input" | md5sum | cut -c1-8
        elif command -v shasum >/dev/null 2>&1; then
            echo "$hash_input" | shasum | cut -c1-8
        else
            echo "$hash_input" | cksum | cut -d' ' -f1 | cut -c1-8
        fi
    fi
}

workspace_hash() {
    if [ -n "$_WS_HASH_CACHE" ]; then
        printf '%s' "$_WS_HASH_CACHE"
        return
    fi

    local p
    p="$(pwd)"
    if command -v md5sum >/dev/null 2>&1; then
        _WS_HASH_CACHE=$(printf '%s' "$p" | md5sum | cut -c1-8)
    elif command -v shasum >/dev/null 2>&1; then
        _WS_HASH_CACHE=$(printf '%s' "$p" | shasum | cut -c1-8)
    else
        _WS_HASH_CACHE=$(printf '%s' "$p" | cksum | cut -d' ' -f1 | cut -c1-8)
    fi
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
    value="${value//\"/}"

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
    DEFAULT_AGENT)
        DEFAULT_AGENT="$value"
        ;;
    PROFILE)
        PROFILE="$value"
        ;;
    IMAGE_PROFILE)
        PROFILE="$value"
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
        --rm)
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
            echo "Docker Image: ${DEVA_DOCKER_IMAGE}:${DEVA_DOCKER_TAG}"
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
        esac
    done
fi

if [ "$MANAGEMENT_MODE" = "shell" ] || [ "$MANAGEMENT_MODE" = "ps" ] || [ "$MANAGEMENT_MODE" = "show-config" ] || [ "$MANAGEMENT_MODE" = "stop" ] || [ "$MANAGEMENT_MODE" = "rm" ] || [ "$MANAGEMENT_MODE" = "clean" ] || [ "$MANAGEMENT_MODE" = "status" ]; then
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
                rgx="^${DEVA_CONTAINER_PREFIX}-${escaped_slug}(\\.\\.|-|$)"
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
                rgx="^${DEVA_CONTAINER_PREFIX}-${escaped_slug}(\\.\\.|-|$)"
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
        session_dir="${DEVA_CONFIG_HOME:-$HOME/.config/deva}/sessions"
        show_all=false

        # Check for -g/--all flag
        for tok in "${PRE_ARGS[@]}"; do
            case "$tok" in
            -g | --all) show_all=true ;;
            esac
        done

        if [ "$show_all" = true ]; then
            # Show all sessions
            if [ ! -d "$session_dir" ] || [ -z "$(ls -A "$session_dir" 2>/dev/null)" ]; then
                echo "No active sessions found"
                exit 0
            fi

            echo "=== All Active Sessions ==="
            echo
            for session in "$session_dir"/*.json; do
                [ -f "$session" ] || continue
                if command -v jq >/dev/null 2>&1; then
                    container=$(jq -r '.container' "$session" 2>/dev/null)
                    agent=$(jq -r '.agent' "$session" 2>/dev/null)
                    workspace=$(jq -r '.workspace' "$session" 2>/dev/null)
                    auth_method=$(jq -r '.auth.method' "$session" 2>/dev/null)
                    auth_details=$(jq -r '.auth.details' "$session" 2>/dev/null)
                    ephemeral=$(jq -r '.ephemeral' "$session" 2>/dev/null)
                    started=$(jq -r '.started_at' "$session" 2>/dev/null)

                    # Check if container is still running
                    if docker ps -q --filter "name=^${container}$" | grep -q .; then
                        status="running"
                    elif docker ps -aq --filter "name=^${container}$" | grep -q .; then
                        status="stopped"
                    else
                        status="removed"
                    fi

                    echo "Container: $container"
                    echo "  Agent:     $agent"
                    echo "  Status:    $status"
                    echo "  Workspace: $workspace"
                    echo "  Auth:      $auth_method"
                    [ "$auth_details" != "null" ] && [ -n "$auth_details" ] && echo "  Details:   $auth_details"
                    echo "  Ephemeral: $ephemeral"
                    echo "  Started:   $started"
                    echo
                fi
            done
        else
            # Show current workspace sessions
            ws_hash=$(workspace_hash)
            found=false

            if [ -d "$session_dir" ]; then
                for session in "$session_dir"/*.json; do
                    [ -f "$session" ] || continue
                    if command -v jq >/dev/null 2>&1; then
                        session_ws_hash=$(jq -r '.workspace_hash' "$session" 2>/dev/null)
                        if [ "$session_ws_hash" = "$ws_hash" ]; then
                            found=true
                            container=$(jq -r '.container' "$session" 2>/dev/null)
                            agent=$(jq -r '.agent' "$session" 2>/dev/null)
                            workspace=$(jq -r '.workspace' "$session" 2>/dev/null)
                            auth_method=$(jq -r '.auth.method' "$session" 2>/dev/null)
                            auth_details=$(jq -r '.auth.details' "$session" 2>/dev/null)
                            ephemeral=$(jq -r '.ephemeral' "$session" 2>/dev/null)
                            started=$(jq -r '.started_at' "$session" 2>/dev/null)
                            last_seen=$(jq -r '.last_seen' "$session" 2>/dev/null)

                            # Check if container is still running
                            if docker ps -q --filter "name=^${container}$" | grep -q .; then
                                status="running"
                            elif docker ps -aq --filter "name=^${container}$" | grep -q .; then
                                status="stopped"
                            else
                                status="removed"
                            fi

                            echo "=== Container Status ==="
                            echo
                            echo "Container: $container"
                            echo "Agent:     $agent"
                            echo "Status:    $status"
                            echo "Workspace: $workspace"
                            echo "Auth:      $auth_method"
                            [ "$auth_details" != "null" ] && [ -n "$auth_details" ] && echo "Details:   $auth_details"
                            echo "Ephemeral: $ephemeral"
                            echo "Started:   $started"
                            echo "Last Seen: $last_seen"
                        fi
                    fi
                done
            fi

            if [ "$found" = false ]; then
                echo "No active sessions for this workspace"
                echo "Use 'deva.sh status --all' to see all sessions"
            fi
        fi
        exit 0
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

load_config_sources

if [ "$AGENT_EXPLICIT" = false ]; then
    ACTIVE_AGENT="$DEFAULT_AGENT"
fi

if [ -z "$CONFIG_HOME" ]; then
    set_config_home_value "$(default_config_home_for_agent "$ACTIVE_AGENT")"
    CONFIG_HOME_AUTO=true
fi

if [ "$CONFIG_HOME_AUTO" = true ]; then
    CONFIG_ROOT="$(dirname "$CONFIG_HOME")"
fi

if [ "$CONFIG_HOME_FROM_CLI" = true ] && [ -n "$CONFIG_HOME" ]; then
    if [ -d "$CONFIG_HOME/claude" ] || [ -d "$CONFIG_HOME/codex" ] || [ -d "$CONFIG_HOME/gemini" ]; then
        CONFIG_ROOT="$CONFIG_HOME"
        CONFIG_HOME=""
        CONFIG_HOME_AUTO=false
    fi
fi

autolink_legacy_into_deva_root() {
    [ "$AUTOLINK" = true ] || return 0
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
}

check_agent "$ACTIVE_AGENT"

if [ -n "$CONFIG_HOME" ]; then
    if [ ! -d "$CONFIG_HOME" ]; then
        mkdir -p "$CONFIG_HOME"
    fi
    if [ "$ACTIVE_AGENT" = "claude" ] && [ ! -f "$CONFIG_HOME/.claude.json" ]; then
        echo '{}' >"$CONFIG_HOME/.claude.json"
    fi
    if [ "$ACTIVE_AGENT" = "gemini" ] && [ ! -f "$CONFIG_HOME/settings.json" ]; then
        echo '{}' >"$CONFIG_HOME/settings.json"
    fi
fi

if dangerous_directory; then
    warn_dangerous_directory
fi

resolve_profile
check_image
prepare_base_docker_args
append_user_volumes
append_extra_docker_args

autolink_legacy_into_deva_root
load_agent_module
AGENT_COMMAND=()
if [ ${#AGENT_ARGV[@]} -gt 0 ]; then
    agent_prepare "${AGENT_ARGV[@]}"
else
    agent_prepare
fi

# Update container name based on auth method
if [ -n "${AUTH_METHOD:-}" ]; then
    # Determine if we need auth suffix
    needs_auth_suffix=false
    if [ "$ACTIVE_AGENT" = "claude" ] && [ "$AUTH_METHOD" != "claude" ]; then
        needs_auth_suffix=true
    elif [ "$ACTIVE_AGENT" = "codex" ] && [ "$AUTH_METHOD" != "chatgpt" ]; then
        needs_auth_suffix=true
    fi

    if [ "$needs_auth_suffix" = true ]; then
        slug="$(generate_container_slug)"
        volume_hash=""
        if [ ${#USER_VOLUMES[@]} -gt 0 ]; then
            volume_hash=$(compute_volume_hash)
        fi

        # Hash credential file path for credentials-file auth
        creds_hash=""
        if [ "$AUTH_METHOD" = "credentials-file" ] && [ -n "${CUSTOM_CREDENTIALS_FILE:-}" ]; then
            if command -v md5sum >/dev/null 2>&1; then
                creds_hash=$(printf '%s' "$CUSTOM_CREDENTIALS_FILE" | md5sum | cut -c1-8)
            elif command -v shasum >/dev/null 2>&1; then
                creds_hash=$(printf '%s' "$CUSTOM_CREDENTIALS_FILE" | shasum | cut -c1-8)
            else
                creds_hash=$(printf '%s' "$CUSTOM_CREDENTIALS_FILE" | cksum | cut -d' ' -f1 | cut -c1-8)
            fi
        fi

        new_container_name=""
        auth_suffix="${AUTH_METHOD}"
        [ -n "$creds_hash" ] && auth_suffix="${AUTH_METHOD}-${creds_hash}"

        if [ "$EPHEMERAL_MODE" = true ]; then
            if [ -n "$volume_hash" ]; then
                new_container_name="${DEVA_CONTAINER_PREFIX}-${slug}..v${volume_hash}..${auth_suffix}-${ACTIVE_AGENT}-$$"
            else
                new_container_name="${DEVA_CONTAINER_PREFIX}-${slug}..${auth_suffix}-${ACTIVE_AGENT}-$$"
            fi
        else
            if [ -n "$volume_hash" ]; then
                new_container_name="${DEVA_CONTAINER_PREFIX}-${slug}..v${volume_hash}..${auth_suffix}"
            else
                new_container_name="${DEVA_CONTAINER_PREFIX}-${slug}..${auth_suffix}"
            fi
        fi

        # Update container name in DOCKER_ARGS
        for ((i = 0; i < ${#DOCKER_ARGS[@]}; i++)); do
            if [ "${DOCKER_ARGS[$i]}" = "--name" ] && [ $((i + 1)) -lt ${#DOCKER_ARGS[@]} ]; then
                DOCKER_ARGS[i + 1]="$new_container_name"
                break
            fi
        done
    fi

    # Label auth method for easier filtering
    DOCKER_ARGS+=(--label "deva.auth=${AUTH_METHOD}")

    # Export container introspection variables
    DOCKER_ARGS+=(-e "DEVA_AUTH_METHOD=${AUTH_METHOD}")
    [ -n "${AUTH_DETAILS:-}" ] && DOCKER_ARGS+=(-e "DEVA_AUTH_DETAILS=${AUTH_DETAILS}")
fi

# Determine container name early for env injection
CONTAINER_NAME=""
for ((i = 0; i < ${#DOCKER_ARGS[@]}; i++)); do
    if [ "${DOCKER_ARGS[$i]}" = "--name" ] && [ $((i + 1)) -lt ${#DOCKER_ARGS[@]} ]; then
        CONTAINER_NAME="${DOCKER_ARGS[$((i + 1))]}"
        break
    fi
done

# Always export container context (regardless of auth method)
DOCKER_ARGS+=(-e "DEVA_CONTAINER_NAME=${CONTAINER_NAME}")
DOCKER_ARGS+=(-e "DEVA_AGENT=${ACTIVE_AGENT}")
DOCKER_ARGS+=(-e "DEVA_WORKSPACE=$(pwd)")
DOCKER_ARGS+=(-e "DEVA_EPHEMERAL=${EPHEMERAL_MODE}")

# Centralized mounting logic based on auth method
# If --config-home is set, use it exclusively and skip auth-based mounting
if [ -n "$CONFIG_HOME" ]; then
    mount_config_home
elif [ -n "${AUTH_METHOD:-}" ]; then
    is_default_auth=false
    if [ "$ACTIVE_AGENT" = "claude" ] && [ "$AUTH_METHOD" = "claude" ]; then
        is_default_auth=true
    elif [ "$ACTIVE_AGENT" = "codex" ] && [ "$AUTH_METHOD" = "chatgpt" ]; then
        is_default_auth=true
    fi

    if [ "$is_default_auth" = true ]; then
        # Default auth: mount all OAuth credentials for shared container
        if [ -n "$CONFIG_ROOT" ] && [ -d "$CONFIG_ROOT" ]; then
            # CONFIG_ROOT mode: mount all agent dirs (includes OAuth via symlinks)
            for d in "$CONFIG_ROOT"/*; do
                [ -d "$d" ] || continue
                [ "$(basename "$d")" = "_shared" ] && continue
                mount_dir_contents_into_home "$d"
            done
        else
            # Direct mode: mount both ~/.claude and ~/.codex
            if [ -d "$HOME/.claude" ]; then
                DOCKER_ARGS+=("-v" "$HOME/.claude:/home/deva/.claude")
            fi
            if [ -f "$HOME/.claude.json" ]; then
                DOCKER_ARGS+=("-v" "$HOME/.claude.json:/home/deva/.claude.json")
            fi
            if [ -d "$HOME/.codex" ]; then
                DOCKER_ARGS+=("-v" "$HOME/.codex:/home/deva/.codex")
            fi
        fi
    else
        # Non-default auth: exclude OAuth credential files
        if [ -n "$CONFIG_ROOT" ] && [ -d "$CONFIG_ROOT" ]; then
            # CONFIG_ROOT mode: selectively mount, excluding credentials
            for agent_dir in "$CONFIG_ROOT"/*; do
                [ -d "$agent_dir" ] || continue
                agent_name=$(basename "$agent_dir")
                [ "$agent_name" = "_shared" ] && continue

                # Determine credential file to exclude
                exclude_file=""
                case "$agent_name" in
                claude) exclude_file=".credentials.json" ;;
                codex) exclude_file="auth.json" ;;
                esac

                # Mount agent dir contents, excluding OAuth credentials
                for item in "$agent_dir"/.* "$agent_dir"/*; do
                    [ -e "$item" ] || continue
                    name=$(basename "$item")
                    case "$name" in
                    . | ..) continue ;;
                    esac

                    # Skip OAuth credential files
                    if [ -n "$exclude_file" ]; then
                        # Check if item is the credential file or contains it
                        if [ "$name" = "$exclude_file" ]; then
                            continue
                        elif [ -d "$item" ] && [ -f "$item/$exclude_file" ]; then
                            # It's a .claude or .codex directory containing credentials
                            # Mount contents individually, excluding credential
                            for subitem in "$item"/* "$item"/.*; do
                                [ -e "$subitem" ] || continue
                                subname=$(basename "$subitem") || {
                                    echo "warning: failed to get basename for $subitem" >&2
                                    continue
                                }
                                [ -n "$subname" ] || continue
                                case "$subname" in
                                . | .. | "$exclude_file") continue ;;
                                esac
                                DOCKER_ARGS+=("-v" "$subitem:/home/deva/$name/$subname")
                            done
                            continue
                        fi
                    fi

                    DOCKER_ARGS+=("-v" "$item:/home/deva/$name")
                done
            done
        else
            # Direct mode: mount ~/.claude and ~/.codex, excluding credentials
            if [ -d "$HOME/.claude" ]; then
                for item in "$HOME/.claude"/* "$HOME/.claude"/.*; do
                    [ -e "$item" ] || continue
                    name=$(basename "$item") || {
                        echo "warning: failed to get basename for $item" >&2
                        continue
                    }
                    [ -n "$name" ] || continue
                    case "$name" in
                    . | .. | .credentials.json) continue ;;
                    esac
                    DOCKER_ARGS+=("-v" "$item:/home/deva/.claude/$name")
                done
            fi
            if [ -f "$HOME/.claude.json" ]; then
                DOCKER_ARGS+=("-v" "$HOME/.claude.json:/home/deva/.claude.json")
            fi
            if [ -d "$HOME/.codex" ]; then
                for item in "$HOME/.codex"/* "$HOME/.codex"/.*; do
                    [ -e "$item" ] || continue
                    name=$(basename "$item") || {
                        echo "warning: failed to get basename for $item" >&2
                        continue
                    }
                    [ -n "$name" ] || continue
                    case "$name" in
                    . | .. | auth.json) continue ;;
                    esac
                    DOCKER_ARGS+=("-v" "$item:/home/deva/.codex/$name")
                done
            fi
        fi
    fi
fi

# Set statusline log paths via env vars (XDG-compliant)
DOCKER_ARGS+=("-e" "CLAUDE_DATA_DIR=/home/deva/.config/deva/claude")
DOCKER_ARGS+=("-e" "CLAUDE_CACHE_DIR=/home/deva/.cache/deva/claude/sessions")

# Mount deva config and cache directories for statusline usage tracking
if [ -d "$HOME/.config/deva" ]; then
    DOCKER_ARGS+=("-v" "$HOME/.config/deva:/home/deva/.config/deva")
fi
if [ -d "$HOME/.cache/deva" ]; then
    DOCKER_ARGS+=("-v" "$HOME/.cache/deva:/home/deva/.cache/deva")
fi

# Mount project-local .claude directory if exists
append_user_envs
if [ -d "$(pwd)/.claude" ]; then
    DOCKER_ARGS+=("-v" "$(pwd)/.claude:$(pwd)/.claude")
fi

DOCKER_ARGS+=("${DEVA_DOCKER_IMAGE}:${DEVA_DOCKER_TAG}")

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

if [ "$DEBUG_MODE" = true ]; then
    echo "=== DEBUG: Docker command ===" >&2
    echo "Container name: $CONTAINER_NAME" >&2
    echo "USER_VOLUMES (${#USER_VOLUMES[@]}): ${USER_VOLUMES[*]}" >&2
    echo "Ephemeral mode: $EPHEMERAL_MODE" >&2
    echo "" >&2
    if [ "$EPHEMERAL_MODE" = false ]; then
        echo "docker run -d ${DOCKER_ARGS[*]:2} tail -f /dev/null" >&2
        echo "docker exec -it $CONTAINER_NAME /usr/local/bin/docker-entrypoint.sh ${AGENT_COMMAND[*]}" >&2
    else
        echo "docker ${DOCKER_ARGS[*]} ${AGENT_COMMAND[*]}" >&2
    fi
    echo "===========================" >&2
    echo "" >&2
fi

if [ "$DRY_RUN" = true ]; then
    exit 0
fi

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

    exec docker exec -it "$CONTAINER_NAME" /usr/local/bin/docker-entrypoint.sh "${AGENT_COMMAND[@]}"
else
    echo "Launching ${ACTIVE_AGENT} (ephemeral mode) via ${DEVA_DOCKER_IMAGE}:${DEVA_DOCKER_TAG}"
    write_session_file
    if ! docker "${DOCKER_ARGS[@]}" "${AGENT_COMMAND[@]}"; then
        echo "error: failed to launch ephemeral container" >&2
        exit 1
    fi
fi
