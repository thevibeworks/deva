---
name: deva-clean
description: Disk cleanup for deva container workspaces - reclaim space without touching bind mounts or unpushed work. Use when the user wants disk space reclaimed in a deva workspace, asks to remove stale worktrees, or a disk-full symptom traces into the workspace. Deleting a single known build dir needs no skill - just delete it.
---

# deva-clean: mount-safe workspace disk cleanup

A deva workspace mixes two kinds of directories that look identical in
ls: bind mounts declared in `.deva` (live host repos) and local dirs
created during work (git worktrees, node_modules, package stores).
rm -rf on the wrong one destroys a live repo on the host. And because
the workspace root is itself a host mount, local dirs still consume
host disk - usually the disk that is actually full.

The run is two passes. Pass one triages everything into a dry-run plan
and stops for approval. Pass two executes only the approved tiers.

## Pass one: triage

### 1. Map the mounts

Read `.deva` for declared VOLUME=host:container[:mode] lines, then take
ground truth from the kernel - config drifts, /proc/mounts does not:

    grep "$(pwd)" /proc/mounts | awk '{print $2}' | sort

The workspace root is usually itself a mount, so everything under it
that is not a separate mount is a local dir living on host disk.

Done when every dir under the workspace is classified mount or local.
Mounts are off limits for the rest of the run.

### 2. Locate the pressure

    df -h / "$(pwd)"

Overlay numbers can lie: on shared-VM runtimes (OrbStack and friends)
overlay df reports the whole VM disk. Container-local truth:

    sudo du -xh -d1 / | sort -rh | head

Done when you know which disk is full. Host mount full: the workspace
is the target. Overlay genuinely full: container caches (~/.cache,
package stores) are the target instead.

### 3. Size the candidates

Candidates = the local dirs from step 1, plus stray files (shell-typo
artifacts like "&1"). Typical: trees from `git worktree add`, one-off
clones, node_modules, .pnpm-store.

    du -sh <candidates> | sort -rh

Done when every candidate has a size.

### 4. Git-triage each candidate

Four verdicts per candidate:

- Type: `.git` file -> linked worktree; `.git` dir -> standalone repo;
  neither -> plain dir.
- Dirty: `git status --porcelain`. Untracked generated files (lockfiles,
  test output) are lower risk than modified source.
- Pushed: `git branch -r --contains HEAD` - empty output means the
  commits exist nowhere but this machine. This is the only pushed test:
  upstream config and ahead/behind counts are a trap (a branch created
  off origin/develop tracks origin/develop and shows "ahead 1" while
  never pushed itself).
- Freshness: remote refs are only as new as the last fetch. Check
  `stat .git/FETCH_HEAD` on the parent repo; flag stale refs in the
  plan.

Inside keepers, node_modules / dist / coverage are separately prunable:
offer cache-prune as the low-risk alternative to removal. Also run
`git worktree list` on each parent repo - "prunable" entries are stale
metadata from already-deleted trees.

Done when every candidate carries all four verdicts. The smallest dir
gets the same triage as the largest: a 4M worktree can hold the only
copy of uncommitted work.

### 5. Assemble the dry-run plan

- Tier 1 (safe): clean + pushed. Sizes and exact commands.
- Tier 2 (confirm): pushed branch, dirty only with generated artifacts.
  Offer full removal and cache-prune-only variants.
- Keep: unpushed commits or uncommitted diffs. Say exactly what would
  be lost and suggest pushing the branches.
- Totals: reclaim per tier.

The plan is pass one's deliverable. Present it and stop - pass two
starts only from explicit approval, tier by tier.

## Pass two: execute approved tiers

- Linked worktrees: `git -C <parent> worktree remove <path>` is the
  only removal path. Its refusal on a dirty tree is the safety net, so
  no --force - and no rm -rf, which bypasses the net and leaves stale
  metadata behind.
- Stale metadata: `git -C <parent> worktree prune`.
- Standalone repos (pushed, clean) and plain dirs: rm -rf.

Safe by construction: `git worktree remove` deletes the checkout only;
branch refs live in the parent repo's .git and survive. Committed work
is never lost - only uncommitted files can be. The metadata edit inside
the parent's .git is normal bookkeeping, not touching the mount.

Done when df shows the reclaim and `git worktree list` on each parent
has no leftovers.
