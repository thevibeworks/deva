# hooks

Opt-in Claude Code hooks. Like `skills/`: repo files you copy in
yourself. Deva never writes into `~/.claude` -- it is bind-mounted from
the host, and your settings are yours.

## cache-handoff.sh

Claude Code keeps the main-thread prompt cache warm for 1h. When you
walk away mid-task and come back later, the cache is dead and the next
turn re-reads the whole context at full price -- and whatever the model
was holding in its head is gone with it.

This hook wakes an idle session ~50min in (while the cache is still
warm, i.e. the re-read is nearly free) and has the model write a
hand-off to a file: goal, state, decisions, next action. It uses the
`asyncRewake` Stop-hook mechanism (verified against claude 2.1.220):
exit 2 from an async hook injects a priority-next notification that
wakes an idle session.

It never interrupts running work: it only fires when the transcript has
not grown since the Stop that scheduled it, only the newest sleeper per
session survives, and it fires at most once per transcript position.

### Install (per workspace)

```bash
mkdir -p "$ws/.claude/hooks"
cp hooks/cache-handoff.sh "$ws/.claude/hooks/"
chmod +x "$ws/.claude/hooks/cache-handoff.sh"
```

Then merge into `$ws/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/cache-handoff.sh",
            "asyncRewake": true,
            "timeout": 3300,
            "rewakeMessage": "Idle hand-off (prompt cache expiring):",
            "rewakeSummary": "Prompt cache expiring - writing hand-off"
          }
        ]
      }
    ]
  }
}
```

The `timeout` must exceed the sleep (default 3000s); hooks without it
get killed at 600s.

### Knobs

```
CC_HANDOFF_AFTER_SEC   seconds idle before firing (default 3000)
CC_HANDOFF_STATE_DIR   pid/done state dir (default $TMPDIR/cc-cache-handoff)
```

State is per-session pid + done files; container-local, nothing
persists or leaks to the host.

### Caveats

- `asyncRewake`, `rewakeMessage`, `rewakeSummary` are internal,
  undocumented settings fields. They work in 2.1.220 and are not
  feature-gated, but a future claude release can break them silently.
- The built-in away-summary does something similar but requires
  terminal blur and skips past 0.9x cache TTL. This hook covers the
  idle-but-focused case (and headless/container sessions, which never
  blur).
