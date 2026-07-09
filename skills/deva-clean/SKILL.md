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

Two passes. Pass one is deterministic and scripted; pass two executes
only what got approved.

## Pass one: triage

Run the bundled script - read-only, emits the tiered plan, never
deletes:

    scripts/triage.sh [workspace] [--fetch]

It maps mounts from /proc/mounts (ground truth - .deva drifts), shows
which disk is under pressure, walks the non-mount dirs, gives every
candidate four verdicts (type, dirty, pushed, freshness), and finds
stale worktree metadata in the mounted parent repos. Verdict semantics
live in the script header; two encode traps worth knowing:

- The pushed test is live ls-remote SHA comparison plus ancestry in
  the default branch - never upstream config. A branch created off
  origin/develop shows "ahead 1" while never pushed itself.
- MERGED is monotonic, provable even against stale refs. Absence is
  not: a branch absent on remote with stale refs is UNVERIFIED, not
  safe. Rerun with --fetch for a definitive verdict.

Then layer the judgment the script refuses to automate:

- Pressure: container overlay genuinely full (rare - on shared-VM
  runtimes overlay df reports the whole VM disk) means container
  caches (~/.cache, package stores) are the target, not the workspace.
- Stray files: the script walks dirs only; shell-typo artifacts like
  "&1" are yours to spot.
- Promotions: KEEP entries flagged MODIFIED TRACKED FILES move to
  tier 2 only when you can name every dirty file as a generated
  artifact (lockfiles, test output) and say so in the plan.
- Demotions: tier 1/2 entries that are functionally live - symlink
  targets, open-PR checkouts - move to keep.
- Keepers: offer cache-prune (node_modules, dist, coverage) as the
  low-risk alternative; for LOCAL-ONLY work, say exactly what would
  be lost and suggest pushing it.

Done when every candidate sits in a tier you can defend. Present the
plan and stop - pass two starts only from explicit approval, tier by
tier.

## Pass two: execute approved tiers

- Linked worktrees: `git -C <parent> worktree remove <path>` is the
  only removal path. Its refusal on a dirty tree is the safety net, so
  no --force - and no rm -rf, which bypasses the net and leaves stale
  metadata behind.
- Tier 2 trees: first delete the named generated files (restore
  tracked ones with `git checkout --`), so the tree is genuinely clean
  and the safety net stays armed.
- Stale metadata: `git -C <parent> worktree prune`.
- Standalone repos (pushed, clean) and plain dirs: rm -rf.

Safe by construction: `git worktree remove` deletes the checkout only;
branch refs live in the parent repo's .git and survive. Committed work
is never lost - only uncommitted files can be. The metadata edit inside
the parent's .git is normal bookkeeping, not touching the mount.

Done when df shows the reclaim and a triage rerun reports empty tiers.
