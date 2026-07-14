# shellcheck shell=bash

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/shared_auth.sh"

toml_escape_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

codex_browser_mcp_config_override() {
    local package
    package="$(configured_env_value DEVA_CODEX_BROWSER_MCP_PACKAGE || true)"
    [ -n "$package" ] || package="$(configured_env_value DEVA_PLAYWRIGHT_MCP_PACKAGE || true)"
    [ -n "$package" ] || package="${DEVA_CODEX_BROWSER_MCP_PACKAGE:-${DEVA_PLAYWRIGHT_MCP_PACKAGE:-@playwright/mcp@0.0.75}}"
    package="$(toml_escape_string "$package")"

    printf '%s' "mcp_servers.playwright={command=\"npx\",args=[\"-y\",\"${package}\",\"--headless\",\"--browser\",\"chromium\",\"--no-sandbox\",\"--isolated\"],startup_timeout_sec=30}"
}

agent_prepare() {
    local -a args
    if [ $# -gt 0 ]; then
        args=("$@")
    else
        args=()
    fi
    AGENT_COMMAND=("codex")

    parse_auth_args "codex" "${args[@]+"${args[@]}"}"
    AUTH_METHOD="$PARSED_AUTH_METHOD"
    local -a remaining_args=("${PARSED_REMAINING_ARGS[@]+"${PARSED_REMAINING_ARGS[@]}"}")

    # Detect --trace flag — only before the -- sentinel; after it, args
    # belong to the agent CLI verbatim (#427). First -- is stripped.
    local use_trace=false
    local seen_sep=false
    if [ ${#remaining_args[@]} -gt 0 ]; then
        local -a filtered_args=()
        local arg
        for arg in "${remaining_args[@]}"; do
            if [ "$arg" = "--" ] && [ "$seen_sep" = false ]; then
                seen_sep=true
            elif [ "$arg" = "--trace" ] && [ "$seen_sep" = false ]; then
                use_trace=true
            else
                filtered_args+=("$arg")
            fi
        done
        remaining_args=("${filtered_args[@]+"${filtered_args[@]}"}")
    fi

    local has_dangerous=false
    local has_model=false

    if [ ${#remaining_args[@]} -gt 0 ]; then
        for ((i=0; i<${#remaining_args[@]}; i++)); do
            case "${remaining_args[$i]}" in
                --dangerously-bypass-approvals-and-sandbox)
                    has_dangerous=true
                    ;;
                -m|--model)
                    has_model=true
                    ((i++))
                    ;;
                -m*)
                    has_model=true
                    ;;
                --model=*)
                    has_model=true
                    ;;
            esac
        done
    fi

    if [ "$has_dangerous" = false ]; then
        AGENT_COMMAND+=("--dangerously-bypass-approvals-and-sandbox")
    fi
    if [ "$has_model" = false ]; then
        AGENT_COMMAND+=("-m" "${DEVA_DEFAULT_CODEX_MODEL:-gpt-5-codex}")
    fi

    if [ "${DEVA_CODEX_BROWSER_MCP:-${DEVA_WITH_BROWSER:-0}}" = "1" ]; then
        AGENT_COMMAND+=("--config" "$(codex_browser_mcp_config_override)")
    fi

    local codex_config
    for codex_config in "${CODEX_CONFIG_OVERRIDES[@]+"${CODEX_CONFIG_OVERRIDES[@]}"}"; do
        AGENT_COMMAND+=("--config" "$codex_config")
    done

    AGENT_COMMAND+=("${remaining_args[@]+"${remaining_args[@]}"}")

    if [ "$use_trace" = true ]; then
        # cctrace codex profile: codex args go after "--"; always mitm.
        # DEVA_TRACE=1 installs the MITM CA into the container store (#414).
        DOCKER_ARGS+=("-e" "DEVA_TRACE=1")
        DEVA_TRACE_ACTIVE=true
        setup_trace_ui_port
        AGENT_COMMAND=("cctrace" "codex" "--no-open" "--" "${AGENT_COMMAND[@]:1}")
    fi

    DOCKER_ARGS+=("-p" "127.0.0.1:1455:1455")

    setup_codex_auth "$AUTH_METHOD"
}

setup_codex_auth() {
    local method="$1"

    case "$method" in
        chatgpt)
            AUTH_DETAILS="chatgpt-oauth (~/.codex)"
            ;;
        api-key)
            validate_openai_key || auth_error "OPENAI_API_KEY not set for --auth-with api-key" \
                                              "Set: export OPENAI_API_KEY=your_api_key"
            AUTH_DETAILS="api-key (OPENAI_API_KEY)"
            DOCKER_ARGS+=("-e" "OPENAI_API_KEY=$OPENAI_API_KEY")
            ;;
        copilot)
            validate_github_token || auth_error "No GitHub token found for copilot auth" \
                                                "Run: copilot-api auth, or set GH_TOKEN=\$(gh auth token)"
            if [ "${DRY_RUN:-false}" = true ]; then
                echo "Skipping copilot proxy start during --dry-run" >&2
            else
                start_copilot_proxy
            fi

            AUTH_DETAILS="github-copilot (proxy port $COPILOT_PROXY_PORT)"
            DOCKER_ARGS+=("-e" "OPENAI_BASE_URL=http://$COPILOT_HOST_MAPPING:$COPILOT_PROXY_PORT")
            DOCKER_ARGS+=("-e" "OPENAI_API_KEY=dummy")

            if [ "${DRY_RUN:-false}" != true ] && [ -z "${OPENAI_MODEL:-}" ]; then
                local models
                models=$(pick_copilot_models "http://$COPILOT_LOCALHOST_MAPPING:$COPILOT_PROXY_PORT")
                local main_model="${models%% *}"
                DOCKER_ARGS+=("-e" "OPENAI_MODEL=$main_model")
            fi

            local no_proxy="$COPILOT_HOST_MAPPING,$COPILOT_LOCALHOST_MAPPING,127.0.0.1"
            DOCKER_ARGS+=("-e" "NO_PROXY=${NO_PROXY:+$NO_PROXY,}$no_proxy")
            DOCKER_ARGS+=("-e" "no_grpc_proxy=${NO_GRPC_PROXY:+$NO_GRPC_PROXY,}$no_proxy")
            ;;
        credentials-file)
            if [ -z "${CUSTOM_CREDENTIALS_FILE:-}" ]; then
                auth_error "CUSTOM_CREDENTIALS_FILE not set for credentials-file auth"
            fi
            AUTH_DETAILS="credentials-file ($CUSTOM_CREDENTIALS_FILE)"
            DOCKER_ARGS+=("-v" "$CUSTOM_CREDENTIALS_FILE:/home/deva/.codex/auth.json")
            echo "Using custom credentials: $CUSTOM_CREDENTIALS_FILE -> /home/deva/.codex/auth.json" >&2
            ;;
        *)
            auth_error "auth method '$method' not implemented"
            ;;
    esac
}
