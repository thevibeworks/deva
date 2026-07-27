# shellcheck shell=bash

# shellcheck disable=SC1091
if [ -f "$(dirname "${BASH_SOURCE[0]}")/shared_auth.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/shared_auth.sh"
fi

agent_prepare() {
    local -a args
    if [ $# -gt 0 ]; then
        args=("$@")
    else
        args=()
    fi
    AGENT_COMMAND=("kimi")

    parse_auth_args "kimi" "${args[@]+"${args[@]}"}"
    AUTH_METHOD="$PARSED_AUTH_METHOD"
    local -a remaining_args=("${PARSED_REMAINING_ARGS[@]+"${PARSED_REMAINING_ARGS[@]}"}")

    filter_trace_flag "${remaining_args[@]+"${remaining_args[@]}"}"
    local use_trace="$TRACE_FLAG_PRESENT"
    remaining_args=("${TRACE_FILTERED_ARGS[@]+"${TRACE_FILTERED_ARGS[@]}"}")

    # Container is the sandbox: auto-approve tool calls. --yolo still lets the
    # agent ask clarifying questions (unlike --auto), so interactive use works.
    AGENT_COMMAND+=("--yolo")

    AGENT_COMMAND+=("${remaining_args[@]+"${remaining_args[@]}"}")

    if [ "$use_trace" = true ]; then
        # cctrace kimi profile: kimi args go after "--"; always mitm.
        # DEVA_TRACE=1 installs the MITM CA into the container store (#414).
        DOCKER_ARGS+=("-e" "DEVA_TRACE=1")
        DEVA_TRACE_ACTIVE=true
        setup_trace_ui_port
        AGENT_COMMAND=("cctrace" "kimi" "--no-open" "--" "${AGENT_COMMAND[@]:1}")
    fi

    setup_kimi_auth "$AUTH_METHOD"
}

setup_kimi_auth() {
    local method="$1"

    case "$method" in
        oauth)
            AUTH_DETAILS="oauth (~/.kimi-code)"
            # First login inside a container has no browser: run
            # `kimi login` in the session (device-code flow, enter the code
            # on any device), or log in on the host once and let the mount
            # carry ~/.kimi-code.
            # Only mount host ~/.kimi-code directly when no config-home mechanism is active.
            # -Q bare mode: no mounts at all. Explicit/auto config-home: centralized mount handles it.
            if [ "${QUICK_MODE:-false}" = false ] && [ "${CONFIG_HOME_FROM_CLI:-false}" = false ] && [ "${CONFIG_HOME_AUTO:-false}" = false ]; then
                if [ -d "$HOME/.kimi-code" ]; then
                    DOCKER_ARGS+=("-v" "$HOME/.kimi-code:/home/deva/.kimi-code")
                else
                    echo "Warning: ~/.kimi-code directory not found, creating it" >&2
                    mkdir -p "$HOME/.kimi-code"
                    DOCKER_ARGS+=("-v" "$HOME/.kimi-code:/home/deva/.kimi-code")
                fi
            fi
            ;;
        api-key)
            # kimi reads NO credential from the shell env (its docs are explicit:
            # `export KIMI_API_KEY` does nothing). The one shell channel is the
            # KIMI_MODEL_* family, which synthesizes an in-memory provider. The
            # key is never written to config.toml, so no ~/.kimi-code mount is
            # needed and the key never lands on disk.
            local key="${KIMI_CODE_API_KEY:-${KIMI_API_KEY:-}}"
            if [ -z "$key" ]; then
                auth_error "KIMI_CODE_API_KEY not set for --auth-with api-key" \
                           "Set: export KIMI_CODE_API_KEY=your_key (from https://platform.kimi.com)"
            fi

            # sk-kim… coding keys authenticate against the Kimi Code coding
            # endpoint, not moonshot.ai. Override both via DEVA_KIMI_* for a
            # direct Moonshot key (base_url https://api.moonshot.ai/v1).
            local model="${DEVA_KIMI_MODEL:-k3}"
            local base_url="${DEVA_KIMI_BASE_URL:-https://api.kimi.com/coding/v1}"

            AUTH_DETAILS="api-key (KIMI_CODE_API_KEY -> KIMI_MODEL_*, model=$model)"
            DOCKER_ARGS+=("-e" "KIMI_MODEL_NAME=$model")
            DOCKER_ARGS+=("-e" "KIMI_MODEL_API_KEY=$key")
            DOCKER_ARGS+=("-e" "KIMI_MODEL_PROVIDER_TYPE=kimi")
            DOCKER_ARGS+=("-e" "KIMI_MODEL_BASE_URL=$base_url")
            ;;
        *)
            auth_error "auth method '$method' not implemented for kimi"
            ;;
    esac
}
