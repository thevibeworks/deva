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
    AGENT_COMMAND=("gemini")

    parse_auth_args "gemini" "${args[@]+"${args[@]}"}"
    AUTH_METHOD="$PARSED_AUTH_METHOD"
    local -a remaining_args=("${PARSED_REMAINING_ARGS[@]+"${PARSED_REMAINING_ARGS[@]}"}")

    AGENT_COMMAND+=("--yolo")

    AGENT_COMMAND+=("${remaining_args[@]+"${remaining_args[@]}"}")

    setup_gemini_auth "$AUTH_METHOD"
}

setup_gemini_auth() {
    local method="$1"

    case "$method" in
        gemini-app-oauth|oauth)
            AUTH_DETAILS="gemini-app-oauth (~/.gemini)"
            if [ -d "$HOME/.gemini" ]; then
                DOCKER_ARGS+=("-v" "$HOME/.gemini:/home/deva/.gemini")
            else
                echo "Warning: ~/.gemini directory not found, creating it" >&2
                mkdir -p "$HOME/.gemini"
                DOCKER_ARGS+=("-v" "$HOME/.gemini:/home/deva/.gemini")
            fi
            ;;
        api-key|gemini-api-key)
            if [ -z "${GEMINI_API_KEY:-}" ]; then
                auth_error "GEMINI_API_KEY not set for --auth-with api-key" \
                           "Set: export GEMINI_API_KEY=your_key"
            fi

            AUTH_DETAILS="api-key (GEMINI_API_KEY)"
            DOCKER_ARGS+=("-e" "GEMINI_API_KEY=$GEMINI_API_KEY")

            local gemini_config_dir
            if [ -n "${CONFIG_ROOT:-}" ]; then
                case "$CONFIG_ROOT" in
                    /*) ;;
                    *) auth_error "CONFIG_ROOT must be absolute path: $CONFIG_ROOT" ;;
                esac
                case "$CONFIG_ROOT" in
                    *..* | *//* | *$'\n'* | *$'\t'*)
                        auth_error "CONFIG_ROOT contains invalid path pattern: $CONFIG_ROOT"
                        ;;
                esac
                local xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
                case "$CONFIG_ROOT" in
                    "$HOME"/* | "$xdg_config"/* | /tmp/deva-*)
                        gemini_config_dir="$CONFIG_ROOT/gemini/.gemini"
                        ;;
                    *)
                        auth_error "CONFIG_ROOT must be under $HOME or XDG_CONFIG_HOME: $CONFIG_ROOT"
                        ;;
                esac
            else
                gemini_config_dir="$HOME/.gemini"
            fi

            mkdir -p "$gemini_config_dir"
            rm -f "$gemini_config_dir/mcp-oauth-tokens-v2.json"

            local settings_file="$gemini_config_dir/settings.json"
            if [ ! -f "$settings_file" ] || ! grep -q '"selectedType"' "$settings_file" 2>/dev/null; then
                cat > "$settings_file" <<'EOF'
{
  "security": {
    "auth": {
      "selectedType": "gemini-api-key"
    }
  }
}
EOF
                echo "Created gemini settings with API key auth: $settings_file" >&2
            else
                echo "Using existing gemini settings: $settings_file" >&2
            fi
            ;;
        vertex)
            AUTH_DETAILS="google-vertex (gcloud)"
            if [ -d "$HOME/.config/gcloud" ]; then
                DOCKER_ARGS+=("-v" "$HOME/.config/gcloud:/home/deva/.config/gcloud:ro")
            fi
            if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
                DOCKER_ARGS+=("-v" "$GOOGLE_APPLICATION_CREDENTIALS:$GOOGLE_APPLICATION_CREDENTIALS:ro")
                DOCKER_ARGS+=("-e" "GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS")
            fi
            if [ -n "${GOOGLE_CLOUD_PROJECT:-}" ]; then
                DOCKER_ARGS+=("-e" "GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT")
            fi
            if [ -n "${GOOGLE_CLOUD_LOCATION:-}" ]; then
                DOCKER_ARGS+=("-e" "GOOGLE_CLOUD_LOCATION=$GOOGLE_CLOUD_LOCATION")
            fi
            ;;
        compute-adc)
            AUTH_DETAILS="compute-default-credentials (GCE metadata)"
            ;;
        credentials-file)
            if [ -z "${CUSTOM_CREDENTIALS_FILE:-}" ]; then
                auth_error "CUSTOM_CREDENTIALS_FILE not set for credentials-file auth"
            fi
            AUTH_DETAILS="credentials-file ($CUSTOM_CREDENTIALS_FILE)"
            DOCKER_ARGS+=("-v" "$CUSTOM_CREDENTIALS_FILE:/home/deva/.config/gcloud/service-account-key.json:ro")
            DOCKER_ARGS+=("-e" "GOOGLE_APPLICATION_CREDENTIALS=/home/deva/.config/gcloud/service-account-key.json")
            echo "Using custom credentials: $CUSTOM_CREDENTIALS_FILE -> service-account-key.json" >&2
            ;;
        *)
            auth_error "auth method '$method' not implemented for gemini"
            ;;
    esac
}
