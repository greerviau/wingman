#!/usr/bin/env bash
# E2E: wm_state usage-update/usage-decide, the persisted fleet-wide
# usage-quota-approach state machine (issue #24). No tmux needed - pure
# wm_state calls plus direct file reads against
# $WINGMAN_HOME/usage-limit-state.json, same fixture/lib.sh conventions as
# tests/api-outage-state.test.sh, the sibling state machine this one mirrors.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

state_field() {
  uv run --no-project --quiet python -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get(sys.argv[2]))
' "$WINGMAN_HOME/usage-limit-state.json" "$1"
}

future_epoch() { echo $(( $(date +%s) + "${1:-3600}" )); }
past_epoch()   { echo $(( $(date +%s) - "${1:-10}" )); }

# --- a fresh install has no state file: usage-update seeds one as clear ------
test_new_home
out="$(wm_state usage-update --owner "" --warn-threshold 80)"
assert_eq "no signal on a fresh install prints 'none'" "$out" "none"
assert_true "the state file is created" "[ -f '$WINGMAN_HOME/usage-limit-state.json' ]"
assert_eq "the seeded state is clear" "$(state_field state)" "clear"

# --- below-threshold reading never flips clear -> approaching -----------------
test_new_home
out="$(wm_state usage-update --owner "" --five-hour-pct 40 --five-hour-resets-at "$(future_epoch)" --warn-threshold 80)"
assert_eq "a below-threshold reading prints 'none'" "$out" "none"
assert_eq "state stays clear" "$(state_field state)" "clear"

# --- absent signal (no windows reported at all) is a no-op --------------------
test_new_home
out="$(wm_state usage-update --owner "" --warn-threshold 80)"
assert_eq "no windows reported at all prints 'none'" "$out" "none"
assert_eq "state stays clear" "$(state_field state)" "clear"

# --- crossing the threshold on five_hour flips clear -> approaching -----------
test_new_home
FUTURE="$(future_epoch)"
out="$(wm_state usage-update --owner "" --five-hour-pct 85 --five-hour-resets-at "$FUTURE" --warn-threshold 80)"
assert_eq "a crossing five_hour reading prints 'usage-limit-approaching'" "$out" "usage-limit-approaching"
assert_eq "state flips to approaching" "$(state_field state)" "approaching"
assert_eq "window is recorded" "$(state_field window)" "five_hour"
assert_eq "used_percentage is recorded" "$(state_field used_percentage)" "85.0"
assert_eq "resets_at is recorded" "$(state_field resets_at)" "$FUTURE.0"

# --- crossing the threshold on seven_day flips clear -> approaching too -------
test_new_home
FUTURE="$(future_epoch)"
out="$(wm_state usage-update --owner "" --seven-day-pct 95 --seven-day-resets-at "$FUTURE" --warn-threshold 80)"
assert_eq "a crossing seven_day reading prints 'usage-limit-approaching'" "$out" "usage-limit-approaching"
assert_eq "window is recorded as seven_day" "$(state_field window)" "seven_day"

# --- a same-state refresh (still approaching) never re-fires ------------------
test_new_home
FUTURE="$(future_epoch)"
wm_state usage-update --owner "" --five-hour-pct 85 --five-hour-resets-at "$FUTURE" --warn-threshold 80 >/dev/null
out2="$(wm_state usage-update --owner "" --five-hour-pct 90 --five-hour-resets-at "$FUTURE" --warn-threshold 80)"
assert_eq "a continued signal while already approaching prints 'none'" "$out2" "none"
assert_eq "state stays approaching" "$(state_field state)" "approaching"

# --- a reading whose resets_at has ALREADY PASSED never triggers clear ->
# approaching, even though used_percentage is well above threshold and the
# poll's own captured_at (this test's wall-clock "now") is fresh. -------------
test_new_home
PAST="$(past_epoch 5)"
out="$(wm_state usage-update --owner "" --five-hour-pct 99 --five-hour-resets-at "$PAST" --warn-threshold 80)"
assert_eq "an already-reset reading never triggers approaching" "$out" "none"
assert_eq "state stays clear" "$(state_field state)" "clear"

# --- usage-decide: wait -> paused ---------------------------------------------
test_new_home
FUTURE="$(future_epoch)"
wm_state usage-update --owner "" --five-hour-pct 85 --five-hour-resets-at "$FUTURE" --warn-threshold 80 >/dev/null
out="$(wm_state usage-decide --decision wait)"
assert_eq "usage-decide wait prints 'paused'" "$out" "paused"
assert_eq "state flips to paused" "$(state_field state)" "paused"
assert_true "decided_at is stamped" "[ \"$(state_field decided_at)\" != 'None' ]"

# --- usage-decide: continue -> acknowledged -----------------------------------
test_new_home
FUTURE="$(future_epoch)"
wm_state usage-update --owner "" --seven-day-pct 90 --seven-day-resets-at "$FUTURE" --warn-threshold 80 >/dev/null
out="$(wm_state usage-decide --decision continue)"
assert_eq "usage-decide continue prints 'acknowledged'" "$out" "acknowledged"
assert_eq "state flips to acknowledged" "$(state_field state)" "acknowledged"

# --- usage-decide against a non-approaching state is a defensive no-op -------
test_new_home
wm_state usage-update --owner "" --warn-threshold 80 >/dev/null   # seed a clear state file
out="$(wm_state usage-decide --decision wait)"
assert_eq "usage-decide against clear is a no-op" "$out" "no-op:clear"
assert_eq "state is left untouched (still clear)" "$(state_field state)" "clear"

# --- auto-clear: approaching -> clear automatically once resets_at passes,
# WITH NO usage-decide call in between (the slow-pilot case) - fires
# usage-limit-reset. -----------------------------------------------------------
test_new_home
NEAR_FUTURE="$(future_epoch 2)"
wm_state usage-update --owner "" --five-hour-pct 85 --five-hour-resets-at "$NEAR_FUTURE" --warn-threshold 80 >/dev/null
assert_eq "state is approaching before the reset" "$(state_field state)" "approaching"
sleep 3
out="$(wm_state usage-update --owner "" --warn-threshold 80)"
assert_eq "the poll after resets_at passes prints 'usage-limit-reset'" "$out" "usage-limit-reset"
assert_eq "state auto-clears to clear" "$(state_field state)" "clear"

# A late usage-decide against the now-auto-cleared state is a no-op, not a
# silent mutation of clear into paused/acknowledged.
out="$(wm_state usage-decide --decision wait)"
assert_eq "a late usage-decide after auto-clear is a no-op" "$out" "no-op:clear"
assert_eq "state remains clear" "$(state_field state)" "clear"

# --- auto-clear from paused fires usage-limit-reset too -----------------------
test_new_home
NEAR_FUTURE="$(future_epoch 2)"
wm_state usage-update --owner "" --five-hour-pct 85 --five-hour-resets-at "$NEAR_FUTURE" --warn-threshold 80 >/dev/null
wm_state usage-decide --decision wait >/dev/null
assert_eq "state is paused before the reset" "$(state_field state)" "paused"
sleep 3
out="$(wm_state usage-update --owner "" --warn-threshold 80)"
assert_eq "paused auto-clears and prints 'usage-limit-reset'" "$out" "usage-limit-reset"
assert_eq "state auto-clears to clear" "$(state_field state)" "clear"

# --- auto-clear from acknowledged is SILENT (prints 'none'), but the state
# file is still written back to clear - the fleet was never paused under
# "continue anyway", so there is nothing to announce, only bookkeeping. -------
test_new_home
NEAR_FUTURE="$(future_epoch 2)"
wm_state usage-update --owner "" --five-hour-pct 85 --five-hour-resets-at "$NEAR_FUTURE" --warn-threshold 80 >/dev/null
wm_state usage-decide --decision continue >/dev/null
assert_eq "state is acknowledged before the reset" "$(state_field state)" "acknowledged"
sleep 3
out="$(wm_state usage-update --owner "" --warn-threshold 80)"
assert_eq "acknowledged auto-clears silently ('none')" "$out" "none"
assert_eq "state is still written back to clear" "$(state_field state)" "clear"

# --- a below-threshold reading arriving after auto-clear does not resurrect
# the old approaching state - a fresh crossing is required. -------------------
test_new_home
NEAR_FUTURE="$(future_epoch 2)"
wm_state usage-update --owner "" --five-hour-pct 85 --five-hour-resets-at "$NEAR_FUTURE" --warn-threshold 80 >/dev/null
sleep 3
wm_state usage-update --owner "" --warn-threshold 80 >/dev/null
assert_eq "state is clear after the reset" "$(state_field state)" "clear"
FUTURE2="$(future_epoch)"
out="$(wm_state usage-update --owner "" --five-hour-pct 90 --five-hour-resets-at "$FUTURE2" --warn-threshold 80)"
assert_eq "a fresh crossing after auto-clear fires approaching again" "$out" "usage-limit-approaching"

test_summary
