# deva.sh - Docker Image
# Provides a fully isolated Claude Code environment with sensible development tools

FROM ubuntu:24.04 AS base

LABEL maintainer="github.com/thevibeworks"
LABEL org.opencontainers.image.title="deva"
LABEL org.opencontainers.image.description="Containerized development environment for Claude Code, Codex, and AI coding tools"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    TZ=UTC \
    PATH=/root/.local/bin:/usr/local/go/bin:$PATH

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget git git-lfs gnupg lsb-release locales tzdata sudo \
        software-properties-common build-essential pkg-config libssl-dev \
        unzip zip bzip2 xz-utils tini gosu less man-db \
        python3-dev libffi-dev \
        jq ripgrep lsof tree make gcc g++ \
        openssh-client rsync \
        shellcheck bat fd-find silversearcher-ag \
        vim \
        procps psmisc zsh && \
    add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.12 python3.12-dev python3.12-venv python3-pip pipx && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.12 1 && \
    locale-gen en_US.UTF-8

# Initialize Git LFS so it's usable for all users
RUN git lfs install --system

# Install language runtimes in parallel-friendly layers
FROM base AS runtimes

ARG NODE_MAJOR=22
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get -y clean && rm -rf /var/lib/apt/lists/*

# Install bun runtime before building Copilot API fork
RUN curl -fsSL https://bun.sh/install | bash && \
    ln -s /root/.bun/bin/bun /usr/local/bin/bun

# Install Copilot API branch with GPT-5 Codex responses support (PR #119 from caozhiyuan fork)
# Pinned to specific commit for reproducibility and security
ARG COPILOT_API_REPO=https://github.com/caozhiyuan/copilot-api.git
ARG COPILOT_API_BRANCH=feature/gpt-5-codex
ARG COPILOT_API_COMMIT=HEAD

RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm install -g npm@latest pnpm && \
    git clone --branch "${COPILOT_API_BRANCH}" "${COPILOT_API_REPO}" /tmp/copilot-api && \
    cd /tmp/copilot-api && \
    git checkout "${COPILOT_API_COMMIT}" && \
    git log --oneline -5 && \
    bun install --frozen-lockfile && bun run build && \
    cd /tmp && npm install -g --ignore-scripts /tmp/copilot-api && \
    rm -rf /tmp/copilot-api && \
    npm cache clean --force

RUN curl -LsSf https://astral.sh/uv/install.sh | sh

RUN --mount=type=cache,target=/tmp/go-cache,sharing=locked \
    ARCH=$(dpkg --print-architecture) && \
    GO_ARCH=$([ "$ARCH" = "amd64" ] && echo "amd64" || echo "arm64") && \
    cd /tmp/go-cache && \
    wget -q https://go.dev/dl/go1.22.0.linux-${GO_ARCH}.tar.gz && \
    tar -C /usr/local -xzf go1.22.0.linux-${GO_ARCH}.tar.gz

FROM runtimes AS cloud-tools

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin

RUN --mount=type=cache,target=/tmp/aws-cache,sharing=locked \
    ARCH=$(dpkg --print-architecture) && \
    AWS_ARCH=$([ "$ARCH" = "amd64" ] && echo "x86_64" || echo "aarch64") && \
    cd /tmp/aws-cache && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "awscliv2.zip" && \
    unzip -q awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws/

FROM cloud-tools AS tools

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    type -p wget >/dev/null || (apt-get update && apt-get install -y wget) && \
    mkdir -p -m 755 /etc/apt/keyrings && \
    wget -nv -O /tmp/githubcli-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg && \
    cat /tmp/githubcli-keyring.gpg > /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    mkdir -p -m 755 /etc/apt/sources.list.d && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y gh && \
    rm -f /tmp/githubcli-keyring.gpg

RUN --mount=type=cache,target=/tmp/delta-cache,sharing=locked \
    ARCH=$(dpkg --print-architecture) && \
    DELTA_ARCH=$([ "$ARCH" = "amd64" ] && echo "x86_64" || echo "aarch64") && \
    cd /tmp/delta-cache && \
    wget -q https://github.com/dandavison/delta/releases/download/0.18.2/delta-0.18.2-${DELTA_ARCH}-unknown-linux-gnu.tar.gz && \
    tar -xzf delta-0.18.2-${DELTA_ARCH}-unknown-linux-gnu.tar.gz && \
    mv delta-0.18.2-${DELTA_ARCH}-unknown-linux-gnu/delta /usr/local/bin/ && \
    rm -rf delta-0.18.2-${DELTA_ARCH}-unknown-linux-gnu*


ENV NPM_CONFIG_FETCH_RETRIES=5 \
    NPM_CONFIG_FETCH_RETRY_FACTOR=2 \
    NPM_CONFIG_FETCH_RETRY_MINTIMEOUT=10000

# Final stage with shell setup
FROM tools AS final

# Create non-root user for agent execution
# Using 1001 as default to avoid conflicts with ubuntu user (usually 1000)
ENV DEVA_USER=deva \
    DEVA_UID=1001 \
    DEVA_GID=1001 \
    DEVA_HOME=/home/deva

RUN groupadd -g "$DEVA_GID" "$DEVA_USER" && \
    useradd -u "$DEVA_UID" -g "$DEVA_GID" -m -s /bin/zsh "$DEVA_USER" && \
    # Allow deva user to run sudo without password for development convenience
    echo "$DEVA_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$DEVA_USER" && \
    chmod 440 "/etc/sudoers.d/$DEVA_USER"

# Configure npm-global directory for deva user
RUN mkdir -p "$DEVA_HOME/.npm-global" && \
    chown -R "$DEVA_UID:$DEVA_GID" "$DEVA_HOME/.npm-global"

# Set npm configuration for deva user and install CLI tooling
USER $DEVA_USER
ARG CLAUDE_CODE_VERSION
ARG CODEX_VERSION

# Record key tool versions as labels for quick inspection
LABEL org.opencontainers.image.claude_code_version=${CLAUDE_CODE_VERSION}
LABEL org.opencontainers.image.codex_version=${CODEX_VERSION}

# Speed up npm installs and avoid noisy audits/funds prompts
ENV NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false

# Use BuildKit cache for npm to speed up repeated builds
RUN --mount=type=cache,target=/home/deva/.npm,uid=${DEVA_UID},gid=${DEVA_GID},sharing=locked \
    npm config set prefix "$DEVA_HOME/.npm-global" && \
    npm install -g --no-audit --no-fund \
        @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
        @mariozechner/claude-trace \
        @openai/codex@${CODEX_VERSION} && \
    npm cache clean --force && \
    npm list -g --depth=0 @anthropic-ai/claude-code @openai/codex || true

# Install Go tools for Atlassian integration (Confluence/Jira/Bitbucket)
RUN go install github.com/lroolle/atlas-cli/cmd/atl@main && \
    sudo mv $HOME/go/bin/atl /usr/local/bin/

RUN git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh "$DEVA_HOME/.oh-my-zsh" && \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$DEVA_HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" && \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "$DEVA_HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"

# Create .zshrc for deva user
RUN echo 'export ZSH="$HOME/.oh-my-zsh"' > "$DEVA_HOME/.zshrc" && \
    echo 'ZSH_THEME="robbyrussell"' >> "$DEVA_HOME/.zshrc" && \
    echo 'plugins=(git docker python golang node npm aws zsh-autosuggestions zsh-syntax-highlighting)' >> "$DEVA_HOME/.zshrc" && \
    echo 'source $ZSH/oh-my-zsh.sh' >> "$DEVA_HOME/.zshrc" && \
    echo 'export PATH=$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/go/bin:/usr/local/go/bin:$PATH' >> "$DEVA_HOME/.zshrc"

USER root

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    chmod -R +x /usr/local/bin/scripts || true

WORKDIR /root

# Use tini as PID 1
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]

CMD ["claude"]
