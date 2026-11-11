#!/usr/bin/env bash
# Self-check. Run: bash scripts/test-caffeinate.sh
# Uses throwaway session ids, so it never touches a real session's locks.
set -u

command -v caffeinate >/dev/null 2>&1 || { echo "SKIP: not macOS (no caffeinate)"; exit 0; }

here=$(cd "$(dirname "$0")" && pwd)
cc="$here/caffeinate.sh"
dir="${TMPDIR:-/tmp}"
A="testA-$$"; B="testB-$$"
fails=0

# Commands read the session from the env, hooks from stdin JSON. CLAUDE_PID is
# unset so the test's caffeinate processes aren't tied to a real CLI pid.
run()  { env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID="$1" bash "$cc" "$2" >/dev/null; }
hook() { env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID=ignored-by-hooks bash "$cc" "$1" <<<"$2" >/dev/null; }
hook_nojq() { env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID=ignored PATH=/usr/bin:/bin bash "$cc" "$1" <<<"$2" >/dev/null; }
pf()   { printf '%s/claude-caffeinate-%s.%s.pid' "$dir" "$1" "$2"; }
en()   { printf '%s/claude-caffeinate-%s.hooks-enabled' "$dir" "$1"; }
alive(){ local p; p=$(cut -d' ' -f1 "$1" 2>/dev/null); [ -n "${p:-}" ] && kill -0 "$p" 2>/dev/null; }
check(){ if [ "$2" = "$3" ]; then echo "ok   — $1"; else echo "FAIL — $1 (want $3, got $2)"; fails=$((fails+1)); fi; }
cleanup(){ for s in "$A" "$B"; do for k in hook manual; do f=$(pf "$s" "$k"); [ -f "$f" ] && kill "$(cut -d' ' -f1 "$f")" 2>/dev/null; rm -f "$f"; done; rm -f "$(en "$s")"; done; }
trap cleanup EXIT

json() { printf '{"session_id":"%s","hook_event_name":"%s"%s}' "$1" "$2" "${3:-}"; }
prompt_A=$(json "$A" UserPromptSubmit); prompt_B=$(json "$B" UserPromptSubmit)
idle_A=$(json "$A" Stop ',"background_tasks":[]'); idle_B=$(json "$B" Stop ',"background_tasks":[]')
busy_A=$(json "$A" Stop ',"background_tasks":[{"id":"w1","type":"workflow","status":"running"}]')
end_A=$(json "$A" SessionEnd ',"reason":"other"'); end_B=$(json "$B" SessionEnd ',"reason":"other"')

# --- hooks are opt-in ---
hook _prompt "$prompt_A"
alive "$(pf "$A" hook)"; check "a fresh session's hooks do nothing" "$?" "1"
run "$A" hooks-on
hook _prompt "$prompt_A"
alive "$(pf "$A" hook)"; check "hooks-on lets the prompt hook caffeinate" "$?" "0"
first=$(cat "$(pf "$A" hook)")
hook _prompt "$prompt_A"
check "second prompt is idempotent" "$(cat "$(pf "$A" hook)")" "$first"

hook _stop "$busy_A"
alive "$(pf "$A" hook)"; check "Stop with a running workflow keeps it awake" "$?" "0"
hook_nojq _stop "$busy_A"
alive "$(pf "$A" hook)"; check "same, without jq on PATH" "$?" "0"
hook _stop "$idle_A"
alive "$(pf "$A" hook)"; check "Stop with nothing running releases it" "$?" "1"

run "$A" off
[ -e "$(en "$A")" ]; check "off turns the hook automation back off" "$?" "1"
hook _prompt "$prompt_A"
alive "$(pf "$A" hook)"; check "hooks are inert again after off" "$?" "1"

# --- manual lock is independent of the hooks ---
run "$A" on
alive "$(pf "$A" manual)"; check "on takes a manual lock with hooks off" "$?" "0"
mfirst=$(cat "$(pf "$A" manual)")
run "$A" on
check "on is idempotent" "$(cat "$(pf "$A" manual)")" "$mfirst"
hook _stop "$idle_A"
alive "$(pf "$A" manual)"; check "Stop cannot release the manual lock" "$?" "0"
run "$A" off
alive "$(pf "$A" manual)"; check "off releases the manual lock" "$?" "1"

# --- two concurrent sessions must not touch each other ---
run "$A" hooks-on; run "$B" hooks-on
hook _prompt "$prompt_A"; hook _prompt "$prompt_B"
[ "$(cat "$(pf "$A" hook)")" != "$(cat "$(pf "$B" hook)")" ]; check "each session gets its own caffeinate pid" "$?" "0"

hook _stop "$idle_A"
alive "$(pf "$B" hook)"; check "A's Stop leaves B awake" "$?" "0"

hook _prompt "$prompt_A"
run "$A" off
alive "$(pf "$B" hook)"; check "A's off leaves B awake" "$?" "0"
[ -e "$(en "$B")" ]; check "A's off leaves B's hook automation on" "$?" "0"
hook _prompt "$prompt_B"
alive "$(pf "$B" hook)"; check "B's hooks still work after A opted out" "$?" "0"

run "$B" on
run "$A" off
alive "$(pf "$B" manual)"; check "A's off leaves B's manual lock" "$?" "0"
hook _end "$end_A"
alive "$(pf "$B" manual)"; check "A's SessionEnd leaves B's manual lock" "$?" "0"
alive "$(pf "$B" hook)"; check "A's SessionEnd leaves B's hook lock" "$?" "0"

# --- SessionEnd owns nothing afterwards ---
hook _end "$end_B"
alive "$(pf "$B" manual)"; check "SessionEnd releases the manual lock" "$?" "1"
alive "$(pf "$B" hook)"; check "SessionEnd releases the hook lock" "$?" "1"
[ -e "$(en "$B")" ]; check "SessionEnd clears the opt-in" "$?" "1"

# --- status ---
run "$A" hooks-on; hook _prompt "$prompt_A"
out=$(env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID="$B" bash "$cc" status)
printf '%s' "$out" | grep -q "session: $B"; check "status names the session" "$?" "0"
printf '%s' "$out" | grep -q "hook automation: off"; check "status reports the opt-in state" "$?" "0"
printf '%s' "$out" | grep -q "other sessions holding a lock: 1"; check "status counts other sessions" "$?" "0"

# --- a lock knows its owner, and dies with it ---
hook _stop "$idle_A"
run "$A" on
args=$(ps -o args= -p "$(cut -d' ' -f1 "$(pf "$A" manual)")")
case "$args" in *" -w "*) rc=0;; *) rc=1;; esac
check "the lock is started with -w <owner>, so a crash releases it" "$rc" "0"
own=$(cut -d' ' -f2 -s "$(pf "$A" manual)")
[ -n "$own" ] && kill -0 "$own" 2>/dev/null; check "the owner pid is recorded and live" "$?" "0"
run "$A" off

# --- crashed session: an orphan lock is reaped by the next invocation ---
# A caffeinate whose owner died without a SessionEnd (kill -9, crash). It was not
# started with -w this owner, so only the reaper can clean it up.
sleep 300 & victim=$!
orphan=$( ( nohup caffeinate -di >/dev/null 2>&1 & echo $! ) )
echo "$orphan $victim" > "$(pf "$B" hook)"
kill "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID="$A" bash "$cc" status >/dev/null
kill -0 "$orphan" 2>/dev/null; check "an orphaned caffeinate is killed" "$?" "1"
[ -e "$(pf "$B" hook)" ]; check "…and its pidfile removed" "$?" "1"

# --- an opt-in flag cannot outlive its session either ---
sleep 300 & victim=$!
echo "$victim" > "$(en "$B")"
kill "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID="$A" bash "$cc" status >/dev/null
[ -e "$(en "$B")" ]; check "a dead session's opt-in flag is cleared" "$?" "1"

# --- stale pidfile pruning ---
echo 999999 > "$(pf "$A" hook)"
env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID="$A" bash "$cc" status >/dev/null
[ -e "$(pf "$A" hook)" ]; check "status prunes a dead pidfile" "$?" "1"

# --- off-all: in a private TMPDIR, so real sessions' locks are never touched ---
iso=$(mktemp -d)
irun() { env -u CLAUDE_PID TMPDIR="$iso" CLAUDE_CODE_SESSION_ID="$1" bash "$cc" "$2" >/dev/null; }
ihook() { env -u CLAUDE_PID TMPDIR="$iso" bash "$cc" "$1" <<<"$2" >/dev/null; }
irun "$A" hooks-on; ihook _prompt "$prompt_A"; irun "$B" on
ipids=$(cut -d' ' -f1 "$iso"/claude-caffeinate-*.pid)
irun "$A" off-all
rc=0; for p in $ipids; do kill -0 "$p" 2>/dev/null && rc=1; done
check "off-all kills every session's caffeinate" "$rc" "0"
ls "$iso"/claude-caffeinate-*.pid >/dev/null 2>&1; check "off-all leaves no pidfile behind" "$?" "1"
[ -e "$iso/claude-caffeinate-$A.hooks-enabled" ]; check "off-all keeps the hook opt-in" "$?" "0"
ihook _prompt "$prompt_A"
alive "$iso/claude-caffeinate-$A.hook.pid"; check "hooks still work after off-all" "$?" "0"
irun "$A" off
rm -rf "$iso"

[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
exit "$fails"
