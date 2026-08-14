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
    AGENT_COMMAND=("dsh")

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

    AGENT_COMMAND+=("${remaining_args[@]+"${remaining_args[@]}"}")

    setup_dsh_auth "$AUTH_METHOD"
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
