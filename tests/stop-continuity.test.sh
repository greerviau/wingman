#!/usr/bin/env bash
# E2E: hooks/stop-continuity.sh - the asyncRewake-registered Stop hook that
# tokenlessly auto-arms bin/watch-fleet when crew are in flight with no live
# cycle, accounting for the previous cycle's exit itself (issue #185). Every
# test here proves the SCRIPT's own logic (claim/foreground/classify/exit-code
# mapping, the markers' own lifecycles) - never that a real Claude Code
# session actually receives a rewake when the script exits 2; that is what
# docs/analysis/2026-08-02-issue-185-*-step-0-*.md establishes empirically.
# See docs/plans/2026-08-02-issue-185-asyncrewake-autoarm-plan.md ("Testing
# strategy") for the full numbered-test rationale this file implements.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/stop-continuity.sh"
WF="$TEST_REPO/bin/watch-fleet"
GUARD="$TEST_REPO/hooks/stop-guard.sh"
export WM_WATCH_INTERVAL=1

# Default 20s, not 10s, for the same reason as wait_for_file's own default
# below: several `uv run --no-project` subprocess startups happen before the
# hook can even reach a claim attempt, and this is only an upper bound - a
# fast invocation returns long before the timeout regardless.
run_hook() { printf '{}' | wm_timeout "${1:-20}" bash "$HOOK"; }

# Default 100 tries (20s), not 50 (10s): every invocation this file waits on
# runs several `uv run --no-project` subprocesses (wm_state init, crew-list,
# the JSON encoders) before it can even reach its own claim attempt, and a
# loaded CI runner's own startup cost for each of those adds up - a 10s
# default was measurably too tight and flaked intermittently across several
# unrelated assertions in this file, not just one.
wait_for_file() {
  # wait_for_file <path> [tries (x0.2s)]
  _wf_tries="${2:-100}"; _wf_n=0
  while [ ! -s "$1" ] && [ "$_wf_n" -lt "$_wf_tries" ]; do sleep 0.2; _wf_n=$((_wf_n+1)); done
  [ -s "$1" ]
}

wait_for_gone() {
  _wfg_tries="${2:-100}"; _wfg_n=0
  while kill -0 "$1" 2>/dev/null && [ "$_wfg_n" -lt "$_wfg_tries" ]; do sleep 0.2; _wfg_n=$((_wfg_n+1)); done
  ! kill -0 "$1" 2>/dev/null
}

wait_for_file_gone() {
  # wait_for_file_gone <path> [tries (x0.2s)] - the inverse of wait_for_file.
  # bin/watch-fleet writes $PIDFILE, then a few lines later clears the three
  # markers - wait_for_file on $PIDFILE alone can return inside that narrow
  # gap, before the markers are actually cleared.
  _wfd_tries="${2:-100}"; _wfd_n=0
  while [ -f "$1" ] && [ "$_wfd_n" -lt "$_wfd_tries" ]; do sleep 0.2; _wfd_n=$((_wfd_n+1)); done
  [ ! -f "$1" ]
}

# A fresh isolated home, PLUS a real tmux session for it - bin/watch-fleet's
# own reconcile step flips any LIVE_STATES crew member with no matching live
# tmux window to 'died' the moment it completes even one poll iteration
# (issues #209/#217; it no longer skips just because the crew session itself
# is absent), so every test here that lets a real watch-fleet cycle run for
# more than an instant needs one, exactly like tests/watch-fleet-classify.test.sh.
new_home() {
  test_new_home
  tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
}

# add_crew_window <id> - the roster record AND its matching live tmux window
# together, so reconcile never has reason to flip it to 'died' mid-test.
add_crew_window() {
  wm_state crew-add --id "$1" --type developer --objective x --repo /tmp --window "wm-$1" --session-id "s-$1" >/dev/null
  tmux new-window -d -t "$WM_TMUX_SESSION" -n "wm-$1" 'sleep 600'
}

# --- (1) Ordinary fast path ---------------------------------------------------
new_home
out="$(run_hook)"; rc=$?
assert_eq "no crew in flight: exit 0" "$rc" "0"
assert_eq "no crew in flight: no stdout" "$out" ""
assert_false "no crew in flight: no claim attempted" "[ -f '$WINGMAN_HOME/watch.pid' ]"

new_home
add_crew_window fp1
wm_state crew-set --id fp1 --status working --summary busy >/dev/null
sleep 300 & lpid=$!; wm_track "$lpid"
echo "$lpid" > "$WINGMAN_HOME/watch.pid"
: > "$WINGMAN_HOME/watch.beat"
out="$(run_hook)"; rc=$?
assert_eq "a live cycle already exists: exit 0" "$rc" "0"
assert_eq "a live cycle already exists: no stdout" "$out" ""
kill "$lpid" 2>/dev/null

# --- (2) Crew in flight, no live cycle, nothing to account for ----------------
# -> a live armed cycle appears with no model turn, then fires and rewakes
# with compose_attention_reason's text (not fire()'s own raw arm instruction).
new_home
add_crew_window d1
wm_state crew-set --id d1 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook2.out" 2>"$WINGMAN_HOME/hook2.err" &
hookpid=$!; wm_track "$hookpid"
assert_true "a live armed cycle appears shortly, with no model turn" "wait_for_file '$WINGMAN_HOME/watch.pid'"
wm_state crew-set --id d1 --status review --summary "done" >/dev/null
assert_true "the hook exits within one poll interval of the fire-eligible flip" "wait_for_gone $hookpid 100"
wait "$hookpid" 2>/dev/null
out2="$(cat "$WINGMAN_HOME/hook2.out" 2>/dev/null)"
assert_contains "the rewake carries a block decision" "$out2" '"decision": "block"'
assert_contains "the rewake carries compose_attention_reason's roster-report text" "$out2" "surfaced via automatic fleet continuity"
assert_not_contains "the rewake does NOT carry fire()'s own raw arm instruction" "$out2" "arm one fresh watch-fleet cycle"
assert_contains "the rewake carries the do-not-arm sentence" "$out2" "do NOT arm a watch-fleet cycle"
unset WM_STOP_CONTINUITY_WINDOW

# --- (3) Exactly one live cycle under two continuity invocations racing ------
new_home
add_crew_window d2
wm_state crew-set --id d2 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=20
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook3a.out" 2>&1 &
h3a=$!; wm_track "$h3a"
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook3b.out" 2>&1 &
h3b=$!; wm_track "$h3b"
assert_true "exactly one cycle claims watch.pid" "wait_for_file '$WINGMAN_HOME/watch.pid'"
_claimant_pid="$(cat "$WINGMAN_HOME/watch.pid")"
assert_true "the claimed pid is a real, live watch-fleet process" "kill -0 $_claimant_pid"
# Stop both invocations directly (we've already proven the singleton held;
# no need to wait a full 20s window out).
kill -TERM "$h3a" "$h3b" 2>/dev/null
kill "$_claimant_pid" 2>/dev/null
wait "$h3a" 2>/dev/null; wait "$h3b" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW

# --- (4) A deliberate --stop is not auto-undone, and is silent ----------------
new_home
add_crew_window d3
wm_state crew-set --id d3 --status working --summary busy >/dev/null
"$WF" >"$WINGMAN_HOME/d3.log" 2>&1 &
d3pid=$!; wm_track "$d3pid"
assert_true "a cycle is live before stopping it" "wait_for_file '$WINGMAN_HOME/watch.pid'"
"$WF" --stop >/dev/null 2>&1
out4="$(run_hook)"; rc4=$?
assert_eq "a deliberate --stop is not auto-undone: exit 0" "$rc4" "0"
assert_eq "a deliberate --stop is silent (no stdout)" "$out4" ""
assert_true "the stop sanction marker exists" "[ -f '$WINGMAN_HOME/watch.stopped' ]"

# Sequence extension: a manual re-arm, SIGTERM'd directly, is classified and
# re-armed fresh on the next invocation - the sanction was cleared by the
# manual arm's own successful claim.
"$WF" >"$WINGMAN_HOME/d3b.log" 2>&1 &
d3b=$!; wm_track "$d3b"
assert_true "the manual re-arm claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
assert_true "the manual claim cleared the stop sanction marker" "wait_for_file_gone '$WINGMAN_HOME/watch.stopped'"
kill -TERM "$d3b" 2>/dev/null
assert_true "the SIGTERM'd cycle actually dies" "wait_for_gone $d3b"
export WM_STOP_CONTINUITY_WINDOW=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook4c.out" 2>&1 &
h4c=$!; wm_track "$h4c"
assert_true "the SIGTERM'd cycle is classified and a fresh cycle is armed, with no model turn" "wait_for_file '$WINGMAN_HOME/watch.pid'"
_after_pid="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
assert_true "the fresh cycle is a real, distinct live process" "[ -n '$_after_pid' ] && kill -0 $_after_pid"
kill -TERM "$h4c" 2>/dev/null
[ -n "$_after_pid" ] && kill "$_after_pid" 2>/dev/null
wait "$h4c" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW

# --- run-scoping: an empty stamp is honored by a session that has a run id ---
new_home
add_crew_window d4
wm_state crew-set --id d4 --status working --summary busy >/dev/null
printf '\n' > "$WINGMAN_HOME/watch.stopped"   # empty stamp: a run-id-less session's own write
export WINGMAN_RUN_ID=run-with-an-id
out5="$(run_hook)"; rc5=$?
assert_eq "an empty-stamped stop sanction is honored, not treated as foreign: exit 0" "$rc5" "0"
assert_eq "an empty-stamped stop sanction is silent" "$out5" ""
assert_false "an empty-stamped stop sanction is not claimed over" "[ -f '$WINGMAN_HOME/watch.pid' ]"
unset WINGMAN_RUN_ID

# --- (5) An arm that fails to come up: typed, actionable, distinct from a rollover
new_home
add_crew_window d5
wm_state crew-set --id d5 --status working --summary busy >/dev/null
mkdir "$WINGMAN_HOME/watch.pid.lock"
( sleep 300 ) & _lockholder=$!; wm_track "$_lockholder"
echo "$_lockholder" > "$WINGMAN_HOME/watch.pid.lock/owner"
export WM_CLAIM_HARD_STALE_AGE=3600
out6="$(run_hook 30)"; rc6=$?
assert_eq "a claim failure still lets the hook itself exit with a rewake" "$rc6" "2"
assert_contains "the rewake carries a block decision" "$out6" '"decision": "block"'
assert_contains "the rewake carries the claim-failure text" "$out6" "did not claim within the continuity window"
assert_not_contains "a claim failure is NOT the do-not-arm auto mode" "$out6" "do NOT arm a watch-fleet cycle"
assert_true "the claim-failure backoff marker is touched" "[ -f '$WINGMAN_HOME/stop-continuity.claimfail' ]"
unset WM_CLAIM_HARD_STALE_AGE
kill "$_lockholder" 2>/dev/null
rm -f "$WINGMAN_HOME/watch.pid.lock/owner"; rmdir "$WINGMAN_HOME/watch.pid.lock" 2>/dev/null

# Claim-failure backoff: immediately re-invoking (lock now clear) does NOT
# reclaim within the same window - it backs off silently.
out7="$(run_hook)"; rc7=$?
assert_eq "the claim-failure backoff suppresses an immediate retry: exit 0" "$rc7" "0"
assert_eq "the claim-failure backoff is silent" "$out7" ""

# --- (6) The self-owned, time-bounded in-flight marker guard ------------------
new_home
add_crew_window d6
wm_state crew-set --id d6 --status working --summary busy >/dev/null
sleep 300 & inpid=$!; wm_track "$inpid"
echo "$inpid" > "$WINGMAN_HOME/stop-continuity.pid"
out8="$(run_hook)"; rc8=$?
assert_eq "a live, fresh in-flight marker defers immediately: exit 0" "$rc8" "0"
assert_eq "a live in-flight marker: silent" "$out8" ""
assert_false "a live in-flight marker: no watch-fleet ever spawned" "[ -f '$WINGMAN_HOME/watch.pid' ]"
kill "$inpid" 2>/dev/null

# Stale-pid companion: a guaranteed-dead pid in the marker is overwritten.
( : ) & deadpid=$!; wait "$deadpid" 2>/dev/null
echo "$deadpid" > "$WINGMAN_HOME/stop-continuity.pid"
export WM_STOP_CONTINUITY_WINDOW=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook9.out" 2>&1 &
h9=$!; wm_track "$h9"
assert_true "a dead-pid marker does not block the claim" "wait_for_file '$WINGMAN_HOME/watch.pid'"
assert_true "the marker is overwritten with this invocation's own pid" "grep -q . '$WINGMAN_HOME/stop-continuity.pid'"
kill -TERM "$h9" 2>/dev/null
wait "$h9" 2>/dev/null
# Make sure this sub-test's own claim is fully torn down (not just the hook
# process) before the next sub-test starts a fresh claim against the same
# $WINGMAN_HOME/watch.pid path.
wait_for_file_gone "$WINGMAN_HOME/watch.pid" 100
unset WM_STOP_CONTINUITY_WINDOW

# Time-bound companion: a genuinely live pid, but aged past window+60, does
# not block - proving the bound is time-based, not liveness-only. The window
# itself is deliberately NOT set to the bare minimum here: only the marker's
# own age (90s) needs to exceed window+60 to prove the point, and a window
# too close to the claim sequence's own setup time (wm_state init, arg
# parsing, the claim-lock dance) risks the referee firing before the child
# even finishes claiming under load, which would make this flaky for a
# reason unrelated to what it's actually testing.
sleep 300 & livepid6=$!; wm_track "$livepid6"
echo "$livepid6" > "$WINGMAN_HOME/stop-continuity.pid"
export WM_STOP_CONTINUITY_WINDOW=10
wm_age_path "$WINGMAN_HOME/stop-continuity.pid" 90
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook10.out" 2>&1 &
h10=$!; wm_track "$h10"
assert_true "a stale-aged but still-alive in-flight pid does not block the claim" "wait_for_file '$WINGMAN_HOME/watch.pid' 100"
kill -TERM "$h10" 2>/dev/null
wait "$h10" 2>/dev/null
kill "$livepid6" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW

# --- (7) The self-bounded window rolls over cleanly across multiple rollovers -
new_home
add_crew_window d7
wm_state crew-set --id d7 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=2
N=3
rollovers=0
for i in 1 2 3; do
  outN="$(run_hook 15)"; rcN=$?
  case "$outN" in
    *'"decision": "block"'*) : ;;
    *) fail "rollover $i produced a block decision"; continue ;;
  esac
  case "$outN" in
    *"window rolled"*) rollovers=$((rollovers+1)) ;;
  esac
done
assert_eq "each of $N sequential invocations rolls over exactly once" "$rollovers" "$N"
assert_false "no invocation left more than one watch-fleet child running" "pgrep -f 'watch-fleet --owner ' >/dev/null 2>&1"
unset WM_STOP_CONTINUITY_WINDOW

# --- (8) A deterministically failing fleet: backoff + standdown markers ------
new_home
add_crew_window d8
wm_state crew-set --id d8 --status working --summary busy >/dev/null
mkdir "$WINGMAN_HOME/watch.pid.lock"
( sleep 300 ) & _bh=$!; wm_track "$_bh"
echo "$_bh" > "$WINGMAN_HOME/watch.pid.lock/owner"
export WM_CLAIM_HARD_STALE_AGE=3600
first="$(run_hook 30)"
assert_contains "first invocation reports the claim failure" "$first" "did not claim within the continuity window"
assert_true "first invocation touches the claim-failure marker" "[ -f '$WINGMAN_HOME/stop-continuity.claimfail' ]"
second="$(run_hook)"
assert_eq "second (immediate) invocation backs off silently, no further claim attempt" "$second" ""
wm_age_path "$WINGMAN_HOME/stop-continuity.claimfail" 500
third="$(run_hook 30)"
assert_contains "after the window elapses, a third invocation retries and reports again" "$third" "did not claim within the continuity window"
unset WM_CLAIM_HARD_STALE_AGE
kill "$_bh" 2>/dev/null
rm -f "$WINGMAN_HOME/watch.pid.lock/owner"; rmdir "$WINGMAN_HOME/watch.pid.lock" 2>/dev/null
rm -f "$WINGMAN_HOME/stop-continuity.claimfail"

# Direct regression: a child that claims and arms successfully, then dies to
# an external kill that bypasses its own INT/TERM trap (SIGKILL here, standing
# in for an OOM kill or an unhandled crash), must be routed through
# --classify's own spurious forensics - NOT misclassified as a claim failure
# just because $exitfile is absent and $child_rc is nonzero (both also true
# of a genuine claim failure). Misrouting this touches $claimfailfile and
# silently suppresses continuity for a full window even though the claim
# path was never actually contended - and the spurious-repeated budget could
# never trip via this path at all, since a single such death would silence
# every subsequent invocation before a second death ever got a chance to be
# classified.
new_home
add_crew_window d8e
wm_state crew-set --id d8e --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=30
assert_false "no spurious-count file exists yet" "[ -f '$WINGMAN_HOME/watch-spurious-count' ]"
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/sre.out" 2>&1 &
hpe=$!; wm_track "$hpe"
assert_true "the child claims and arms" "wait_for_file '$WINGMAN_HOME/watch.pid'"
assert_contains "the child genuinely armed (not merely attempted)" "$(cat "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)" "armed pid="
cpide="$(cat "$WINGMAN_HOME/watch.pid")"
kill -9 "$cpide" 2>/dev/null
assert_true "the hook notices the death and exits" "wait_for_gone $hpe 100"
wait "$hpe" 2>/dev/null
out_sre="$(cat "$WINGMAN_HOME/sre.out" 2>/dev/null)"
assert_false "a successful-arm-then-kill is NOT misrouted to the claim-failure branch" "[ -f '$WINGMAN_HOME/stop-continuity.claimfail' ]"
assert_not_contains "the rewake does not carry the claim-failure text" "$out_sre" "did not claim within the continuity window"
assert_eq "the death reached --classify's own forensics (the spurious count advanced to 1)" "$(cat "$WINGMAN_HOME/watch-spurious-count" 2>/dev/null)" "1"
unset WM_STOP_CONTINUITY_WINDOW

# Direct regression, companion to the one above: an external TERM landing on
# the HOOK ITSELF (not the child) - forwarded to a child that had already
# claimed and armed - must ALSO be routed through --classify, not
# misclassified as a claim failure. This is a DIFFERENT failure mode from
# the SIGKILL-to-child case above: here $child's own INT/TERM trap runs
# cleanly and removes $pidfile as part of an entirely ordinary exit, so
# neither $child_rc (the in-flight wait() is itself interrupted by the same
# signal, returning 143 regardless of $child's own real exit code) nor
# $pidfile's own content (cleanly cleared either way) can tell this apart
# from "never claimed" - only $term_forwarded (this hook's own local record
# of having received and forwarded the signal) and $armlog's own "armed
# pid=" confirmation can.
new_home
add_crew_window d8f
wm_state crew-set --id d8f --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=30
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/srf.out" 2>&1 &
hpf=$!; wm_track "$hpf"
assert_true "the child claims and arms" "wait_for_file '$WINGMAN_HOME/watch.pid'"
assert_contains "the child genuinely armed (not merely attempted)" "$(cat "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)" "armed pid="
kill -TERM "$hpf" 2>/dev/null
assert_true "the hook notices and exits" "wait_for_gone $hpf 100"
wait "$hpf" 2>/dev/null
out_srf="$(cat "$WINGMAN_HOME/srf.out" 2>/dev/null)"
assert_false "a TERM forwarded to an already-armed child is NOT misrouted to the claim-failure branch" "[ -f '$WINGMAN_HOME/stop-continuity.claimfail' ]"
assert_not_contains "the rewake (if any) does not carry the claim-failure text" "$out_srf" "did not claim within the continuity window"
unset WM_STOP_CONTINUITY_WINDOW

# spurious-repeated companion: repeated genuine external-kill deaths
# eventually trip the standdown. Bounded-loop, not a fixed round count: with
# the pidfile-comparison fix above, a death can be classified via TWO
# distinct paths (the SAME invocation's own post-window accounting after its
# child is killed, or the NEXT invocation's own pre-claim accounting
# re-examining the prior dead pidfile before ever attempting its own claim -
# see step 9 vs step 11 in the plan) - which one trips the budget on which
# exact round is not itself the invariant this test cares about; a
# pre-claim trip also means that specific invocation never claims at all, so
# this only kills a genuinely fresh claim when one actually appears.
new_home
add_crew_window d8b
wm_state crew-set --id d8b --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=30
_trip_out=""
_round=0
while [ ! -f "$WINGMAN_HOME/watch.suppressed" ] && [ "$_round" -lt 6 ]; do
  _round=$((_round+1))
  _prev_pid="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
  printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/sr$_round.out" 2>&1 &
  hp=$!; wm_track "$hp"
  _n=0
  while kill -0 "$hp" 2>/dev/null && [ "$_n" -lt 100 ]; do
    _cur_pid="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
    if [ -n "$_cur_pid" ] && [ "$_cur_pid" != "$_prev_pid" ]; then
      kill -9 "$_cur_pid" 2>/dev/null
      break
    fi
    sleep 0.1; _n=$((_n+1))
  done
  wait_for_gone "$hp" 100 >/dev/null 2>&1
  wait "$hp" 2>/dev/null
  _trip_out="$(cat "$WINGMAN_HOME/sr$_round.out" 2>/dev/null)"
done
assert_true "the standdown trips within a bounded number of genuine deaths" "[ -f '$WINGMAN_HOME/watch.suppressed' ]"
assert_contains "the tripping invocation rewakes via manual-remedy (no do-not-arm sentence)" "$_trip_out" "fleet supervision is not being maintained"
assert_not_contains "the tripping invocation is not auto mode" "$_trip_out" "do NOT arm a watch-fleet cycle"
assert_contains "the standdown marker carries the composed remedy text on line 2+" "$(tail -n +2 "$WINGMAN_HOME/watch.suppressed" 2>/dev/null)" "fleet supervision is not being maintained"
before_spur="$(cat "$WINGMAN_HOME/watch-spurious-count" 2>/dev/null)"
suppressed_out="$(run_hook)"
assert_eq "while suppressed, a subsequent invocation exits 0 with no rewake" "$suppressed_out" ""
after_spur="$(cat "$WINGMAN_HOME/watch-spurious-count" 2>/dev/null)"
assert_eq "while suppressed, --classify is never called (the spurious count is untouched)" "$after_spur" "$before_spur"
# A manual claim clears the standdown.
"$WF" >"$WINGMAN_HOME/d8b-manual.log" 2>&1 &
mc=$!; wm_track "$mc"
assert_true "the manual arm claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
assert_true "the standdown marker is cleared shortly after the claim (a few lines after PIDFILE in bin/watch-fleet)" "wait_for_file_gone '$WINGMAN_HOME/watch.suppressed'"
kill "$mc" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW

# stop-guard.sh nags with the standdown's own composed text while it holds -
# not the routine nudge - and treats a foreign-run stamp as inactive
# (cross-hook predicate-consistency, and the precondition-regression pair).
new_home
add_crew_window d8c
wm_state crew-set --id d8c --status working --summary busy >/dev/null
{
  printf '%s\n' "run-a"
  printf '%s\n' "the watcher for this session has died 3 times in a row (composed remedy text)"
} > "$WINGMAN_HOME/watch.suppressed"
export WINGMAN_RUN_ID=run-a
guard_out="$(printf '{"stop_hook_active": false}' | bash "$GUARD")"
assert_contains "stop-guard nags with the standdown's composed remedy text" "$guard_out" "composed remedy text"
assert_not_contains "stop-guard does NOT nag with the routine nudge while suppressed" "$guard_out" "Arm one by running 'bin/watch-fleet'"
export WINGMAN_RUN_ID=run-b
guard_out2="$(printf '{"stop_hook_active": false}' | bash "$GUARD")"
assert_eq "a foreign-run standdown reads as inactive to stop-guard (cross-hook predicate consistency)" "$guard_out2" ""
unset WINGMAN_RUN_ID
rm -f "$WINGMAN_HOME/watch.suppressed"

# Claim-failure recovery companion: a successful manual claim clears the
# claim-failure marker, not just ages it.
touch "$WINGMAN_HOME/stop-continuity.claimfail"
"$WF" >"$WINGMAN_HOME/d8d.log" 2>&1 &
mc2=$!; wm_track "$mc2"
assert_true "the manual claim succeeds" "wait_for_file '$WINGMAN_HOME/watch.pid'"
assert_true "the successful manual claim clears the claim-failure marker" "wait_for_file_gone '$WINGMAN_HOME/stop-continuity.claimfail'"
kill "$mc2" 2>/dev/null

# Precondition-regression companions (no crew in flight at all): the direct
# regression test for the round-6 dropped-precondition bug.
new_home
export WM_STOP_AUTOARM=0
out_pc1="$(printf '{"stop_hook_active": false}' | bash "$GUARD")"
assert_eq "WM_STOP_AUTOARM=0 with no crew in flight: stop-guard is silent" "$out_pc1" ""
unset WM_STOP_AUTOARM
export WINGMAN_RUN_ID=run-a
{
  printf '%s\n' "run-a"
  printf '%s\n' "composed remedy text"
} > "$WINGMAN_HOME/watch.suppressed"
out_pc2="$(printf '{"stop_hook_active": false}' | bash "$GUARD")"
assert_eq "an active standdown with no crew in flight: stop-guard is silent" "$out_pc2" ""
unset WINGMAN_RUN_ID
rm -f "$WINGMAN_HOME/watch.suppressed"

# --- (9) The referee's write-before-kill ordering + the wait-time snapshot ---
new_home
add_crew_window d9
wm_state crew-set --id d9 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=8
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook9r.out" 2>&1 &
h9r=$!; wm_track "$h9r"
assert_true "a cycle claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
sleep 3
wm_state crew-set --id d9 --status review --summary "done" >/dev/null
assert_true "the hook exits (via fire, not the referee's rollover)" "wait_for_gone $h9r 100"
wait "$h9r" 2>/dev/null
out9r="$(cat "$WINGMAN_HOME/hook9r.out" 2>/dev/null)"
assert_contains "a fire landing near the window's own expiry reports fire, never rolled" "$out9r" "surfaced via automatic fleet continuity"
assert_not_contains "never rolled when fire actually happened" "$out9r" "window rolled"
unset WM_STOP_CONTINUITY_WINDOW

new_home
add_crew_window d9b
wm_state crew-set --id d9b --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=5
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook9s.out" 2>&1 &
h9s=$!; wm_track "$h9s"
assert_true "a cycle claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
cpid9s="$(cat "$WINGMAN_HOME/watch.pid")"
# Kill the child directly, close to the window's own expiry (not "well
# before" it), so the referee's own sleep could plausibly still complete
# during the reap/cancellation gap if the snapshot fix were absent. A little
# more slack than the bare minimum, so ordinary system-load jitter in the
# claim/startup path doesn't turn this into a flaky test in either direction.
sleep 4.3
kill -9 "$cpid9s" 2>/dev/null
assert_true "the hook exits" "wait_for_gone $h9s 100"
wait "$h9s" 2>/dev/null
out9s="$(cat "$WINGMAN_HOME/hook9s.out" 2>/dev/null)"
assert_not_contains "an external kill near expiry is never misreported as rolled" "$out9s" "window rolled"
unset WM_STOP_CONTINUITY_WINDOW

# --- (10) unwaited, checked once per invocation, after the window closes ----
new_home
add_crew_window d10
wm_state crew-set --id d10 --status working --summary busy >/dev/null
wm_state ask-new --id ask-d10 --from "" --to d10 --question "covered?" >/dev/null
export WM_STOP_CONTINUITY_WINDOW=2
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook10u.out" 2>&1 &
h10u=$!; wm_track "$h10u"
assert_true "the claim is NOT blocked by an unattended ask" "wait_for_file '$WINGMAN_HOME/watch.pid'"
assert_true "the hook eventually rolls over and exits" "wait_for_gone $h10u 100"
wait "$h10u" 2>/dev/null
out10u="$(cat "$WINGMAN_HOME/hook10u.out" 2>/dev/null)"
assert_contains "the rollover body is present" "$out10u" "window rolled"
assert_contains "the unwaited-ask text is appended to the same rewake" "$out10u" "pending question with no live waiter"
unset WM_STOP_CONTINUITY_WINDOW

# No-duplicate-with-stop-guard companion: both hooks agree byte-for-byte.
guard_u_out="$(printf '{"stop_hook_active": false}' | bash "$GUARD")"
assert_contains "stop-guard independently reports the same unwaited ask" "$guard_u_out" "ask-d10"

# --- (11) Manual/model arm racing continuity ---------------------------------
new_home
add_crew_window d11
wm_state crew-set --id d11 --status working --summary busy >/dev/null
"$WF" >"$WINGMAN_HOME/d11-prior.log" 2>&1 &
priorpid=$!; wm_track "$priorpid"
assert_true "a prior cycle is live" "wait_for_file '$WINGMAN_HOME/watch.pid'"
"$WF" --stop >/dev/null 2>&1
export WM_STOP_CONTINUITY_WINDOW=30
"$WF" >"$WINGMAN_HOME/d11-manual.log" 2>&1 &
manualpid=$!; wm_track "$manualpid"
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook11.out" 2>&1 &
h11=$!; wm_track "$h11"
sleep 2
assert_true "exactly one cycle survives the race" "[ -s '$WINGMAN_HOME/watch.pid' ]"
assert_true "the stale --stop sanction was cleared by whichever side won the claim" "wait_for_file_gone '$WINGMAN_HOME/watch.stopped'"
kill -TERM "$h11" 2>/dev/null
_survivor="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
[ -n "$_survivor" ] && kill "$_survivor" 2>/dev/null
wait "$h11" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW

# --- (12) Orphan self-heal ----------------------------------------------------
new_home
add_crew_window d12
wm_state crew-set --id d12 --status working --summary busy >/dev/null
"$WF" >"$WINGMAN_HOME/d12.log" 2>&1 &
orphanpid=$!; wm_track "$orphanpid"
assert_true "a cycle is live" "wait_for_file '$WINGMAN_HOME/watch.pid'"
# Simulate the hook process itself being SIGKILL'd mid-window (untrappable) -
# the orphan (the still-live watch-fleet child) is left alive and unaccounted.
out12a="$(run_hook)"; rc12a=$?
assert_eq "the orphan is still alive: exit 0 (nothing to do)" "$rc12a" "0"
assert_eq "the orphan is still alive: silent" "$out12a" ""
assert_true "the orphan itself is untouched and still running" "kill -0 $orphanpid"
kill "$orphanpid" 2>/dev/null
assert_true "the orphan actually dies" "wait_for_gone $orphanpid"
# d12's own status never becomes fire-eligible in this test, so a fully
# correct invocation legitimately just keeps blocking (silently) once its
# fresh claim succeeds - "arms fresh" is proven by a NEW, distinct watch.pid
# appearing, not by waiting on a block/rewake decision that has nothing to
# report here.
export WM_STOP_CONTINUITY_WINDOW=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook12b.out" 2>&1 &
h12b=$!; wm_track "$h12b"
assert_true "once the orphan is gone, the next invocation classifies it and arms fresh" "wait_for_file '$WINGMAN_HOME/watch.pid'"
_fresh_pid="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
assert_true "the fresh cycle is a distinct, real live process" "[ -n '$_fresh_pid' ] && [ '$_fresh_pid' != '$orphanpid' ] && kill -0 $_fresh_pid"
kill -TERM "$h12b" 2>/dev/null
wait "$h12b" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW
[ -n "$_fresh_pid" ] && kill "$_fresh_pid" 2>/dev/null

# --- (13) Incident-runbook routing --------------------------------------------
# The summary text deliberately does NOT contain the word "stalled" - only
# the bracketed status field does - so this test can only pass via the
# anchored `[stalled]` match, not the unanchored substring match it replaced
# (see the free-text negative companion below for the direct regression on
# that anchoring specifically).
new_home
add_crew_window d13
wm_state crew-set --id d13 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook13.out" 2>&1 &
h13=$!; wm_track "$h13"
assert_true "a cycle claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
wm_state crew-set --id d13 --status stalled --summary "no pane output for a while" >/dev/null
assert_true "the hook exits on the stall" "wait_for_gone $h13 100"
wait "$h13" 2>/dev/null
out13="$(cat "$WINGMAN_HOME/hook13.out" 2>/dev/null)"
assert_contains "the routing sentence names 'stalled'" "$out13" "a 'stalled' reason"
assert_contains "the generic roster-report instruction is still present" "$out13" "surfaced via automatic fleet continuity"
assert_contains "the routing sentence points at the incident runbook" "$out13" "docs/runbooks/incidents.md"
unset WM_STOP_CONTINUITY_WINDOW

# Free-text negative companion: a member's own status NOTE contains the word
# "stalled" as ordinary free text, but its bracketed STATUS is something
# else (not `stalled`) - the routing sentence must NOT fire. An unanchored
# substring match against the "## New events" section (which the note text
# lives inside too) would false-positive here; the anchored `[stalled]`
# match correctly does not.
new_home
add_crew_window d13b
wm_state crew-set --id d13b --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook13b.out" 2>&1 &
h13b=$!; wm_track "$h13b"
assert_true "a cycle claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
wm_state crew-set --id d13b --status review --summary "checking why the watcher stalled earlier" >/dev/null
assert_true "the hook exits on the fire" "wait_for_gone $h13b 100"
wait "$h13b" 2>/dev/null
out13b="$(cat "$WINGMAN_HOME/hook13b.out" 2>/dev/null)"
assert_contains "the fire itself is still reported" "$out13b" "surfaced via automatic fleet continuity"
assert_not_contains "free text containing 'stalled' does NOT trigger the runbook routing" "$out13b" "docs/runbooks/incidents.md"
unset WM_STOP_CONTINUITY_WINDOW

test_summary
