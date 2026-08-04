#!/usr/bin/env bash
# E2E: bin/lib/tmux-guardian.sh (issue #218) - the out-of-cgroup liveness
# logger for the shared tmux server. Runs the real script against a private,
# disposable tmux server (WM_GUARDIAN_TMUX_ARGS="-L <socket>") so this never
# touches whatever the box's real default socket holds, and never races
# other test files' own tmux activity on that shared socket.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

GUARDIAN="$TEST_REPO/bin/lib/tmux-guardian.sh"
SOCK="wm-test-guardian-${WM_TEST_RUN_ID:-x}-$$"
export WM_GUARDIAN_TMUX_ARGS="-L $SOCK"
export WM_GUARDIAN_INTERVAL="0.2"
export WM_GUARDIAN_MAX_EVENT_LINES="40"

test_new_home
wm_on_exit "tmux -L '$SOCK' kill-server >/dev/null 2>&1"

wait_for_grep() {
  # Poll <file> for <pattern> (a `case`-style glob, not a regex - matching
  # this repo's assert_contains) instead of a fixed sleep, so this is not
  # flaky under load. Bounded at 5s (25 x 0.2s), comfortably above the
  # guardian's own 0.2s poll interval set above.
  _f="$1"; _pat="$2"
  _i=0
  while [ "$_i" -lt 25 ]; do
    [ -f "$_f" ] && case "$(cat "$_f" 2>/dev/null)" in *"$_pat"*) return 0 ;; esac
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

# --- 1. --status with nothing running -----------------------------------
_out="$("$GUARDIAN" --status)"
assert_contains "status: not running before anything starts" "$_out" "not running"

# --- 2. a private tmux server exists before the guardian ever starts -----
tmux -L "$SOCK" new-session -d -s sess1 -n win1 'sleep 300'
PID1="$(tmux -L "$SOCK" list-sessions -F '#{pid}')"
[ -n "$PID1" ] && ok "private tmux server started (pid $PID1)" || fail "private tmux server started"

"$GUARDIAN" --daemon &
GPID=$!
wm_track "$GPID"

wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "server-first-seen"
assert_contains "first-seen event recorded" "$(cat "$WINGMAN_HOME/tmux-guardian-events.log" 2>/dev/null)" "server pid $PID1"
assert_contains "first-seen event captured server ancestry" \
  "$(cat "$WINGMAN_HOME/tmux-guardian-events.log" 2>/dev/null)" "tmux: server"

_status="$("$GUARDIAN" --status)"
assert_contains "status: running after startup" "$_status" "running: pid"

# --- 3. idempotent: a second --daemon invocation never duplicates --------
"$GUARDIAN" --daemon &
DUP_PID=$!
wait "$DUP_PID"
_dup_rc=$?
assert_eq "second --daemon invocation exits 0 (no-op, already running)" "$_dup_rc" "0"
_pf_pid="$(cat "$WINGMAN_HOME/tmux-guardian.pid" 2>/dev/null)"
assert_eq "pidfile still names the original instance" "$_pf_pid" "$GPID"

# --- 4. killing the server is detected and logged -------------------------
tmux -L "$SOCK" kill-server
wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "server-died"
assert_contains "death event names the dead pid" \
  "$(cat "$WINGMAN_HOME/tmux-guardian-events.log" 2>/dev/null)" "tracked pid $PID1 no longer answers"

_status="$("$GUARDIAN" --status)"
assert_contains "status still reports the guardian itself running through the outage" "$_status" "running: pid"

# --- 5. a revival under a new pid is detected with fresh ancestry ---------
tmux -L "$SOCK" new-session -d -s sess2 -n win2 'sleep 300'
PID2="$(tmux -L "$SOCK" list-sessions -F '#{pid}')"
[ -n "$PID2" ] && [ "$PID2" != "$PID1" ] || fail "revival produced a genuinely new server pid"

wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "server-revived"
_events="$(cat "$WINGMAN_HOME/tmux-guardian-events.log" 2>/dev/null)"
assert_contains "revival event names the new pid" "$_events" "server pid $PID2 answered again"
assert_contains "revival event captured the new server's ancestry" "$_events" "ancestry of $PID2"

# --- 6. --stop shuts it down cleanly and clears the pidfile ---------------
"$GUARDIAN" --stop
_i=0
while [ "$_i" -lt 25 ] && kill -0 "$GPID" 2>/dev/null; do sleep 0.2; _i=$((_i + 1)); done
assert_false "guardian process exits after --stop" "kill -0 $GPID 2>/dev/null"
assert_false "--stop removes the pidfile" "[ -f '$WINGMAN_HOME/tmux-guardian.pid' ]"
_status="$("$GUARDIAN" --status)"
assert_contains "status: not running after --stop" "$_status" "not running"

tmux -L "$SOCK" kill-server >/dev/null 2>&1

# --- 7. the events log is bounded, never grows without limit -------------
# A single server-died/server-changed event embeds a full system-wide `ps`
# snapshot, so its real size depends on how busy the box running this suite
# happens to be - too variable to assert a tiny fixed line count against.
# Instead: measure one full death+revival cycle's actual contribution, run
# several more, and confirm the file stays close to that single-cycle size
# rather than growing linearly with the cycle count - which is what the
# truncation logic (checked at the top of every event write) exists to
# prevent. A real bound bug (truncation never firing) would show up here as
# roughly Nx growth over N cycles; the line stays flat.
rm -f "$WINGMAN_HOME/tmux-guardian-events.log" "$WINGMAN_HOME/tmux-guardian.pid" "$WINGMAN_HOME/tmux-guardian.heartbeat"
tmux -L "$SOCK" new-session -d -s sess3 -n win3 'sleep 300'
"$GUARDIAN" --daemon &
GPID2=$!
wm_track "$GPID2"
wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "server-first-seen"

one_death_revival_cycle() {
  # Waits on the specific pid transition this cycle produces, not the bare
  # "server-died"/"server-revived" strings - those stay present (until the
  # next truncation happens to scroll them out) from an earlier cycle, so a
  # bare substring check can return true immediately without ever having
  # observed THIS cycle's own event, breaking the timing this loop depends
  # on to actually accumulate write pressure across cycles.
  _oc_old_pid="$(tmux -L "$SOCK" list-sessions -F '#{pid}' 2>/dev/null | head -n1)"
  tmux -L "$SOCK" kill-server >/dev/null 2>&1
  wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "tracked pid $_oc_old_pid no longer answers"
  tmux -L "$SOCK" new-session -d -s "sess-loop-$1" -n w "sleep 300"
  _oc_new_pid="$(tmux -L "$SOCK" list-sessions -F '#{pid}' 2>/dev/null | head -n1)"
  wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "server pid $_oc_new_pid answered again"
}

one_death_revival_cycle 0
_base_lines="$(wc -l < "$WINGMAN_HOME/tmux-guardian-events.log" 2>/dev/null | tr -d ' ')"
_j=1
while [ "$_j" -lt 8 ]; do
  one_death_revival_cycle "$_j"
  _j=$((_j + 1))
done
_final_lines="$(wc -l < "$WINGMAN_HOME/tmux-guardian-events.log" 2>/dev/null | tr -d ' ')"
# 8 cycles with no truncation would be ~8x _base_lines; allow up to 3x as a
# generous margin (truncation only checks/trims once per write, so a little
# overshoot above _base_lines is expected and fine).
_cap=$((_base_lines * 3))
assert_true "events log stays roughly flat across repeated cycles, not linear (base ${_base_lines}, after 8 cycles ${_final_lines}, cap ${_cap})" \
  "[ '$_final_lines' -le '$_cap' ]"

"$GUARDIAN" --stop

test_summary
