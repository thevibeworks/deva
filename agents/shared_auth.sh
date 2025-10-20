# shellcheck shell=bash

# shellcheck disable=SC2034
readonly COPILOT_DEFAULT_PORT="4141"
# shellcheck disable=SC2034
readonly COPILOT_HOST_MAPPING="host.docker.internal"
# shellcheck disable=SC2034
readonly COPILOT_LOCALHOST_MAPPING="localhost"
readonly COPILOT_LOG_FILE="/tmp/deva-auth-copilot-api.log"
readonly COPILOT_CACHE_TTL=300

COPILOT_MODELS_CACHE=""
COPILOT_CACHE_TIME=0

auth_error() {
    echo "error: $1" >&2
    [ -n "${2:-}" ] && echo "hint: $2" >&2
    exit 1
}

debug_log() {
    if [ "${DEVA_DEBUG:-}" = "true" ]; then
        echo "DEBUG: $*" >&2
    fi
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]
}

validate_url() {
    local url="$1"
    [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]
}

validate_env_name() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

validate_github_token() {
    [ -f "$HOME/.local/share/copilot-api/github_token" ] || [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]
}

validate_anthropic_key() {
    [ -n "${ANTHROPIC_API_KEY:-}" ]
}

validate_openai_key() {
    [ -n "${OPENAI_API_KEY:-}" ]
}

COPILOT_PROXY_PID=""
COPILOT_PROXY_PORT="$COPILOT_DEFAULT_PORT"

is_process_alive() {
    local pid="$1"
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && grep -q "copilot-api" "/proc/$pid/cmdline" 2>/dev/null
}

start_copilot_proxy() {
    if is_process_alive "$COPILOT_PROXY_PID"; then
        echo "GitHub Copilot proxy already running (PID $COPILOT_PROXY_PID)"
        return 0
    fi

    if curl -s -f "http://localhost:$COPILOT_PROXY_PORT/" >/dev/null 2>&1; then
        echo "GitHub Copilot proxy already running on port $COPILOT_PROXY_PORT"
        return 0
    fi

    validate_github_token || auth_error "No GitHub token found for copilot auth" \
                                        "Run: copilot-api auth, or set GH_TOKEN=\$(gh auth token)"

    local cmd=(copilot-api start --port "$COPILOT_PROXY_PORT")
    if [ -f "$HOME/.local/share/copilot-api/github_token" ]; then
        echo "Using saved GitHub token from copilot-api"
    elif [ -n "${GH_TOKEN:-${GITHUB_TOKEN}}" ]; then
        echo "Using provided GitHub token"
        cmd+=(--github-token "${GH_TOKEN:-${GITHUB_TOKEN}}")
    fi

    debug_log "Starting GitHub Copilot API proxy on port $COPILOT_PROXY_PORT"
    echo "Starting GitHub Copilot API proxy..."
    echo "Proxy logs: $COPILOT_LOG_FILE"
    "${cmd[@]}" >>"$COPILOT_LOG_FILE" 2>&1 &
    COPILOT_PROXY_PID=$!

    local timeout="${COPILOT_PROXY_TIMEOUT:-30}"
    local attempt=0
    local backoff=0.1
    while [ "$attempt" -lt "$timeout" ]; do
        if curl -s -f "http://localhost:$COPILOT_PROXY_PORT/" >/dev/null 2>&1; then
            echo "✓ GitHub Copilot proxy ready on port $COPILOT_PROXY_PORT"
            return 0
        fi
        sleep "$backoff"
        attempt=$((attempt + 1))
        [ "$backoff" = "0.1" ] && backoff=0.2 || [ "$backoff" = "0.2" ] && backoff=0.5 || [ "$backoff" = "0.5" ] && backoff=1
    done

    echo "Last 20 lines from proxy log:" >&2
    tail -20 "$COPILOT_LOG_FILE" >&2
    auth_error "Copilot proxy failed to start after ${timeout}s" \
               "Check logs: $COPILOT_LOG_FILE"
}

stop_copilot_proxy() {
    if [ -n "$COPILOT_PROXY_PID" ]; then
        echo "Stopping Copilot proxy (PID $COPILOT_PROXY_PID)"
        kill "$COPILOT_PROXY_PID" 2>/dev/null || true
        COPILOT_PROXY_PID=""
    fi
}

pick_best_model() {
    local model_type="$1"
    local available_models="$2"
    local preferences=""

    case "$model_type" in
        main)
            preferences="claude-opus-4.1:100 claude-opus-4:90 claude-sonnet-4:80 gpt-5:70 gpt-4o:60"
            ;;
        fast)
            preferences="o3-mini-2025-01-31:100 o3-mini:90 gpt-4o-mini:80 gpt-5-mini:70 gpt-4o:60"
            ;;
        *)
            debug_log "Unknown model type: $model_type"
            return 1
            ;;
    esac

    local best_model=""
    local best_score=0

    local pref
    for pref in $preferences; do
        local model="${pref%:*}"
        local score="${pref#*:}"

        if echo "$available_models" | grep -q "^$model$"; then
            if [ "$score" -gt "$best_score" ]; then
                best_model="$model"
                best_score="$score"
            fi
        fi
    done

    echo "$best_model"
}

pick_copilot_models() {
    local base_url="${1:-http://$COPILOT_LOCALHOST_MAPPING:$COPILOT_PROXY_PORT}"
    local current_time
    current_time=$(date +%s)

    if [ -n "$COPILOT_MODELS_CACHE" ] && [ $((current_time - COPILOT_CACHE_TIME)) -lt $COPILOT_CACHE_TTL ]; then
        debug_log "Using cached model selection: $COPILOT_MODELS_CACHE"
        echo "$COPILOT_MODELS_CACHE"
        return 0
    fi

    debug_log "Cache miss, fetching models from $base_url"
    local models_json=""

    if command -v curl >/dev/null 2>&1; then
        models_json=$(curl -fsS --max-time 2 "$base_url/v1/models" 2>/dev/null || true)
    fi

    local main_model=""
    local fast_model=""

    if [ -n "$models_json" ] && command -v jq >/dev/null 2>&1; then
        local all_models
        all_models=$(echo "$models_json" | jq -r '.data[].id' 2>/dev/null || true)

        if [ -n "$all_models" ]; then
            debug_log "Available models: $(echo "$all_models" | tr '\n' ' ')"
            main_model=$(pick_best_model "main" "$all_models")
            fast_model=$(pick_best_model "fast" "$all_models")
        fi
    fi

    main_model="${main_model:-claude-sonnet-4}"
    fast_model="${fast_model:-o3-mini-2025-01-31}"

    COPILOT_MODELS_CACHE="$main_model $fast_model"
    COPILOT_CACHE_TIME="$current_time"

    debug_log "Selected and cached models: main=$main_model fast=$fast_model"
    echo "$main_model $fast_model"
}

convert_claude_model_alias() {
    case "$1" in
        sonnet-4) echo "claude-sonnet-4" ;;
        opus-4) echo "claude-opus-4" ;;
        opus-4.1) echo "claude-opus-4.1" ;;
        *) echo "$1" ;;
    esac
}

convert_openai_model_alias() {
    case "$1" in
        gpt-5-codex) echo "gpt-5-codex" ;;
        gpt-5) echo "gpt-5" ;;
        4o) echo "gpt-4o" ;;
        4o-mini) echo "gpt-4o-mini" ;;
        o3-mini) echo "o3-mini" ;;
        *) echo "$1" ;;
    esac
}

parse_auth_args() {
    local agent_name="$1"
    shift
    local -a args=("$@")
    local -a supported_methods

    case "$agent_name" in
        claude)
            supported_methods=(claude oat api-key bedrock vertex copilot)
            ;;
        codex)
            supported_methods=(chatgpt api-key copilot)
            ;;
        *)
            auth_error "Unknown agent: $agent_name"
            ;;
    esac

    local auth_method=""
    local -a remaining_args=()
    local i=0

    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            --auth-with)
                if [ $((i + 1)) -ge ${#args[@]} ]; then
                    auth_error "--auth-with requires a method"
                fi
                auth_method="${args[$((i + 1))]}"

                local method_supported=false
                local method
                for method in "${supported_methods[@]}"; do
                    if [ "$method" = "$auth_method" ]; then
                        method_supported=true
                        break
                    fi
                done

                if [ "$method_supported" = false ]; then
                    local supported_list
                    supported_list=$(IFS=', '; echo "${supported_methods[*]}")
                    auth_error "$agent_name agent doesn't support auth method '$auth_method'" \
                               "Supported: $supported_list"
                fi

                i=$((i + 2))
                ;;
            *)
                remaining_args+=("${args[$i]}")
                i=$((i + 1))
                ;;
        esac
    done

    if [ -z "$auth_method" ]; then
        case "$agent_name" in
            claude) auth_method="claude" ;;
            codex) auth_method="chatgpt" ;;
        esac
    fi

    # shellcheck disable=SC2034
    PARSED_AUTH_METHOD="$auth_method"
    # shellcheck disable=SC2034
    PARSED_REMAINING_ARGS=("${remaining_args[@]+"${remaining_args[@]}"}")
}