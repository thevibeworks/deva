# shellcheck shell=bash

# shellcheck disable=SC1091
if [ -f "$(dirname "${BASH_SOURCE[0]}")/shared_auth.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/shared_auth.sh"
fi

# Provider API keys pi reads from the environment (packages/ai
# env-api-keys). deva's api-key mode passes every one that is set --
# pi is multi-provider by design -- and requires at least one.
# Order matters: the first set key names the auth tag.
PI_API_KEY_VARS=(ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY XAI_API_KEY OPENROUTER_API_KEY)

agent_prepare() {
    local -a args
    if [ $# -gt 0 ]; then
        args=("$@")
    else
        args=()
    fi
    AGENT_COMMAND=("pi")

    parse_auth_args "pi" "${args[@]+"${args[@]}"}"
    AUTH_METHOD="$PARSED_AUTH_METHOD"
    local -a remaining_args=("${PARSED_REMAINING_ARGS[@]+"${PARSED_REMAINING_ARGS[@]}"}")

    filter_trace_flag "${remaining_args[@]+"${remaining_args[@]}"}"
    local use_trace="$TRACE_FLAG_PRESENT"
    remaining_args=("${TRACE_FILTERED_ARGS[@]+"${TRACE_FILTERED_ARGS[@]}"}")

    if [ "$use_trace" = true ]; then
        auth_error "--trace is not supported for pi yet" \
                   "cctrace has no pi profile"
    fi

    # Container is the sandbox: pi has no permission system at all (its
    # security doc says to run it in a contained environment -- that is
    # exactly what deva does). The one interactive gate is project trust
    # (loading workspace .pi/ settings/extensions, default ask); --approve
    # unlocks it so unattended runs never stall on the prompt.
    AGENT_COMMAND+=("--approve")
    # The image pins the CLI; the startup version check would nag (and
    # phone pi.dev) on every launch for an update we deliberately hold.
    DOCKER_ARGS+=("-e" "PI_SKIP_VERSION_CHECK=1")

    AGENT_COMMAND+=("${remaining_args[@]+"${remaining_args[@]}"}")

    setup_pi_auth "$AUTH_METHOD"
}

setup_pi_auth() {
    local method="$1"

    case "$method" in
        oauth)
            AUTH_DETAILS="oauth (~/.pi)"
            # Everything pi persists lives under ~/.pi/agent (no XDG):
            # auth.json (from in-app /login; tokens AUTO-REFRESH, so the
            # mount must stay writable), sessions, settings, trust.json.
            # Only mount the host dir directly when no config-home
            # mechanism is active. -Q bare mode: no mounts at all.
            # Explicit/auto config-home: centralized mount handles it.
            if [ "${QUICK_MODE:-false}" = false ] && [ "${CONFIG_HOME_FROM_CLI:-false}" = false ] && [ "${CONFIG_HOME_AUTO:-false}" = false ]; then
                if [ ! -d "$HOME/.pi" ]; then
                    echo "Warning: ~/.pi directory not found, creating it" >&2
                    mkdir -p "$HOME/.pi"
                fi
                DOCKER_ARGS+=("-v" "$HOME/.pi:/home/deva/.pi")
            fi
            ;;
        api-key)
            # Provider keys travel as env only. No mount: a mounted ~/.pi
            # carries auth.json, which OUTRANKS env keys in pi and could
            # silently bill another account (same no-mount contract as
            # grok/kimi/opencode api-key). At least one key is required;
            # all set keys are passed -- pi is multi-provider by design.
            local var found=""
            for var in "${PI_API_KEY_VARS[@]}"; do
                if [ -n "${!var:-}" ]; then
                    [ -n "$found" ] || found="$var"
                    DOCKER_ARGS+=("-e" "${var}=${!var}")
                fi
            done
            if [ -z "$found" ]; then
                auth_error "no provider API key set for --auth-with api-key" \
                           "Set at least one of: ${PI_API_KEY_VARS[*]}"
            fi
            AUTH_DETAILS="api-key (${found})"
            ;;
        *)
            auth_error "auth method '$method' not implemented for pi"
            ;;
    esac
}
