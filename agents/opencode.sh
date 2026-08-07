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
    AGENT_COMMAND=("opencode")

    parse_auth_args "opencode" "${args[@]+"${args[@]}"}"
    AUTH_METHOD="$PARSED_AUTH_METHOD"
    local -a remaining_args=("${PARSED_REMAINING_ARGS[@]+"${PARSED_REMAINING_ARGS[@]}"}")

    filter_trace_flag "${remaining_args[@]+"${remaining_args[@]}"}"
    local use_trace="$TRACE_FLAG_PRESENT"
    remaining_args=("${TRACE_FILTERED_ARGS[@]+"${TRACE_FILTERED_ARGS[@]}"}")

    if [ "$use_trace" = true ]; then
        auth_error "--trace is not supported for opencode yet" \
                   "cctrace has no opencode profile (thevibeworks/cctrace#89)"
    fi

    # Container is the sandbox: opencode already allows everything inside the
    # workspace; unlock the interactive asks (outside-workspace access,
    # doom-loop guard, .env reads) that would stall an unattended run.
    DOCKER_ARGS+=("-e" 'OPENCODE_PERMISSION={"doom_loop":"allow","external_directory":{"*":"allow"},"read":{"*":"allow"}}')
    # The image pins the CLI version; the in-app updater must not fight it.
    DOCKER_ARGS+=("-e" "OPENCODE_DISABLE_AUTOUPDATE=1")

    AGENT_COMMAND+=("${remaining_args[@]+"${remaining_args[@]}"}")

    setup_opencode_auth "$AUTH_METHOD"
}

setup_opencode_auth() {
    local method="$1"

    case "$method" in
        oauth)
            AUTH_DETAILS="oauth (~/.local/share/opencode)"
            # opencode is XDG-native: auth.json (from `opencode auth login` /
            # TUI /connect) lives in the data dir; config and state ride
            # along so plugins and model prefs persist. Cache (models.json,
            # self-update bin) stays container-local on purpose.
            # Only mount host dirs directly when no config-home mechanism is
            # active. -Q bare mode: no mounts at all. Explicit/auto
            # config-home: centralized mount handles it.
            if [ "${QUICK_MODE:-false}" = false ] && [ "${CONFIG_HOME_FROM_CLI:-false}" = false ] && [ "${CONFIG_HOME_AUTO:-false}" = false ]; then
                local entry
                while IFS= read -r entry; do
                    [ -n "$entry" ] || continue
                    if [ ! -d "$HOME/$entry" ]; then
                        echo "Warning: ~/$entry directory not found, creating it" >&2
                        mkdir -p "$HOME/$entry"
                    fi
                    DOCKER_ARGS+=("-v" "$HOME/$entry:/home/deva/$entry")
                done < <(agent_canonical_basenames "opencode")
            fi
            ;;
        api-key)
            # OPENCODE_API_KEY authenticates the opencode gateway provider
            # (console.opencode.ai service-account key). No mount: a mounted
            # data dir carries auth.json, which outranks the env key and
            # could silently bill another account (same no-mount contract
            # as grok/kimi api-key).
            local key="${OPENCODE_API_KEY:-}"
            if [ -z "$key" ]; then
                auth_error "OPENCODE_API_KEY not set for --auth-with api-key" \
                           "Set: export OPENCODE_API_KEY=your_key (from console.opencode.ai)"
            fi
            AUTH_DETAILS="api-key (OPENCODE_API_KEY)"
            DOCKER_ARGS+=("-e" "OPENCODE_API_KEY=$key")
            ;;
        *)
            auth_error "auth method '$method' not implemented for opencode"
            ;;
    esac
}
