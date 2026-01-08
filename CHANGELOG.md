# Changelog

All notable changes to Claude Code YOLO will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] - 2026-01-08

### Added
- **tmux bridge**: Connect container tmux client to host tmux server via TCP bridge
  - `deva-bridge-tmux-host` (host-side) and `deva-bridge-tmux` (container-side)
  - Build tmux 3.6a from source with SHA256 verification
  - Documented as privileged host bridge in AGENTS.md
- **Gemini agent support**: Add `agents/gemini.sh` for Google Gemini CLI
- **Docker-in-Docker auto-mount**: `/var/run/docker.sock` auto-mounted with `--no-docker` opt-out
- **Version management**: `scripts/version-upgrade.sh` and `scripts/release-utils.sh`
- **Build resilience**: Use `gh api` instead of `curl` to avoid GitHub rate limits

### Fixed
- docker-entrypoint.sh: usermod error handling for mounted volumes (no longer fatal under set -e)
- Dockerfile: explicit chmod 755 for script permissions (fixes execute-only bug)

### Changed
- Environment variables for tmux bridge use `DEVA_BRIDGE_*` prefix

## [0.7.0] - 2025-09-18 - **BREAKING: MAJOR REBRAND & REFACTOR**

**Claude Code YOLO → deva.sh Multi-Agent Wrapper**

This release transforms claude-code-yolo from a Claude-specific wrapper into **deva.sh** - a unified multi-agent wrapper supporting Claude Code, OpenAI Codex, and future coding agents.

### Added
- **Multi-Agent Architecture**: Pluggable agent system with `agents/claude.sh` and `agents/codex.sh` modules
- **Unified Dispatcher**: `deva.sh` as the main entry point with agent selection via first argument (`deva.sh codex`)
- **Project-Scoped Container Management**:
  - `deva.sh --ps` lists all deva containers for current project
  - `deva.sh --inspect` / `deva.sh shell` with fzf picker for multi-container attach
  - Container naming: `deva-<agent>-<project>-<pid>`
- **Enhanced Config System**:
  - `--config-home` / `-H` mounts entire auth directories (`.claude`, `.codex`) into `/home/deva`
  - New `.deva` / `.deva.local` config files with legacy `.claude-yolo*` support
  - `CONFIG_HOME` environment propagation to agents
- **Agent-Specific Safety**: Auto-injection of safety flags (`--dangerously-skip-permissions` for Claude, `--dangerously-bypass-approvals-and-sandbox` for Codex)
- **Codex OAuth Protection**: Strips conflicting `OPENAI_*` env vars when `.codex/auth.json` is mounted

### Changed
- **BREAKING**: `deva.sh` replaces `claude.sh` as the primary interface
- **BREAKING**: Docker image changed to `ghcr.io/thevibeworks/deva` (was `ghcr.io/thevibeworks/ccyolo`)
- **BREAKING**: Container user path changed from `/root` to `/home/deva`
- **Backward Compatibility**: `claude-yolo` → `deva.sh claude` shim maintained
- **Deprecation Warnings**: `claude.sh` and `claudeb.sh` now warn before forwarding to `deva.sh`

### Migration Guide
```bash
# Old workflow
claude.sh --yolo -v ~/.ssh:/root/.ssh:ro

# New workflow
deva.sh claude -v ~/.ssh:/home/deva/.ssh:ro

# Or use the shim (warns but works)
claude-yolo -v ~/.ssh:/home/deva/.ssh:ro
```

This release implements the complete vision from #98 - a Docker-first multi-agent wrapper that preserves YOLO ergonomics while enabling polyglot AI toolchains.

## [0.6.0] - 2025-09-16

### Added
- GitHub Copilot authentication mode (`--auth-with copilot` / `--copilot`) with automatic proxy launch in local and YOLO runs.
- Model auto-discovery from the Copilot proxy, with clear logging when defaults are injected.


## [0.5.1] - 2025-08-28

### Changed
- Updated Claude Code base version to 1.0.95 with new features:
  - /todos command to list current todo items
  - /memory command now allows direct editing of imported memory files
  - Individual slash command arguments ($1, $2, $3) like shell scripts
  - argument-hint frontmatter for slash commands (e.g., `[pr-number] [priority] [assignee]`)
  - MCP output warnings when responses exceed token limits (10k warning, 25k max)
  - Configurable MCP output limit via MAX_MCP_OUTPUT_TOKENS environment variable
  - Vertex AI support for global endpoints
  - SDK: Add custom tools as callbacks

## [0.5.0] - 2025-08-27

### Added
- Project-specific config file support (`.claude-yolo` in project root)
- OAuth token authentication method (`--oat`, experimental)
- Full configuration reference file (`.claude-yolo.full`)
- Environment variable expansion support (`${VAR:-default}`)
- Sensitive environment variable masking (API keys, tokens, secrets)
- `--host-net` option for Docker networking
- Configuration display in startup output

### Changed
- Updated Claude Code base version to 1.0.93
- Unified model aliasing system across all authentication methods
- Improved environment and volume parsing
- Enhanced security with controlled mounts and permissions
- Simplified example config file
- Streamlined release workflow through claude-yolo

### Fixed
- Critical security issues with config file handling
- Environment variable display formatting
- Volume mount permissions and validation

### Security
- Mask sensitive values in environment variable output
- Enhanced config file validation and security checks

## [0.4.3] - 2025-07-21

### Changed
- Updated Claude Code base version to 1.0.54 with latest features:
  - Hooks: UserPromptSubmit hook, PreCompact hook
  - Custom slash commands: argument-hint frontmatter, restored namespacing
  - Shell: In-memory snapshots for better file operation reliability
  - Search (Grep) tool redesigned with enhanced parameters
  - MCP: server instructions support, enhanced tool result display
  - @-mention file truncation increased from 100 to 2000 lines
  - New /export command for conversation sharing
  - /doctor command for settings file validation
  - Progress messages for Bash tool based on command output
  - --append-system-prompt now works in interactive mode
  - Vim mode navigation improvements (c, f/F, t/T commands)
  - Fixed config file corruption with atomic writes

## [0.4.2] - 2025-07-10

### Changed
- Migrate repository from lroolle to thevibeworks org

## [0.4.1] - 2025-07-08

### Changed
- Expand ~ to $HOME in release command for Docker compatibility
- Make Claude cmd configurable in release workflow
- Update Claude version to 1.0.44 and improve release flow

## [0.4.0] - 2025-07-08

### Added
- Unified `--auth-with` pattern for authentication method selection
- Environment variable pass-through with `-e` flag support
- Custom config directory support
- Controlled mount security with proper read-only handling

### Changed
- Complete auth system refactor with proper model handling
- Docker architecture: moved to `/home/claude` for better permissions
- Environment variable standardization: `CLAUDE_YOLO_*` → `CCYOLO_*`
- Streamlined docker-entrypoint.sh with improved error handling

### Fixed
- Docker permission issues with auth file handling
- Security improvements with controlled mounts

## [0.3.0] - 2025-07-02

### Changed
- Streamlined Docker image build process
- Updated npm global installation path
- Enhanced CI pipeline with release workflow and version check
- Improved container registry configuration

## [0.2.6] - 2025-06-24

### Fixed
- Makefile registry inconsistency with ghcr.io default image

## [0.2.5] - 2025-06-25

### Changed
- Add note on `CLAUDE_CONFIG_DIR` and fix gcloud config symlink in entrypoint

## [0.2.4] - 2025-06-23

### Added
- Unified logging system for improved UX
- Clean output by default showing only authentication method
- Verbose mode displays model selection, proxy configuration, and debug info

### Fixed
- Argument parsing infinite loop in claude-yolo for --inspect and --ps options
- Duplicate argument handling causing inconsistent behavior with mixed options
- claude-trace --run-with syntax (removed unnecessary "claude" argument)
- Container shortcuts now properly exit after --ps command

### Changed
- Consolidated all claude-yolo argument parsing through single parse_args() function
- Enhanced claude-trace argument injection for proper --dangerously-skip-permissions placement
- Improved logging organization
- Updated documentation with logging capabilities and examples

### Performance
- Docker build caching in GitHub Actions (dual GHA + registry cache strategy)

## [0.2.3] - 2025-06-23

### Added
- Dynamic fallback UID/GID selection for root users

### Fixed
- Handle UID 0 (root user) case in docker-entrypoint.sh
- Add explicit github_token to claude-code-review action
- Handle UID=0 and GID=0 independently for security

### Changed
- Simplify root user handling with hardcoded 1000 fallback
- Remove redundant comments in UID/GID handling
- Run Claude review once per PR and on manual trigger

### Performance
- Docker build caching improvements in GitHub Actions

### Documentation
- Update logs and changelog for issue #19 caching fix
- Clarify root cause and solution for UID 0 handling
- Add OIDC token fix to dev log

## [0.2.2] - 2025-06-23

### Added
- Docker image update to ghcr.io with fallback to Docker Hub
- Note when falling back to Docker Hub image in installer

### Fixed
- Set shellcheck to error severity to prevent CI blocking

### Documentation
- Improve usage examples across all documentation

## [0.2.1] - 2025-06-23

### Fixed
- Move shellcheck to CI workflow, remove from release

## [0.2.0] - 2025-06-23

### Added
- --verbose flag to show environment info and pass to Docker

## [0.1.0] - 2025-06-21

### Added
- Initial release of Claude Code YOLO Docker wrapper
- Dual-mode architecture: Local mode (default) and YOLO mode (Docker)
- Support for 4 authentication methods:
  - Claude App OAuth (`--claude`, `-c`)
  - Anthropic API Key (`--api-key`, `-a`)
  - AWS Bedrock (`--bedrock`, `-b`)
  - Google Vertex AI (`--vertex`, `-v`)
- Full development environment in Docker image:
  - Ubuntu 24.04 base
  - Python 3.12, Node.js 22, Go 1.22, Rust
  - Development tools: git, docker, aws, jq, ripgrep, fzf
  - Claude CLI and claude-trace pre-installed
- Automatic `--dangerously-skip-permissions` in YOLO mode
- Non-root user support with UID/GID mapping
- Authentication file mounting and permission handling
- Proxy support with automatic localhost translation
- Model alias system for easy model selection
- Docker socket mounting option (disabled by default)
- Shell access to container (`--shell`)
- Request tracing support (`--trace`)
- Dangerous directory detection with user confirmation prompt
- Quick install script for one-line setup
- Standalone `claude-yolo` script for convenient access
- Prefixed logging with `[claude.sh]` for better identification
- Updated documentation with claude-trace integration details

### Security
- Container isolation for safe execution
- Directory access limited to current working directory
- Non-root execution inside container
- Docker socket mounting disabled by default
- Warning system for dangerous directories (home, system directories)
