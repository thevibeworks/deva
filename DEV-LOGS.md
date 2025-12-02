# Development Logs & WIPs
- Prepend new entries with:
  ```markdown
  # [YYYY-MM-DD] Dev Log: <Subject>
  - Why: <one-line reason>
  - What: <brief list of changes>
  - Result: <outcome/impact>
  ```
- Prepend new WIP within the `# WIP` section.
  - use `- [ ]` for tasks, `- [x]` for completed items.
- We write or explain to the damn point. Be clear, be super concise - no fluff, no hand-holding, no repeating.
- Be specific about what was done, why it was done, and any important context.
- Minimal markdown markers, no unnecessary formatting, minimal emojis.
- Reference issue numbers in the format `#<issue-number>` for easy linking.


# [2025-11-27] Dev Log: Docker-in-Docker auto-mount support
- Why: Common dev workflow need - testing containers, building images, CI/CD simulation inside deva environments
- What: Auto-mount Docker socket (`/var/run/docker.sock`) by default with graceful detection, opt-out via `--no-docker` flag or `DEVA_NO_DOCKER=1`, quick permission fix (chmod 666) for deva user access
- Result: DinD works out-of-box on Linux/macOS/WSL2, no manual socket mounting needed, aligns with YOLO philosophy (make it work, container is the boundary)

# [2025-10-26] Dev Log: Custom credential files via --auth-with
- Why: Users have multiple credential files, needed direct path support beyond predefined auth methods
- What: `--auth-with /path/to/creds.json` now works, auto-backup existing credentials, workspace session tracking in `~/.config/deva/sessions/*.json`
- Result: Flexible credential switching, backward compatible with predefined methods (claude/api-key/bedrock/etc)

# [2025-09-30] Dev Log: Persistent container reuse with tmux-style UX (#108)
- Why: Per-invocation containers were slow, stateless, and clobbered each other; we wanted tmux-like persistence.
- What:
  - Container naming settles on `deva-<parent>-<project>` for the shared instance and `--rm` for throwaway runs, avoiding cross-repo collisions.
  - Subcommands (`ps`, `attach`, `shell`, `stop`, `rm`, `clean`) mirror docker/tmux; smart auto-select handles the single-container case; `attach` boots an agent, `shell` drops into zsh.
  - Global mode (`-g`) exposes containers outside the current tree while keeping local defaults sane; lifecycle keeps containers detached but exec-ready.
  - Cleanup: removed Linux-only flock, dead attach helpers, and stray comments to stay shellcheck-clean without breaking macOS.
- Result: Containers now persist per project with faster warm starts, intuitive control flow, and no platform regressions.

# [2025-09-23] Dev Log: Multi-auth design for deva framework
- Why: Port mature multi-auth system from claude.sh to support different AI providers (Anthropic, OpenAI, AWS, Google, GitHub) across all agents.
- What:
  - **Design Decision**: Agent-level auth (`deva.sh claude --auth-with bedrock`) over global-level (`deva.sh --auth-with bedrock claude`)
  - **Auth Method Naming**: `claude`=Claude.ai OAuth, `chatgpt`=ChatGPT OAuth, `copilot`=GitHub Copilot proxy (different API endpoints per agent)
  - **Copilot Complexity**: Claude uses Anthropic endpoints (`/v1/messages`, `ANTHROPIC_BASE_URL`), Codex uses OpenAI endpoints (`/v1/chat/completions`, `OPENAI_BASE_URL`)
  - **Auth Matrix**: Claude supports claude/oat/api-key/bedrock/vertex/copilot; Codex supports chatgpt/api-key/copilot; copilot works via different proxy endpoints
  - **Implementation Plan**: Each agent parses --auth-with, shared copilot proxy management, agent-specific env vars and endpoints
- Result: Agent-level auth with provider-specific implementations. Copilot proxy serves both Anthropic and OpenAI formats but agents configure different base URLs and env var namespaces.

## More about --auth-with copilot

### Claude Code with --auth-with copilot:
- Uses ANTHROPIC_BASE_URL=http://localhost:4141
- Uses ANTHROPIC_API_KEY=dummy
- Hits endpoint: POST /v1/messages (Anthropic format)
- Proxy translates: Anthropic messages → OpenAI format → GitHub Copilot

### Codex with --auth-with copilot:
- Uses OPENAI_BASE_URL=http://localhost:4141
- Uses OPENAI_API_KEY=dummy
- Hits endpoint: POST /v1/chat/completions (OpenAI format)
- Proxy handles: OpenAI format → GitHub Copilot (direct)

### Complete Auth Matrix

  | Agent  | claude | oat | api-key | bedrock | vertex | chatgpt | copilot                  |
  |--------|--------|-----|---------|---------|--------|---------|--------------------------|
  | Claude | ✅     | ✅  | ✅      | ✅      | ✅     | ❌      | ✅ (Anthropic endpoints) |
  | Codex  | ❌     | ❌  | ✅      | ❌      | ❌     | ✅      | ✅ (OpenAI endpoints)    |



# [2025-09-19] Dev Log: Profile-only UX; decouple build from run
- Why: Running agents should be trivial; mixing build concerns into the run wrapper created ambiguity (pull vs build, tag vs Dockerfile) and too many knobs. Teams need predictable per‑project defaults.
- What:
  - Added `--profile`/`-p` (canonical).
  - Rust maps to `ghcr.io/thevibeworks/deva:rust` (same repo, tag-based).
  - Wrapper flags allowed before or after the agent; help and examples clarified.
  - Reserve `-p` for deva; pass agent prompt flags after `--` (breaking but explicit).
  - Config: default XDG root `~/.config/deva` with per-agent homes; `-c DIR` treated as DEVA ROOT when it contains `claude/` or `codex/`.
  - Auto-link legacy creds into DEVA ROOT by default (`~/.claude*`, `~/.codex`); disable with `--no-autolink`, `AUTOLINK=false`, or `DEVA_NO_AUTOLINK=1`.
  - Builder flags were WIP; not shipped. Removed from code; use Makefile targets (`make build`, `make build-rust`) or explicit `docker build` instead.
  - When an image:tag is missing, error now prints one‑liners per profile (Makefile + docker commands).
  - Makefile: add `build-rust`, `buildx-multi-rust`; bump CLI versions (Claude `1.0.119`, Codex `0.39.0`).
- Result: Zero‑thought startup, clean per‑project defaults via `.deva` PROFILE, reproducible paths with fewer CLI options, clearer fixes when images are absent.

Context (whole view):
- The real problem
  - Build concerns leaked into run UX; unclear precedence; too many flags.
  - Lack of per‑project defaults led to ad‑hoc flags per run.
- What users actually need
  - “deva” just runs; per‑project default profile; single explicit prepare step; actionable errors; reproducibility with pinned tags and Makefile targets.
- Better UX proposal (next)
  - `prepare` subcommand (pull tag; optionally build via env), `.deva` PROFILE first, auto-detect profile (Cargo.toml ⇒ rust), `doctor` diagnostics.

# [2025-09-18] Dev Log: Complete rebrand to deva.sh multi-agent wrapper
- Why: Transform claude-code-yolo from Claude-specific wrapper into unified multi-agent wrapper per #98. Enable Codex integration without breaking existing YOLO ergonomics.
- What: **COMPREHENSIVE REFACTOR**
  - **Architecture**: Built pluggable agent system with `agents/claude.sh` and `agents/codex.sh` modules, unified dispatcher `deva.sh`
  - **Container Management**: Project-scoped containers (`deva-<agent>-<project>-<pid>`), `--ps`/`--inspect`/`shell` commands with fzf picker
  - **Config Evolution**: `--config-home`/`-c` mounts entire auth homes (`.claude`, `.codex`) to `/home/deva`, new `.deva*` config files with `.claude-yolo*` back-compat
  - **Agent Safety**: Auto-inject safety flags (`--dangerously-skip-permissions` for Claude, `--dangerously-bypass-approvals-and-sandbox` for Codex)
  - **OAuth Protection**: Strip conflicting `OPENAI_*` env vars when `.codex/auth.json` is mounted to preserve OAuth sessions
  - **Backward Compatibility**: `claude-yolo` → `deva.sh claude` shim, deprecation warnings for `claude.sh`/`claudeb.sh`
  - **Documentation**: Complete rewrite of README, CHANGELOG, install scripts to reflect deva.sh-first workflow
- Result: **MAJOR VERSION** - claude-code-yolo is now "deva.sh Multi-Agent Wrapper". All legacy functionality preserved via shims, new multi-agent capabilities unlocked, Codex OAuth stable.

# [2025-09-16] Dev Log: Copilot API proxy integration
- Why: Add first-class support for GitHub Copilot (`copilot-api`) as Anthropic-compatible backend for Claude Code (local + Docker), resilient behind proxies.
- What:
  - New `--auth-with copilot` mode: token validation (saved or `GH_TOKEN`/`GITHUB_TOKEN`), local proxy lifecycle management.
  - Base URL wiring: local `ANTHROPIC_BASE_URL=http://localhost:4141`; Docker `http://host.docker.internal:4141` (+ entrypoint rewrite safety).
  - Proxy bypass: set `NO_PROXY`/`no_grpc_proxy` to include `localhost,127.0.0.1,host.docker.internal` so 4141 calls skip HTTP/gRPC proxies.
  - Model defaults: auto-detect from `/v1/models`; prefer `gpt-5-mini` for fast, fallback to `gpt-4o-mini`; main fallback `claude-sonnet-4`.
  - Docker: auto-pick models from host proxy when unset; pass via `-e` to claude in container.
- Result: Copilot proxy works reliably in both modes; sane defaults without manual env; no more proxy misroutes.


# [2025-07-10] Dev Log: Complete namespace migration to thevibeworks
- Why: Migrate from lroolle org to thevibeworks, shorten Docker image name for cleaner registry
- What: Updated all references, Docker images, URLs across entire codebase, kept command name for backward compatibility
- Result: Clean migration with repo at thevibeworks/claude-code-yolo, Docker image at thevibeworks/ccyolo, command stays claude-yolo

**Changes Made**:
- Repo: `lroolle/claude-code-yolo` → `thevibeworks/claude-code-yolo`
- Docker: `ghcr.io/lroolle/claude-code-yolo` → `ghcr.io/thevibeworks/ccyolo`
- Command: Kept `claude-yolo` (backward compatibility)
- Project: Kept "Claude Code YOLO" title

**Files Updated**: Makefile, README.md, CLAUDE.md, claude.sh, claude-yolo, install.sh, Dockerfile, CHANGELOG.md, DEV-LOGS.md, scripts/, claude-yolo-pro/

Addresses issue #48.

## Dev Log: 2025-07-09

### [enhancement-completed] Auth system overhaul and environment handling

**Problem**: Messy auth flags, poor environment handling, inconsistent Docker mounts.

**Solution**:
- Unified auth with `--auth-with` pattern (claude|api-key|bedrock|vertex)
- Proper environment var handling with `-e` flag
- Controlled auth directory mounting with explicit permissions
- Smart model name handling for each auth mode

**Technical**:
- Freed -v for Docker volume mounts (was conflicting with --vertex)
- Added model name translation for API key mode
- Implemented proper ARN generation for Bedrock
- Added environment detection for tools and auth status

**Result**: Clean auth system, proper env handling, secure mounts.

---

## Dev Log: 2025-07-08

### [enhancement-completed] Custom config directory and environment variable support

**Problem**: Users needed separate auth sessions for different projects and better environment variable handling.

**Root Cause**: Fixed path mounting made multi-project auth management difficult, no env var support in Docker mode.

**Solution**: Added `--config` flag for custom Claude config home and `-e` flag for environment variables.

**Implementation**:
- `--config ~/work-claude` creates and mounts custom config directory
- `-e NODE_ENV=dev` or `-e DEBUG` passes environment variables
- Fixed npm-global path handling for claude user
- Standardized mount paths to `/home/claude` instead of `/root`
- Environment variable naming: `CLAUDE_YOLO_*` → `CCYOLO_*`
- Auth isolation: unset conflicting auth variables per mode

**Benefits**:
- ✅ **Project isolation**: Separate auth sessions per project
- ✅ **Environment control**: Full env var support in Docker mode
- ✅ **Path consistency**: All mounts to `/home/claude`
- ✅ **Auth reliability**: No cross-contamination between auth modes

**Related**: Issues #46, #45 (configuration management)

**Status**: ✅ **COMPLETED**

---

## Issue Analysis: 2025-07-04

### [enhancement-analysis] Docker Compose configuration support

**Problem**: Command line arguments become unmanageable for complex setups with multiple volumes and environment variables.

**Current Pain Point**:
```bash
claude-yolo -v ~/.ssh:/root/.ssh:ro -v ~/Desktop/claude:/home/claude/.claude/ -v ~/.config/git:/home/claude/.config/git -v ../yolo-tools/scripts/barkme.sh:/home/claude/.local/bin/barkme.sh --continue
```

**Root Cause Analysis**:
1. **CLI limitations**: Long command lines are hard to edit, share, version control
2. **Multi-container needs**: Users want playwright services, MCP servers, other tools
3. **Team collaboration**: Complex setups need to be shared across team members
4. **Missing configuration hierarchy**: No project vs user vs local settings distinction

**Proposed Solution**: Docker Compose integration following Claude Code's settings pattern

**Configuration Hierarchy** (mirrors Claude Code's approach):
```
.claude/
├── claude-yolo.local.yml    # Project-local (gitignored)
├── claude-yolo.yml          # Project-shared (version controlled)
└── ~/.claude/claude-yolo.yml # User global
```

**Multi-container Support**:
```yaml
# .claude/claude-yolo.yml
version: '3.8'
services:
  claude:
    image: ghcr.io/thevibeworks/ccyolo:latest
    volumes:
      - ~/.ssh:/root/.ssh:ro
      - ${PWD}:${PWD}
    depends_on:
      - playwright
      - mcp-server

  playwright:
    image: mcr.microsoft.com/playwright:v1.40.0-focal
    ports: ["3000:3000"]

  mcp-server:
    image: custom/mcp-server:latest
    ports: ["8080:8080"]
```

**Implementation Requirements**:
1. **Auto-detection**: Check for compose files in precedence order
2. **Backward compatibility**: Keep CLI args for simple cases
3. **Multi-container orchestration**: Full Docker Compose integration
4. **Settings coexistence**: Respect existing `.claude/settings.json` handling

**Benefits**:
- ✅ **Manageable configs**: No more insane command lines
- ✅ **Team collaboration**: Share service definitions via git
- ✅ **Multi-container**: Enable complex development environments
- ✅ **Familiar patterns**: Follow Claude Code's settings hierarchy
- ✅ **Version control**: Compose files are easily tracked

**Related Issues**:
- Issue #24: Environment variable support (partially addresses)
- Issue #33: DevContainer support question (compose provides better solution)

**Status**: Analysis complete, ready for implementation

## Issue Analysis: 2025-06-23

### [bug-fixed] Root user (UID 0) handling in docker-entrypoint.sh

**Problem**: `sudo claude-yolo` fails with "usermod: UID '0' already exists" error.

**Root Cause**: Can't reassign existing UID 0 (root) to claude user.

**Security Fix**: Handle UID=0 and GID=0 independently to prevent root group assignment.

**Solution**: Use fallback UID/GID 1000 for proper file ownership with existing collision handling.

**Status**: ✅ **COMPLETED** - PR #22

---

## Issue Analysis: 2025-06-23

### [bug-fixed] Claude Code Review OIDC token authentication error

**Problem**: CI failing with "Invalid OIDC token" after changing permissions to write.

**Solution**: Added explicit `github_token: ${{ secrets.GITHUB_TOKEN }}` to force direct token auth.

**Cause**: Write permissions trigger GitHub App auth by default, but no App configured.

**Status**: ✅ **COMPLETED**

---

## Issue Analysis: 2025-06-23
### [enhancement-completed] Claude Code Review workflow simplification

**Problem**: Overcomplicated workflow with manual duplicate detection using GitHub CLI.

**Solution**: Adopted ChatGPT pattern with critical fixes:
- `pull_request_target` → enables secret access for `ANTHROPIC_API_KEY`
- Concurrency groups → automatic duplicate prevention
- Proper checkout ref → works for comment-triggered reviews
- Removed complex GitHub CLI duplicate detection logic

**Result**: 50% fewer lines, more reliable, follows GitHub best practices.

**Status**: ✅ **COMPLETED**

---

## Issue Analysis: 2025-06-23

### [enhancement-completed] Clean startup message redesign

**Problem**: Startup messages were excessively verbose (65+ lines) with poor UX.

**Solution**: Clean headers with color-coded auth status, transparent volume listing, consistent branding.

**Result**: 65+ lines → ~10 lines with essential info only.

**Status**: ✅ **COMPLETED**

---

## Issue Analysis: 2025-06-22

### [enhancement-completed] Script simplification

**Problems Fixed**:

1. **USE_NONROOT complexity eliminated**: Removed 50+ lines of unnecessary code
   - Always run as claude user (was already default behavior)
   - Removed dead root mode code path from docker-entrypoint.sh
   - Simplified UID/GID mapping logic

**Results**:
- ✅ Consistent trace syntax between local and Docker modes
- ✅ 50+ lines removed from docker-entrypoint.sh
- ✅ Always run as claude user for security and simplicity

**Status**: ✅ **COMPLETED**

---

## Issue Analysis: 2025-06-22

### [bug-fixed] Incorrect Claude CLI usage with redundant '.' directory argument

**Problem**: Throughout the codebase, Claude CLI was being used incorrectly with '.' as a directory argument.

**Root Cause**: Claude CLI doesn't take a directory argument. According to `claude --help`, Claude:
- Starts an interactive session by default
- Automatically works in the current working directory
- Takes `[prompt]` as an optional argument, not a directory path

**Issues Fixed**:
- `claude .` → `claude` (the '.' was being passed as a prompt, not a directory)
- `claude-yolo .` → `claude-yolo` (no directory argument needed)
- All help text examples showing incorrect usage patterns

**Files Updated**:
- **claude.sh**: Fixed 11 examples in help text
- **claude-yolo**: Fixed 4 examples in help text
- **All documentation**: Will need updating (README.md, CLAUDE.md, install.sh)

**Impact**: This explains why `--trace .` was showing version info instead of starting interactive mode - the '.' was being interpreted as a prompt argument to Claude.

**Status**: ✅ **COMPLETED** - Help text fixed, documentation needs updating

## Issue Analysis: 2025-06-22

### [enhancement-completed] Improved docker-entrypoint.sh environment detection

**Problem**: docker-entrypoint.sh incorrectly classified Dockerfile-installed files as "user-mounted" and provided poor environment information.

**Issues Fixed**:
1. **Incorrect file classification**: `.oh-my-zsh`, `.zshrc`, `.local`, etc. marked as "user-mounted" when installed by Dockerfile
2. **Poor environment detection**: Basic tool versions without context or organization
3. **Verbose logging noise**: All container-installed files logged as if user-mounted
4. **Missing tool information**: No detection of AWS CLI, GitHub CLI, Docker, etc. installed in container

**Solution Implemented**:
- **Smart file classification**: Distinguish Dockerfile-installed vs user-mounted files
- **Enhanced environment detection**: Show all development tools from Dockerfile (Python, Node.js, Go, Rust, AWS CLI, GitHub CLI, Docker)
- **Organized verbose output**: Categorized sections for Tools, Authentication, Configuration
- **Appropriate logging levels**: Container-installed files use `log_verbose`, user-mounted use `log_entrypoint`

**Technical Implementation**:
- Updated file classification in `/root/*` handling with explicit categories
- Enhanced `show_environment_info()` with structured tool detection
- Added authentication status detection (AWS, GCloud, GitHub tokens)
- Improved verbose logging organization with clear sections

**Results**:
- ✅ **Accurate classification**: Container vs user-mounted files properly identified
- ✅ **Comprehensive tool info**: All Dockerfile-installed tools detected and versioned
- ✅ **Clean verbose output**: Organized sections with relevant information
- ✅ **Reduced noise**: Container-installed files no longer logged as "user-mounted"

**Status**: ✅ **COMPLETED**

---

## Issue Analysis: 2025-06-22

### [enhancement-completed] Unified logging system implementation

**Problem**: Inconsistent logging patterns scattered throughout claude.sh and docker-entrypoint.sh with mixed approaches to verbosity control.

**Issues Fixed**:
1. **Inconsistent patterns**: Mix of `[ "$QUIET" != true ] && echo`, `[ "$VERBOSE" = true ] && echo`, direct echo
2. **Duplicate logic**: Repeated verbosity checks throughout both scripts
3. **Poor maintainability**: No centralized logging functions
4. **Inconsistent stderr usage**: Some logs to stdout, others to stderr

**Solution Implemented**:
- **Unified logging functions**: `log_info()`, `log_verbose()`, `log_error()`, `log_warn()`
- **Specialized functions**: `log_auth()`, `log_model()`, `log_proxy()`, `log_entrypoint()`
- **Consistent stderr routing**: All logs go to stderr, keeping stdout clean
- **Centralized flag handling**: Single point of verbosity control per script

**Technical Implementation**:
- Added 6 core logging functions to both scripts
- Migrated 33+ logging patterns in claude.sh to unified system
- Migrated 20+ logging patterns in docker-entrypoint.sh with argument-based detection
- Updated documentation across README.md, CLAUDE.md, CHANGELOG.md
- Maintained backward compatibility

**Results**:
- ✅ **Consistent API**: All logging through standardized functions
- ✅ **Clean migration**: Drop-in replacements for existing patterns
- ✅ **Proper flag handling**: Centralized QUIET/VERBOSE logic
- ✅ **Maintainable code**: Eliminated duplicate logging logic
- ✅ **Enhanced UX**: Clean, controllable output at all verbosity levels

**Status**: ✅ **COMPLETED**

---

## Issue Analysis: 2025-06-22

### [enhancement-completed] Clean up version and startup message verbosity

**Problem**: Current --version and startup messages are excessively verbose, poor UX.

**Issues Fixed**:
1. **--version chaos**: Shows full container startup + environment info + linking messages
2. **Startup noise**: 30+ lines of environment info, entrypoint messages, linking details
3. **Poor expectations**: Users expect clean, fast version info

**Solution Implemented**:
- **--version**: Clean local version only ("Claude Code YOLO v0.2.0")
- **--version --verbose**: Extended info including Claude CLI version via container check
- **Startup**: Two-line summary with key info:
  ```
  Claude Code YOLO v0.2.0 | Auth: OAuth | Working: /path/to/project
  Container: ccyolo-myproject-12345
  ```
- **Flags**: Added --quiet and --verbose for user control over output verbosity

**Technical Implementation**:
- Two-pass argument parsing: collect --verbose/--quiet flags first
- Conditional message display based on verbosity flags
- Docker entrypoint checks for --quiet/--verbose in arguments
- Clean auth method display mapping (claude → OAuth)

**Results**:
- ✅ **--version**: Single line output (was 30+ lines)
- ✅ **--version --verbose**: Extended info when needed
- ✅ **Startup**: Two-line summary (was verbose environment dump)
- ✅ **Control flags**: --quiet and --verbose work in both local and Docker modes

**Status**: ✅ **COMPLETED**

---

## Issue Analysis: 2025-06-22

### [enhancement-completed] Script simplification and consistency fixes

**Problem**: Inconsistent claude-trace syntax and unnecessary USE_NONROOT complexity.

**Solutions Implemented**:
- Fixed claude.sh:305 claude-trace syntax (removed "claude" argument)
- Removed USE_NONROOT variable and dead root mode code
- Simplified docker-entrypoint.sh by 50+ lines
- Always run as claude user for consistency

**Result**: Cleaner, more maintainable codebase with consistent behavior.

**Status**: ✅ **COMPLETED**

---

## Issue Analysis: 2025-06-22

### [issue-analysis] claude.sh and docker-entrypoint.sh complexity review

**Problems Identified**:

1. **Inconsistent claude-trace syntax**:
   - claude.sh:305 (local): `--run-with claude .` ❌
   - claude.sh:648 (docker): `--run-with .` ✅

2. **USE_NONROOT unnecessary complexity**:
   - Always set to `true` in Docker mode (line 512)
   - Root mode code path is dead code (lines 246-275 in docker-entrypoint.sh)
   - Adds 100+ lines of UID/GID mapping, symlink creation
   - No real benefit since we always use non-root anyway

3. **Cursor bot was wrong**:
   - Current docker-entrypoint.sh logic is actually correct
   - Transforms: `--run-with .` → `--run-with --dangerously-skip-permissions .`
   - Bot confused about argument order

**Solutions**:
- Fix local mode claude-trace syntax (remove "claude")
- Remove USE_NONROOT entirely, always run as claude user
- Simplify docker-entrypoint.sh by 50+ lines

**Status**: Analysis complete

---

## Issue Analysis: 2025-06-22

### [bug-critical] Argument parsing infinite loop in claude-yolo

**Problem**: Cursor bot detected critical bugs in claude-yolo argument parsing.

**Root Cause Analysis**:

**Bug 1 - Infinite Loop**: Lines 84-89 in parse_args() missing `shift` statements:
```bash
--inspect)
    inspect_container  # ❌ Missing shift - infinite loop
;;
--ps)
    list_containers   # ❌ Missing shift - infinite loop
;;
```

**Bug 2 - Duplicate Handling**: Lines 122-137 duplicate parse_args() logic:
```bash
# Main script also handles --inspect/--ps directly
case "$1" in
--inspect) inspect_container ;;  # ❌ Duplicate of parse_args
--ps) list_containers ;;         # ❌ Duplicate + no exit
```

**Impact**:
- Infinite loop when using `--inspect` or `--ps`
- `--ps` shows containers but continues to exec claude.sh
- Mixed options like `claude-yolo --inspect -v ~/foo:/bar` silently ignore -v
- Inconsistent behavior between direct calls and mixed arguments

**Technical Details**:
- **Flow Issue**: parse_args() calls inspect_container() → exits, but missing shift causes loop
- **Design Flaw**: Two separate parsing paths with different behaviors
- **Silent Failures**: Some argument combinations work, others don't

**Status**: Critical - requires immediate fix

---

## Issue Analysis: 2025-06-22

### [problem-discovered] GitHub CLI auth fails in containers

**Problem**: Mounting `~/.config/gh/` doesn't work for GitHub CLI authentication in containers.

**Root Cause**: Modern `gh` uses secure keyring storage instead of plain text files:
- **Host**: Tokens stored in macOS Keychain/Linux Secret Service/Windows Credential Manager
- **Container**: No keyring access, auth fails even with mounted config directory
- **Split State**: Config files present but tokens inaccessible

**Technical Details**:
```bash
# Host auth state:
~/.config/gh/config.yml     # Configuration
~/.config/gh/hosts.yml      # May contain tokens OR keyring references
System Keyring              # Actual tokens (secure storage)

# Container reality:
/root/.config/gh/config.yml # ✅ Mounted successfully
/root/.config/gh/hosts.yml  # ✅ Mounted but may reference unavailable keyring
No System Keyring          # ❌ DBus/keyring services not available
```

**Why This Matters**: Current codebase has complete auth system for Claude/AWS/GCloud but GitHub CLI missing.

**Immediate Impact**: Cannot create PRs or manage GitHub repos from within containers.

**Solutions Research**:
1. **Environment Variable**: `GH_TOKEN="ghp_xxx"` - simple, headless-friendly
2. **Insecure Storage**: `gh auth login --insecure-storage` on host, then mount works
3. **Token Injection**: `echo $TOKEN | gh auth login --with-token` in container
4. **Mount Strategy**: Add explicit GitHub CLI auth mounting to claude.sh

**Status**: Research complete, need implementation decision.

---

## Issue Analysis: 2025-06-22

### [enhancement] Controlled auth directory mounting

**Problem**: Symlinking all /root/* was too broad and risky.

**Better approach**: Explicit, controlled mounts with proper permissions:
```bash
# claude.sh mounts:
~/.claude → /root/.claude          # read-write (auth tokens)
~/.config → /root/.config:ro       # read-only (XDG tools)
~/.aws → /root/.aws:ro            # read-only
~/.ssh → /root/.ssh:ro            # read-only
~/.gitconfig → /root/.gitconfig:ro # read-only

# docker-entrypoint.sh:
- Symlinks specific directories to /home/claude
- Sets XDG_CONFIG_HOME=/root/.config
- Maintains controlled access list
```

**Benefits**:
- ✅ Security: Read-only where appropriate
- ✅ XDG compliance: Entire .config dir for gh/gcloud/etc
- ✅ Explicit: Clear what's accessible
- ✅ Safe: No unexpected file exposure

**Status**: -> **IMPLEMENTED**

### [enhancement-implemented] Consolidate auth options to --auth-with pattern

**Problem**: Auth flags conflict with common conventions (-v for volumes vs Vertex).

**Current mess**:
- `-c/--claude` → Claude app (OAuth)
- `-a/--api-key` → Anthropic API
- `-b/--bedrock` → AWS Bedrock
- `-v/--vertex` → Google Vertex AI (blocks -v for volumes!)

**Solution**: Single `--auth-with` parameter:
```bash
claude.sh --auth-with vertex .     # Explicit auth method
claude.sh -v ~/.ssh:/root/.ssh .   # -v now free for volumes
```

**Implementation**:
1. ✅ Added `--auth-with METHOD` parsing in claude.sh
2. ✅ Kept old flags for backward compatibility (with deprecation warnings)
3. ✅ Freed up `-v` for volume mounting (Docker convention)
4. ✅ Updated claude-yolo to use `-v` instead of `--mount`

**Benefits**:
- ✅ Follows Docker convention (-v for volumes)
- ✅ Cleaner, extensible auth interface
- ✅ No more flag conflicts
- ✅ Better CLI UX

**Status**: ✅ **IMPLEMENTED**

### [enhancement-implemented] Generalized config mounting

**Problem**: Hardcoding each tool's config mount doesn't scale.

**Root cause**: Mount to /root, run as claude user -> symlink hell.

**Initial Proposal**: Mount entire ~/.config, use XDG standards.

**Implemented Solution**: Added flexible volume mounting via `-v` argument in claude-yolo.

```bash
# New usage - users can mount any config they need:
claude-yolo -v ~/.gitconfig:/root/.gitconfig .
claude-yolo -v ~/.ssh:/root/.ssh:ro .
claude-yolo -v ~/tools:/tools -v ~/data:/data .

# Implementation in claude-yolo:
- Parse -v/--mount arguments, collect in array
- Pass to claude.sh via CLAUDE_EXTRA_VOLUMES env var
- claude.sh adds these volumes to Docker run command
```

**Benefits**:
- ✅ **Flexible**: Mount any config/directory as needed
- ✅ **Familiar**: Uses Docker's -v syntax
- ✅ **Secure**: Users control what to expose
- ✅ **Extensible**: No hardcoded tool list to maintain

**Result**: Zero maintenance. New tools work via explicit mounting.

**Status**: ✅ **IMPLEMENTED** - Added -v/--mount support to claude-yolo

## Issue Analysis: 2025-06-22

### [bug-fixed] --trace flag doesn't pass --dangerously-skip-permissions in YOLO mode

**Problem**: `claude-yolo --trace .` fails to add `--dangerously-skip-permissions` to the claude command.

**Root Cause Found**:
- In `claude.sh:562`, when `--trace` is used, the command was incorrectly constructed as:
  ```bash
  claude-trace --include-all-requests --run-with .
  ```
- **Missing `claude` command**: Should be `claude-trace --include-all-requests --run-with claude .`

**Two-Part Fix Implemented**:

1. **Fixed command construction** in `claude.sh:562`:
   ```bash
   claude-trace --include-all-requests --run-with claude .
   ```

2. **Enhanced argument injection** in `docker-entrypoint.sh`:
   ```bash
   elif [ "$cmd" = "claude-trace" ]; then
       # claude-trace --include-all-requests --run-with claude [args]
       # Inject --dangerously-skip-permissions after "claude"
       while parsing args; do
           if [ "${args[$i]}" = "--run-with" ] && [ "${args[$((i+1))]}" = "claude" ]; then
               new_args+=("--run-with" "claude" "--dangerously-skip-permissions")
           fi
       done
   ```

**Result**:
- Input: `claude-yolo --trace .`
- Command: `claude-trace --include-all-requests --run-with claude .`
- Executed: `claude-trace --include-all-requests --run-with claude --dangerously-skip-permissions .`

**Status**: ✅ **FIXED** - Two-part fix ensures proper command structure and flag injection

---

### [enhancement] Make dev tool installation more flexible

**Problem**: All dev tools are baked into Dockerfile, requiring full image rebuild for new tools.

**Current State**:
- Tools installed in Dockerfile:92-117 (gh, delta, claude, claude-trace)
- Static installation makes customization inflexible
- Image size grows with every tool added
- No runtime tool management

**Solution Options**:

#### Option 1: Runtime Package Installation
```bash
# Environment-driven installation in entrypoint
CLAUDE_INSTALL_PACKAGES="gh,terraform,kubectl"
```
Pros: Maximum flexibility, smaller base image
Cons: Slower startup, network dependency, caching complexity

#### Option 2: Tool Manifest System
```yaml
# .claude-tools.yml in project
tools:
  - gh
  - terraform
  - kubectl
```
Pros: Project-specific tools, version control
Cons: Added complexity, manifest management

#### Option 3: Layered Image Approach
```dockerfile
FROM thevibeworks/ccyolo:base
RUN install-tool gh terraform kubectl
```
Pros: Docker-native, cacheable layers
Cons: Multiple image variants, registry complexity

#### Option 4: Package Manager Integration
```bash
# In entrypoint, detect and install via various PMs
[ -f requirements.txt ] && pip install -r requirements.txt
[ -f package.json ] && npm install -g $(jq -r '.globalDependencies[]' package.json)
```
Pros: Leverages existing ecosystem patterns
Cons: Multiple package manager complexity

**Recommendation**: Start with Option 1 (runtime installation) with intelligent caching.

---

### [enhancement] Inconsistent authentication handling for dev tools

**Problem**: While Claude auth is seamlessly handled via ~/.claude mounting, other dev tools require manual auth setup inside the container.

**Current Auth State**:
- ✅ **Claude**: Auto-mounted via `~/.claude` → `/root/.claude` → `/home/claude/.claude` (symlink)
- ✅ **AWS**: Auto-mounted via `~/.aws` → `/root/.aws` → `/home/claude/.aws` (symlink)
- ✅ **Google Cloud**: Auto-mounted via `~/.config/gcloud` → `/root/.config/gcloud` → `/home/claude/.config/gcloud` (symlink)
- ❌ **GitHub CLI**: Requires manual `gh auth login` or token pasting into `/home/claude/.config/gh/`
- ❌ **Docker Hub**: No auth mounting for `docker login`
- ❌ **Terraform**: No auth mounting for `.terraform.d/credentials`
- ❌ **NPM**: No auth mounting for `.npmrc`

**Impact**: Inconsistent developer experience - some tools work seamlessly, others require manual setup.

**Solution Options**:

#### Option 1: Expand Auto-Mounting
```bash
# In claude.sh, add more auth directories
[ -d "$HOME/.config/gh" ] && DOCKER_ARGS+=("-v" "$HOME/.config/gh:/root/.config/gh")
[ -f "$HOME/.npmrc" ] && DOCKER_ARGS+=("-v" "$HOME/.npmrc:/root/.npmrc")
[ -d "$HOME/.docker" ] && DOCKER_ARGS+=("-v" "$HOME/.docker:/root/.docker")
[ -d "$HOME/.terraform.d" ] && DOCKER_ARGS+=("-v" "$HOME/.terraform.d:/root/.terraform.d")
```
**Pros**: Consistent with current approach, minimal complexity
**Cons**: Hard-coded tool list, doesn't scale

#### Option 2: Generic Config Directory Mounting
```bash
# Mount entire config directories
DOCKER_ARGS+=("-v" "$HOME/.config:/root/.config")
DOCKER_ARGS+=("-v" "$HOME/.local:/root/.local")
```
**Pros**: Catches all XDG-compliant tools automatically
**Cons**: Over-broad mounting, potential security concerns

#### Option 3: Selective Config Mounting with Detection
```bash
# Auto-detect and mount known auth files/dirs
AUTH_PATHS=(
    ".config/gh"     # GitHub CLI
    ".docker"        # Docker Hub
    ".terraform.d"   # Terraform
    ".npmrc"         # NPM
    ".pypirc"        # PyPI
    ".cargo"         # Rust Cargo
)
```
**Pros**: Balanced approach, extensible list
**Cons**: Requires maintenance of auth path list

#### Option 4: Environment Variable Auth Pass-through
```bash
# Pass auth tokens as environment variables
[ -n "$GH_TOKEN" ] && DOCKER_ARGS+=("-e" "GH_TOKEN=$GH_TOKEN")
[ -n "$DOCKER_PASSWORD" ] && DOCKER_ARGS+=("-e" "DOCKER_PASSWORD=$DOCKER_PASSWORD")
[ -n "$NPM_TOKEN" ] && DOCKER_ARGS+=("-e" "NPM_TOKEN=$NPM_TOKEN")
```
**Pros**: Secure, doesn't require file system access
**Cons**: Token-based only, doesn't work for OAuth flows

**Recommendation**: Combine Option 3 (selective mounting) with Option 4 (env var pass-through) for comprehensive auth support.

**Files Affected**:
- `claude.sh:354-376` (current auth mounting logic)
- `docker-entrypoint.sh:91-127` (symlink creation for claude user)

---

### [enhancement-resolved] Multiple Claude instances workflow

**Original Problem**: Users wanted multiple Claude instances in same project without container name conflicts.

**Original Goal Misunderstanding**: We thought users wanted shared containers, but they actually just wanted **multiple simultaneous instances**.

**Simple Solution Implemented**:
- **Reverted to process-based naming**: `claude-code-yolo-${CURRENT_DIR_BASENAME}-$$`
- **Keep `--rm` for auto-cleanup**: Each instance gets its own container
- **No complexity needed**: Each process gets unique container name via `$$`

**Result**:
```bash
# Terminal 1:
claude-yolo .  # → claude-code-yolo-myproject-12345

# Terminal 2:
claude-yolo .  # → claude-code-yolo-myproject-67890

# Both run simultaneously, both auto-cleanup
```

**Why This Works Better**:
- ✅ **Simple**: No shared state, no daemon logic, no container reuse
- ✅ **Isolated**: Each Claude instance in its own container
- ✅ **Clean**: Containers auto-remove with `--rm`
- ✅ **Scalable**: Run as many instances as needed

**Key Insight**: Sometimes the simplest solution (unique names per process) is better than complex shared container architecture.

**Status**: ✅ **RESOLVED** - Ultra-simple solution implemented

---

### [enhancement-completed] Container inspection shortcuts

**Problem**: Container inspection workflow was cumbersome - required multiple steps to access running containers.

**Original Workflow Pain Points**:
1. **Manual discovery**: Must run `docker ps` → find container → copy name
2. **Multi-step access**: `docker exec -it <name> /bin/zsh` → `su - claude` to get proper user context

**Solution Implemented**: Added inspection shortcuts to `claude-yolo` wrapper

**Features Added**:
- `claude-yolo --inspect`: Auto-find and enter container as claude user
- `claude-yolo --ps`: List all containers for current project
- **Smart selection**: Auto-select single container, prompt for multiple
- **Project-aware**: Only shows containers matching current directory pattern

**Implementation Details**:
```bash
# Container discovery by pattern
CONTAINER_PATTERN="claude-code-yolo-${CURRENT_DIR_BASENAME}-"
find_project_containers() {
    docker ps --filter "name=$CONTAINER_PATTERN" --format "{{.Names}}" 2>/dev/null
}

# Smart container selection
if [ $num_containers -eq 1 ]; then
    # Auto-select single container
    exec docker exec -it "$container" gosu claude /bin/zsh
else
    # Prompt user to choose from multiple
    echo "Multiple containers found for this project:"
    # ... interactive selection
fi
```

**User Experience**:

**Before** (painful):
```bash
docker ps                                    # Find container
docker exec -it claude-code-yolo-proj-12345 /bin/zsh  # Enter container
su - claude                                  # Switch to proper user
```

**After** (one command):
```bash
claude-yolo --inspect                       # Auto-find + auto-su to claude user
```

**Multiple Container Support**:
```bash
claude-yolo --inspect

Multiple containers found for this project:
  1) claude-code-yolo-myproject-12345 (Up 5 minutes)
  2) claude-code-yolo-myproject-67890 (Up 2 minutes)

Select container to inspect (1-2): 1
Entering container claude-code-yolo-myproject-12345 as claude user...
```

**Files Modified**:
- `claude-yolo`: Enhanced from simple 22-line wrapper to 75-line tool with container management
- Added help system with `claude-yolo --help`

**Status**: ✅ **COMPLETED** - Issue #4 resolved
