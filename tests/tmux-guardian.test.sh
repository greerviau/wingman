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

# Poll <file> for <pattern> (a `case`-style glob, not a regex - matching
# this repo's assert_contains) instead of a fixed sleep, so this is not
# flaky under load. Bounded at 5s (25 x 0.2s), comfortably above the
# guardian's own 0.2s poll interval set above. Every call site checks the
# return value and fails explicitly on timeout (review round 2, must-fix A
# item d): a silently-ignored timeout previously let the test charge ahead
# into a downstream assert_contains whose failure message named the wrong
# problem (content that never arrived) instead of the real one (the wait
# itself never resolved).
wait_for_grep() {
  _f="$1"; _pat="$2"
  _i=0
  while [ "$_i" -lt 25 ]; do
    [ -f "$_f" ] && case "$(cat "$_f" 2>/dev/null)" in *"$_pat"*) return 0 ;; esac
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

# Poll until <socket> genuinely stops answering - not just "we issued
# kill-server". tmux's own server teardown is not synchronous with the
# command returning, and creating a new session on the same socket while
# the old server is still mid-teardown can itself fail silently ("server
# exited unexpectedly", no session created) rather than cleanly starting a
# fresh one. Reproduced independently in review: ~60% of immediate
# kill-then-new-session pairs on an idle box hit this. Bounded at 5s; a
# socket that never dies is a genuine test-environment failure to surface,
# not something to paper over by proceeding anyway (must-fix A item a).
wait_for_socket_dead() {
  _sk="$1"
  _i=0
  while [ "$_i" -lt 25 ]; do
    tmux -L "$_sk" list-sessions >/dev/null 2>&1 || return 0
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

# Create a new session on <socket>, retrying with a short backoff until
# list-sessions actually reports a pid - the same kill-then-recreate race
# wait_for_socket_dead guards on the OTHER side: even once the old server
# is confirmed dead, a new-session issued while the socket path itself is
# still settling can fail silently. Prints the new pid on success, prints
# nothing and returns 1 on exhaustion (must-fix A item b: retry until
# non-empty, rather than trusting the first attempt).
#
# <suffix>, not a full session name: tests/run.sh's own static invariant
# check requires every variable used as a new-session target to be
# traceable back to $WM_TMUX_SESSION, even though this file's sessions live
# on a private -L socket that check doesn't otherwise reason about - genuine
# defense in depth (a $SOCK isolation bug would still leave a run-tagged,
# sweepable name behind on the default socket), not just satisfying the
# check's own text-matching.
new_session_retry() {
  _ns_sock="$1"
  _ns_sess="${WM_TMUX_SESSION}-$2"
  _ns_win="$3"; shift 3
  _ns_i=0
  while [ "$_ns_i" -lt 25 ]; do
    tmux -L "$_ns_sock" new-session -d -s "$_ns_sess" -n "$_ns_win" "$@" 2>/dev/null
    _ns_pid="$(tmux -L "$_ns_sock" list-sessions -F '#{pid}' 2>/dev/null | head -n1)"
    if [ -n "$_ns_pid" ]; then
      printf '%s' "$_ns_pid"
      return 0
    fi
    sleep 0.1
    _ns_i=$((_ns_i + 1))
  done
  return 1
}

# Kill <socket>'s server (if any) and wait for it to actually be gone -
# the paired half of new_session_retry, used at every "start fresh" point
# in this file so a leftover server from an earlier section is never a
# hidden source of the same race.
kill_server_and_wait() {
  tmux -L "$1" kill-server >/dev/null 2>&1
  wait_for_socket_dead "$1" || fail "socket $1 never stopped answering after kill-server"
}

# --- 1. --status with nothing running -----------------------------------
_out="$("$GUARDIAN" --status)"
assert_contains "status: not running before anything starts" "$_out" "not running"

# --- 2. a private tmux server exists before the guardian ever starts -----
PID1="$(new_session_retry "$SOCK" sess1 win1 'sleep 300')" \
  || fail "private tmux server started"
[ -n "$PID1" ] && ok "private tmux server started (pid $PID1)" || fail "private tmux server started"

"$GUARDIAN" --daemon &
GPID=$!
wm_track "$GPID"

wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "server-first-seen" \
  || fail "server-first-seen never appeared"
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
kill_server_and_wait "$SOCK"
wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "server-died" \
  || fail "server-died never appeared"
assert_contains "death event names the dead pid" \
  "$(cat "$WINGMAN_HOME/tmux-guardian-events.log" 2>/dev/null)" "tracked pid $PID1 no longer answers"

_status="$("$GUARDIAN" --status)"
assert_contains "status still reports the guardian itself running through the outage" "$_status" "running: pid"

# --- 5. a revival under a new pid is detected with fresh ancestry ---------
PID2="$(new_session_retry "$SOCK" sess2 win2 'sleep 300')" \
  || fail "revival produced a genuinely new server pid"
[ -n "$PID2" ] && [ "$PID2" != "$PID1" ] || fail "revival produced a genuinely new server pid"

wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "server-revived" \
  || fail "server-revived never appeared"
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

kill_server_and_wait "$SOCK"

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
PID3="$(new_session_retry "$SOCK" sess3 win3 'sleep 300')" || fail "sess3 started"
"$GUARDIAN" --daemon &
GPID2=$!
wm_track "$GPID2"
wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "server-first-seen" \
  || fail "server-first-seen never appeared for sess3"

one_death_revival_cycle() {
  # Waits on the specific pid transition this cycle produces, not the bare
  # "server-died"/"server-revived" strings - those stay present (until the
  # next truncation happens to scroll them out) from an earlier cycle, so a
  # bare substring check can return true immediately without ever having
  # observed THIS cycle's own event, breaking the timing this loop depends
  # on to actually accumulate write pressure across cycles.
  _oc_old_pid="$(tmux -L "$SOCK" list-sessions -F '#{pid}' 2>/dev/null | head -n1)"
  kill_server_and_wait "$SOCK"
  wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "tracked pid $_oc_old_pid no longer answers" \
    || fail "cycle $1: death of $_oc_old_pid never observed"
  _oc_new_pid="$(new_session_retry "$SOCK" "sess-loop-$1" w 'sleep 300')" \
    || fail "cycle $1: recreate never produced a pid"
  wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "server pid $_oc_new_pid answered again" \
    || fail "cycle $1: revival of $_oc_new_pid never observed"
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

# --- 8 (MUST-FIX 2, review round 1): a same-window turnover (kill+recreate
# faster than one poll interval - the exact shape the 2026-08-04 incident's
# own 17ms-later panes demonstrated is possible) must not destroy the dead
# server's own last-known-good heartbeat by overwriting it with the NEW
# server's state before the server-changed event ever reads it. Uses its own
# guardian instance with a much longer interval so the kill+recreate below
# reliably lands inside a single poll window rather than racing it.
wait_for_heartbeat_pid() {
  # Poll the heartbeat FILE (rewritten on every single poll, unlike the
  # events log's one-shot server-first-seen) until it names <pid> as
  # server_pid - confirming the guardian has DEFINITELY completed a poll
  # cycle observing <pid>, rather than assuming any fixed amount of wall
  # time was enough for its background job to even get scheduled. A CI
  # runner sharing far fewer cores across many concurrent test files can
  # delay that first poll well past what a quiet dev box would ever see;
  # this makes the precondition self-verifying instead of timing-shaped.
  # Bounded generously (15s) since this only needs to happen once per
  # guardian instance, not once per poll.
  _f="$1"; _pid="$2"
  _i=0
  while [ "$_i" -lt 75 ]; do
    [ -f "$_f" ] && grep -q "^server_pid: $_pid\$" "$_f" 2>/dev/null && return 0
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

rm -f "$WINGMAN_HOME/tmux-guardian-events.log" "$WINGMAN_HOME/tmux-guardian.pid" "$WINGMAN_HOME/tmux-guardian.heartbeat"
kill_server_and_wait "$SOCK"
FT_PID1="$(new_session_retry "$SOCK" fastturn1 w 'sleep 300')" || fail "fastturn1 started"
# A longer interval than the rest of this file's 0.2s: what matters here is
# not speed but headroom - the kill+recreate below must land inside this
# guardian's OWN sleep between polls, and the precondition wait above
# already absorbs however long the first poll itself took to happen.
WM_GUARDIAN_INTERVAL=5 "$GUARDIAN" --daemon &
FTGPID=$!
wm_track "$FTGPID"
wait_for_heartbeat_pid "$WINGMAN_HOME/tmux-guardian.heartbeat" "$FT_PID1" \
  && ok "guardian confirmed observing the first server before the turnover" \
  || fail "guardian confirmed observing the first server before the turnover"

# Deliberately back-to-back (no wait_for_socket_dead here - that is the
# scenario this case exists to exercise), but still retried until it
# actually produces a distinct pid rather than trusting the first attempt
# (must-fix A item b): the same kill/recreate race applies here too, it is
# just that this specific case *wants* the two to land in the same poll
# window rather than avoiding it.
tmux -L "$SOCK" kill-server >/dev/null 2>&1
FT_PID2=""
_ft_i=0
while [ "$_ft_i" -lt 25 ]; do
  tmux -L "$SOCK" new-session -d -s "${WM_TMUX_SESSION}-fastturn2" -n w 'sleep 300' 2>/dev/null
  FT_PID2="$(tmux -L "$SOCK" list-sessions -F '#{pid}' 2>/dev/null | head -n1)"
  [ -n "$FT_PID2" ] && [ "$FT_PID2" != "$FT_PID1" ] && break
  sleep 0.1
  _ft_i=$((_ft_i + 1))
done
[ -n "$FT_PID2" ] && [ "$FT_PID2" != "$FT_PID1" ] || fail "fastturn2 never produced a distinct pid"

wait_for_grep "$WINGMAN_HOME/tmux-guardian-events.log" "pid $FT_PID1 -> $FT_PID2" \
  || fail "server-changed for $FT_PID1 -> $FT_PID2 never appeared"
_ft_events="$(cat "$WINGMAN_HOME/tmux-guardian-events.log" 2>/dev/null)"
assert_contains "a same-window turnover fires server-changed" "$_ft_events" "server-changed"
assert_contains "the logged heartbeat is the OLD (dead) server's" "$_ft_events" "server_pid: $FT_PID1"
assert_not_contains "the logged heartbeat is NOT already the new server's" "$_ft_events" "server_pid: $FT_PID2"

"$GUARDIAN" --stop
kill_server_and_wait "$SOCK"

# --- 9 (MUST-FIX 1, review round 1): the guardian must survive being
# launched exactly the way bin/wingman launches it - scope-wrapped AND
# setsid'd, from INSIDE the very tmux pane whose server later dies - not
# from this test script's own, unrelated shell the way every assertion
# above does. Without setsid, systemd-run's cgroup isolation is real but
# irrelevant: the process is still a member of the pane's terminal session,
# and when that pane's tmux server dies, the kernel sends SIGHUP to the
# session's foreground process group. A guardian trapping only TERM/INT
# dies silently, writing nothing - the exact failure this whole file was
# blind to before this case existed, since launching it from the test
# script's own shell never put it in the pane's session in the first place.
#
# (Review round 2, must-fix B.) The launch command is not hand-copied here:
# it is extracted, verbatim, from bin/wingman's own source text. A hand-
# transcribed duplicate would keep passing even if bin/wingman's real line
# regressed (e.g. setsid silently dropped again) - confirmed as a real gap
# by the reviewer, who removed setsid from bin/wingman and left this test
# untouched: the suite stayed 100% green. Extracting the real line means
# any such regression makes the grep below find nothing, which fails loudly
# instead of testing a line bin/wingman no longer actually runs.
#
# Skipped, not silently passed, if systemd-run/the user D-Bus isn't
# available here - the same condition bin/wingman itself checks.
if command -v systemd-run >/dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -e "${XDG_RUNTIME_DIR}/systemd/private" ]; then
  _wingman_launch_line="$(grep -F 'systemd-run --user --scope --collect --quiet -- setsid "$WM_LIB/tmux-guardian.sh" --daemon' "$TEST_REPO/bin/wingman")"
  if [ -z "$_wingman_launch_line" ]; then
    fail "bin/wingman's guardian launch line was not found verbatim (it may have regressed, or this test's expected text is stale)"
  else
    ok "bin/wingman's guardian launch line still contains setsid"

    SOCK2="wm-test-guardian-launch-${WM_TEST_RUN_ID:-x}-$$"
    wm_on_exit "tmux -L '$SOCK2' kill-server >/dev/null 2>&1"
    LAUNCHHOME="$(wm_mktemp_dir)/wm-launch"
    mkdir -p "$LAUNCHHOME"

    # No trailing command: the pane's foreground process must be an actual
    # shell reading a REPL loop, not a bare `sleep 300` (used elsewhere in
    # this file as a cheap keep-alive) - send-keys below only does anything
    # if something in the pane is reading and executing its own stdin.
    LAUNCHSESS="${WM_TMUX_SESSION}-launchsess"
    tmux -L "$SOCK2" new-session -d -s "$LAUNCHSESS" -n w
    LAUNCH_PID1="$(tmux -L "$SOCK2" list-sessions -F '#{pid}' 2>/dev/null | head -n1)"
    [ -n "$LAUNCH_PID1" ] || fail "launchsess started"

    # $WM_LIB is bin/wingman's own name for bin/lib/ (set by common.sh,
    # which a bare pane never sources) - exported here as its own statement,
    # NOT as a same-line "VAR=val cmd" prefix, so the EXTRACTED line's own
    # "$WM_LIB/tmux-guardian.sh" reference actually resolves to the real
    # script when the pane's shell evaluates it. A prefix assignment
    # (`WM_LIB='...' systemd-run ... "$WM_LIB/..."`) does NOT work here -
    # argument expansion happens in the pane's shell before that prefix
    # takes effect for the child, so "$WM_LIB" would still resolve to
    # whatever it was beforehand (empty), not the just-assigned value.
    # Confirmed directly: that shape produces `setsid: failed to execute
    # /tmux-guardian.sh: No such file or directory` - the exact silent
    # failure this test saw before this fix (WM_LIB must be a real,
    # already-exported shell variable, exactly as it is inside bin/wingman
    # itself by the time its own line runs).
    tmux -L "$SOCK2" send-keys -t "$LAUNCHSESS" \
      "export WINGMAN_HOME='$LAUNCHHOME'; export WM_GUARDIAN_TMUX_ARGS='-L $SOCK2'; export WM_GUARDIAN_INTERVAL=0.2; export WM_LIB='$TEST_REPO/bin/lib'; $_wingman_launch_line" Enter

    wait_for_grep "$LAUNCHHOME/tmux-guardian-events.log" "server-first-seen" \
      || fail "the pane-launched guardian never recorded server-first-seen"
    GUARDIAN_PID1="$(cat "$LAUNCHHOME/tmux-guardian.pid" 2>/dev/null)"
    [ -n "$GUARDIAN_PID1" ] && ok "the pane-launched guardian recorded a pid" || fail "the pane-launched guardian recorded a pid"

    tmux -L "$SOCK2" kill-server >/dev/null 2>&1
    _i=0
    while [ "$_i" -lt 25 ]; do
      [ -f "$LAUNCHHOME/tmux-guardian-events.log" ] && grep -q "server-died" "$LAUNCHHOME/tmux-guardian-events.log" 2>/dev/null && break
      sleep 0.2
      _i=$((_i + 1))
    done

    assert_true "the guardian process itself survives its own pane's tmux server dying (SIGHUP without setsid)" \
      "kill -0 $GUARDIAN_PID1 2>/dev/null"
    assert_contains "a server-died event was written by the still-live guardian" \
      "$(cat "$LAUNCHHOME/tmux-guardian-events.log" 2>/dev/null)" "tracked pid $LAUNCH_PID1 no longer answers"

    kill -TERM "$GUARDIAN_PID1" 2>/dev/null
  fi
else
  echo "  SKIP - launch-topology regression (systemd-run/user D-Bus unavailable here)"
fi

test_summary
