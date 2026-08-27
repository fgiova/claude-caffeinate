#!/usr/bin/env bash
# claude-caffeinate — keep the Mac awake, by hand or (opt-in) driven by hooks.
#
# Usage: caffeinate.sh <on|off|hooks-on|status|_prompt|_stop|_end>
#   on        manual lock for THIS session: awake until `off`, hooks can't release it
#   off       release this session's locks and turn its hook automation back off
#   hooks-on  opt this session into hook automation (awake while Claude works)
#   status    print this session's state, plus a read-only count of other sessions
#   _prompt   UserPromptSubmit hook   (reads hook JSON on stdin)
#   _stop     Stop hook               (reads hook JSON on stdin)
#   _end      SessionEnd hook: releases everything owned by that session
#
# Hook automation is OFF until `hooks-on` asks for it, and the opt-in is scoped to
# one session — as is every lock, so concurrent Claude sessions never release each
# other's.
set -u

# caffeinate is macOS-only; stay harmless everywhere else.
command -v caffeinate >/dev/null 2>&1 || { echo "caffeinate not available (macOS only) — nothing to do"; exit 0; }

dir="${TMPDIR:-/tmp}"
prefix="$dir/claude-caffeinate-"

# Session key: hook stdin JSON wins (hooks may run without our env), then the env
# var Claude Code exports to commands, then the CLI pid.
session_id() {
  local input=${1:-} sid=
  if [ -n "$input" ]; then
    sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
    [ -z "$sid" ] && sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  fi
  [ -z "$sid" ] && sid="${CLAUDE_CODE_SESSION_ID:-}"
  [ -z "$sid" ] && sid="${CLAUDE_PID:-}"
  printf '%s' "${sid:-default}"
}

# The Claude process that owns a lock: its env var if exported to us, else the
# nearest `claude` ancestor of this script.
owner_pid() {
  if [ -n "${CLAUDE_PID:-}" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then printf '%s' "$CLAUDE_PID"; return; fi
  local p=$PPID i=0
  while [ "$i" -lt 6 ] && [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in *claude*) printf '%s' "$p"; return;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); i=$((i+1))
  done
}

# A pidfile holds "<caffeinate pid> <owner pid>"; the owner may be absent.
caff_pid()  { cut -d' ' -f1 "$1" 2>/dev/null; }
owner_of()  { cut -d' ' -f2 -s "$1" 2>/dev/null; }
alive() { local pid; pid=$(caff_pid "$1"); [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; }

start() {
  alive "$1" && return 0
  local own; own=$(owner_pid)
  # -d: no display sleep   -i: no idle system sleep
  # -w <pid>: die with the Claude process, so a crashed session can't leak a lock.
  if [ -n "$own" ]; then
    nohup caffeinate -di -w "$own" >/dev/null 2>&1 &
  else
    nohup caffeinate -di >/dev/null 2>&1 &
  fi
  echo "$! $own" > "$1"
}

stop() {
  local pid; pid=$(caff_pid "$1")
  [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
  rm -f "$1"
}

# Housekeeping, run on every invocation:
#   - a caffeinate that already exited (its `-w` owner died) leaves a stale pidfile
#   - a caffeinate whose owner session is gone is an orphan: kill it
# This is the backstop for `-w` — a lock started without a known owner, or a
# session killed with -9, is still cleaned up by the next invocation.
prune() {
  local pf own
  for pf in "$prefix"*.pid; do
    [ -e "$pf" ] || continue
    if ! alive "$pf"; then rm -f "$pf"; continue; fi
    own=$(owner_of "$pf")
    [ -n "${own:-}" ] || continue
    kill -0 "$own" 2>/dev/null || stop "$pf"
  done
  for f in "$prefix"*.hooks-enabled; do
    [ -e "$f" ] || continue
    own=$(cat "$f" 2>/dev/null || true)
    [ -n "${own:-}" ] || continue
    kill -0 "$own" 2>/dev/null || rm -f "$f"
  done
}

others() {
  local n=0
  for pf in "$prefix"*.pid; do
    [ -e "$pf" ] || continue
    case "$pf" in "$hook"|"$manual") continue;; esac
    alive "$pf" && n=$((n+1))
  done
  printf '%s' "$n"
}

cmd="${1:-status}"
input=
case "$cmd" in _*) input=$(cat 2>/dev/null || true);; esac

sid=$(session_id "$input")
hook="${prefix}${sid}.hook.pid"
manual="${prefix}${sid}.manual.pid"
enabled="${prefix}${sid}.hooks-enabled"

prune

case "$cmd" in
  on)
    start "$manual"
    echo "Mac stays awake — manual lock held for this session. Release it with /claude-caffeinate:off."
    ;;
  off)
    rm -f "$enabled"
    stop "$manual"
    stop "$hook"
    n=$(others)
    echo "Released — this session no longer keeps the Mac awake, and its hook automation is off."
    [ "$n" = "0" ] || echo "Note: $n other Claude session(s) still hold a lock — untouched, by design."
    ;;
  hooks-on)
    owner_pid > "$enabled"
    echo "Hook automation on for this session: awake while Claude works, asleep when it stops. Off again with /claude-caffeinate:off. (New sessions start with it off.)"
    ;;
  status)
    echo "session: $sid"
    if alive "$manual"; then echo "manual lock: ON (pid $(caff_pid "$manual"))"; else echo "manual lock: off"; fi
    if alive "$hook"; then echo "hook lock: ON (pid $(caff_pid "$hook"))"; else echo "hook lock: off"; fi
    [ -e "$enabled" ] && echo "hook automation: ON" || echo "hook automation: off (default — enable with /claude-caffeinate:hooks-on)"
    echo "other sessions holding a lock: $(others)"
    ;;
  _prompt)
    [ -e "$enabled" ] || exit 0
    start "$hook"
    ;;
  _stop)
    # Background work — subagents, workflows, background shells — keeps the Mac awake.
    # `Stop` fires when the main agent yields, which happens while that work still runs;
    # releasing there would sleep the Mac mid-task. A later `Stop` sees an empty list and
    # releases.
    bg=$(printf '%s' "$input" | jq -r '(.background_tasks // []) | length' 2>/dev/null || true)
    if [ -n "${bg:-}" ]; then
      [ "$bg" = "0" ] || exit 0
    elif printf '%s' "$input" | grep -q '"background_tasks"[[:space:]]*:[[:space:]]*\[[[:space:]]*{'; then
      exit 0  # no jq: `[` then `{` means at least one task
    fi
    stop "$hook"
    ;;
  _end)
    # The session is over: nothing it owns should outlive it, manual lock included.
    stop "$hook"
    stop "$manual"
    rm -f "$enabled"
    ;;
  *)
    echo "usage: $(basename "$0") <on|off|hooks-on|status|_prompt|_stop|_end>" >&2
    exit 2
    ;;
esac
exit 0
