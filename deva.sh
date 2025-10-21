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

DEVA_DOCKER_IMAGE="${DEVA_DOCKER_IMAGE:-ghcr.io/thevibeworks/deva}"
DEVA_DOCKER_TAG="${DEVA_DOCKER_TAG:-latest}"
DEVA_CONTAINER_PREFIX="${DEVA_CONTAINER_PREFIX:-deva}"
DEFAULT_AGENT="${DEVA_DEFAULT_AGENT:-claude}"

# Profile controls
# Prefer DEVA_PROFILE; accept legacy DEVA_IMAGE_PROFILE for back-compat
PROFILE="${DEVA_PROFILE:-${DEVA_IMAGE_PROFILE:-}}"

# Shared config directory (mounted for all agents, optional)
CONFIG_ROOT=""

USER_VOLUMES=()
USER_ENVS=()
EXTRA_DOCKER_ARGS=()
CONFIG_HOME=""
CONFIG_HOME_AUTO=false
CONFIG_HOME_FROM_CLI=false
AUTOLINK=true
if [ -n "${DEVA_NO_AUTOLINK:-}" ]; then AUTOLINK=false; fi
SKIP_CONFIG=false
CONFIG_ERRORS=()
LOADED_CONFIGS=()
AGENT_ARGS=()
AGENT_EXPLICIT=false

usage() {
    cat <<'USAGE'
deva.sh - Docker-based multi-agent launcher (Claude, Codex)

Usage:
  deva.sh [deva flags] [agent] [-- agent-flags]
  deva.sh [agent] [deva flags] [-- agent-flags]
  deva.sh shell
  deva.sh help

Container management:
  deva.sh --inspect          Attach to running container for current project
  deva.sh --ps               List containers for current project
  deva.sh rm                 Remove containers for current project
  deva.sh clean              Remove all deva containers (including stopped)
  deva.sh --show-config      Show resolved configuration (debug)

Deva flags:
  -v SRC:DEST[:OPT]       Mount additional volumes inside the container
  -c DIR, --config-home   DIR
                          Mount an alternate auth/config home into /home/deva
  -e VAR[=VALUE]          Pass environment variable into the container (pulls from host when VALUE omitted)
  -p NAME, --profile      NAME
                          Select profile: base (default), rust. Pulls tag, falls back to Dockerfile.<profile>
  --host-net              Use host networking for the agent container
  --                      Everything after this sentinel is passed to the agent unchanged

Examples:
  deva.sh                             # Launch default agent (Claude)
  deva.sh -p rust claude              # Deva flags like `deva.sh --flags`
  deva.sh codex -v ~/.ssh:/home/deva/.ssh:ro -- -m gpt-5-codex
  deva.sh -c ~/work-claude-home -- --trace
  deva.sh --show-config               # Debug configuration
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

# Determine default per-agent config home under XDG
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

project_container_rows() {
    local project
    local all_containers="${1:-false}"
    project="$(basename "$(pwd)")"

    local ps_flags=""
    if [ "$all_containers" = "true" ]; then
        ps_flags="-a"
    fi

    # List containers matching the project name pattern
    docker ps $ps_flags --filter "name=${DEVA_CONTAINER_PREFIX}-" --format '{{.Names}}\t{{.Status}}\t{{.CreatedAt}}' |
        grep -F -- "-${project}-" || true
}

extract_agent_from_name() {
    local name="$1"
    local rest
    rest="${name#"${DEVA_CONTAINER_PREFIX}"-}"
    printf '%s' "${rest%%-*}"
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

attach_to_container() {
    local container="$1"
    local user="${DEVA_USER:-deva}"
    if ! docker exec -it "$container" gosu "$user" /bin/zsh 2>/dev/null; then
        docker exec -it "$container" /bin/zsh
    fi
}

list_containers_pretty() {
    local rows
    rows=$(project_container_rows)
    if [ -z "$rows" ]; then
        echo "No running containers found for project $(basename "$(pwd)")"
        return
    fi

    printf 'NAME\tAGENT\tSTATUS\tCREATED AT\n'
    printf '%s\n' "$rows" | while IFS=$'\t' read -r name status created; do
        printf '%s\t%s\t%s\t%s\n' "$name" "$(extract_agent_from_name "$name")" "$status" "$created"
    done
}

remove_project_containers() {
    local project
    project="$(basename "$(pwd)")"
    local rows
    rows=$(project_container_rows true)

    if [ -z "$rows" ]; then
        echo "No containers found for project $project"
        return 0
    fi

    local count
    count=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    echo "Found $count container(s) for project $project:"
    printf '%s\n' "$rows" | while IFS=$'\t' read -r name status created; do
        printf '  - %s\t[%s]\n' "$name" "$status"
    done
    echo ""

    printf 'Remove all containers for project %s? (y/N): ' "$project"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Aborted"
        return 1
    fi

    printf '%s\n' "$rows" | while IFS=$'\t' read -r name status _; do
        echo "Removing container: $name"
        if docker rm -f "$name" >/dev/null 2>&1; then
            echo "✓ Removed $name"
        else
            echo "✗ Failed to remove $name" >&2
        fi
    done
}

remove_all_containers() {
    local all_rows
    all_rows=$(docker ps -a --filter "name=${DEVA_CONTAINER_PREFIX}-" --format '{{.Names}}\t{{.Status}}\t{{.CreatedAt}}')

    if [ -z "$all_rows" ]; then
        echo "No deva containers found"
        return 0
    fi

    local count
    count=$(printf '%s\n' "$all_rows" | wc -l | tr -d ' ')
    echo "Found $count deva container(s):"
    printf '%s\n' "$all_rows" | while IFS=$'\t' read -r name status created; do
        printf '  - %s\t[%s]\n' "$name" "$status"
    done
    echo ""

    printf 'Remove ALL deva containers? (y/N): '
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Aborted"
        return 1
    fi

    printf '%s\n' "$all_rows" | while IFS=$'\t' read -r name status _; do
        echo "Removing container: $name"
        if docker rm -f "$name" >/dev/null 2>&1; then
            echo "✓ Removed $name"
        else
            echo "✗ Failed to remove $name" >&2
        fi
    done
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
            # Mask sensitive values
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
    local project
    project="$(basename "$(pwd)")"
    container_name="${DEVA_CONTAINER_PREFIX}-${ACTIVE_AGENT}-${project}-$$"

    DOCKER_ARGS=(
        run --rm -it
        --name "$container_name"
        -v "$(pwd):$(pwd)"
        -w "$(pwd)"
        -e "WORKDIR=$(pwd)"
        -e "DEVA_AGENT=${ACTIVE_AGENT}"
        -e "DEVA_UID=$(id -u)"
        -e "DEVA_GID=$(id -g)"
        --add-host host.docker.internal:host-gateway
    )

    if [ -n "${LANG:-}" ]; then DOCKER_ARGS+=(-e "LANG=$LANG"); fi
    if [ -n "${LC_ALL:-}" ]; then DOCKER_ARGS+=(-e "LC_ALL=$LC_ALL"); fi
    if [ -n "${TZ:-}" ]; then DOCKER_ARGS+=(-e "TZ=$TZ"); fi
    if [ -n "${GIT_AUTHOR_NAME:-}" ]; then DOCKER_ARGS+=(-e "GIT_AUTHOR_NAME=$GIT_AUTHOR_NAME"); fi
    if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then DOCKER_ARGS+=(-e "GIT_AUTHOR_EMAIL=$GIT_AUTHOR_EMAIL"); fi
    if [ -n "${GIT_COMMITTER_NAME:-}" ]; then DOCKER_ARGS+=(-e "GIT_COMMITTER_NAME=$GIT_COMMITTER_NAME"); fi
    if [ -n "${GIT_COMMITTER_EMAIL:-}" ]; then DOCKER_ARGS+=(-e "GIT_COMMITTER_EMAIL=$GIT_COMMITTER_EMAIL"); fi
    if [ -n "${GH_TOKEN:-}" ]; then DOCKER_ARGS+=(-e "GH_TOKEN=$GH_TOKEN"); fi
    if [ -n "${GITHUB_TOKEN:-}" ]; then DOCKER_ARGS+=(-e "GITHUB_TOKEN=$GITHUB_TOKEN"); fi
    if [ -n "${OPENAI_API_KEY:-}" ]; then DOCKER_ARGS+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY"); fi
    if [ -n "${OPENAI_ORGANIZATION:-}" ]; then DOCKER_ARGS+=(-e "OPENAI_ORGANIZATION=$OPENAI_ORGANIZATION"); fi
    if [ -n "${OPENAI_BASE_URL:-}" ]; then DOCKER_ARGS+=(-e "OPENAI_BASE_URL=$OPENAI_BASE_URL"); fi

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
        # Warn about /root/* mounts (should be /home/deva/*)
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

append_user_envs() {
    if [ ${#USER_ENVS[@]} -eq 0 ]; then
        return
    fi

    local env_spec
    for env_spec in "${USER_ENVS[@]}"; do
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

    # Expand tilde
    if [[ "$src" == ~* ]]; then
        src="$(expand_tilde "$src")"
    fi

    # Resolve relative filesystem paths while leaving Docker named volumes untouched
    if [[ "$src" == ./* || "$src" == ../* ]]; then
        src="$(absolute_path "$src")"
    elif [[ "$src" == /* ]]; then
        :
    elif [[ "$src" == .* ]]; then
        src="$(absolute_path "$src")"
    fi

    echo "$src:$remainder"
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
    # New, preferred key
    PROFILE)
        PROFILE="$value"
        ;;
    # Legacy compatibility: map IMAGE_PROFILE to PROFILE silently
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
        --host-net)
            EXTRA_DOCKER_ARGS+=("--net" "host")
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

# Resolve image based on selected profile and overrides
resolve_profile() {
    # Map profiles to images (prefer prebuilt registries, fallback handled by check_image)
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
        # Unknown profile – leave as provided by env, check_image will report
        if [ "$DEVA_DOCKER_IMAGE_ENV_SET" = false ] && [ -z "${DEVA_DOCKER_IMAGE:-}" ]; then
            DEVA_DOCKER_IMAGE="$default_repo"
        fi
        ;;
    esac
}

is_known_agent() { [ -f "$AGENTS_DIR/$1.sh" ]; }

ACTION="run"
MANAGEMENT_MODE="launch"

# Split CLI into Deva flags, agent, and agent args (after --)
RAW_ARGS=("$@")
WRAPPER_ARGS=()
AGENT_ARGV=()
ACTIVE_AGENT=""

# Find sentinel index
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

# Detect management commands in PRE_ARGS
if [ ${#PRE_ARGS[@]} -gt 0 ]; then
for tok in "${PRE_ARGS[@]}"; do
    case "$tok" in
    help | --help | -h)
        usage
        exit 0
        ;;
    --show-config)
        MANAGEMENT_MODE="show-config"
        ;;
    shell)
        MANAGEMENT_MODE="inspect"
        ACTION="shell"
        ;;
    --inspect)
        MANAGEMENT_MODE="inspect"
        ;;
    --ps)
        MANAGEMENT_MODE="ps"
        ;;
    rm)
        MANAGEMENT_MODE="rm"
        ;;
    clean)
        MANAGEMENT_MODE="clean"
        ;;
    esac
done
fi

if [ "$MANAGEMENT_MODE" = "inspect" ] || [ "$MANAGEMENT_MODE" = "ps" ] || [ "$MANAGEMENT_MODE" = "show-config" ] || [ "$MANAGEMENT_MODE" = "rm" ] || [ "$MANAGEMENT_MODE" = "clean" ]; then
    if [ "$MANAGEMENT_MODE" = "ps" ]; then
        list_containers_pretty
        exit 0
    fi

    if [ "$MANAGEMENT_MODE" = "rm" ]; then
        remove_project_containers
        exit 0
    fi

    if [ "$MANAGEMENT_MODE" = "clean" ]; then
        remove_all_containers
        exit 0
    fi

    if [ "$MANAGEMENT_MODE" = "show-config" ]; then
        # Parse args first to load config
        if [ ${#RAW_ARGS[@]} -gt 0 ]; then
            parse_wrapper_args "${RAW_ARGS[@]}"
        fi
        load_config_sources
        # Detect agent from PRE_ARGS
        if [ ${#PRE_ARGS[@]} -gt 0 ]; then
            for tok in "${PRE_ARGS[@]}"; do
                if [[ "$tok" != -* ]] && [[ "$tok" != "help" ]] && [[ "$tok" != "shell" ]] && [[ "$tok" != "--inspect" ]] && [[ "$tok" != "--ps" ]] && [[ "$tok" != "--show-config" ]] && [[ "$tok" != "rm" ]] && [[ "$tok" != "clean" ]] && is_known_agent "$tok"; then
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

    container_name=$(pick_container) || exit 1
    attach_to_container "$container_name"
    exit 0
fi

# Select agent: first token in PRE_ARGS that matches a known agent
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

# Build WRAPPER_ARGS = PRE_ARGS minus agent token
if [ ${#PRE_ARGS[@]} -gt 0 ]; then
for i in "${!PRE_ARGS[@]}"; do
    if [ "$i" -eq "$agent_idx" ]; then continue; fi
    WRAPPER_ARGS+=("${PRE_ARGS[$i]}")
done
fi

# Agent argv is everything after --
if [ ${#POST_ARGS[@]} -gt 0 ]; then
    AGENT_ARGV=("${POST_ARGS[@]}")
else
    AGENT_ARGV=()
fi

# Parse Deva flags
if [ ${#WRAPPER_ARGS[@]} -gt 0 ]; then
    parse_wrapper_args "${WRAPPER_ARGS[@]}"
else
    parse_wrapper_args
fi
# Back-compat: treat unrecognized wrapper tokens as agent args
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

# Default per-agent CONFIG_HOME if not set
if [ -z "$CONFIG_HOME" ]; then
    set_config_home_value "$(default_config_home_for_agent "$ACTIVE_AGENT")"
    CONFIG_HOME_AUTO=true
fi

# Discover CONFIG_ROOT when using default XDG per-agent home
if [ "$CONFIG_HOME_AUTO" = true ]; then
    CONFIG_ROOT="$(dirname "$CONFIG_HOME")"
fi

# If user passed -c (or legacy -H) pointing at a deva root, treat it as CONFIG_ROOT
if [ "$CONFIG_HOME_FROM_CLI" = true ] && [ -n "$CONFIG_HOME" ]; then
    if [ -d "$CONFIG_HOME/claude" ] || [ -d "$CONFIG_HOME/codex" ]; then
        CONFIG_ROOT="$CONFIG_HOME"
        CONFIG_HOME=""
        CONFIG_HOME_AUTO=false
    fi
fi

# Auto-link legacy creds into deva root if absent (optional)
autolink_legacy_into_deva_root() {
    [ "$AUTOLINK" = true ] || return
    [ "$CONFIG_HOME_FROM_CLI" = false ] || return
    [ -n "${CONFIG_ROOT:-}" ] || return
    [ -d "$CONFIG_ROOT" ] || mkdir -p "$CONFIG_ROOT"

    # Claude
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
    # Ensure a persistent file exists for Claude CLI settings
    if [ -d "$CONFIG_ROOT/claude" ] && [ ! -e "$CONFIG_ROOT/claude/.claude.json" ] && [ ! -L "$CONFIG_ROOT/claude/.claude.json" ]; then
        echo '{}' >"$CONFIG_ROOT/claude/.claude.json"
        echo "scaffold: created $CONFIG_ROOT/claude/.claude.json" >&2
    fi

    # Codex
    if [ -d "$HOME/.codex" ]; then
        [ -d "$CONFIG_ROOT/codex" ] || mkdir -p "$CONFIG_ROOT/codex"
        if [ ! -e "$CONFIG_ROOT/codex/.codex" ] && [ ! -L "$CONFIG_ROOT/codex/.codex" ]; then
            ln -s "$HOME/.codex" "$CONFIG_ROOT/codex/.codex"
            echo "autolink: ~/.codex -> $CONFIG_ROOT/codex/.codex" >&2
        fi
    fi
    # Ensure Codex dir exists for persistence
    if [ -d "$CONFIG_ROOT" ]; then
        [ -d "$CONFIG_ROOT/codex/.codex" ] || mkdir -p "$CONFIG_ROOT/codex/.codex"
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
fi

if dangerous_directory; then
    warn_dangerous_directory
fi

resolve_profile
check_image
prepare_base_docker_args
append_user_volumes
append_user_envs
append_extra_docker_args
# Mount configs: prefer full deva root if detected
if [ -n "$CONFIG_ROOT" ] && [ -d "$CONFIG_ROOT" ]; then
    autolink_legacy_into_deva_root
    for d in "$CONFIG_ROOT"/*; do
        [ -d "$d" ] || continue
        [ "$(basename "$d")" = "_shared" ] && continue
        mount_dir_contents_into_home "$d"
    done
else
    autolink_legacy_into_deva_root
    mount_config_home
fi
load_agent_module
AGENT_COMMAND=()
if [ ${#AGENT_ARGV[@]} -gt 0 ]; then
    agent_prepare "${AGENT_ARGV[@]}"
else
    agent_prepare
fi

DOCKER_ARGS+=("${DEVA_DOCKER_IMAGE}:${DEVA_DOCKER_TAG}")

if [ "$ACTION" = "shell" ]; then
    AGENT_COMMAND=("/bin/zsh")
fi

if [ ${#AGENT_COMMAND[@]} -eq 0 ]; then
    echo "error: agent $ACTIVE_AGENT did not provide a launch command" >&2
    exit 1
fi

echo "Launching ${ACTIVE_AGENT} via ${DEVA_DOCKER_IMAGE}:${DEVA_DOCKER_TAG}"
docker "${DOCKER_ARGS[@]}" "${AGENT_COMMAND[@]}"
