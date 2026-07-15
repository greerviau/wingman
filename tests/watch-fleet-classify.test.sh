#!/usr/bin/env bash
# E2E: bin/watch-fleet --classify - the exit-record writes at each of watch-fleet's
# own exit points, the classifier that turns a just-completed cycle's exit into
# one of six outcomes (healthy/fire/remote-control-dropped/stopped/spurious/
# spurious-repeated), the write-priority order between racing writers, the loud
# claim-time drop log, and the pure consecutive-count failure budget with its
# three-rule writer invariant and reset-on-trip. See docs/plans/2026-07-13-
# wingman-skills-for-robust-operation.md for the full design this proves.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
export WM_WATCH_INTERVAL=1
# Every backgrounded watch-fleet here is registered via wm_track; lib.sh's
# shared trap reaps it on exit - no per-file trap needed or allowed.

# A pid guaranteed dead: spawn a trivial subshell and wait for it to exit.
dead_pid() {
  ( : ) &
  _dp=$!
  wait "$_dp" 2>/dev/null
  echo "$_dp"
}

# --- argument-parser acceptance: --classify never hits "unknown arg" ---------
test_new_home
out="$(wm_timeout 10 "$WF" --classify 2>&1)"
assert_not_contains "bare --classify is accepted by the argument parser" "$out" "unknown arg"
test_new_home
out="$(wm_timeout 10 "$WF" --classify --owner leadx 2>&1)"
assert_not_contains "--classify --owner <id> is accepted by the argument parser" "$out" "unknown arg"

# --- dispatch-point boundary: --classify against a live cycle never claims ---
test_new_home
wm_state crew-add --id d1 --type developer --objective x --repo /tmp --window wm-d1 --session-id s1 >/dev/null
wm_state crew-set --id d1 --status working --summary "in progress" >/dev/null
"$WF" >"$WINGMAN_HOME/bg.log" 2>&1 &
bgpid=$!
wm_track "$bgpid"
sleep 2
before_pid="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
out="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "classify against a live cycle (no record) reports healthy" "$out" "healthy"
assert_false "classify never creates the claim lock" "[ -d '$WINGMAN_HOME/watch.pid.lock' ]"
assert_eq "classify never mutates the pidfile" "$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)" "$before_pid"
assert_true "the live cycle is still running (classify never entered the blocking loop)" "kill -0 $bgpid"
kill "$bgpid" 2>/dev/null

# --- exhaustive hint vocabulary (no cycle live in every case) -----------------
test_new_home
out="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "no pidfile at all: clean-exit-or-sigterm" "$out" "spurious 1 clean-exit-or-sigterm"

test_new_home
dp="$(dead_pid)"
echo "$dp" > "$WINGMAN_HOME/watch.pid"
out="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "pidfile naming a dead pid: sigkill-suspected" "$out" "spurious 1 sigkill-suspected"

test_new_home
sleep 300 &
livepid=$!
wm_track "$livepid"
echo "$livepid" > "$WINGMAN_HOME/watch.pid"
# No BEATFILE at all: beat_age() reads as 999999 (definitely stale), so
# cycle_live is false despite the pid being alive.
out="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "pidfile naming a live pid, stale beacon: hung-or-stale-pidfile" "$out" "spurious 1 hung-or-stale-pidfile"
kill "$livepid" 2>/dev/null

test_new_home
mkdir "$WINGMAN_HOME/watch.pid.lock"
out="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "a leaked claim lock, no cycle live: stale-claim-lock" "$out" "spurious 1 stale-claim-lock"

# --- r7 ordering regression: cycle_live wins over a coexisting leaked lock ----
# A stale, unrelated lock (left over from some earlier, already-resolved
# incident) coexisting with a genuinely live, healthy cycle must never be
# misclassified as that cycle's own failure.
test_new_home
"$WF" >"$WINGMAN_HOME/live.log" 2>&1 &
livepid2=$!
wm_track "$livepid2"
sleep 2
mkdir "$WINGMAN_HOME/watch.pid.lock"
out="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "cycle_live is checked, and wins, before the lock check is ever reached" "$out" "healthy"
kill "$livepid2" 2>/dev/null
rmdir "$WINGMAN_HOME/watch.pid.lock" 2>/dev/null

# --- exit-record consumption: fire ---------------------------------------------
test_new_home
wm_state crew-add --id f1 --type analyst --objective x --repo /tmp --window wm-f1 --session-id sf1 >/dev/null
wm_state crew-set --id f1 --status done --summary "finished x" >/dev/null
fout="$(wm_timeout 45 "$WF" 2>/dev/null)"
assert_contains "the arm fires on the done member" "$fout" "done: f1"
assert_eq "fire() writes 'fire' to the exit-record" "$(cat "$WINGMAN_HOME/watch-exit" 2>/dev/null)" "fire"
cout="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "classify reads and reports the fire record" "$cout" "fire"
assert_false "the record is consumed (deleted) after being read" "[ -f '$WINGMAN_HOME/watch-exit' ]"
cout2="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_true "a second consecutive classify does not replay the consumed record" "[ \"$cout2\" != fire ]"

# --- exit-record consumption: remote-control-dropped ---------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm_self_pane 'printf "Remote Control disconnected - Transport closed: this connection is no longer usable\n"; sleep 600'
printf '%s:wm_self_pane\n' "$WM_TMUX_SESSION" > "$WINGMAN_HOME/self-pane"
rout="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "the self-pane check fires" "$rout" "remote-control-dropped: wingman"
assert_eq "the self-pane exit writes its own record" "$(cat "$WINGMAN_HOME/watch-exit" 2>/dev/null)" "remote-control-dropped"
rcout="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "classify reads and reports the remote-control-dropped record" "$rcout" "remote-control-dropped"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- write priority (r5 finding 4): a racing healthy write never clobbers fire -
# Simulate the exact interleaving: cycle A already wrote its `fire` record and
# has not yet reached its own `rm -f "$PIDFILE"`; redundant arm B evaluates the
# singleton guard in that window and must skip its own `healthy` write.
test_new_home
sleep 300 &
livepid3=$!
wm_track "$livepid3"
echo "$livepid3" > "$WINGMAN_HOME/watch.pid"
: > "$WINGMAN_HOME/watch.beat"
printf 'fire\n' > "$WINGMAN_HOME/watch-exit"
out="$(wm_timeout 10 "$WF" 2>&1)"
assert_contains "the redundant arm reports healthy (does not start a rival)" "$out" "healthy"
assert_eq "the fire record is never clobbered by the racing healthy write" "$(cat "$WINGMAN_HOME/watch-exit" 2>/dev/null)" "fire"
kill "$livepid3" 2>/dev/null

# --- loud claim-time drop (r5 finding 5) ---------------------------------------
test_new_home
wm_state crew-add --id ld1 --type developer --objective y --repo /tmp --window wm-ld1 --session-id sld1 >/dev/null
wm_state crew-set --id ld1 --status done --summary "finished y" >/dev/null
wm_timeout 45 "$WF" >/dev/null 2>&1
assert_eq "the fire record is left pending (never classified)" "$(cat "$WINGMAN_HOME/watch-exit" 2>/dev/null)" "fire"
"$WF" >"$WINGMAN_HOME/ld.log" 2>&1 &
ldpid=$!
wm_track "$ldpid"
sleep 2
assert_true "the fresh arm claims and blocks" "kill -0 $ldpid"
assert_contains "the dropped record is logged before being cleared" "$(cat "$WINGMAN_HOME/watch-spurious.log" 2>/dev/null)" "dropped-wake"
assert_contains "the dropped-wake line carries the record's contents" "$(cat "$WINGMAN_HOME/watch-spurious.log" 2>/dev/null)" "fire"
assert_false "the stale record is cleared at claim time" "[ -f '$WINGMAN_HOME/watch-exit' ]"
kill "$ldpid" 2>/dev/null

# --- the failure budget: timing-independence -----------------------------------
# Three genuinely spurious classifications in a row, with an arbitrary delay
# between them, must still trip on the third - the direct regression test for
# every wall-clock-coupled design (r3/r4/r5-draft) five review rounds rejected.
test_new_home
out1="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "first spurious classification: count 1" "$out1" "spurious 1 clean-exit-or-sigterm"
sleep 2
out2="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "second spurious classification: count 2" "$out2" "spurious 2 clean-exit-or-sigterm"
sleep 3
out3="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "third spurious classification trips the budget regardless of elapsed time" "$out3" "spurious-repeated 3 clean-exit-or-sigterm"

# --- the failure budget: the plan's own headline repro (never claims) ----------
# A claim-lock with a live owner refuses every arm attempt across all three
# rounds - the failure budget must count this as three genuine failures, not
# fall through an "unknown lifetime, don't count" gap. (Before issue #74's fix,
# ANY leaked lock - dead owner or not - reproduced this; after the fix, only a
# lock this design deliberately refuses to reclaim still does, so this uses a
# live owner rather than a bare/dead one.)
test_new_home
mkdir "$WINGMAN_HOME/watch.pid.lock"
( sleep 300 ) & _budget_holder=$!
wm_track "$_budget_holder"
echo "$_budget_holder" > "$WINGMAN_HOME/watch.pid.lock/owner"
wm_timeout 15 "$WF" >/dev/null 2>&1
lout1="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "arm 1 (owner alive, refused) classifies as spurious 1" "$lout1" "spurious 1 stale-claim-lock"
wm_timeout 15 "$WF" >/dev/null 2>&1
lout2="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "arm 2 (still refused) classifies as spurious 2" "$lout2" "spurious 2 stale-claim-lock"
wm_timeout 15 "$WF" >/dev/null 2>&1
lout3="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "arm 3 (still refused) trips spurious-repeated" "$lout3" "spurious-repeated 3 stale-claim-lock"
kill "$_budget_holder" 2>/dev/null
rmdir "$WINGMAN_HOME/watch.pid.lock" 2>/dev/null

# --- the failure budget: a non-spurious outcome resets the count ---------------
test_new_home
out1="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "spurious 1" "$out1" "spurious 1 clean-exit-or-sigterm"
out2="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "spurious 2" "$out2" "spurious 2 clean-exit-or-sigterm"
sleep 300 &
livepid4=$!
wm_track "$livepid4"
echo "$livepid4" > "$WINGMAN_HOME/watch.pid"
: > "$WINGMAN_HOME/watch.beat"
out3="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "a healthy classification resets the count" "$out3" "healthy"
kill "$livepid4" 2>/dev/null
rm -f "$WINGMAN_HOME/watch.pid" "$WINGMAN_HOME/watch.beat"
out4="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "the next spurious after a reset starts fresh at 1, not 3" "$out4" "spurious 1 clean-exit-or-sigterm"

# --- the failure budget: reset-on-trip ------------------------------------------
test_new_home
wm_timeout 10 "$WF" --classify >/dev/null 2>&1
wm_timeout 10 "$WF" --classify >/dev/null 2>&1
trip="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "the third classification trips spurious-repeated" "$trip" "spurious-repeated 3 clean-exit-or-sigterm"
after_trip="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "the trip consumes the budget - the very next spurious is plain, not repeated" "$after_trip" "spurious 1 clean-exit-or-sigterm"

# --- the failure budget: a successful claim never alters the count file --------
# The most direct regression test for the "Files touched" instruction that once
# contradicted the design section: an arm that wins its claim and is then killed
# must leave watch-spurious-count exactly as classify last left it.
test_new_home
wm_timeout 10 "$WF" --classify >/dev/null 2>&1
wm_timeout 10 "$WF" --classify >/dev/null 2>&1
before_count="$(cat "$WINGMAN_HOME/watch-spurious-count" 2>/dev/null)"
assert_eq "count is 2 before the claim" "$before_count" "2"
"$WF" >"$WINGMAN_HOME/e5.log" 2>&1 &
e5pid=$!
wm_track "$e5pid"
_w=0
while [ ! -s "$WINGMAN_HOME/watch.pid" ] && [ "$_w" -lt 30 ]; do sleep 0.2; _w=$((_w+1)); done
assert_true "the fresh arm actually claimed" "[ -s '$WINGMAN_HOME/watch.pid' ]"
kill -9 "$e5pid" 2>/dev/null
after_count="$(cat "$WINGMAN_HOME/watch-spurious-count" 2>/dev/null)"
assert_eq "a successful claim leaves the count file untouched" "$after_count" "$before_count"

# --- missing count file reads as 0 under set -u --------------------------------
test_new_home
assert_false "no count file exists yet" "[ -f '$WINGMAN_HOME/watch-spurious-count' ]"
out="$(wm_timeout 10 "$WF" --classify 2>&1)"
assert_eq "the first classification against a missing count file starts at 1, not an unbound-variable crash" "$out" "spurious 1 clean-exit-or-sigterm"

# --- WM_SPURIOUS_BUDGET_COUNT is env-overridable -------------------------------
test_new_home
out1="$(wm_timeout 10 env WM_SPURIOUS_BUDGET_COUNT=2 "$WF" --classify 2>/dev/null)"
assert_eq "with a budget of 2, the first is plain spurious" "$out1" "spurious 1 clean-exit-or-sigterm"
out2="$(wm_timeout 10 env WM_SPURIOUS_BUDGET_COUNT=2 "$WF" --classify 2>/dev/null)"
assert_eq "with a budget of 2, the second trips spurious-repeated" "$out2" "spurious-repeated 2 clean-exit-or-sigterm"

# --- issue #107: a deliberate --stop is distinct from an accidental death ------

# Regression proof: an accidental death (kill -9, standing in for a kill the
# syntactic guard missed, or an OOM kill) still classifies as spurious,
# unchanged by this fix - this is the "unexpectedly dead" half of the
# required distinction.
test_new_home
"$WF" >"$WINGMAN_HOME/kill9.log" 2>&1 &
killpid=$!
wm_track "$killpid"
sleep 2
assert_true "the cycle is live before the kill" "kill -0 $killpid"
kill -9 "$killpid" 2>/dev/null
_w=0
while kill -0 "$killpid" 2>/dev/null && [ "$_w" -lt 30 ]; do sleep 0.2; _w=$((_w+1)); done
out="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "an accidental kill -9 still classifies as spurious sigkill-suspected" "$out" "spurious 1 sigkill-suspected"

# The new behavior: a deliberate --stop classifies as stopped, never spurious.
test_new_home
"$WF" >"$WINGMAN_HOME/stop.log" 2>&1 &
stoppid=$!
wm_track "$stoppid"
sleep 2
assert_true "the cycle is live before --stop" "kill -0 $stoppid"
"$WF" --stop >/dev/null 2>&1
out="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "a deliberate --stop classifies as stopped, not spurious" "$out" "stopped"
count="$(cat "$WINGMAN_HOME/watch-spurious-count" 2>/dev/null)"
[ -n "$count" ] || count=0
assert_eq "a deliberate stop never contributes to the failure budget" "$count" "0"
_w=0
while kill -0 "$stoppid" 2>/dev/null && [ "$_w" -lt 30 ]; do sleep 0.2; _w=$((_w+1)); done
assert_false "the process is no longer running after --stop" "kill -0 $stoppid 2>/dev/null"

# --stop with nothing running still records stopped cleanly (the marker write
# on the "nothing to stop" branch doesn't regress and isn't misread).
test_new_home
"$WF" --stop >/dev/null 2>&1
out="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "--stop with nothing running still records stopped cleanly" "$out" "stopped"

# The distinction holds for an owner-scoped (lead) cycle too, not just the bare
# wingman one - the regression proof for gap 2's fix.
test_new_home
"$WF" --owner leadx >"$WINGMAN_HOME/stop-owner.log" 2>&1 &
ownerpid=$!
wm_track "$ownerpid"
sleep 2
assert_true "the owner-scoped cycle is live before --stop" "kill -0 $ownerpid"
"$WF" --owner leadx --stop >/dev/null 2>&1
oout="$(wm_timeout 10 "$WF" --classify --owner leadx 2>/dev/null)"
assert_eq "an owner-scoped --stop classifies as stopped too" "$oout" "stopped"
ocount="$(cat "$WINGMAN_HOME/watch-spurious-count-leadx" 2>/dev/null)"
[ -n "$ocount" ] || ocount=0
assert_eq "the owner-scoped failure budget is untouched by a deliberate stop" "$ocount" "0"
_w=0
while kill -0 "$ownerpid" 2>/dev/null && [ "$_w" -lt 30 ]; do sleep 0.2; _w=$((_w+1)); done
assert_false "the owner-scoped process is no longer running after --stop" "kill -0 $ownerpid 2>/dev/null"

test_summary
