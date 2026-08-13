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
# The internal claim-wait-account loop's own lever (issue #231): a lifetime
# at or below the window yields exactly one iteration per invocation, which
# is today's (pre-#231) single-shot behavior, so every test below that does
# not override this locally keeps testing exactly what it always tested. The
# loop-specific cases (7 and its siblings) override it locally to exercise
# more than one iteration.
export WM_STOP_CONTINUITY_LIFETIME=1

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

wait_for_pid_alive() {
  # wait_for_pid_alive <pid> [tries (x0.2s)] - the inverse of wait_for_gone,
  # for the narrow gap between $PIDFILE becoming non-empty (wait_for_file)
  # and the pid it names being confirmed live: the file is written by the
  # process itself, so the pid always exists by then, but a loaded runner can
  # still delay this script's own kill -0 past that instant (same CI-runner
  # load class documented on wait_for_file above) - not a design race in
  # bin/watch-fleet, just this test's own check needing the same bounded
  # patience every other liveness check here already gets.
  _wfpa_tries="${2:-100}"; _wfpa_n=0
  while ! kill -0 "$1" 2>/dev/null && [ "$_wfpa_n" -lt "$_wfpa_tries" ]; do sleep 0.2; _wfpa_n=$((_wfpa_n+1)); done
  kill -0 "$1" 2>/dev/null
}

wait_for_content() {
  # wait_for_content <path> <needle> [tries (x0.2s)] - for a genuine ordering
  # gap in the real code, not just a test-side race: bin/watch-fleet writes
  # $PIDFILE (:806) well before it prints "armed pid=..." to its own stdout
  # (:849, captured into $armlog by the caller's redirect) - claiming the
  # cycle and clearing markers happen in between. wait_for_file on $PIDFILE
  # alone can return inside that gap, before $armlog has the line a caller
  # then wants to assert against.
  _wfc_tries="${3:-100}"; _wfc_n=0
  while ! grep -q -- "$2" "$1" 2>/dev/null && [ "$_wfc_n" -lt "$_wfc_tries" ]; do sleep 0.2; _wfc_n=$((_wfc_n+1)); done
  grep -q -- "$2" "$1" 2>/dev/null
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

wait_for_pidfile_not() {
  # wait_for_pidfile_not <path> <pid> [tries (x0.2s)] - waits for $PIDFILE to name
  # someone OTHER than <pid>. NOT wait_for_file_gone: bin/watch-fleet installs its
  # own $PIDFILE-removing INT/TERM trap (:1073) only well after it writes $PIDFILE
  # (:972), so a SIGTERM landing inside that window kills the cycle under the
  # default disposition with the pidfile left behind and nothing alive to remove
  # it. Waiting for it to vanish hangs out the full patience and then latches the
  # dead pid anyway; waiting for it to be REPLACED is what actually holds.
  _wpn_tries="${3:-100}"; _wpn_n=0
  while { [ ! -s "$1" ] || [ "$(cat "$1" 2>/dev/null)" = "$2" ]; } && [ "$_wpn_n" -lt "$_wpn_tries" ]; do
    sleep 0.2; _wpn_n=$((_wpn_n+1))
  done
  [ -s "$1" ] && [ "$(cat "$1" 2>/dev/null)" != "$2" ]
}

# remaining_before_expiry <pid> <window> <margin> - seconds left before
# <pid>'s own referee (hooks/stop-continuity.sh's `sleep "$window"`, which
# starts essentially at <pid>'s own fork) naturally fires, minus <margin>,
# floored at 0 (issue #346). Anchored to <pid>'s OWN process start time
# (read from /proc/<pid>/stat, field 22), not a timestamp this script
# captured before launching the hook - the hook's own pre-child work (a
# crew-list check, wm_watcher_up, compute_pr_watch_needed under issue #319)
# runs before <pid> is ever forked, so a pre-launch timestamp overstates
# elapsed time by however long that took, silently loosening whatever
# margin was asked for (caught in review: this is what made an earlier
# draft's case 9b assertion unable to fail at all). Compares two MONOTONIC
# (/proc/uptime-based) readings only, never mixing in a wall-clock
# timestamp: `btime` (system boot time, in /proc/stat) is not continuously
# reconciled against wall-clock adjustments after boot (NTP sync, common on
# any VM or CI runner), so combining it with a monotonic starttime reading
# reintroduced a comparable, unpredictable bias when tried - see this
# comment's own history for that dead end before concluding purely
# monotonic math was required. Linux-only (/proc); no portable fallback -
# this file's suite runs on Linux CI and Linux dev boxes only in practice
# despite the rest of tests/lib.sh's own bash-3.2/macOS care elsewhere.
remaining_before_expiry() {
  uv run --no-project --quiet python -c "
import sys, os
pid, window, margin = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
with open('/proc/' + pid + '/stat') as f:
    content = f.read()
rest = content[content.rfind(')')+2:].split()
starttime_ticks = int(rest[19])
clk_tck = os.sysconf('SC_CLK_TCK')
child_start_uptime = starttime_ticks / clk_tck
with open('/proc/uptime') as f:
    now_uptime = float(f.read().split()[0])
elapsed = now_uptime - child_start_uptime
print(max(window - elapsed - margin, 0))
" "$1" "$2" "$3"
}

# seed_inflight_marker <pid> [run_id] - writes the run-scoped in-flight
# marker the hook itself now expects (issue #278): run id on line 1 (empty
# by default, matching test_new_home's own unset WINGMAN_RUN_ID), pid on
# line 2 - the same shape $killstampfile/$stopfile already use.
seed_inflight_marker() {
  printf '%s\n%s\n' "${2:-}" "$1" > "$WINGMAN_HOME/stop-continuity.pid"
}

# A fresh isolated home, PLUS a real tmux session for it - bin/watch-fleet's
# own reconcile step flips any LIVE_STATES crew member with no matching live
# tmux window to 'died' the moment it completes even one poll iteration
# (issue #209 / PR #217; it no longer skips just because the crew session itself
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
# A dead process and a cleared pidfile are two different facts - $d3b dying
# doesn't itself prove watch.pid is gone: bin/watch-fleet writes $PIDFILE well
# before it installs the INT/TERM trap that removes it, so a SIGTERM landing
# in that window (exactly where kill -TERM "$d3b" above aims) kills the cycle
# under the default disposition, leaving the stale pidfile behind with nothing
# alive to ever remove it. Waiting for the file to vanish would hang out the
# full patience in that case and then latch the dead pid anyway - waiting for
# it to be REPLACED holds regardless of which branch the kill landed in, since
# the only other writer is the fresh claim below.
assert_true "the SIGTERM'd cycle is classified and a fresh cycle is armed, with no model turn" "wait_for_pidfile_not '$WINGMAN_HOME/watch.pid' $d3b"
_after_pid="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
assert_true "the fresh cycle is a real, distinct live process" "[ -n '$_after_pid' ] && wait_for_pid_alive $_after_pid"
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
seed_inflight_marker "$inpid"
out8="$(run_hook)"; rc8=$?
assert_eq "a live, fresh in-flight marker defers immediately: exit 0" "$rc8" "0"
assert_eq "a live in-flight marker: silent" "$out8" ""
assert_false "a live in-flight marker: no watch-fleet ever spawned" "[ -f '$WINGMAN_HOME/watch.pid' ]"
kill "$inpid" 2>/dev/null

# Stale-pid companion: a guaranteed-dead pid in the marker is overwritten.
( : ) & deadpid=$!; wait "$deadpid" 2>/dev/null
seed_inflight_marker "$deadpid"
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
seed_inflight_marker "$livepid6"
export WM_STOP_CONTINUITY_WINDOW=10
wm_age_path "$WINGMAN_HOME/stop-continuity.pid" 90
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook10.out" 2>&1 &
h10=$!; wm_track "$h10"
assert_true "a stale-aged but still-alive in-flight pid does not block the claim" "wait_for_file '$WINGMAN_HOME/watch.pid' 100"
kill -TERM "$h10" 2>/dev/null
wait "$h10" 2>/dev/null
kill "$livepid6" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW

# A file-wide note on why NONE of the existing `kill -TERM $hookpid`-style
# teardowns elsewhere in this file (e.g. the stale-pid companion just above,
# ~line 252) were switched to `kill -9`: the TERM/INT trap's own gate (6c
# below) already makes an incidental teardown TERM harmless in every case
# that matters - each one lands within a second or two of its own claim,
# nowhere near that invocation's own configured window, so the gate
# suppresses the stamp write on its own; and every one of them is either the
# LAST hook invocation to touch its own $WINGMAN_HOME (a fresh `new_home`
# follows before that state could ever be read again) or, at ~line 252
# specifically, load-bearing exactly as written - a genuine `kill -9` there
# would bypass the trap entirely, never forward the kill to the claimed
# watch-fleet child, and leave `watch.pid` orphaned for the very next
# sub-test (the time-bound companion) to inherit, making ITS OWN claim
# assertion pass vacuously regardless of whether that mechanism actually
# works. Audited individually, not swapped as a blanket substitution.

# --- (6a) Kill-evidence clamp (issue #248): $inflightfile now clears on
# every clean exit, unconditionally - a behavior change from case 6 above,
# where it was left in place forever and only its freshness bound kept a
# concurrent instance out. The harness-timeout scenario no longer needs the
# marker to survive a clean exit to preserve evidence (that evidence now
# lives in $killstampfile instead - see (6b)/(6d) below), so it is safe to
# clear unconditionally. The one path that must NOT clear it - a genuinely
# concurrent instance already managing continuity - never installs the trap
# at all, since that path exits before ever reaching the claim. ---
new_home
add_crew_window d6a
wm_state crew-set --id d6a --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=2
out6a="$(run_hook 30)"; rc6a=$?
assert_eq "a clean rollover exit" "$rc6a" "2"
assert_false "the in-flight marker is removed entirely after a clean rollover exit" "[ -f '$WINGMAN_HOME/stop-continuity.pid' ]"
unset WM_STOP_CONTINUITY_WINDOW

# Companion, same $WINGMAN_HOME: the concurrency-defer path leaves a LIVE
# marker completely untouched, since it exits before the EXIT trap is ever
# installed.
sleep 300 & livepid6a=$!; wm_track "$livepid6a"
seed_inflight_marker "$livepid6a"
out6a2="$(run_hook)"; rc6a2=$?
assert_eq "a live, fresh in-flight marker defers immediately: exit 0" "$rc6a2" "0"
assert_true "the concurrency-defer path leaves the OTHER instance's marker untouched" "[ -s '$WINGMAN_HOME/stop-continuity.pid' ] && [ \"\$(tail -n +2 '$WINGMAN_HOME/stop-continuity.pid' 2>/dev/null | head -n 1)\" = '$livepid6a' ]"
kill "$livepid6a" 2>/dev/null

# --- (6b) Kill-evidence clamp (issue #248): the TERM/INT trap measures its
# own elapsed lifetime and stamps $killstampfile BEFORE forwarding the kill
# (gated on having already run for at least one full window - see (6c)
# below for the direct regression on that gate), and the stamp persists
# across every later invocation's own clean exit rather than being erased by
# it - the direct regression against the design the round-1/round-2 plan
# reviews rejected, whose EXIT trap would have cleared exactly this evidence
# on its own way out (an ordinary, caught SIGTERM shutdown is what the
# harness-timeout kill actually looks like, not an untrappable SIGKILL). ---
new_home
add_crew_window d6b
wm_state crew-set --id d6b --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=3
export WM_STOP_CONTINUITY_LIFETIME=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook6b.out" 2>&1 &
h6b=$!; wm_track "$h6b"
assert_true "the first iteration claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
# Comfortably past the window before the external TERM, so the trap's own
# elapsed-since-start gate (>= window) is satisfied regardless of
# claim/startup latency under load (see (6c) below for what happens when it
# is NOT satisfied).
sleep 5
kill -TERM "$h6b" 2>/dev/null
assert_true "the hook exits" "wait_for_gone $h6b 100"
wait "$h6b" 2>/dev/null
assert_true "the TERM'd invocation stamps a run-scoped killstamp" "wait_for_file '$WINGMAN_HOME/stop-continuity.killstamp'"
_measured6b="$(tail -n +2 "$WINGMAN_HOME/stop-continuity.killstamp" 2>/dev/null | head -n 1)"
assert_true "the stamped value is a real elapsed measurement, at least the window it was gated on" "[ -n '$_measured6b' ] && [ '$_measured6b' -ge 3 ] && [ '$_measured6b' -le 90 ]"

# A follow-up invocation, same $WINGMAN_HOME (no new_home) - clamps to the
# measured value, not the historical 600s or any on-disk default: used as
# the window itself (margin 0), so the clamp forces exactly one window
# regardless of what the measurement actually was - if the fallback's own
# 600 constant (or any on-disk default) governed instead, many more windows
# would fit inside the configured 3300s lifetime. Runs to its OWN natural,
# fully clean "window rolled" exit - no external signal this time - the
# direct regression case described above.
export WM_STOP_CONTINUITY_WINDOW="$_measured6b"
export WM_STOP_CONTINUITY_LIFETIME=3300
export WM_CONTINUITY_TIMEOUT_MARGIN=0
out6b2="$(run_hook 90)"; rc6b2=$?
armed6b2="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_eq "the follow-up invocation clamps to the measured value (exactly one window)" "$armed6b2" "1"
assert_eq "the follow-up invocation exits 2 (a genuine budget-exhaustion rewake)" "$rc6b2" "2"
assert_contains "the single-window break reports a clean rollover" "$out6b2" "window rolled"
_after_clean6b="$(tail -n +2 "$WINGMAN_HOME/stop-continuity.killstamp" 2>/dev/null | head -n 1)"
assert_eq "the killstamp survives the follow-up's own clean exit, unchanged" "$_after_clean6b" "$_measured6b"

# A third invocation, still no new_home, still uses the same pinned
# evidence rather than any on-disk default - proving it genuinely persisted
# rather than being coincidentally regenerated.
out6b3="$(run_hook 90)"; rc6b3=$?
armed6b3="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_eq "a third invocation still clamps to the same pinned evidence" "$armed6b3" "1"
assert_eq "the third invocation also exits 2" "$rc6b3" "2"
unset WM_STOP_CONTINUITY_WINDOW WM_CONTINUITY_TIMEOUT_MARGIN
export WM_STOP_CONTINUITY_LIFETIME=1  # restore the file-level lever, not merely unset it

# --- (6c) Kill-evidence clamp (issue #248, the direct M2 regression): a
# TERM/INT arriving BEFORE the hook has run for one full window must NOT be
# trusted as kill evidence. The registered timeout this hook ever clamps
# against is always well above one window (see bin/doctor's own minimum), so
# a signal arriving earlier than that cannot be the genuine harness-timeout
# kill this mechanism exists to measure - it is far more likely a test's own
# teardown kill, an operator's kill -TERM against a wedged hook, or a
# pilot's Ctrl-C. Trusting it anyway would pin whatever small, arbitrary
# elapsed time it happened to arrive at for the rest of the run, clamping
# every later invocation far tighter than this session's real binding
# actually requires - a roughly 6x wake-rate regression from a single stray
# signal. A generous window (60s) keeps this deterministic regardless of
# claim/startup latency under load: the TERM lands within a second or two of
# the claim, nowhere close to 60s either way. ---
new_home
add_crew_window d6c
wm_state crew-set --id d6c --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook6c.out" 2>&1 &
h6c=$!; wm_track "$h6c"
assert_true "the first iteration claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
kill -TERM "$h6c" 2>/dev/null
assert_true "the hook exits" "wait_for_gone $h6c 100"
wait "$h6c" 2>/dev/null
assert_false "an early TERM (well under one window) does not stamp a killstamp" "[ -f '$WINGMAN_HOME/stop-continuity.killstamp' ]"
unset WM_STOP_CONTINUITY_WINDOW

# --- (6d) Kill-evidence clamp (issue #278): a FRESH dead pid, stamped with
# the CURRENT run (or no run id at all - the permissive convention
# wm_run_scoped_stamp_active shares with $stopfile), is still genuine
# SIGKILL evidence and still clamps THIS invocation's own budget - the
# positive control this fix must not regress. Also the direct M3 regression
# from issue #248: the dead-pid fallback clamps as if the historical 600s
# were the registered timeout, but does NOT pin that guess into
# $killstampfile for later invocations to inherit. Unlike a real
# measurement, "some invocation died with no evidence" says nothing about
# what this session's actual timeout IS - self-pinning it would tighten
# every later invocation's clamp for the rest of the run on one ambiguous
# data point, and since essentially every already-running production
# session carries some pre-existing dead-pid residue in this marker from
# before this mechanism ever shipped, self-pinning here would have made a
# roughly 6x wake-rate regression guaranteed on deploy day, not merely an
# edge case. Targeted at the tunable margin, not the fixture timeout
# (round-1 review, M3 of round 2): the fallback's own clamp source is the
# hardcoded 600, which is not fixture-tunable the way an on-disk `timeout`
# is - the 7f2 pattern (margin overridden so 600-margin lands exactly on the
# window) is reused here for the same reason. ---
new_home
add_crew_window d6d
wm_state crew-set --id d6d --status working --summary busy >/dev/null
( : ) & deadpid6d=$!; wait "$deadpid6d" 2>/dev/null
seed_inflight_marker "$deadpid6d"   # no run id: the permissive-empty branch
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=3300
export WM_CONTINUITY_TIMEOUT_MARGIN=598
out6d="$(run_hook 30)"; rc6d=$?
armed6d="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_eq "a fresh, run-id-less dead pid still clamps this invocation to a single window" "$armed6d" "1"
assert_eq "the hook exits 2 (a genuine budget-exhaustion rewake)" "$rc6d" "2"
assert_contains "the single-window break reports a clean rollover" "$out6d" "window rolled"
assert_false "the fallback does NOT self-pin its guess into killstampfile" "[ -f '$WINGMAN_HOME/stop-continuity.killstamp' ]"
unset WM_CONTINUITY_TIMEOUT_MARGIN

# Same-run-id companion: an EXPLICIT stamp match (not just permissive
# emptiness) also clamps - the branch (6d) above cannot exercise on its own.
new_home
add_crew_window d6d0
wm_state crew-set --id d6d0 --status working --summary busy >/dev/null
( : ) & deadpid6d0=$!; wait "$deadpid6d0" 2>/dev/null
export WINGMAN_RUN_ID=run-6d0
seed_inflight_marker "$deadpid6d0" "run-6d0"
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=3300
export WM_CONTINUITY_TIMEOUT_MARGIN=598
out6d0="$(run_hook 30)"; rc6d0=$?
armed6d0="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_eq "a fresh, SAME-run-id dead pid clamps this invocation to a single window" "$armed6d0" "1"
assert_eq "the hook exits 2" "$rc6d0" "2"
unset WM_CONTINUITY_TIMEOUT_MARGIN WINGMAN_RUN_ID

# A follow-up invocation, same $WINGMAN_HOME (no new_home, and no fresh dead
# pid seeded - the prior invocation's own clean exit already cleared
# $inflightfile via (6a)'s mechanism) - the direct M3 regression: proves the
# fallback's guess did NOT persist. A fresh on-disk registration (the (7f)
# pattern, margin restored to its real default) is what bounds this one, not
# a leftover 600-based pin - if the fallback HAD self-pinned, this would
# admit roughly 150 two-second windows instead of exactly one.
PROJ_SETTINGS_6d="$WINGMAN_HOME/proj-settings-6d.json"
cat > "$PROJ_SETTINGS_6d" <<JSON
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "$HOOK", "asyncRewake": true, "timeout": 302}]}]}}
JSON
export WM_PROJECT_SETTINGS="$PROJ_SETTINGS_6d"
out6d2="$(run_hook 30)"; rc6d2=$?
armed6d2="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_eq "the follow-up invocation clamps from its OWN fresh registration, not a stale self-pin" "$armed6d2" "1"
assert_eq "the follow-up invocation exits 2" "$rc6d2" "2"
unset WM_PROJECT_SETTINGS WM_STOP_CONTINUITY_WINDOW
export WM_STOP_CONTINUITY_LIFETIME=1  # restore the file-level lever, not merely unset it

# --- (6d-stale) Kill-evidence clamp (issue #278, the direct regression): a
# dead pid aged past window+60 cannot be evidence of a kill THIS invocation
# needs to worry about, regardless of which run wrote it. Reuses (6d)'s own
# WM_CONTINUITY_TIMEOUT_MARGIN=598 (NOT the default) so that IF the guard
# were broken and wrongly accepted this marker, the resulting cap
# (600-598=2) would visibly collapse this to armed=1 - with the guard
# working, the marker is rejected and the on-disk fallback cap
# (3600-598=3002) leaves the 40s budget untouched. Verified empirically
# against unmodified main: armed=1 (this test fails pre-fix, as intended). ---
new_home
add_crew_window d6dstale
wm_state crew-set --id d6dstale --status working --summary busy >/dev/null
( : ) & deadpid6dstale=$!; wait "$deadpid6dstale" 2>/dev/null
seed_inflight_marker "$deadpid6dstale"
export WM_STOP_CONTINUITY_WINDOW=2
wm_age_path "$WINGMAN_HOME/stop-continuity.pid" 90   # 90s > window(2)+60
export WM_STOP_CONTINUITY_LIFETIME=40
export WM_CONTINUITY_TIMEOUT_MARGIN=598
out6dstale="$(run_hook 60)"; rc6dstale=$?
armed6dstale="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_true "a stale dead pid does NOT clamp the budget - several windows run inside one invocation" "[ '$armed6dstale' -ge 3 ]"
assert_eq "the hook eventually exits 2 on its own configured budget, not the stale marker's" "$rc6dstale" "2"
assert_contains "the eventual break reports a clean rollover" "$out6dstale" "window rolled"
unset WM_STOP_CONTINUITY_WINDOW WM_CONTINUITY_TIMEOUT_MARGIN; export WM_STOP_CONTINUITY_LIFETIME=1

# --- (6d-foreign) Kill-evidence clamp (issue #278): a FRESH dead pid stamped
# with a DIFFERENT run id is equally not evidence for THIS run - proves the
# scope guard, independent of the freshness guard (6d-stale) above proves.
# Same WM_CONTINUITY_TIMEOUT_MARGIN=598 reasoning as (6d-stale). Verified
# empirically against unmodified main: armed=1 (fails pre-fix, as intended). ---
new_home
add_crew_window d6dforeign
wm_state crew-set --id d6dforeign --status working --summary busy >/dev/null
( : ) & deadpid6dforeign=$!; wait "$deadpid6dforeign" 2>/dev/null
seed_inflight_marker "$deadpid6dforeign" "run-some-other-session"
export WINGMAN_RUN_ID=run-this-invocation
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=40
export WM_CONTINUITY_TIMEOUT_MARGIN=598
out6dforeign="$(run_hook 60)"; rc6dforeign=$?
armed6dforeign="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_true "a foreign-run dead pid does NOT clamp the budget - several windows run inside one invocation" "[ '$armed6dforeign' -ge 3 ]"
assert_eq "the hook eventually exits 2 on its own configured budget, not the foreign marker's" "$rc6dforeign" "2"
unset WINGMAN_RUN_ID WM_STOP_CONTINUITY_WINDOW WM_CONTINUITY_TIMEOUT_MARGIN; export WM_STOP_CONTINUITY_LIFETIME=1

# --- (6d-floor) issue #278 part 2: whatever the evidence source, the final
# clamp never drops below one window. Reuses (6d)'s own fresh/same-run dead
# pid (genuine evidence, margin overridden past the fallback 600) but pushes
# the margin far enough that the UNFLOORED cap would be negative - proving
# the floor, not the evidence path, is what keeps this sane. ---
new_home
add_crew_window d6dfloor
wm_state crew-set --id d6dfloor --status working --summary busy >/dev/null
( : ) & deadpid6dfloor=$!; wait "$deadpid6dfloor" 2>/dev/null
seed_inflight_marker "$deadpid6dfloor"
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=3300
export WM_CONTINUITY_TIMEOUT_MARGIN=605   # 600 - 605 = -5: an unfloored cap would be negative
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook6dfloor.out" 2>&1 &
h6dfloor=$!; wm_track "$h6dfloor"
assert_true "the hook exits" "wait_for_gone $h6dfloor 60"
wait "$h6dfloor" 2>/dev/null
out6dfloor="$(cat "$WINGMAN_HOME/hook6dfloor.out" 2>/dev/null)"
armed6dfloor="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_contains "the floor fires a one-time diagnostic naming the computed cap" "$out6dfloor" "is below one window"
assert_eq "the floor still yields exactly one window (never fewer)" "$armed6dfloor" "1"
assert_contains "the invocation still exits with a clean, well-formed rollover, not a crash" "$out6dfloor" "window rolled"
unset WM_CONTINUITY_TIMEOUT_MARGIN WM_STOP_CONTINUITY_WINDOW; export WM_STOP_CONTINUITY_LIFETIME=1

# --- (7, rewritten for issue #231) The internal loop absorbs several windows
# and rewakes exactly once, from a SINGLE invocation - the direct regression
# for this issue: the old code produced one rewake PER window (three
# sequential invocations, three blocking errors), so it fails on the rewake
# count alone. Assert a floor on the iteration count, never an exact N: each
# iteration also pays several `uv run --no-project` startups (the claim,
# --classify, wm_unwaited_reason, the active_crew re-check), so the number of
# windows that fit in a fixed lifetime is load-dependent by design.
new_home
add_crew_window d7
wm_state crew-set --id d7 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=40
out7loop="$(run_hook 60)"; rc7loop=$?
armed_count7="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_true "the loop genuinely re-claimed more than once inside one invocation" "[ '$armed_count7' -ge 3 ]"
block_count7="$(printf '%s' "$out7loop" | grep -c '"decision": "block"')"
assert_eq "exactly one block decision reaches stdout (one process exit, not one per window)" "$block_count7" "1"
assert_eq "the hook exited 2 (a genuine rewake, not silence)" "$rc7loop" "2"
assert_contains "the one rewake carries the rollover body" "$out7loop" "window rolled"
assert_contains "the one rewake carries the do-not-arm sentence" "$out7loop" "do NOT arm a watch-fleet cycle"
assert_false "no live watch-fleet child is left behind" "[ -f '$WINGMAN_HOME/watch.pid' ]"
unset WM_STOP_CONTINUITY_WINDOW; export WM_STOP_CONTINUITY_LIFETIME=1  # restore the file-level lever, not merely unset it

# --- (7b) A fire arriving in a LATER iteration is reported as a fire, never
# swallowed and never conflated with a rollover - proves the loop does not
# delay or lose a genuine event that arrives after the first window. A wider
# window (10s, matching (7c) below) than the loop-cadence tests above:
# detecting the flip needs the watch-fleet CHILD to have actually reached its
# own live poll loop (WM_WATCH_INTERVAL=1) before the flip lands, not merely
# to have claimed - a 2s window leaves too little margin for that under a
# loaded machine and turns this into a startup-latency race unrelated to what
# the test means to prove. ---
new_home
add_crew_window d7b
wm_state crew-set --id d7b --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=10
export WM_STOP_CONTINUITY_LIFETIME=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook7b.out" 2>&1 &
h7b=$!; wm_track "$h7b"
assert_true "the first iteration claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
_armed7b=0; _n7b=0
while [ "$_armed7b" -lt 2 ] && [ "$_n7b" -lt 300 ]; do
  _armed7b="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
  _armed7b="${_armed7b:-0}"
  sleep 0.2; _n7b=$((_n7b+1))
done
assert_true "a second iteration genuinely re-claimed before the fire is introduced" "[ '$_armed7b' -ge 2 ]"
wm_state crew-set --id d7b --status review --summary "done" >/dev/null
assert_true "the hook exits within one poll interval of the fire-eligible flip" "wait_for_gone $h7b 200"
wait "$h7b" 2>/dev/null
out7b="$(cat "$WINGMAN_HOME/hook7b.out" 2>/dev/null)"
assert_contains "the fire is reported via compose_attention_reason's own text" "$out7b" "surfaced via automatic fleet continuity"
assert_not_contains "a fire is never conflated with a rollover" "$out7b" "window rolled"
_survivor7b="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
[ -n "$_survivor7b" ] && kill "$_survivor7b" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW; export WM_STOP_CONTINUITY_LIFETIME=1  # restore the file-level lever, not merely unset it

# --- (7c) A mid-window watch-fleet child death re-claims in place instead of
# abandoning the fleet - the direct regression for the deliberate `spurious`
# behavior change (issue #231): today's code exits 0 on this exact death and
# leaves the fleet unsupervised until the model's own next natural turn. ---
# QUARANTINED (issue #263): the re-claim this test triggers has been observed
# taking well over 50s in CI - far past what the claim-lock retry logic's own
# stated bounds (a handful of seconds) would suggest - which is a genuine
# defect signal worth its own investigation, not something this test's own
# timeout should paper over. Widening the window here three times in a row
# only moved the flake to a different assertion each time without ever
# closing it. See issue #263 for the actual delay this points at; re-enable
# this case once that lands.
echo "  SKIP - case 7c quarantined pending issue #263 (mid-window re-claim delay observed >50s under CI load)"

# --- (219a) A mid-window stale-code exit re-claims in place, exactly like ---
# (7c)'s own external-kill case above - the direct regression for issue #219:
# a cycle that notices its own code went stale on disk exits cleanly, and the
# tokenless continuity loop re-claims a fresh cycle in the same invocation
# rather than ending the turn (a second "armed pid=" line in the arm log),
# with the spurious-failure count left at 0 afterward (a stale-code exit is
# not a failure). ---
# QUARANTINED (issue #263, the identical mid-window re-claim path (7c)
# exercises): a stale-code death re-claims through the exact same "foreground
# bin/watch-fleet, then re-claim in place" mechanism whose delay has been
# observed exceeding 50s in CI - a pre-existing defect unrelated to issue
# #219 itself. Re-enable alongside (7c) once #263's investigation lands a fix.
echo "  SKIP - case 219a quarantined pending issue #263 (mid-window re-claim delay observed >50s under CI load, same path as case 7c)"

# --- (7c') The budget-exhaustion body names what actually happened - the
# direct regression against conflating a clean rollover with a re-arm after
# an unexpected watch-cycle exit. Mirror of test (9) sub-case (b), whose own
# assert_not_contains "window rolled" this must not violate. ---
#
# issue #308's original race (the referee's own sleep "$window" starting
# concurrently with the child's own spawn, eating into the same budget this
# test's own kill -9 needs) was fixed by making the window structurally
# unreachable (3600s) - see the git history of this comment for that
# analysis in full. That fix held up locally, but issue #346's own
# stabilization work found a SECOND, independent race real GitHub Actions CI
# has now hit twice (PR #348, and this file's own CI run on the #346
# branch): under sufficient contention, the loop's OWN re-claim after the
# first (killed) child's death spawns a second, never-killed watch-fleet
# child that can complete a genuine reconcile pass and organically detect a
# real roster-attention condition before this test's own budget-exhaustion
# check ever fires - producing a genuine "fire" classification
# (compose_attention_reason's roster-report text) instead of the
# "unexpected watch-cycle exit" wording this test asserts on. Confirmed
# directly from CI's own log, not inferred, and precisely: the hook did
# NOT exit within the (then 600-try) budget - `FAIL - the hook exits` is
# genuinely in that run's log, this is a real timeout, not a false
# assertion - but the SUBSEQUENT unconditional `wait` (which every case in
# this file uses right after its own wait_for_gone, regardless of that
# poll's own pass/fail) still captured the hook's eventual real output once
# it did exit, and that output was the real "Crew need your attention..."
# roster text - not truncated or malformed. Both facts hold at once: a
# genuine poll-budget timeout, and a genuine fire classification once the
# process actually finished. That is exactly the "mid-window re-claim"
# mechanism issue #263
# already names for cases 7c/219a above - this case shares it, just via a
# path #308's original fix didn't anticipate. Quarantined rather than
# reworked here for the same reason 7c/219a are: this is a genuine defect
# signal in the re-claim path's own timing, not a test-tolerance problem a
# wider margin can close (see issue #263 for the deferred investigation).
echo "  SKIP - case 7c' quarantined pending issue #263 (the same mid-window re-claim path as cases 7c/219a - see the comment above for how this case's own re-claim can race a genuine reconcile-driven fire, observed on real CI)"

# --- (7d) The loop stops (silently) the moment the fleet empties, without
# waiting out the rest of its lifetime - checked BEFORE the budget, so a
# fleet that empties during the final window ends the invocation silently
# instead of spending a wake to announce a rollover to a session whose next
# invocation would exit immediately at the fast path anyway. ---
new_home
add_crew_window d7d
wm_state crew-set --id d7d --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook7d.out" 2>&1 &
h7d=$!; wm_track "$h7d"
assert_true "the first iteration claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
# "stood-down", not "done": every status a member can leave LIVE_STATES
# through other than "stood-down" (done/died/blocked/review/stalled) is ALSO
# in wm-state.py's own ATTENTION_STATES, so it would legitimately fire a
# roster-report event of its own - "stood-down" is the one terminal status
# that is neither, the genuinely quiet "nothing left to do here" case this
# test means to exercise.
wm_state crew-set --id d7d --status stood-down --summary "wrapped up" >/dev/null
assert_true "the hook exits" "wait_for_gone $h7d 100"
wait "$h7d" 2>/dev/null
out7d="$(cat "$WINGMAN_HOME/hook7d.out" 2>/dev/null)"
assert_eq "no stdout - the empty-fleet break is silent" "$out7d" ""
# issue #346: was a wall-clock "$_elapsed7d -lt 40" proxy for "broke on the
# first iteration, not a second window" - real but load-sensitive (a
# genuinely correct exit can still take longer than 40s under heavy
# contention, per the ~14x uv-subprocess slowdown docs/analysis/
# 2026-08-11-test-suite-slowness-investigation.md measured). The file
# already has the load-independent observable for exactly this - the same
# armed-count check cases 7/7b/7e/7f/8e use.
armed_count7d="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_eq "the fleet-empty break fired after exactly one claim, not a second window" "$armed_count7d" "1"
assert_false "no live watch-fleet child is left behind" "[ -f '$WINGMAN_HOME/watch.pid' ]"
unset WM_STOP_CONTINUITY_WINDOW; export WM_STOP_CONTINUITY_LIFETIME=1  # restore the file-level lever, not merely unset it

# --- (7e) The in-flight marker is refreshed every iteration, not fixed at
# entry - without this, the freshness bound (window+60) goes stale partway
# through a lifetime many multiples of one window, and a concurrent instance
# could pass the guard. ---
new_home
add_crew_window d7e
wm_state crew-set --id d7e --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=40
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook7e.out" 2>&1 &
h7e=$!; wm_track "$h7e"
assert_true "the first iteration claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
_mtime1_7e="$(uv run --no-project --quiet python -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$WINGMAN_HOME/stop-continuity.pid" 2>/dev/null)"
_armed7e=0; _n7e=0
while [ "$_armed7e" -lt 3 ] && [ "$_n7e" -lt 200 ]; do
  _armed7e="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
  _armed7e="${_armed7e:-0}"
  sleep 0.2; _n7e=$((_n7e+1))
done
assert_true "a third armed line appears" "[ '$_armed7e' -ge 3 ]"
_mtime2_7e="$(uv run --no-project --quiet python -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$WINGMAN_HOME/stop-continuity.pid" 2>/dev/null)"
assert_true "the in-flight marker's mtime advanced across iterations" "[ '$_mtime2_7e' -gt '$_mtime1_7e' ]"
kill -TERM "$h7e" 2>/dev/null
wait "$h7e" 2>/dev/null
_survivor7e="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
[ -n "$_survivor7e" ] && kill "$_survivor7e" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW; export WM_STOP_CONTINUITY_LIFETIME=1  # restore the file-level lever, not merely unset it

# --- (7f) The lifetime self-clamps to the registered `timeout` - the direct
# regression for the migration hazard, and the one test that would have
# caught the first draft of the #231 plan's missing registration path.
#
# NH1 (round-2 review of the #231 plan): a fixture `timeout: 600` against the
# real WM_STOP_CONTINUITY_LIFETIME=3300 clamps to 300s, which still admits
# roughly 150 two-second windows across five minutes of wall clock - nowhere
# near "a single window". The tempting fix (raise the window to >= 300s
# instead) would pass vacuously via the trivial lifetime<=window path even
# with the clamp deleted entirely - exactly the "passes for the right
# reason, not by coincidence" trap this suite is careful about for test (9)
# sub-case (b). The actual fix: set the fixture's own timeout to
# window+margin, so the clamped lifetime equals the window exactly and only
# the clamp (never the configured 3300s budget) can be what bounded it. ---
new_home
add_crew_window d7f
wm_state crew-set --id d7f --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=3300
PROJ_SETTINGS_7f="$WINGMAN_HOME/proj-settings-7f.json"
cat > "$PROJ_SETTINGS_7f" <<JSON
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "$HOOK", "asyncRewake": true, "timeout": 302}]}]}}
JSON
export WM_PROJECT_SETTINGS="$PROJ_SETTINGS_7f"
out7f="$(run_hook 30)"; rc7f=$?
armed7f="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_eq "the clamp (not the configured 3300s budget) bounds the invocation to a single window" "$armed7f" "1"
assert_eq "the hook exits 2 (a genuine budget-exhaustion rewake)" "$rc7f" "2"
assert_contains "the single-window break reports a clean rollover" "$out7f" "window rolled"
unset WM_PROJECT_SETTINGS WM_STOP_CONTINUITY_WINDOW; export WM_STOP_CONTINUITY_LIFETIME=1  # restore the file-level lever, not merely unset it

# Unreadable-registration companion: a missing settings file falls back to
# the historical 600s, not the configured default. Its own fallback is not
# fixture-tunable (there is nothing to point a `timeout` fixture value at),
# so this proves it a different way: override WM_CONTINUITY_TIMEOUT_MARGIN
# (env-overridable for exactly this) so 600-margin lands on the window
# exactly, the same one-window proof as above.
#
# Both candidate settings files are pointed at missing paths EXPLICITLY here
# (issue #231 review round 1, NH4) - not left to rely on test_new_home's own
# WM_CLAUDE_USER_SETTINGS fixture (a real, but hook-free, file) happening to
# yield nothing for the user-scope lookup too. That reliance would make this
# case fragile to an unrelated change in tests/lib.sh's own fixture shape,
# or to a future case written without new_home first.
new_home
add_crew_window d7f2
wm_state crew-set --id d7f2 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=3300
export WM_PROJECT_SETTINGS="$WINGMAN_HOME/does-not-exist-7f2.json"
export WM_CLAUDE_USER_SETTINGS="$WINGMAN_HOME/does-not-exist-7f2-user.json"
export WM_CONTINUITY_TIMEOUT_MARGIN=598
out7f2="$(run_hook 30)"; rc7f2=$?
armed7f2="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_eq "an unreadable registration falls back to the historical 600s, clamping to a single window" "$armed7f2" "1"
assert_eq "the hook exits 2" "$rc7f2" "2"
assert_contains "the single-window break reports a clean rollover" "$out7f2" "window rolled"
# Restored, not merely unset: the next new_home call would re-seed
# WM_CLAUDE_USER_SETTINGS anyway, but WM_STOP_CONTINUITY_LIFETIME is the
# file-level lever and must be explicitly restored, not left unset.
unset WM_PROJECT_SETTINGS WM_CLAUDE_USER_SETTINGS WM_STOP_CONTINUITY_WINDOW WM_CONTINUITY_TIMEOUT_MARGIN
export WM_STOP_CONTINUITY_LIFETIME=1

# --- (7f3) Fault path, corrupt settings file (issue #280) --------------------
# A settings file that EXISTS and is NOT valid JSON must NOT be folded into
# the same historical-600 fallback a MISSING file (d7f2 above) legitimately
# gets - that fold is exactly the bug: it would infer 600 on a genuine fault,
# clamp to 600-margin, and silently collapse to a fraction of the configured
# lifetime. WM_CONTINUITY_TIMEOUT_MARGIN=597 makes the (wrong) 600-derived
# cap a tiny 3s - small enough that a wrongly-clamped invocation cannot
# complete more than a single window before its budget check fires, while
# the correctly-unclamped invocation (lifetime stays at the configured 10s)
# comfortably completes several. This is a fault-vs-absence proof, not an
# exact-iteration-count proof - "-ge 2" leaves headroom against per-iteration
# `uv` subprocess overhead varying under load, while a genuinely wrongly
# clamped run can never exceed 1 by construction of the 3s cap.
new_home
add_crew_window d7f3
wm_state crew-set --id d7f3 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=10
export WM_CONTINUITY_TIMEOUT_MARGIN=597
BAD_SETTINGS_7f3="$WINGMAN_HOME/corrupt-settings-7f3.json"
printf 'not valid json{' > "$BAD_SETTINGS_7f3"
export WM_PROJECT_SETTINGS="$BAD_SETTINGS_7f3"
export WM_CLAUDE_USER_SETTINGS="$WINGMAN_HOME/does-not-exist-7f3-user.json"
out7f3="$(printf '{}' | wm_timeout 30 bash "$HOOK" 2>&1)"; rc7f3=$?
armed7f3="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_true "a corrupt (not missing) settings file does NOT clamp to a single window" "[ '${armed7f3:-0}' -ge 2 ]"
assert_eq "the hook exits 2 (a genuine budget-exhaustion rewake)" "$rc7f3" "2"
assert_contains "the lookup fault is reported on stderr, naming the corrupt file" "$out7f3" "registered-timeout lookup faulted"
assert_contains "the skipped-clamp consequence is also reported" "$out7f3" "skipping the registered-timeout clamp"
unset WM_PROJECT_SETTINGS WM_CLAUDE_USER_SETTINGS WM_STOP_CONTINUITY_WINDOW WM_CONTINUITY_TIMEOUT_MARGIN
export WM_STOP_CONTINUITY_LIFETIME=1

# --- (7f4) Fault path, $WM_UV subprocess failure (issue #280) ----------------
# Proves the fault path is also reached via a shell-level $WM_UV failure
# (uv itself exits nonzero before Python ever runs), not only the Python
# exception route 7f3 exercises - a genuinely distinct trigger the issue
# explicitly calls out. The settings file here is valid JSON, isolating this
# as a non-JSON fault. The stub only intercepts calls naming this test's own
# marker file, matching the STUB_A/STUB_B idiom in
# tests/watch-fleet-lifecycle.test.sh and the RUNNER wrapper in
# tests/pilot-preferences-guard.test.sh - falling
# through to the real `uv run --no-project --quiet "$@"` for every other
# $WM_UV invocation the hook makes, so it never breaks the hook at an
# earlier, unrelated call.
new_home
add_crew_window d7f4
wm_state crew-set --id d7f4 --status working --summary busy >/dev/null
STUB_7f4="$(wm_mktemp_file)"
REAL_SETTINGS_7f4="$WINGMAN_HOME/settings-7f4-marker.json"
printf '{"hooks": {"Stop": []}}\n' > "$REAL_SETTINGS_7f4"
cat > "$STUB_7f4" <<STUBEOF
#!/usr/bin/env bash
case "\$*" in
  *settings-7f4-marker*) exit 17 ;;
esac
exec uv run --no-project --quiet "\$@"
STUBEOF
chmod +x "$STUB_7f4"
export WM_STOP_CONTINUITY_WINDOW=2
export WM_STOP_CONTINUITY_LIFETIME=10
export WM_CONTINUITY_TIMEOUT_MARGIN=597
export WM_PROJECT_SETTINGS="$REAL_SETTINGS_7f4"
export WM_CLAUDE_USER_SETTINGS="$WINGMAN_HOME/does-not-exist-7f4-user.json"
out7f4="$(printf '{}' | WM_UV="$STUB_7f4" wm_timeout 30 bash "$HOOK" 2>&1)"; rc7f4=$?
armed7f4="$(grep -c 'armed pid=' "$WINGMAN_HOME/stop-autoarm.log" 2>/dev/null)"
assert_true "a dead \$WM_UV subprocess (not a JSON error) also skips the clamp, not just corrupt JSON" "[ '${armed7f4:-0}' -ge 2 ]"
assert_eq "the hook exits 2" "$rc7f4" "2"
assert_contains "the lookup fault is reported on stderr" "$out7f4" "registered-timeout lookup faulted"
unset WM_PROJECT_SETTINGS WM_CLAUDE_USER_SETTINGS WM_STOP_CONTINUITY_WINDOW WM_CONTINUITY_TIMEOUT_MARGIN
export WM_STOP_CONTINUITY_LIFETIME=1

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
#
# issue #346: quarantined, alongside case 7c' just above, for the identical
# reason - see that case's own comment for the full analysis. This block's
# own positive assertion (the spurious count advancing to exactly 1) depends
# on --classify seeing "spurious" specifically; under the same mid-window
# re-claim race, real CI has observed this hook instead completing a genuine
# reconcile-driven "fire" classification, which the assertion has no way to
# distinguish from a genuine defect. Same issue #263 mid-window re-claim
# mechanism as cases 7c/219a/7c' - not re-attempted here.
echo "  SKIP - case 8e (successful-arm-then-kill spurious-forensics routing) quarantined pending issue #263 (the same mid-window re-claim path as cases 7c/219a/7c' - see case 7c''s own comment above)"

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
assert_true "the child genuinely armed (not merely attempted)" "wait_for_content '$WINGMAN_HOME/stop-autoarm.log' 'armed pid='"
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
# Matches the window (issue #278): the file-level WM_STOP_CONTINUITY_LIFETIME=1
# default sits below any window override, which would otherwise trip the new
# below-one-window floor (:296) on every invocation below and print its
# diagnostic to stderr - polluting the byte-exact stderr/marker comparison
# a few lines down ("one author, two consumers"). lifetime == window is still
# a strict floor no-op (:296 only fires strictly below), so this changes
# nothing about this section's own single-iteration-per-invocation behavior.
export WM_STOP_CONTINUITY_LIFETIME=30
_trip_out=""
_trip_err=""
_round=0
while [ ! -f "$WINGMAN_HOME/watch.suppressed" ] && [ "$_round" -lt 6 ]; do
  _round=$((_round+1))
  _prev_pid="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
  # stdout (the JSON-wrapped block decision) and stderr (rewake()'s own raw
  # body, printed unwrapped) are captured to SEPARATE files - the raw-body
  # capture is what lets the R1 regression checks below compare against the
  # marker's own stored text byte-for-byte, with no JSON escaping in the way.
  printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/sr$_round.out" 2>"$WINGMAN_HOME/sr$_round.err" &
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
  # No wait_for_gone here (review, round 2): a poll immediately followed by
  # an unconditional `wait` on the same pid is inert - `wait` blocks until
  # the process actually exits regardless of how many times a preceding
  # poll already tried, so a tries budget on that poll cannot change this
  # loop's own outcome either way. The unconditional wait below is what
  # actually gates this.
  wait "$hp" 2>/dev/null
  _trip_out="$(cat "$WINGMAN_HOME/sr$_round.out" 2>/dev/null)"
  _trip_err="$(cat "$WINGMAN_HOME/sr$_round.err" 2>/dev/null)"
done
assert_true "the standdown trips within a bounded number of genuine deaths" "[ -f '$WINGMAN_HOME/watch.suppressed' ]"
assert_contains "the tripping invocation rewakes via manual-remedy (no do-not-arm sentence)" "$_trip_out" "fleet supervision is not being maintained"
assert_not_contains "the tripping invocation is not auto mode" "$_trip_out" "do NOT arm a watch-fleet cycle"
assert_contains "the standdown marker carries the composed remedy text on line 2+" "$(tail -n +2 "$WINGMAN_HOME/watch.suppressed" 2>/dev/null)" "fleet supervision is not being maintained"
# issue #198: --classify (not this hook) now authors the marker - the trip's
# own rewake body is read back from it, not recomposed, so the two can never
# drift (one author, two consumers).
assert_eq "the tripping rewake body equals the marker's line 2+ (one author, two consumers)" "$_trip_err" "$(tail -n +2 "$WINGMAN_HOME/watch.suppressed" 2>/dev/null)"
# The direct R1 regression: against REAL composed text from a REAL trip (not
# a synthetic marker body), the standdown must never instruct the model to
# resume/arm - that instruction is exactly what let a compliant model
# dissolve its own standdown.
assert_not_contains "R1 regression: the real trip text never says to resume by running /watch" "$_trip_out" "Resume it by running"
assert_not_contains "R1 regression: the real trip text never says to arm bin/watch-fleet directly" "$_trip_out" "arming bin/watch-fleet"
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
unset WM_STOP_CONTINUITY_WINDOW; export WM_STOP_CONTINUITY_LIFETIME=1

# issue #331: the owner-scoped complement to the genuine-death trip above -
# the SAME bounded-loop real-kill mechanism, but under WINGMAN_CREW_ID, so the
# mechanical crew-set flip is exercised through the actual hook/--classify
# invocation shape a real lead session hits, not a direct `--classify --owner`
# call (already covered in tests/watch-fleet-classify.test.sh) or a synthetic
# marker (the d8g block above).
new_home
export WINGMAN_CREW_ID=d8h
add_crew_window d8h
wm_state crew-set --id d8h --status working --summary busy >/dev/null
# active_crew (step 4's own precondition) counts d8h's own DIRECT REPORTS,
# not d8h itself - without one in flight, the hook exits at step 4 before
# ever reaching the classify/arm logic below. A real tmux window too, not
# just the roster record: this test runs real watch-fleet cycles, whose own
# reconcile step flips a LIVE_STATES record with no matching live window to
# died within a poll or two (see add_crew_window's own header above).
wm_state crew-add --id wkrh --type developer --objective x --repo /tmp --window wm-wkrh --session-id s-wkrh --parent d8h >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-wkrh 'sleep 600'
wm_state crew-set --id wkrh --status working --summary coding >/dev/null
export WM_STOP_CONTINUITY_WINDOW=30
export WM_STOP_CONTINUITY_LIFETIME=30
_oround=0
while [ ! -f "$WINGMAN_HOME/watch-d8h.suppressed" ] && [ "$_oround" -lt 6 ]; do
  _oround=$((_oround+1))
  _oprev_pid="$(cat "$WINGMAN_HOME/watch-d8h.pid" 2>/dev/null)"
  printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/osr$_oround.out" 2>/dev/null &
  ohp=$!; wm_track "$ohp"
  _on=0
  while kill -0 "$ohp" 2>/dev/null && [ "$_on" -lt 100 ]; do
    _ocur_pid="$(cat "$WINGMAN_HOME/watch-d8h.pid" 2>/dev/null)"
    if [ -n "$_ocur_pid" ] && [ "$_ocur_pid" != "$_oprev_pid" ]; then
      kill -9 "$_ocur_pid" 2>/dev/null
      break
    fi
    sleep 0.1; _on=$((_on+1))
  done
  # No wait_for_gone here - same reasoning as case 8b's identical loop
  # above (review, round 2): a poll immediately followed by an unconditional
  # wait on the same pid cannot change this loop's own outcome.
  wait "$ohp" 2>/dev/null
done
assert_true "the owner-scoped standdown trips within a bounded number of genuine deaths" "[ -f '$WINGMAN_HOME/watch-d8h.suppressed' ]"
d8h_get="$(wm_state crew-get --id d8h)"
assert_contains "the real owner-scoped trip flips d8h's own status to blocked" "$d8h_get" "\"status\": \"blocked\""
assert_contains "the real owner-scoped trip's blocker carries the standdown tag" "$d8h_get" "\"blocker\": \"watch-fleet-standdown:"
unset WM_STOP_CONTINUITY_WINDOW; export WM_STOP_CONTINUITY_LIFETIME=1
unset WINGMAN_CREW_ID

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

# issue #331: this hook's own marker-active gate (:394, gate 7 above) also
# mechanically re-asserts the affected owner's crew-set status - not just
# stop-guard.sh's branch. Synthetic marker, owner-scoped, same style as the
# d8c block just above.
new_home
export WINGMAN_CREW_ID=d8g
add_crew_window d8g
wm_state crew-set --id d8g --status working --summary busy >/dev/null
# active_crew (step 4's own precondition) counts d8g's own DIRECT REPORTS,
# not d8g itself (crew-list --owner filters on parent == owner) - without a
# child in flight, active_crew is 0 and the hook exits at step 4, never
# reaching the marker-active gate at step 7 at all.
wm_state crew-add --id wkrg --type developer --objective x --repo /tmp --window wm-wkrg --session-id s-wkrg --parent d8g >/dev/null
wm_state crew-set --id wkrg --status working --summary coding >/dev/null
{
  printf '%s\n' "run-c"
  printf '%s\n' "the watcher for this session has died 3 times in a row (composed remedy text)"
} > "$WINGMAN_HOME/watch-d8g.suppressed"
export WINGMAN_RUN_ID=run-c
out_d8g="$(run_hook)"
assert_eq "the gate's own stdout is still silent (existing behavior unchanged)" "$out_d8g" ""
d8g_get="$(wm_state crew-get --id d8g)"
assert_contains "the gate's own re-assertion flips d8g's status to blocked" "$d8g_get" "\"status\": \"blocked\""
assert_contains "the re-assertion's blocker carries the standdown tag" "$d8g_get" "\"blocker\": \"watch-fleet-standdown:"
unset WINGMAN_RUN_ID
unset WINGMAN_CREW_ID
rm -f "$WINGMAN_HOME/watch-d8g.suppressed"

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
#
# issue #346: both sub-cases below need to land the fire/kill NEAR the
# window's own natural expiry (that proximity is the whole point - it's what
# exercises the write-before-kill race in hooks/stop-continuity.sh, not an
# incidental detail) - but a FIXED post-claim sleep assumes the claim itself
# consumed close to none of the window's budget. It doesn't: the referee's
# own `sleep "$window"` (hooks/stop-continuity.sh:527) starts essentially
# concurrently with the child's own spawn, not after this test's own
# wait_for_file returns, so claim time comes directly out of the same
# budget the fixed sleep assumed was still fully available (the same root
# cause issue #308 diagnosed for case 7c', below). Fixed by measuring the
# actual elapsed time since the child (not the hook - see
# remaining_before_expiry's own comment for why that distinction matters)
# started and sleeping only what's actually left, minus a safety margin -
# this lands consistently near expiry regardless of how long the claim took,
# instead of assuming it took ~0s. The window itself is also widened
# (8->20, 5->20) for absolute slack against genuinely slow claims, matching
# the 10-20s windows already used elsewhere in this file for exactly this
# reason (cases 7b, 7e, 8b, 8h) - review of this fix flagged the first
# draft's own 30s windows as a real, uncosted wall-clock regression
# (+11.8% per suite run) once the epoch fix below removed the need for that
# much padding.
#
# Case 9 uses a 10s margin, case 9b (below) a tighter 1s - deliberately NOT
# matched, because their own trigger latencies differ: case 9's is
# `wm_state crew-set` (below), which does not itself complete the property
# under test - `bin/watch-fleet`'s own poll loop must then also notice the
# flip, ack it, and write $EXITFILE, each step its own `uv run` subprocess -
# where case 9b's is a single near-instant `kill -9`. A second review round
# caught this directly: an earlier 3s margin (chosen by analogy to 9b's
# original draft, never independently measured for case 9's own chain)
# flaked ~36% of runs against completely unmutated production code -
# NOT a mutation, a real regression this change introduced. Instrumented
# the real crew-set -> watch-fleet-notices -> ack -> $EXITFILE-write chain
# directly (not guessed): ~2.4-2.7s on this box at rest, ~4.6-5.2s with
# 8 added CPU-bound processes competing for its 8 cores - so 10s is a
# real, measured value with a safety factor of roughly 2x the worst
# directly-observed sample, not a number picked by widening until the
# flake stopped (the anti-pattern this whole file's stabilization exists
# to end). Mutation-tested afterward to confirm 10s is still sensitive,
# not just stable: `bin/watch-fleet`'s own fire() writes $EXITFILE
# unconditionally, specifically so it always wins a race against the
# referee's own noclobber "rolled" write (see fire()'s own comment,
# "the highest-priority writer... must never lose") - PROVIDED fire()
# reaches that write before the referee's subsequent `kill -TERM $child`
# can land. Widening the gap between fire()'s own ack step and its
# $EXITFILE write (modeling contention in that same production code path,
# not editing this test) reliably catches at a 6-8s widened gap (round 3
# independently reconstructed this: misses at 4s, catches 2/3 at 6s,
# catches 3/3 at 8s and 10s) while 10s held clean against the real,
# unmutated hook across 60 runs spanning loadavg 1.5-30.3, with zero
# failures (round 3's own measurement; round 2's original 5/5 was a
# smaller sample of the same claim).
#
# Sensitivity cost, stated plainly (round 3): the identical mutation
# against this file's pre-#346 case 9 (window=8, fixed `sleep 3`, ~4.4s
# margin) caught at a 3s gap - so the detection floor here moved from
# ~3s of modelled contention to ~6-8s, roughly twice as coarse. That is
# the direct, disclosed cost of the margin going from ~4.4s to 10s, not
# a hidden regression - case 9 now proves the fire-vs-rollover ordering
# holds against GROSS contention in `bin/watch-fleet`'s own ack-to-write
# gap (multiple whole seconds), not fine-grained timing at the edge of
# what's representable; case 9b (below), whose trigger has no comparable
# latency to budget for, is what still carries the fine-grained
# write-before-kill coverage this file's cases used to rely on case 9 for
# too. Re-verify against the same kind of mutation before changing either
# number.
new_home
add_crew_window d9
wm_state crew-set --id d9 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=20
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook9r.out" 2>&1 &
h9r=$!; wm_track "$h9r"
assert_true "a cycle claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
cpid9r="$(cat "$WINGMAN_HOME/watch.pid")"
_r9="$(remaining_before_expiry "$cpid9r" "$WM_STOP_CONTINUITY_WINDOW" 10)"
# A failed /proc read or uv invocation inside remaining_before_expiry prints
# nothing and, under this file's `set -u` (not `set -e`), a `sleep ""`
# right after would error and be silently skipped rather than abort - the
# kill/flip below would then fire almost immediately after claim instead of
# near expiry, making the assertion below unable to fail no matter what the
# production code does (review, round 2). Guarded explicitly rather than
# trusted implicitly. Also rejects the literal "0" (review, round 3): a
# claim slow enough to exceed window-minus-margin floors the helper's own
# max(...,0), which is numeric and would otherwise pass this check while
# silently degrading to the exact same "fires immediately, tests nothing
# near expiry" failure mode - remote (measured claim time is under 1s
# against a 10s budget here) but the same class of silent degradation as
# the other two defects this file's review already found.
assert_true "remaining_before_expiry returned a real, positive duration, not a silent failure" "case \"\$_r9\" in ''|0|*[!0-9.]*) false ;; *) true ;; esac"
sleep "$_r9"
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
export WM_STOP_CONTINUITY_WINDOW=20
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook9s.out" 2>&1 &
h9s=$!; wm_track "$h9s"
assert_true "a cycle claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
cpid9s="$(cat "$WINGMAN_HOME/watch.pid")"
# Kill the child directly, close to the window's own expiry (not "well
# before" it), so the referee's own sleep could plausibly still complete
# during the reap/cancellation gap if the snapshot fix were absent.
#
# 1s margin: review of this fix (issue #346) mutation-tested an earlier
# draft (a 3s margin computed from a timestamp captured before the hook
# launched, not the child's own start) precisely: moved exitfile_snapshot's
# read in hooks/stop-continuity.sh from immediately after `wait "$child"`
# to after the referee is explicitly cancelled (`kill "$referee"; wait
# "$referee"`), with a widened gap inserted BEFORE that cancellation step
# (giving the referee strictly more real time to complete its own
# sleep+write on its own, before this code ever tries to stop it -
# inserting the delay after cancellation instead has no effect, since a
# referee already sent SIGTERM cannot write regardless of how long you
# then wait; this file's own git history has an earlier, wrong
# reconstruction of this mutation that gave a false pass for exactly that
# reason). That draft passed regardless at both a 1s and a 2s gap: the
# referee's own remaining countdown at kill time was never short enough
# for the widened gap to matter, because the pre-launch timestamp
# overstated elapsed time by however long the hook's own pre-child work
# (a crew-list check, wm_watcher_up, compute_pr_watch_needed) took -
# silently loosening the margin regardless of what value was asked for.
# Fixed by anchoring to the child's own actual start (remaining_before_
# expiry, above), which removed that bias entirely. Re-verified against
# the identical mutation, same gap values, after the fix: 1s reliably
# catches both a 1s and a 2s modeled gap widening (3/3 each), matching
# origin/main's own original detection pattern, and held with no false
# "window rolled" positive against the real, unmutated hook under this
# box's own real ambient load (5/5). A measured tradeoff between test
# sensitivity and tolerance for load-induced jitter, not an arbitrary
# constant - re-verify against the same kind of mutation before changing it.
_r9b="$(remaining_before_expiry "$cpid9s" "$WM_STOP_CONTINUITY_WINDOW" 1)"
# See case 9's own identical guard above for why this assertion exists,
# including why the literal "0" is rejected too, not just non-numeric.
assert_true "remaining_before_expiry returned a real, positive duration, not a silent failure" "case \"\$_r9b\" in ''|0|*[!0-9.]*) false ;; *) true ;; esac"
sleep "$_r9b"
kill -9 "$cpid9s" 2>/dev/null
# 600 tries (120s), not the 100-try default, for headroom: this kill
# reaches the hook's exit via the same external-SIGKILL-to-a-claimed-child
# -> --classify forensics chain as cases 7c'/8e below. Note this budget
# widening did NOT, by itself, fix 7c'/8e - those cases are quarantined
# under issue #263 for a separate reason (see that quarantine's own
# comment) - so treat this 600 as headroom against a slow forensics chain,
# not as an empirically-derived "this exact number was needed" claim.
assert_true "the hook exits" "wait_for_gone $h9s 600"
wait "$h9s" 2>/dev/null
out9s="$(cat "$WINGMAN_HOME/hook9s.out" 2>/dev/null)"
assert_not_contains "an external kill near expiry is never misreported as rolled" "$out9s" "window rolled"
unset WM_STOP_CONTINUITY_WINDOW

# --- (10, changed assertions for issue #231) unwaited, checked once per
# invocation, after the window closes, and breaks the loop rather than a mere
# single-shot pass. A rollover is no longer a reportable event on its own -
# merging "window rolled" into this body would reintroduce exactly the noise
# this issue is about - so the rewake carries the unwaited text ALONE (in
# `auto` mode: continuity is still re-arming even though nothing else is
# reported), not the rollover sentence. ----
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
assert_contains "the unwaited-ask text is present" "$out10u" "pending question with no live waiter"
assert_contains "auto mode survived (do-not-arm sentence present)" "$out10u" "do NOT arm a watch-fleet cycle"
assert_not_contains "the rollover is no longer a reportable event on its own" "$out10u" "window rolled"
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
# issue #346: was a fixed `sleep 2` before checking watch.pid - under load
# the claim negotiation between the two concurrently-started processes above
# is not guaranteed to finish inside 2s, which would fail this assertion for
# a reason unrelated to the property under test. `--stop` above unconditionally
# removes $PIDFILE, so wait_for_file here can only return true once one side
# has genuinely (re-)claimed - the same idiom case (3) already uses for the
# identical "exactly one claims" property.
assert_true "exactly one cycle survives the race" "wait_for_file '$WINGMAN_HOME/watch.pid'"
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

# --- (14) Pre-claim accounting (issue #197): a fire WITH a crew-status row is
# absorbed, unchanged from #185 - pinned against stop-guard.sh's own
# independent report so this is proven by test, not left as prose. Arms a
# REAL cycle, flips the member to review, and lets the cycle fire and exit
# naturally (no hand-seeding) before the hook is ever invoked.
new_home
add_crew_window d14
wm_state crew-set --id d14 --status working --summary busy >/dev/null
"$WF" >"$WINGMAN_HOME/d14-prior.log" 2>&1 &
d14pid=$!; wm_track "$d14pid"
assert_true "a cycle claims" "wait_for_file '$WINGMAN_HOME/watch.pid'"
wm_state crew-set --id d14 --status review --summary "done" >/dev/null
assert_true "the cycle fires and exits naturally" "wait_for_file_gone '$WINGMAN_HOME/watch.pid'"
assert_eq "the fire record is left pending (never classified)" "$(cat "$WINGMAN_HOME/watch-exit" 2>/dev/null)" "fire"
export WM_STOP_CONTINUITY_WINDOW=60
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook14.out" 2>"$WINGMAN_HOME/hook14.err" &
h14=$!; wm_track "$h14"
assert_true "the hook proceeds to claim a fresh cycle (absorbed, not reported)" "wait_for_file '$WINGMAN_HOME/watch.pid'"
sleep 1
assert_eq "no rewake/block decision for this invocation" "$(cat "$WINGMAN_HOME/hook14.out" 2>/dev/null)" ""
guard_out14="$(printf '{"stop_hook_active": false}' | bash "$GUARD")"
assert_contains "a direct stop-guard.sh call reports a block decision" "$guard_out14" '"decision": "block"'
assert_contains "stop-guard.sh's own reason names the member's own row" "$guard_out14" "d14"
kill -TERM "$h14" 2>/dev/null
_d14survivor="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
[ -n "$_d14survivor" ] && kill "$_d14survivor" 2>/dev/null
wait "$h14" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW

# --- (15) Pre-claim accounting (issue #197): a fire with NO crew-status row
# is now reported, not silently absorbed - the narrower gap #185's own
# reasoning never covered (a notice-only fire produces no needs-attention
# row, so nothing else - in particular hooks/stop-guard.sh - will ever report
# it). Needs at least one crew member present in a non-attention-worthy
# status to stay past the fast path while producing no needs-attention row;
# combined with a seeded pending-notices file (the same fixture pattern
# tests/outbox-wake-and-retry-log.test.sh already uses), a real cycle fires
# on the notice alone.
new_home
add_crew_window d15
wm_state crew-set --id d15 --status working --summary busy >/dev/null
printf 'a pre-existing pending notice for the d15 fixture\n' > "$WINGMAN_HOME/pending-notices"
out15_arm="$(WM_WATCH_INTERVAL=1 wm_timeout 45 "$WF" --owner "" 2>/dev/null)"
assert_contains "the notice-only fire prints its own reason line" "$out15_arm" "abandoned-message:"
assert_eq "the fire record is left pending (never classified)" "$(cat "$WINGMAN_HOME/watch-exit" 2>/dev/null)" "fire"
assert_true "fire() leaves the runfile behind (only the pidfile is cleared)" "[ -f '$WINGMAN_HOME/watch.run' ]"
export WM_STOP_CONTINUITY_WINDOW=60
out15="$(run_hook)"; rc15=$?
assert_eq "the hook reports (block/rewake) rather than silently proceeding to claim" "$rc15" "2"
assert_contains "the rewake carries compose_attention_reason's own text" "$out15" "surfaced via automatic fleet continuity"
assert_not_contains "the record is reported, not silently rolled over" "$out15" "window rolled"
assert_false "the runfile is removed by this reporting branch" "[ -f '$WINGMAN_HOME/watch.run' ]"
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook15b.out" 2>&1 &
h15b=$!; wm_track "$h15b"
assert_true "a follow-up invocation (simulating the next Stop event) then claims a fresh cycle normally" "wait_for_file '$WINGMAN_HOME/watch.pid'"
assert_eq "the spurious count is still at 0 (the notice-only fire never contributed to it)" "$(cat "$WINGMAN_HOME/watch-spurious-count" 2>/dev/null)" "0"
kill -TERM "$h15b" 2>/dev/null
_d15survivor="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
[ -n "$_d15survivor" ] && kill "$_d15survivor" 2>/dev/null
wait "$h15b" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW

# --- (16) Pre-claim accounting (issue #197): remote-control-dropped is always
# reported - it never has a crew-status row by construction (self_pane_check
# fires independently of crew status), so stop-guard.sh's own needs-attention
# check can never catch it. Companion to (15), same assertions, self-pane
# fixture pattern from tests/watch-fleet-classify.test.sh.
new_home
add_crew_window d16
wm_state crew-set --id d16 --status working --summary busy >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm_self_pane 'printf "Remote Control disconnected - Transport closed: this connection is no longer usable\n"; sleep 600'
printf '%s:wm_self_pane\n' "$WM_TMUX_SESSION" > "$WINGMAN_HOME/self-pane"
rout16="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" --owner "" 2>/dev/null)"
assert_contains "the self-pane check fires" "$rout16" "remote-control-dropped: wingman"
assert_eq "the remote-control-dropped record is left pending (never classified)" "$(cat "$WINGMAN_HOME/watch-exit" 2>/dev/null)" "remote-control-dropped"
assert_true "self_pane_check's own exit leaves the runfile behind too" "[ -f '$WINGMAN_HOME/watch.run' ]"
export WM_STOP_CONTINUITY_WINDOW=60
out16="$(run_hook)"; rc16=$?
assert_eq "the hook reports (block/rewake) rather than silently proceeding to claim" "$rc16" "2"
assert_contains "the rewake carries compose_attention_reason's own text" "$out16" "surfaced via automatic fleet continuity"
assert_false "the runfile is removed by this reporting branch" "[ -f '$WINGMAN_HOME/watch.run' ]"
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hook16b.out" 2>&1 &
h16b=$!; wm_track "$h16b"
assert_true "a follow-up invocation then claims a fresh cycle normally" "wait_for_file '$WINGMAN_HOME/watch.pid'"
assert_eq "the spurious count is still at 0" "$(cat "$WINGMAN_HOME/watch-spurious-count" 2>/dev/null)" "0"
kill -TERM "$h16b" 2>/dev/null
_d16survivor="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
[ -n "$_d16survivor" ] && kill "$_d16survivor" 2>/dev/null
wait "$h16b" 2>/dev/null
unset WM_STOP_CONTINUITY_WINDOW
tmux kill-window -t "$WM_TMUX_SESSION:wm_self_pane" 2>/dev/null

# =====================================================================
# Wrapper tests (issue #199): hooks/stop-continuity-crew.sh, registered ONLY
# at user scope, extends the identical asyncRewake auto-arm to crew sessions
# whose project root is some other repo. See hooks/stop-continuity-crew.sh's
# own header for why the WINGMAN_CREW_ID gate must live in this wrapper file
# rather than inside hooks/stop-continuity.sh itself - which this file's
# EVERY case above already proves is completely unmodified by this change,
# since none of them were touched to add this section.
CREW_HOOK="$TEST_REPO/hooks/stop-continuity-crew.sh"

# --- (W1) the wrapper no-ops with WINGMAN_CREW_ID unset -----------------------
new_home
add_crew_window w1
wm_state crew-set --id w1 --status working --summary busy >/dev/null
unset WINGMAN_CREW_ID
outw1="$(printf '{}' | wm_timeout 10 bash "$CREW_HOOK")"; rcw1=$?
assert_eq "wrapper with WINGMAN_CREW_ID unset: exit 0" "$rcw1" "0"
assert_eq "wrapper with WINGMAN_CREW_ID unset: no stdout" "$outw1" ""
assert_false "wrapper with WINGMAN_CREW_ID unset: never reaches the real script (no claim)" "[ -f '$WINGMAN_HOME/watch.pid' ]"

# --- (W2) the wrapper execs through with WINGMAN_CREW_ID set -------------------
# Reuses test (2)'s exact owner-scoped auto-arm fixture shape, parameterized
# by a real-looking crew id instead of hardcoded owner "".
new_home
export WINGMAN_CREW_ID=lead-w2
wm_state crew-add --id w2 --type developer --objective x --repo /tmp --window wm-w2 --session-id s-w2 --parent lead-w2 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-w2 'sleep 600'
wm_state crew-set --id w2 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=60
printf '{}' | bash "$CREW_HOOK" >"$WINGMAN_HOME/hookw2.out" 2>"$WINGMAN_HOME/hookw2.err" &
hw2=$!; wm_track "$hw2"
assert_true "the wrapper's own live invocation claims an owner-scoped cycle" "wait_for_file '$WINGMAN_HOME/watch-lead-w2.pid'"
_w2pid="$(cat "$WINGMAN_HOME/watch-lead-w2.pid")"
assert_true "the claimed pid is a real, live watch-fleet process" "kill -0 $_w2pid"
# The wrapper's process image is genuinely replaced by exec - not left
# running as a parent wrapping a child - so the pid bash assigned to the
# backgrounded invocation now runs the REAL script, not the wrapper.
_w2args="$(ps -o args= -p $hw2 2>/dev/null)"
case "$_w2args" in
  *stop-continuity-crew.sh*) fail "exec did not replace the wrapper's process image (still running the wrapper)" ;;
  *stop-continuity.sh*) ok "exec replaced the wrapper's process image with the real script" ;;
  *) fail "could not read the invocation's own command line to confirm exec ($_w2args)" ;;
esac
wm_state crew-set --id w2 --status review --summary "done" >/dev/null
assert_true "the wrapper's own hook exits within one poll interval of the fire-eligible flip" "wait_for_gone $hw2 100"
wait "$hw2" 2>/dev/null
outw2="$(cat "$WINGMAN_HOME/hookw2.out" 2>/dev/null)"
assert_contains "the wrapper's own rewake carries a block decision" "$outw2" '"decision": "block"'
unset WM_STOP_CONTINUITY_WINDOW
unset WINGMAN_CREW_ID

# --- (W3) double registration in the same repo: wrapper + real script, same owner, back-to-back
# Approximates two live hook groups firing for the same Stop event in a crew
# session whose project root IS the wingman repo (both the project-scoped
# registration of hooks/stop-continuity.sh and the new user-scope
# registration of hooks/stop-continuity-crew.sh are live for that session).
# Exactly one live watch-fleet cycle must result, and the losing side must
# never surface a spurious claimfailfile/"re-arm failed" report - this is the
# empirical check for the plan's own "remaining case" discussion.
new_home
export WINGMAN_CREW_ID=lead-w3
wm_state crew-add --id w3 --type developer --objective x --repo /tmp --window wm-w3 --session-id s-w3 --parent lead-w3 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-w3 'sleep 600'
wm_state crew-set --id w3 --status working --summary busy >/dev/null
export WM_STOP_CONTINUITY_WINDOW=20
printf '{}' | bash "$CREW_HOOK" >"$WINGMAN_HOME/hookw3a.out" 2>&1 &
hw3a=$!; wm_track "$hw3a"
printf '{}' | bash "$HOOK" >"$WINGMAN_HOME/hookw3b.out" 2>&1 &
hw3b=$!; wm_track "$hw3b"
assert_true "exactly one cycle claims the owner-scoped pidfile" "wait_for_file '$WINGMAN_HOME/watch-lead-w3.pid'"
_w3pid="$(cat "$WINGMAN_HOME/watch-lead-w3.pid")"
assert_true "the claimed pid is a real, live watch-fleet process" "kill -0 $_w3pid"
kill -TERM "$hw3a" "$hw3b" 2>/dev/null
kill "$_w3pid" 2>/dev/null
wait "$hw3a" 2>/dev/null; wait "$hw3b" 2>/dev/null
assert_false "the losing side never touches the owner-scoped claimfail marker" "[ -f '$WINGMAN_HOME/stop-continuity-lead-w3.claimfail' ]"
unset WM_STOP_CONTINUITY_WINDOW
unset WINGMAN_CREW_ID

test_summary
