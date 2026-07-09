#!/usr/bin/env bash
# triage.sh - deva-clean pass one: read-only triage of a deva workspace.
# Emits a tiered dry-run plan on stdout. Never deletes anything.
#
# Usage: triage.sh [WORKSPACE] [--fetch]
#
#   WORKSPACE   workspace root (default: current directory)
#   --fetch     refresh each repo's default branch before the merged
#               check (writes refs into the repo's .git only; worktrees
#               and mounts are untouched)
#
# Verdicts:
#   PUSHED-EXACT  remote branch tip == local HEAD (live ls-remote)
#   MERGED        HEAD is ancestor of origin/<default>; monotonic, so
#                 provable even against stale refs
#   LOCAL-ONLY    branch absent on remote, HEAD not in fresh default
#   UNVERIFIED    branch absent on remote, default ref stale and no
#                 --fetch: could be recently merged - treat as keep
#   DIVERGED      remote branch exists but tip differs from HEAD
#   OFFLINE       ls-remote failed: no live evidence
#   NO-REMOTE     repo has no origin remote
set -uo pipefail
shopt -s nullglob dotglob

WS=$PWD
DO_FETCH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fetch) DO_FETCH=1 ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) WS=$(cd "$1" && pwd) || exit 2 ;;
  esac
  shift
done
NET_TIMEOUT=${DEVA_CLEAN_TIMEOUT:-20}

# --- step 1: mount map (ground truth: the kernel, not .deva) ----------
mapfile -t MOUNTS < <(awk -v ws="$WS" '$2 == ws || index($2, ws"/") == 1 {print $2}' /proc/mounts | sort)

is_mount() {
  local m
  for m in "${MOUNTS[@]}"; do [[ $m == "$1" ]] && return 0; done
  return 1
}

has_mount_below() {
  local m
  for m in "${MOUNTS[@]}"; do [[ $m == "$1"/* ]] && return 0; done
  return 1
}

echo "== deva-clean triage: $WS"
echo "== mounts: ${#MOUNTS[@]} (off limits)"
is_mount "$WS" || echo "!! workspace root is not a bind mount - is this a deva workspace?"

# --- step 2: locate the pressure --------------------------------------
echo
echo "-- pressure"
df -h / "$WS" | awk 'NR==1 || $NF=="/" || $NF=="'"$WS"'"'

# --- step 3: candidates = non-mount dirs; descend only through dirs
# --- that still contain mounts beneath them ----------------------------
CANDIDATES=()
collect() {
  local e
  for e in "$1"/*/; do
    e=${e%/}
    [[ ${e##*/} == .git ]] && continue
    if is_mount "$e"; then continue; fi
    if has_mount_below "$e"; then collect "$e"; else CANDIDATES+=("$e"); fi
  done
}
collect "$WS"

# --- step 4: four verdicts per candidate -------------------------------
declare -A DEF_BRANCH FETCH_STATE   # cached per remote URL
T1=() T2=() KEEP=() JUDGE=()
T1_KB=0 T2_KB=0

kb() { du -sk "$1" 2>/dev/null | cut -f1; }
hsize() { echo "$1" | awk '{ if ($1>=1048576) printf "%.1fG", $1/1048576; else if ($1>=1024) printf "%.0fM", $1/1024; else printf "%dK", $1 }'; }

for d in "${CANDIDATES[@]}"; do
  size_kb=$(kb "$d"); size=$(hsize "$size_kb")

  if [[ -f $d/.git ]]; then type=linked
  elif [[ -d $d/.git ]]; then type=standalone
  else JUDGE+=("$size  $d  (no git evidence - judgment call)"); continue; fi

  head=$(git -C "$d" rev-parse HEAD 2>/dev/null) || { KEEP+=("$size  $d  unreadable git state"); continue; }
  br=$(git -C "$d" rev-parse --abbrev-ref HEAD)
  porcelain=$(git -C "$d" status --porcelain 2>/dev/null)
  dirty=0; untracked_only=1
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    dirty=$((dirty + 1))
    [[ $line == '??'* ]] || untracked_only=0
  done <<< "$porcelain"

  url=$(git -C "$d" remote get-url origin 2>/dev/null) || url=""
  verdict=""
  if [[ -z $url ]]; then
    verdict=NO-REMOTE
  else
    if [[ -z ${DEF_BRANCH[$url]:-} ]]; then
      DEF_BRANCH[$url]=$(timeout "$NET_TIMEOUT" git -C "$d" ls-remote --symref origin HEAD 2>/dev/null \
        | awk '$1=="ref:"{sub("refs/heads/","",$2); print $2; exit}')
    fi
    def=${DEF_BRANCH[$url]}
    if [[ -z $def ]]; then
      verdict=OFFLINE
    else
      remote_sha=""
      [[ $br != HEAD ]] && remote_sha=$(timeout "$NET_TIMEOUT" git -C "$d" ls-remote origin "refs/heads/$br" 2>/dev/null | cut -f1)
      if [[ -n $remote_sha && $remote_sha == "$head" ]]; then
        verdict=PUSHED-EXACT
      else
        base_ref="" base_note=""
        if [[ $DO_FETCH == 1 && -z ${FETCH_STATE[$url]:-} ]]; then
          if timeout $((NET_TIMEOUT * 3)) git -C "$d" fetch origin "$def" >/dev/null 2>&1; then
            FETCH_STATE[$url]=fresh
          else FETCH_STATE[$url]=failed; fi
        fi
        common=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir)
        if [[ ${FETCH_STATE[$url]:-} == fresh ]]; then
          base_ref=FETCH_HEAD base_note=fresh
        elif git -C "$d" rev-parse -q --verify "origin/$def" >/dev/null 2>&1; then
          base_ref="origin/$def"
          base_note="refs from $(stat -c %y "$common/FETCH_HEAD" 2>/dev/null | cut -d' ' -f1 || echo unknown)"
        fi
        if [[ -n $base_ref ]] && git -C "$d" merge-base --is-ancestor "$head" "$base_ref" 2>/dev/null; then
          verdict="MERGED($def,$base_note)"
        elif [[ -n $remote_sha ]]; then
          verdict=DIVERGED
        elif [[ $base_note == fresh ]]; then
          verdict=LOCAL-ONLY
        else
          verdict="UNVERIFIED($base_note; rerun with --fetch)"
        fi
      fi
    fi
  fi

  row="$size  $d  [$type $br] dirty=$dirty $verdict"
  case $verdict in
    PUSHED-EXACT|MERGED*)
      if [[ $dirty -eq 0 ]]; then
        if [[ $type == linked ]]; then
          parent=$(dirname "$(git -C "$d" rev-parse --path-format=absolute --git-common-dir)")
          T1+=("$row"$'\n'"      \$ git -C $parent worktree remove $d")
        else
          T1+=("$row"$'\n'"      \$ rm -rf $d")
        fi
        T1_KB=$((T1_KB + size_kb))
      elif [[ $untracked_only -eq 1 ]]; then
        T2+=("$row"$'\n'"      untracked: $(echo "$porcelain" | sed 's/^?? //' | head -5 | tr '\n' ' ')")
        T2_KB=$((T2_KB + size_kb))
      else
        KEEP+=("$row - MODIFIED TRACKED FILES (promote to tier 2 only with judgment)")
      fi ;;
    *) KEEP+=("$row") ;;
  esac
done

# --- stale worktree metadata in mounted parent repos -------------------
PRUNABLE=()
for m in "${MOUNTS[@]}"; do
  [[ -d $m/.git ]] || continue
  n=$(git -C "$m" worktree list --porcelain 2>/dev/null | grep -c '^prunable') || n=0
  [[ $n -gt 0 ]] && PRUNABLE+=("$m: $n stale entries -> \$ git -C $m worktree prune")
done

# --- step 5: the plan ---------------------------------------------------
section() {
  echo; echo "-- $1"; shift
  local x any=0
  for x in "$@"; do [[ -n $x ]] && { printf '  %s\n' "$x"; any=1; }; done
  [[ $any -eq 0 ]] && echo "  (none)"
  return 0
}
section "TIER 1: safe (clean + pushed/merged), reclaim ~$(hsize $T1_KB)" "${T1[@]:-}"
section "TIER 2: confirm (pushed/merged, untracked files only), reclaim ~$(hsize $T2_KB)" "${T2[@]:-}"
section "KEEP: would lose the only copy" "${KEEP[@]:-}"
section "JUDGMENT: no git evidence, decide case by case" "${JUDGE[@]:-}"
section "stale worktree metadata" "${PRUNABLE[@]:-}"
echo
echo "== plan only - nothing was deleted. Execution is pass two (see SKILL.md)."
