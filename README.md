# claude-caffeinate

Keeps your Mac awake while Claude Code is working and lets it sleep again when
Claude stops — but only for the sessions you ask, when you ask. No always-on
hooks, no session stepping on another's.

A fork of [FelipeOFF/caffeinate-claude-plugin](https://github.com/FelipeOFF/caffeinate-claude-plugin)
with opt-in, per-session control added.

macOS only: everything is a no-op where `/usr/bin/caffeinate` doesn't exist.

## Install

```
/plugin marketplace add fgiova/claude-caffeinate
/plugin install claude-caffeinate
```

## Nothing happens until you ask

Installing changes no behaviour: the hooks are wired but inert. Everything below
is scoped to the session you run it in.

| Command | Effect |
|---|---|
| `/claude-caffeinate:on` | manual lock — awake until you release it, `Stop` can't touch it |
| `/claude-caffeinate:off` | release this session's locks and turn its hook automation back off |
| `/claude-caffeinate:hooks-on` | hand this session to the hooks: awake while Claude works, asleep when it stops |
| `/claude-caffeinate:status` | this session's state, plus how many other sessions hold a lock |

The opt-in is per session, so a new session always starts inert.

### Shorter names, optionally

Plugin commands always carry their plugin prefix. If you want prefix-free
aliases, install two user-level commands that call the same script:

```bash
bash scripts/install-commands.sh              # /caffeinate and /decaffeinate
bash scripts/install-commands.sh --uninstall
```

Both spellings share one state.

### Remote Control

Driving a session from your phone is exactly when the Mac must not sleep: `Stop`
fires between remote prompts, so `hooks-on` would release the lock in the gaps.
Use `on` — the manual lock, which no hook can drop — for the whole remote
session.

Remote Control itself can't be toggled from a plugin: `/remote-control` (alias
`/rc`) is a UI command, with no tool, hook event or CLI equivalent after startup.

### Once `hooks-on` is in effect

| Hook | What happens |
|---|---|
| `UserPromptSubmit` | starts that session's `caffeinate -di` |
| `Stop` | releases it — unless background tasks are still running |
| `SessionEnd` | releases everything that session owned, manual lock included |

Concurrent sessions each own their own `caffeinate` process, so stopping one —
`Stop`, `SessionEnd`, or `off` — never releases another's. `off` reports how many
other sessions still hold the Mac awake; it will not touch them.

Same commands from a terminal, no Claude session needed:

```bash
bash scripts/caffeinate.sh on|off|hooks-on|status
```

## State

Flag files in `$TMPDIR` (per-boot, nothing to clean up by hand):

- `claude-caffeinate-<session>.hook.pid` — hook-owned lock, as `<caffeinate pid> <owner pid>`
- `claude-caffeinate-<session>.manual.pid` — manual lock from `on`, same shape
- `claude-caffeinate-<session>.hooks-enabled` — present once that session ran `hooks-on`, holding its owner pid

The session id comes from the hook payload for hooks and from
`$CLAUDE_CODE_SESSION_ID` for commands — the same value, so both halves address
the same state (a plain shell falls back to `$CLAUDE_PID`). The manual lock is a
separate `caffeinate` process from the hook lock, which is why `Stop` can't kill
it.

### A crashed session can't leave the Mac awake

Two independent guards, because `SessionEnd` doesn't fire on a crash or `kill -9`:

1. Every lock is started as `caffeinate -di -w <owner>`, so it exits with the
   Claude process that asked for it. The owner is `$CLAUDE_PID` when exported,
   otherwise the nearest `claude` ancestor of the script — hooks and commands both
   resolve it, so the `-w` is always there.
2. Every invocation reaps: a lock whose owner pid is gone is killed, its pidfile
   removed, and a dead session's opt-in flag cleared. This catches anything the
   first guard couldn't, and the state lives in `$TMPDIR`, which a reboot clears.

## Test

```bash
bash scripts/test-caffeinate.sh
```

Safe to run alongside real sessions: it works on throwaway session ids only.

## License

MIT
