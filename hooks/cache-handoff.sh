#!/usr/bin/env bash
# Wake Claude for a hand-off while the 1h prompt cache is still warm.
#
# Runs as an asyncRewake Stop hook: it detaches, sleeps through the idle
# gap, and exits 2 to wake the model only if the session is still idle
# and this is still the newest pending sleeper for the session.
#
# Behavior verified against claude 2.1.220:
#   - main-thread prompt cache TTL is 1h (5m for background queries,
#     and during usage overage).
#   - a command hook with asyncRewake:true that exits 2 injects a
#     priority-next task notification, which wakes an idle session.
#     stderr wins over stdout for the payload.
#   - the built-in away-summary only fires on terminal blur and skips
#     past 0.9x TTL; an idle-but-focused session gets nothing.
# Fire at 50min, not 60: leaves the model room to finish before the
# cache dies.

set -uo pipefail

FIRE_AFTER="${CC_HANDOFF_AFTER_SEC:-3000}"
STATE_DIR="${CC_HANDOFF_STATE_DIR:-${TMPDIR:-/tmp}/cc-cache-handoff}"

input=$(cat)
read -r active session transcript <<<"$(
  printf '%s' "$input" | jq -r '[(.stop_hook_active // false), .session_id, (.transcript_path // "")] | @tsv'
)"

# The rewake itself marks the next turn stop-hook-active. Never chain
# off our own wake.
[[ "$active" == "true" ]] && exit 0
[[ -z "$session" || "$session" == "null" ]] && exit 0

mkdir -p "$STATE_DIR" || exit 0
pidfile="$STATE_DIR/$session.pid"
donefile="$STATE_DIR/$session.done"

size_of() {
    if [[ -f "$1" ]]; then
        wc -c <"$1" | tr -d ' '
    else
        echo 0
    fi
}
before=$(size_of "$transcript")

# Supersede any older sleeper for this session. Claude Code does not
# deduplicate async hooks, so every Stop would otherwise leave a
# process behind.
if [[ -f "$pidfile" ]]; then
    old=$(cat "$pidfile" 2>/dev/null)
    [[ -n "$old" && "$old" != "$$" ]] && kill "$old" 2>/dev/null
fi
echo $$ >"$pidfile"

sleep "$FIRE_AFTER"

# A newer Stop claimed the session while we slept.
[[ "$(cat "$pidfile" 2>/dev/null)" == "$$" ]] || exit 0
# A turn is in flight (started but not yet stopped) -- do not interrupt.
[[ "$(size_of "$transcript")" == "$before" ]] || exit 0
# Already handed off at this exact transcript position.
[[ "$(cat "$donefile" 2>/dev/null)" == "$before" ]] && exit 0

echo "$before" >"$donefile"

cat >&2 <<'EOF'
This session has been idle for ~50 minutes. The 1h prompt cache is close
to expiring, so this is the last cheap read of the full context.

Write a hand-off now, then stop. Do not start new work.

Cover, in plain prose:
  - the goal, and where the current task actually stands
  - decisions made and what they cost / ruled out
  - what was verified against reality vs. still assumed
  - the one next action, concrete enough to execute cold

Persist it to a file so it survives the cache and this context. Then
reply with one or two sentences saying where you put it.
EOF
exit 2
