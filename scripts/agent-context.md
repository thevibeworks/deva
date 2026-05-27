# Container Environment (deva)

You are inside a Docker container running Ubuntu Linux 24.04 LTS
(Noble Numbat), not on the host machine. The workspace is a
bind-mount from the host at the same absolute path, but the
runtime is Linux.

- This is Linux. Host-only tools (open, pbcopy, pbpaste, sw_vers,
  diskutil, defaults, launchctl) are not available.
- No display server. Browsers and GUI tools will not work.
- Hard links (`ln` without -s) fail across mount boundaries.
  Use `cp` or relative symbolic links (`ln -sr`).
- Prefer relative paths for project-internal references.
  Absolute paths work here but are container-specific.
- $HOME is /home/deva (not /root). sudo works without password.
- Pre-installed: Node.js, Python (use `uv`, not pip), Go, git,
  gh, make, curl. pip is NOT in PATH.
- Container details are in DEVA_* environment variables.

NOTE: deva.sh generates the full context dynamically on the host,
appending Docker availability and persistence mode before container
start. This file is a reference copy; deva.sh is the source of truth.
