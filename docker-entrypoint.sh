#!/bin/bash
set -e

DEVA_USER="${DEVA_USER:-deva}"
DEVA_UID="${DEVA_UID:-1001}"
DEVA_GID="${DEVA_GID:-1001}"
DEVA_HOME="${DEVA_HOME:-/home/deva}"
DEVA_AGENT="${DEVA_AGENT:-claude}"

get_claude_version() {
    local version=""
    for path in "/usr/local/bin/claude" "/usr/bin/claude" "$(command -v claude 2>/dev/null)"; do
        if [ -x "$path" ]; then
            version=$($path --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            break
        fi
    done
    echo "$version"
}

get_codex_version() {
    local version=""
    for path in "/usr/local/bin/codex" "/usr/bin/codex" "$(command -v codex 2>/dev/null)"; do
        if [ -x "$path" ]; then
            version=$($path --version 2>/dev/null | head -1)
            break
        fi
    done
    echo "$version"
}

show_environment_info() {
    local header="[deva]"
    case "$DEVA_AGENT" in
    claude)
        if [ -n "$CLAUDE_VERSION" ]; then
            header+=" Starting Claude Code v$CLAUDE_VERSION"
        else
            header+=" Claude Code (version detection failed)"
        fi
        ;;
    codex)
        if [ -n "$CODEX_VERSION" ]; then
            header+=" Starting Codex ($CODEX_VERSION)"
        else
            header+=" Codex CLI (version detection failed)"
        fi
        ;;
    *)
        header+=" Starting agent: $DEVA_AGENT"
        ;;
    esac
    echo "$header"

    if [ "$VERBOSE" = "true" ]; then
        echo ""
        echo "deva.sh YOLO Environment"
        echo "================================"
        echo "Agent: $DEVA_AGENT"
        echo "Working Directory: $(pwd)"
        echo "Running as: $(whoami) (UID=$(id -u), GID=$(id -g))"
        echo "Python: $(python3 --version 2>/dev/null || echo 'Not found')"
        echo "Node.js: $(node --version 2>/dev/null || echo 'Not found')"
        echo "Go: $(go version 2>/dev/null || echo 'Not found')"
        echo ""
        sleep 0.1

        if [ "$DEVA_AGENT" = "claude" ]; then
            local cli_path=""
            for path in "/usr/local/bin/claude" "/usr/bin/claude" "$(command -v claude 2>/dev/null)"; do
                if [ -x "$path" ]; then
                    cli_path="$path"
                    break
                fi
            done
            if [ -n "$cli_path" ]; then
                echo "Claude CLI: $($cli_path --version 2>/dev/null || echo 'Found but version failed')"
                echo "Claude location: $cli_path"
            else
                echo "Claude CLI not found in PATH"
            fi

            if [ -d "$DEVA_HOME/.claude" ]; then
                echo "Claude auth directory mounted"
                # shellcheck disable=SC2012
                ls -la "$DEVA_HOME/.claude" | head -5
            else
                echo "warning: Claude auth directory not found in $DEVA_HOME/.claude"
            fi
        else
            local codex_path=""
            for path in "/usr/local/bin/codex" "/usr/bin/codex" "$(command -v codex 2>/dev/null)"; do
                if [ -x "$path" ]; then
                    codex_path="$path"
                    break
                fi
            done
            if [ -n "$codex_path" ]; then
                echo "Codex CLI: $($codex_path --version 2>/dev/null || echo 'Found but version failed')"
                echo "Codex location: $codex_path"
            else
                echo "Codex CLI not found in PATH"
            fi

            if [ -d "$DEVA_HOME/.codex" ]; then
                echo "Codex auth directory mounted"
                # shellcheck disable=SC2012
                ls -la "$DEVA_HOME/.codex" | head -5
            else
                echo "warning: Codex auth directory not found in $DEVA_HOME/.codex"
            fi
        fi

        if [ -n "$grpc_proxy" ] || [ -n "$HTTP_PROXY" ] || [ -n "$HTTPS_PROXY" ]; then
            echo "Proxy configuration:"
            [ -n "$grpc_proxy" ] && echo "  gRPC: $grpc_proxy"
            [ -n "$HTTPS_PROXY" ] && echo "  HTTPS: $HTTPS_PROXY"
            [ -n "$HTTP_PROXY" ] && echo "  HTTP: $HTTP_PROXY"
        fi

        echo "Running as: $DEVA_USER (UID=$DEVA_UID, GID=$DEVA_GID)"
        echo "================================"
    fi
}

normalize_locale_variant() {
    local in="$1"
    [ -n "$in" ] || return 0
    local base="${in%%.*}"
    local enc="${in#*.}"
    if [ "$base" = "$in" ]; then
        printf '%s' "$in"
        return 0
    fi
    enc=$(printf '%s' "$enc" | tr '[:upper:]' '[:lower:]')
    if [ "$enc" = "utf8" ] || [ "$enc" = "utf-8" ]; then
        printf '%s.UTF-8' "$base"
    else
        printf '%s.%s' "$base" "$enc"
    fi
}

ensure_timezone() {
    if [ -n "$TZ" ] && [ -e "/usr/share/zoneinfo/$TZ" ]; then
        ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime 2>/dev/null || true
        echo "$TZ" >/etc/timezone 2>/dev/null || true
    fi
}

ensure_locale() {
    local want="${LC_ALL:-${LANG:-}}"
    [ -n "$want" ] || return 0

    local want_norm
    want_norm=$(normalize_locale_variant "$want")

    local want_lower
    want_lower=$(printf '%s' "$want_norm" | tr '[:upper:]' '[:lower:]')
    if locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qx -- "$want_lower"; then
        return 0
    fi

    local base="${want_norm%%.*}"
    local gen_line="${base}.UTF-8 UTF-8"
    if ! grep -q -E "^\s*${base}\.UTF-8\s+UTF-8\s*$" /etc/locale.gen 2>/dev/null; then
        printf '%s\n' "$gen_line" >>/etc/locale.gen 2>/dev/null || true
    fi
    if command -v locale-gen >/dev/null 2>&1; then
        locale-gen "$base.UTF-8" >/dev/null 2>&1 || true
    fi
    if command -v update-locale >/dev/null 2>&1; then
        update-locale LANG="$LANG" LC_ALL="${LC_ALL:-$LANG}" LANGUAGE="${LANGUAGE:-}" >/dev/null 2>&1 || true
    fi
}

setup_nonroot_user() {
    local current_uid
    current_uid=$(id -u "$DEVA_USER")
    local current_gid
    current_gid=$(id -g "$DEVA_USER")

    if [ "$DEVA_UID" = "0" ]; then
        echo "[entrypoint] WARNING: Host UID is 0. Using fallback 1000."
        DEVA_UID=1000
    fi
    if [ "$DEVA_GID" = "0" ]; then
        echo "[entrypoint] WARNING: Host GID is 0. Using fallback 1000."
        DEVA_GID=1000
    fi

    if [ "$DEVA_GID" != "$current_gid" ]; then
        [ "$VERBOSE" = "true" ] && echo "[entrypoint] updating $DEVA_USER GID: $current_gid -> $DEVA_GID"
        if getent group "$DEVA_GID" >/dev/null 2>&1; then
            local existing_group
            existing_group=$(getent group "$DEVA_GID" | cut -d: -f1)
            usermod -g "$DEVA_GID" "$DEVA_USER" 2>/dev/null || true
            [ "$VERBOSE" = "true" ] && echo "[entrypoint] joined existing group $existing_group"
        else
            groupmod -g "$DEVA_GID" "$DEVA_USER"
        fi
    fi

    if [ "$DEVA_UID" != "$current_uid" ]; then
        [ "$VERBOSE" = "true" ] && echo "[entrypoint] updating $DEVA_USER UID: $current_uid -> $DEVA_UID"
        # usermod may fail with rc=12 when it can't chown home directory (mounted volumes)
        # The UID change itself usually succeeds even when chown fails
        if ! usermod -u "$DEVA_UID" -g "$DEVA_GID" "$DEVA_USER" 2>/dev/null; then
            # Verify what UID we actually got
            local actual_uid
            actual_uid=$(id -u "$DEVA_USER" 2>/dev/null)
            if [ -z "$actual_uid" ]; then
                echo "[entrypoint] ERROR: cannot determine UID for $DEVA_USER" >&2
                exit 1
            fi
            if [ "$actual_uid" != "$DEVA_UID" ]; then
                echo "[entrypoint] WARNING: UID change failed ($DEVA_USER is UID $actual_uid, wanted $DEVA_UID)" >&2
                # Adapt to reality so subsequent operations use correct UID
                DEVA_UID="$actual_uid"
            fi
        fi
        # Only chown files owned by container, skip mounted volumes
        find "$DEVA_HOME" -maxdepth 1 ! -type l -user root -exec chown "$DEVA_UID:$DEVA_GID" {} \; 2>/dev/null || true
    fi

    chmod 755 /root 2>/dev/null || true
}

fix_rust_permissions() {
    local rh="/opt/rustup"
    local ch="/opt/cargo"
    if [ -d "$rh" ]; then chown -R "$DEVA_UID:$DEVA_GID" "$rh" 2>/dev/null || true; fi
    if [ -d "$ch" ]; then chown -R "$DEVA_UID:$DEVA_GID" "$ch" 2>/dev/null || true; fi
    [ -d "$rh" ] || mkdir -p "$rh"
    [ -d "$ch" ] || mkdir -p "$ch"
}

fix_docker_socket_permissions() {
    if [ -S /var/run/docker.sock ]; then
        chmod 666 /var/run/docker.sock 2>/dev/null || true
    fi
}

build_gosu_env_cmd() {
    local user="$1"
    shift
    exec gosu "$user" env "HOME=$DEVA_HOME" "PATH=$PATH" "$@"
}

ensure_agent_binaries() {
    case "$DEVA_AGENT" in
    claude)
        if ! command -v claude >/dev/null 2>&1; then
            echo "error: Claude CLI not found in container"
            exit 1
        fi
        ;;
    codex)
        if ! command -v codex >/dev/null 2>&1; then
            echo "error: Codex CLI not found in container"
            exit 1
        fi
        ;;
    esac
}

main() {
    export PATH="/home/deva/.local/bin:/home/deva/.npm-global/bin:/root/.local/bin:/usr/local/go/bin:/opt/cargo/bin:/usr/local/cargo/bin:$PATH"
    export RUSTUP_HOME="${RUSTUP_HOME:-/opt/rustup}"
    export CARGO_HOME="${CARGO_HOME:-/opt/cargo}"

    CLAUDE_VERSION="$(get_claude_version)"
    CODEX_VERSION="$(get_codex_version)"

    if [ -n "$ANTHROPIC_BASE_URL" ]; then
        case "$ANTHROPIC_BASE_URL" in
        http://localhost:* | http://localhost/* | http://127.0.0.1:* | http://127.0.0.1/*)
            export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL/localhost/host.docker.internal}"
            export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL/127.0.0.1/host.docker.internal}"
            ;;
        esac
    fi

    ensure_timezone
    ensure_locale
    show_environment_info

    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        cd "$WORKDIR"
    fi

    ensure_agent_binaries
    setup_nonroot_user
    fix_rust_permissions
    fix_docker_socket_permissions

    if [ $# -eq 0 ]; then
        if [ "$DEVA_AGENT" = "codex" ]; then
            build_gosu_env_cmd "$DEVA_USER" codex --dangerously-bypass-approvals-and-sandbox -m "${DEVA_DEFAULT_CODEX_MODEL:-gpt-5-codex}"
        else
            build_gosu_env_cmd "$DEVA_USER" claude --dangerously-skip-permissions
        fi
        return
    fi

    cmd="$1"
    shift

    if [ "$DEVA_AGENT" = "claude" ]; then
        if [ "$cmd" = "claude" ] || [ "$cmd" = "$(command -v claude 2>/dev/null)" ]; then
            # Add --dangerously-skip-permissions if not already present
            local has_dsp=false
            for arg in "$@"; do
                if [ "$arg" = "--dangerously-skip-permissions" ]; then
                    has_dsp=true
                    break
                fi
            done
            if [ "$has_dsp" = true ]; then
                build_gosu_env_cmd "$DEVA_USER" "$cmd" "$@"
            else
                build_gosu_env_cmd "$DEVA_USER" "$cmd" "$@" --dangerously-skip-permissions
            fi
        elif [ "$cmd" = "claude-trace" ]; then
            # claude-trace: ensure --dangerously-skip-permissions follows --run-with
            local has_dsp=false
            for arg in "$@"; do
                if [ "$arg" = "--dangerously-skip-permissions" ]; then
                    has_dsp=true
                    break
                fi
            done
            if [ "$has_dsp" = true ]; then
                # Already has --dangerously-skip-permissions, pass through
                build_gosu_env_cmd "$DEVA_USER" "$cmd" "$@"
            else
                # Insert --dangerously-skip-permissions after --run-with
                args=("$@")
                new_args=()
                for arg in "${args[@]}"; do
                    if [ "$arg" = "--run-with" ]; then
                        new_args+=("--run-with" "--dangerously-skip-permissions")
                    else
                        new_args+=("$arg")
                    fi
                done
                build_gosu_env_cmd "$DEVA_USER" "$cmd" "${new_args[@]}"
            fi
        else
            build_gosu_env_cmd "$DEVA_USER" "$cmd" "$@"
        fi
    else
        build_gosu_env_cmd "$DEVA_USER" "$cmd" "$@"
    fi
}

main "$@"
