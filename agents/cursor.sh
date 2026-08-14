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
    AGENT_COMMAND=("cursor-agent")

    parse_auth_args "cursor" "${args[@]+"${args[@]}"}"
    AUTH_METHOD="$PARSED_AUTH_METHOD"
    local -a remaining_args=("${PARSED_REMAINING_ARGS[@]+"${PARSED_REMAINING_ARGS[@]}"}")

    filter_trace_flag "${remaining_args[@]+"${remaining_args[@]}"}"
    local use_trace="$TRACE_FLAG_PRESENT"
    remaining_args=("${TRACE_FILTERED_ARGS[@]+"${TRACE_FILTERED_ARGS[@]}"}")

    if [ "$use_trace" = true ]; then
        auth_error "--trace is not supported for cursor yet" \
                   "cctrace has no cursor profile"
    fi

    # Container is the sandbox: --force ("Run Everything"; --yolo is its
    # alias) allows commands unless explicitly denied, same rationale as
    # every other agent. The image neutralizes the CLI's silent startup
    # self-update by stripping the write bit from its versions dir --
    # updaters fight pins.
    AGENT_COMMAND+=("--force")
    # Login flow is browser OAuth; in a container there is no browser.
    # NO_OPEN_BROWSER makes `cursor-agent login` print the URL instead,
    # so first login works over any terminal. Harmless otherwise.
    DOCKER_ARGS+=("-e" "NO_OPEN_BROWSER=1")

    AGENT_COMMAND+=("${remaining_args[@]+"${remaining_args[@]}"}")

    setup_cursor_auth "$AUTH_METHOD"
}

setup_cursor_auth() {
    local method="$1"

    case "$method" in
        oauth)
            AUTH_DETAILS="oauth (config-home cursor)"
            # No host ~/.cursor mount, ever -- unlike ~/.pi or ~/.dsh
            # that dir is the Cursor IDE's state (worktrees, per-project
            # chats, IDE config), not a CLI-only home, and on macOS the
            # CLI keeps auth in the keychain anyway so the mount would
            # not even carry credentials across. Cursor state lives in
            # the per-agent config home (~/.config/deva/cursor): run
            # `cursor-agent login` once inside the container (the URL
            # prints, NO_OPEN_BROWSER is set) and auth.json persists in
            # the mounted config home. -Q bare mode: no mounts at all.
            ;;
        api-key)
            # CURSOR_API_KEY travels as env only. No mount, and the
            # default credential path gets a blank overlay: a carried-in
            # auth.json could silently bill another account (same
            # no-mount contract as grok/kimi/opencode/pi/dsh api-key).
            if [ -z "${CURSOR_API_KEY:-}" ]; then
                auth_error "CURSOR_API_KEY not set for --auth-with api-key" \
                           "Set CURSOR_API_KEY or use oauth mode (default)"
            fi
            DOCKER_ARGS+=("-e" "CURSOR_API_KEY=${CURSOR_API_KEY}")
            AUTH_DETAILS="api-key (CURSOR_API_KEY)"
            ;;
        *)
            auth_error "auth method '$method' not implemented for cursor"
            ;;
    esac
}
