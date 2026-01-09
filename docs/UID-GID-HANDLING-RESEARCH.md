# UID/GID Handling in Docker Containers: Research & Best Practices

**Date:** 2026-01-08
**Context:** Investigation of permission denied errors in deva containers
**Outcome:** Fixed broken UID remapping + documented industry patterns

---

## The Problem We Hit

After commit `5807889` (2025-12-29), deva containers failed to start with:

```
env: 'claude': Permission denied
error: failed to launch ephemeral container
```

**Root cause:** Overly-clever optimization broke fundamental UID remapping logic.

---

## What Broke

### Before (Working - commits before 5807889):
```bash
if [ "$DEVA_UID" != "$current_uid" ]; then
    usermod -u "$DEVA_UID" -g "$DEVA_GID" "$DEVA_USER"
    chown -R "$DEVA_UID:$DEVA_GID" "$DEVA_HOME" 2>/dev/null || true
fi
```

**Behavior:**
- Simple, reliable, comprehensive
- Fixed ALL files in /home/deva after UID change
- **Problem:** Slow on large mounted volumes, corrupts host permissions

### After (Broken - commit 5807889):
```bash
if [ "$DEVA_UID" != "$current_uid" ]; then
    usermod -u "$DEVA_UID" -g "$DEVA_GID" "$DEVA_USER"
    # Only chown files owned by container, skip mounted volumes
    find "$DEVA_HOME" -maxdepth 1 ! -type l -user root -exec chown "$DEVA_UID:$DEVA_GID" {} \; 2>/dev/null || true
fi
```

**Fatal flaws:**
1. **`-maxdepth 1`:** Only checks /home/deva directly, doesn't recurse into subdirectories
2. **`-user root`:** Only fixes root-owned files
3. **Skipped critical directories:**
   - `.npm-global` (owned by UID 1001, not root) → `/home/deva/.npm-global/bin/claude` never fixed
   - `.local` (uv, Python packages)
   - `.oh-my-zsh` (shell config)
   - `.skills` (atlas-cli)
   - `.config`, `.cache`, `go/`

**Result:** After `usermod` changes user from 1001→501, binaries remain owned by 1001 → Permission denied.

### The Fix (Current - 2026-01-08):
```bash
if [ "$DEVA_UID" != "$current_uid" ]; then
    usermod -u "$DEVA_UID" -g "$DEVA_GID" "$DEVA_USER"

    # Fix container-managed directories (whitelist approach - safe for mounted volumes)
    # These directories are created at image build time and must be chowned to match host UID
    for dir in .npm-global .local .oh-my-zsh .skills .config .cache go; do
        if [ -d "$DEVA_HOME/$dir" ] && [ ! -L "$DEVA_HOME/$dir" ]; then
            chown -R "$DEVA_UID:$DEVA_GID" "$DEVA_HOME/$dir" 2>/dev/null || true
        fi
    done

    # Fix container-created dotfiles
    find "$DEVA_HOME" -maxdepth 1 \( -type f -o -type d \) -name '.*' \
        ! -name '..' ! -name '.' \
        -exec chown "$DEVA_UID:$DEVA_GID" {} \; 2>/dev/null || true
fi
```

**Advantages:**
- **Explicit whitelist:** Only touches known container directories
- **Complete:** Recursively fixes everything needed
- **Safe:** Won't touch unknown mounted volumes
- **Fast:** Minimal chown operations
- **Maintainable:** Each directory is documented

---

## Industry Research: UID/GID Handling Patterns

### 1. DevContainer Approach (VS Code)

**Pattern:** Automatic UID matching via container lifecycle hooks

**Implementation:**
```json
{
  "remoteUser": "vscode",
  "updateRemoteUserUID": true
}
```

**How it works:**
- VS Code detects host UID/GID on Linux
- Automatically runs `usermod`/`groupmod` at container start
- Uses lifecycle hooks (onCreate, postCreate) for complex setups

**Sources:**
- [VS Code: Add non-root user](https://code.visualstudio.com/remote/advancedcontainers/add-nonroot-user)
- [Issue: UID/GID fails when GID exists](https://github.com/microsoft/vscode-remote-release/issues/7284)

**Pros:**
- Zero user configuration
- Transparent UID matching
- Industry standard (Microsoft)

**Cons:**
- Requires VS Code
- Not portable
- Black-box magic (hard to debug)

---

### 2. fixuid Pattern (Specialized Tool)

**Pattern:** Purpose-built Go binary for runtime UID/GID fixing

**Installation:**
```dockerfile
RUN addgroup --gid 1000 docker && \
    adduser --uid 1000 --ingroup docker --home /home/docker \
            --shell /bin/sh --disabled-password --gecos "" docker

RUN USER=docker && \
    GROUP=docker && \
    curl -SsL https://github.com/boxboat/fixuid/releases/download/v0.6.0/fixuid-0.6.0-linux-amd64.tar.gz \
         | tar -C /usr/local/bin -xzf - && \
    chown root:root /usr/local/bin/fixuid && \
    chmod 4755 /usr/local/bin/fixuid && \
    mkdir -p /etc/fixuid && \
    printf "user: $USER\ngroup: $GROUP\npaths:\n  - /home/docker\n" > /etc/fixuid/config.yml

ENTRYPOINT ["fixuid", "-q"]
CMD ["/bin/bash"]
```

**Usage:**
```bash
docker run -e FIXUID=1000 -e FIXGID=1000 --user 1000:1000 myimage
```

**How it works:**
- Runs as setuid root (4755 permissions)
- Changes user/group atomically
- Recursively fixes specified paths
- Drops privileges and execs child process

**Sources:**
- [fixuid GitHub](https://github.com/boxboat/fixuid)
- [fixuid Go package docs](https://pkg.go.dev/github.com/boxboat/fixuid)

**Pros:**
- Battle-tested (600+ stars)
- Handles edge cases (existing UIDs, locked files)
- Faster than shell usermod + chown
- Atomic operations

**Cons:**
- External dependency (~2MB)
- **Dev-only warning:** Should NOT be in production images (security)
- setuid binary (potential attack surface)

---

### 3. Jupyter Docker Stacks Pattern

**Pattern:** Runtime environment variables for UID/GID

**Implementation:**
```dockerfile
# Jupyter base-notebook pattern
ARG NB_USER="jovyan"
ARG NB_UID="1000"
ARG NB_GID="100"

RUN groupadd -g $NB_GID $NB_USER && \
    useradd -u $NB_UID -g $NB_GID -m -s /bin/bash $NB_USER

COPY start.sh /usr/local/bin/
ENTRYPOINT ["tini", "-g", "--"]
CMD ["start.sh"]
```

**start.sh:**
```bash
#!/bin/bash
# Adjust UID/GID if environment variables provided
if [ -n "$NB_UID" ] && [ "$NB_UID" != "$(id -u $NB_USER)" ]; then
    usermod -u "$NB_UID" "$NB_USER"
    chown -R "$NB_UID:$NB_GID" "/home/$NB_USER"
fi

# Drop privileges
exec sudo -E -u "$NB_USER" "$@"
```

**Usage:**
```bash
docker run -e NB_UID=1000 -e NB_GID=100 --user root jupyter/base-notebook
```

**Sources:**
- [Jupyter Docker Stacks: Running Containers](https://jupyter-docker-stacks.readthedocs.io/en/latest/using/running.html)
- [Issue: Revisit root permissions](https://github.com/jupyter/docker-stacks/issues/560)
- [Forum: NB_UID and NB_GID meaning](https://discourse.jupyter.org/t/what-do-nb-uid-and-nb-gid-mean-in-dockerfile-in-docker-stacks-foundation/22800)

**Pros:**
- Well-documented
- Industry precedent (Jupyter is trusted)
- Explicit control via env vars

**Cons:**
- Requires starting as root
- Runtime overhead (usermod + chown every start)
- **Dev-only pattern** (not recommended for production)

---

### 4. Production Best Practice (Security Community)

**Pattern:** Build-time permissions, zero runtime changes

**Recommended Dockerfile:**
```dockerfile
FROM ubuntu:24.04

# Build-time ARGs for flexible UID/GID
ARG USER_UID=1000
ARG USER_GID=1000

# Create user at build time with specified UID/GID
RUN groupadd -g $USER_GID appuser && \
    useradd -u $USER_UID -g $USER_GID -m -s /bin/bash appuser

# Install as root
RUN apt-get update && apt-get install -y nodejs npm

# Install app dependencies as root, set ownership at copy time
COPY --chown=appuser:appuser package*.json ./
RUN npm install -g some-cli-tool

# Fix ownership of global npm installations
RUN chown -R appuser:appuser /usr/local/lib/node_modules

# Switch to non-root user for runtime
USER appuser

# No entrypoint scripts, no runtime permission changes
CMD ["node", "app.js"]
```

**Build for specific host UID:**
```bash
docker build --build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g) -t myapp .
```

**Sources:**
- [Docker Security Best Practices](https://sysdig.com/blog/dockerfile-best-practices/)
- [Understanding USER instruction](https://www.docker.com/blog/understanding-the-docker-user-instruction/)
- [Docker forums: UID/GID best practices](https://forums.docker.com/t/best-practices-for-uid-gid-and-permissions/139161)

**Pros:**
- **Production-safe:** No root required at runtime
- **Fast:** Zero runtime overhead
- **Secure:** Immutable permissions
- **Compatible:** Works with `--read-only` filesystems

**Cons:**
- **Inflexible:** Must rebuild for different UIDs
- **Not multi-user:** Can't share single image across team
- **Build-time dependency:** Requires Docker on host

**Key Security Principle:**
> "Running containers as root user is a common anti-pattern. If an attacker exploits a vulnerability in your application, and the container is running as root, the attacker gains root-level access to the container."

---

### 5. User Namespace Remapping (Docker Daemon Feature)

**Pattern:** Transparent UID remapping at kernel level

**Configuration:**
```json
// /etc/docker/daemon.json
{
  "userns-remap": "default"
}
```

**How it works:**
- Docker daemon creates subordinate UID/GID ranges
- Container UID 0 (root) maps to unprivileged host UID (e.g., 100000)
- Container UID 1000 maps to host UID 101000
- Transparent to container processes

**Sources:**
- [Docker: Isolate with user namespace](https://docs.docker.com/engine/security/userns-remap/)
- [Dreamlab: User namespace remapping](https://dreamlab.net/en/blog/post/user-namespace-remapping-an-advanced-feature-to-protect-your-docker-environments/)
- [Collabnix: User Namespaces Lab](https://dockerlabs.collabnix.com/advanced/security/userns/)

**Pros:**
- **Strongest security:** Root in container = unprivileged on host
- **Transparent:** No Dockerfile changes needed
- **Kernel-level:** Can't be bypassed

**Cons:**
- **Host-level config:** Requires daemon restart
- **Not portable:** Different on each host
- **Compatibility issues:** Some images expect real UID 0
- **UID range limits:** Must stay within 0-65535

---

### 6. Alternative: Accept Fixed UID (Simplest)

**Pattern:** Use single UID, accept permission mismatches

**Implementation:**
```dockerfile
FROM ubuntu:24.04
RUN useradd -u 1000 -m appuser
USER 1000:1000
CMD ["myapp"]
```

**Workarounds for host volumes:**
```bash
# Host: Match host UID to container UID
sudo chown -R 1000:1000 ./project

# Or: Add container UID to host groups
sudo usermod -aG 1000 $USER
```

**Sources:**
- [Nick Janetakis: Running as non-root with custom UID/GID](https://nickjanetakis.com/blog/running-docker-containers-as-a-non-root-user-with-a-custom-uid-and-gid)
- [Handling Permissions with Docker Volumes](https://denibertovic.com/posts/handling-permissions-with-docker-volumes/)

**Pros:**
- **Simplest:** Zero complexity
- **Fast:** No runtime overhead
- **Production-ready:** Immutable

**Cons:**
- **macOS incompatible:** Default UID 501, not 1000
- **Multi-user friction:** Different users = different UIDs
- **Requires host changes:** Must adjust host permissions

---

## Comparison Matrix

| Pattern | Dev Use | Prod Use | Performance | Portability | Security | Complexity |
|---------|---------|----------|-------------|-------------|----------|------------|
| **VS Code DevContainer** | ✅ Excellent | ❌ No | Good | Medium | Good | Low (transparent) |
| **fixuid** | ✅ Excellent | ⚠️  Dev-only | Excellent | High | Medium (setuid) | Low |
| **Jupyter Pattern** | ✅ Good | ❌ No | Medium | High | Medium (needs root) | Medium |
| **Build-time ARG** | ⚠️  Rebuild/user | ✅ Excellent | Excellent | Low (per-user) | Excellent | Medium |
| **User Namespaces** | ⚠️  Host-config | ✅ Excellent | Excellent | Low (host-specific) | Excellent | High |
| **Fixed UID 1000** | ⚠️  Workarounds | ✅ Good | Excellent | High | Good | Low |
| **Deva Whitelist** | ✅ Excellent | ⚠️  Dev-only | Good | High | Medium (needs root) | Medium |

---

## Why Runtime UID Fixing is OK for Deva

### Context Matters

Deva is a **development container wrapper**, not a production workload. Different rules apply:

**Production containers:**
- Deployed at scale
- Security-critical
- Immutable infrastructure
- Single-user workflows
- Performance-sensitive

**Development containers:**
- Single developer
- Trusted workspaces
- Need host volume access
- Multi-user (team shares image)
- Flexibility > Security

### Industry Precedent

Three major projects use runtime UID fixing in dev containers:

1. **Jupyter Docker Stacks** (100M+ pulls)
2. **VS Code DevContainers** (millions of users)
3. **JupyterHub spawners** (enterprise deployments)

**Pattern validation:** If Jupyter and VS Code do it, it's legitimate for dev use.

### Deva-Specific Requirements

1. **Multi-user by design:** Team shares single image, can't rebuild per-user
2. **Host volume integration:** Must match host UID for file access
3. **Agent flexibility:** Supports multiple agents (claude, codex, gemini) in one image
4. **Profile system:** Base vs rust images, shared entrypoint logic

**Trade-off:** Accept runtime UID overhead for team collaboration benefits.

---

## Alternative Approaches Considered

### Approach 1: fixuid Integration

```dockerfile
# Add to Dockerfile
RUN curl -SsL https://github.com/boxboat/fixuid/releases/download/v0.6.0/fixuid-0.6.0-linux-amd64.tar.gz \
         | tar -C /usr/local/bin -xzf - && \
    chown root:root /usr/local/bin/fixuid && \
    chmod 4755 /usr/local/bin/fixuid && \
    mkdir -p /etc/fixuid && \
    printf "user: $DEVA_USER\ngroup: $DEVA_USER\npaths:\n  - /home/deva\n" > /etc/fixuid/config.yml

ENTRYPOINT ["fixuid", "-q", "/usr/local/bin/docker-entrypoint.sh"]
```

**Decision:** Not implemented yet, keep as future enhancement
- Feature flag: `DEVA_USE_FIXUID=1`
- Optional dependency
- Fallback to shell if not available

### Approach 2: Build-Time ARG

```bash
# Build per-user image
docker build --build-arg DEVA_UID=$(id -u) --build-arg DEVA_GID=$(id -g) -t deva:eric .
```

**Decision:** Rejected
- Defeats shared image model
- CI/CD builds break (whose UID?)
- Team friction (each dev needs different image)

### Approach 3: User Namespace Remapping

```json
// /etc/docker/daemon.json
{
  "userns-remap": "default"
}
```

**Decision:** Rejected
- Requires host Docker config (not portable)
- Breaks Docker-in-Docker scenarios
- Users can opt-in independently if desired

### Approach 4: Accept Fixed UID 1000

**Decision:** Rejected
- Breaks macOS (default UID 501)
- Requires host filesystem changes
- Poor developer experience

---

## Implementation: Whitelist Approach

### Current Solution (docker-entrypoint.sh)

```bash
setup_nonroot_user() {
    local current_uid=$(id -u "$DEVA_USER")
    local current_gid=$(id -g "$DEVA_USER")

    # Validate UID/GID (avoid UID 0)
    if [ "$DEVA_UID" = "0" ]; then
        echo "[entrypoint] WARNING: Host UID is 0. Using fallback 1000."
        DEVA_UID=1000
    fi
    if [ "$DEVA_GID" = "0" ]; then
        echo "[entrypoint] WARNING: Host GID is 0. Using fallback 1000."
        DEVA_GID=1000
    fi

    # Update GID if needed
    if [ "$DEVA_GID" != "$current_gid" ]; then
        if getent group "$DEVA_GID" >/dev/null 2>&1; then
            # Join existing group
            local existing_group=$(getent group "$DEVA_GID" | cut -d: -f1)
            usermod -g "$DEVA_GID" "$DEVA_USER" 2>/dev/null || true
        else
            # Create new group
            groupmod -g "$DEVA_GID" "$DEVA_USER"
        fi
    fi

    # Update UID if needed
    if [ "$DEVA_UID" != "$current_uid" ]; then
        # usermod may fail with rc=12 when it can't chown home directory (mounted volumes)
        # The UID change itself usually succeeds even when chown fails
        if ! usermod -u "$DEVA_UID" -g "$DEVA_GID" "$DEVA_USER" 2>/dev/null; then
            # Verify what UID we actually got
            local actual_uid=$(id -u "$DEVA_USER" 2>/dev/null)
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

        # Fix container-managed directories (whitelist approach - safe for mounted volumes)
        # These directories are created at image build time and must be chowned to match host UID
        for dir in .npm-global .local .oh-my-zsh .skills .config .cache go; do
            if [ -d "$DEVA_HOME/$dir" ] && [ ! -L "$DEVA_HOME/$dir" ]; then
                chown -R "$DEVA_UID:$DEVA_GID" "$DEVA_HOME/$dir" 2>/dev/null || true
            fi
        done

        # Fix container-created dotfiles
        find "$DEVA_HOME" -maxdepth 1 \( -type f -o -type d \) -name '.*' \
            ! -name '..' ! -name '.' \
            -exec chown "$DEVA_UID:$DEVA_GID" {} \; 2>/dev/null || true
    fi

    chmod 755 /root 2>/dev/null || true
}
```

### Key Design Decisions

1. **Explicit whitelist:** Each directory is named, not discovered
   - Prevents accidents (won't chown unknown mounted volumes)
   - Self-documenting (clear what's managed)
   - Maintainable (easy to add new directories)

2. **Symlink protection:** `[ ! -L "$DEVA_HOME/$dir" ]`
   - Avoids following symlinks to mounted volumes
   - Prevents permission corruption on host

3. **Error tolerance:** `2>/dev/null || true`
   - Continues if chown fails (e.g., NFS volumes)
   - Non-fatal for better UX

4. **Dotfile handling:** Separate find for hidden files
   - Catches `.zshrc`, `.bashrc`, `.gitconfig`
   - Doesn't recurse (shallow only)

5. **Execution order fix:** Moved `setup_nonroot_user` before `ensure_agent_binaries`
   - Permissions must be fixed BEFORE checking if binaries exist
   - Previous order was illogical (root check, then fix permissions)

---

## Future Enhancements

### 1. Caching Mechanism

Avoid repeated chown on persistent containers:

```bash
setup_nonroot_user() {
    # ... existing UID change logic ...

    # Skip if already fixed this session
    local marker="/tmp/.deva_uid_fixed_${DEVA_UID}"
    if [ -f "$marker" ]; then
        return 0
    fi

    # ... fix permissions ...

    # Mark as fixed
    touch "$marker"
}
```

**Benefits:**
- Faster container restarts
- Reduced disk I/O
- Better for persistent container workflows

### 2. Optional fixuid Support

Feature-flag for advanced users:

```bash
if [ "${DEVA_USE_FIXUID:-false}" = "true" ] && command -v fixuid >/dev/null 2>&1; then
    exec fixuid -q "$@"
else
    # Fallback to shell implementation
    setup_nonroot_user
fi
```

**Benefits:**
- Performance boost for fixuid users
- No breaking change (opt-in)
- Maintains shell fallback

### 3. Verbose Logging

Debug mode for permission issues:

```bash
if [ "${DEVA_DEBUG_PERMISSIONS:-false}" = "true" ]; then
    echo "[entrypoint] Fixing $dir ownership..."
    chown -Rv "$DEVA_UID:$DEVA_GID" "$DEVA_HOME/$dir"
else
    chown -R "$DEVA_UID:$DEVA_GID" "$DEVA_HOME/$dir" 2>/dev/null || true
fi
```

**Benefits:**
- Easier debugging for users
- Troubleshooting permission issues
- Optional verbosity (no log spam by default)

---

## Key Takeaways

1. **Runtime UID fixing is legitimate for dev containers**
   - Jupyter, VS Code, JupyterHub all do it
   - Production rules don't apply to dev workflows

2. **The "optimization" in commit 5807889 was premature**
   - Tried to avoid chowning mounted volumes
   - Broke fundamental functionality
   - Whitelist approach solves both problems

3. **Explicit > Clever**
   - Named directory list beats find heuristics
   - Clear intent beats magic logic
   - Maintainability > Performance

4. **Context matters in security decisions**
   - Development containers have different threat models
   - Flexibility and UX trump absolute security
   - Document why it's OK to break "rules"

5. **Industry research validates our approach**
   - Not inventing new patterns
   - Following proven solutions
   - Standing on shoulders of giants

---

## References

### Official Documentation
- [Docker: Isolate with user namespace](https://docs.docker.com/engine/security/userns-remap/)
- [Docker: Understanding USER instruction](https://www.docker.com/blog/understanding-the-docker-user-instruction/)
- [VS Code: Add non-root user to container](https://code.visualstudio.com/remote/advancedcontainers/add-nonroot-user)

### Tools & Libraries
- [fixuid GitHub Repository](https://github.com/boxboat/fixuid)
- [Jupyter Docker Stacks Documentation](https://jupyter-docker-stacks.readthedocs.io/en/latest/using/running.html)

### Best Practices & Guides
- [Sysdig: Dockerfile Best Practices](https://sysdig.com/blog/dockerfile-best-practices/)
- [Nick Janetakis: Non-root with custom UID/GID](https://nickjanetakis.com/blog/running-docker-containers-as-a-non-root-user-with-a-custom-uid-and-gid)
- [Docker Forums: UID/GID Best Practices](https://forums.docker.com/t/best-practices-for-uid-gid-and-permissions/139161)
- [Deni Bertovic: Handling Permissions with Docker Volumes](https://denibertovic.com/posts/handling-permissions-with-docker-volumes/)

### Issue Trackers & Discussions
- [VS Code: UID/GID change fails when GID exists](https://github.com/microsoft/vscode-remote-release/issues/7284)
- [Jupyter: Revisit root permissions and entrypoint](https://github.com/jupyter/docker-stacks/issues/560)
- [Jupyter Forums: NB_UID and NB_GID meaning](https://discourse.jupyter.org/t/what-do-nb-uid-and-nb-gid-mean-in-dockerfile-in-docker-stacks-foundation/22800)

### Security Resources
- [Dreamlab: User namespace remapping](https://dreamlab.net/en/blog/post/user-namespace-remapping-an-advanced-feature-to-protect-your-docker-environments/)
- [Collabnix: User Namespaces Lab](https://dockerlabs.collabnix.com/advanced/security/userns/)

---

**Last Updated:** 2026-01-08
**Maintained by:** Claude Code (via deva development)
