# shellcheck shell=bash

# Load shared auth utilities
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
    AGENT_COMMAND=("codex")

    parse_auth_args "codex" "${args[@]+"${args[@]}"}"
    AUTH_METHOD="$PARSED_AUTH_METHOD"
    local -a remaining_args=("${PARSED_REMAINING_ARGS[@]+"${PARSED_REMAINING_ARGS[@]}"}")

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

    AGENT_COMMAND+=("${remaining_args[@]+"${remaining_args[@]}"}")

    DOCKER_ARGS+=("-p" "127.0.0.1:1455:1455")

    setup_codex_auth "$AUTH_METHOD"
}

setup_codex_auth() {
    local method="$1"

    case "$method" in
        chatgpt)
            ;;
        api-key)
            validate_openai_key || auth_error "OPENAI_API_KEY not set for --auth-with api-key" \
                                              "Set: export OPENAI_API_KEY=your_api_key"
            DOCKER_ARGS+=("-e" "OPENAI_API_KEY=$OPENAI_API_KEY")
            ;;
        copilot)
            validate_github_token || auth_error "No GitHub token found for copilot auth" \
                                                "Run: copilot-api auth, or set GH_TOKEN=\$(gh auth token)"
            start_copilot_proxy

            DOCKER_ARGS+=("-e" "OPENAI_BASE_URL=http://$COPILOT_HOST_MAPPING:$COPILOT_PROXY_PORT")
            DOCKER_ARGS+=("-e" "OPENAI_API_KEY=dummy")

            if [ -z "${OPENAI_MODEL:-}" ]; then
                local models
                models=$(pick_copilot_models "http://$COPILOT_LOCALHOST_MAPPING:$COPILOT_PROXY_PORT")
                local main_model="${models%% *}"
                DOCKER_ARGS+=("-e" "OPENAI_MODEL=$main_model")
            fi

            # Configure proxy settings for container
            local no_proxy="$COPILOT_HOST_MAPPING,$COPILOT_LOCALHOST_MAPPING,127.0.0.1"
            DOCKER_ARGS+=("-e" "NO_PROXY=${NO_PROXY:+$NO_PROXY,}$no_proxy")
            DOCKER_ARGS+=("-e" "no_grpc_proxy=${NO_GRPC_PROXY:+$NO_GRPC_PROXY,}$no_proxy")
            ;;
        *)
            auth_error "auth method '$method' not implemented"
            ;;
    esac
}
