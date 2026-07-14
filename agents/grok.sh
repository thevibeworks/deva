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
    AGENT_COMMAND=("grok")

    parse_auth_args "grok" "${args[@]+"${args[@]}"}"
    AUTH_METHOD="$PARSED_AUTH_METHOD"
    local -a remaining_args=("${PARSED_REMAINING_ARGS[@]+"${PARSED_REMAINING_ARGS[@]}"}")

    # Detect --trace flag (cctrace grok client profile, cctrace >= 0.11)
    local use_trace=false
    if [ ${#remaining_args[@]} -gt 0 ]; then
        local -a filtered_args=()
        local arg
        for arg in "${remaining_args[@]}"; do
            if [ "$arg" = "--trace" ]; then
                use_trace=true
            else
                filtered_args+=("$arg")
            fi
        done
        remaining_args=("${filtered_args[@]+"${filtered_args[@]}"}")
    fi

    AGENT_COMMAND+=("--always-approve")

    AGENT_COMMAND+=("${remaining_args[@]+"${remaining_args[@]}"}")

    if [ "$use_trace" = true ]; then
        # cctrace grok profile: grok args go after "--"; always mitm.
        # DEVA_TRACE=1 installs the MITM CA into the container store (#414).
        DOCKER_ARGS+=("-e" "DEVA_TRACE=1")
        DEVA_TRACE_ACTIVE=true
        AGENT_COMMAND=("cctrace" "grok" "--no-open" "--" "${AGENT_COMMAND[@]:1}")
    fi

    setup_grok_auth "$AUTH_METHOD"
}

setup_grok_auth() {
    local method="$1"

    case "$method" in
        oauth)
            AUTH_DETAILS="oauth (~/.grok)"
            # First login inside a container has no browser: run
            # `grok login --device-auth` in the session, or auth on the
            # host once and let the mount carry ~/.grok/auth.json.
            # Only mount host ~/.grok directly when no config-home mechanism is active.
            # -Q bare mode: no mounts at all. Explicit/auto config-home: centralized mount handles it.
            if [ "${QUICK_MODE:-false}" = false ] && [ "${CONFIG_HOME_FROM_CLI:-false}" = false ] && [ "${CONFIG_HOME_AUTO:-false}" = false ]; then
                if [ -d "$HOME/.grok" ]; then
                    DOCKER_ARGS+=("-v" "$HOME/.grok:/home/deva/.grok")
                else
                    echo "Warning: ~/.grok directory not found, creating it" >&2
                    mkdir -p "$HOME/.grok"
                    DOCKER_ARGS+=("-v" "$HOME/.grok:/home/deva/.grok")
                fi
            fi
            ;;
        api-key)
            if [ -z "${XAI_API_KEY:-}" ]; then
                auth_error "XAI_API_KEY not set for --auth-with api-key" \
                           "Set: export XAI_API_KEY=your_key (from https://console.x.ai)"
            fi

            # No ~/.grok mount in this mode (grok_api_key_no_mount in
            # deva.sh): grok resolves config credentials above XAI_API_KEY,
            # so a mounted config.toml could silently bill another account.
            AUTH_DETAILS="api-key (XAI_API_KEY)"
            DOCKER_ARGS+=("-e" "XAI_API_KEY=$XAI_API_KEY")
            ;;
        *)
            auth_error "auth method '$method' not implemented for grok"
            ;;
    esac
}
