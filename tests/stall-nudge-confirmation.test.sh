#!/usr/bin/env bash
# E2E: issue #236 - the stall self-heal nudge marker must mean "confirmed, for
# this episode", not merely "an attempt was made, ever". Both defect
# reproductions from the plan's section 2, inverted into regression coverage,
# plus the retry path and the marker upgrade path they depend on. All driven
# through the real bin/watch-fleet against a real tmux window and the shared
# composer stub fixture (tests/fixtures/composer-stub.sh), so a submission is
# proven by a genuine SUBMITTED line rather than by grepping scrollback for
# text that may only have been typed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"

WF="$TEST_REPO/bin/watch-fleet"
COMPOSER_STUB="$TEST_REPO/tests/fixtures/composer-stub.sh"
export WM_WATCH_INTERVAL=1

# Small submit knobs throughout, so a composer-leaving attempt (and its own
# internal WM_SUBMIT_TRIES retry loop) resolves quickly - this file drives
# several attempts per case where composer-confirm-delivery.test.sh only ever
# needs one.
export WM_SUBMIT_DELAY=0.3 WM_READY_POLL=0.3 WM_SUBMIT_POLL=0.3 WM_READY_TRIES=15 WM_SUBMIT_TRIES=3

marker_state()    { awk '{print $1}' "$1" 2>/dev/null; }
marker_attempts()  { awk '{print $2}' "$1" 2>/dev/null; }
marker_clock()     { awk '{print $3}' "$1" 2>/dev/null; }

# --- case 1: confirmed path - marker state, single submit, empty composer ----
test_new_home
SN1_MARKER="$(wm_mktemp_file)"
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id sn1 --type developer --objective x --repo /tmp --window wm-sn1 --session-id ssn1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-sn1 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$SN1_MARKER' bash '$COMPOSER_STUB'"
sleep 1
wm_age_status sn1
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  "$WF" >"$WINGMAN_HOME/sn1.log" 2>&1 &
sn1pid=$!
wm_track "$sn1pid"
nudgefile1="$WINGMAN_HOME/stall-sn1.nudged"
_wait=0
while [ ! -f "$nudgefile1" ] && [ "$_wait" -lt 30 ]; do sleep 1; _wait=$((_wait+1)); done
assert_true "the marker appears" "[ -f '$nudgefile1' ]"
assert_eq "the marker state is confirmed" "$(marker_state "$nudgefile1")" "confirmed"
assert_eq "exactly one SUBMITTED line" "$(grep -c SUBMITTED "$SN1_MARKER")" "1"
sn1_region="$(wm_composer_text_in "$(wm_tmux_pane_text "$WM_TMUX_SESSION:wm-sn1")")"
sn1_empty=0; wm_composer_is_empty "$sn1_region" && sn1_empty=1
assert_eq "the composer is empty after delivery" "$sn1_empty" "1"
assert_contains "nudged_at was stamped" "$(wm_state crew-get --id sn1)" '"nudged_at"'
i=0; while kill -0 "$sn1pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher exited on the stall once the wait window elapsed" "kill -0 $sn1pid"
assert_contains "cycle exits with the stalled reason" "$(cat "$WINGMAN_HOME/sn1.log")" "stalled: sn1"
assert_contains "reason states a check-in nudge already ran, confirmed" \
  "$(cat "$WINGMAN_HOME/sn1.log")" "even after a check-in nudge"
kill "$sn1pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- case 2: unconfirmed path - bounded retry, honest escalation -------------
# WM_TEST_SWALLOW=1: the composer stub never registers Enter, matching what
# the real self-heal nudge sees against a genuinely wedged pane's input.
test_new_home
SN2_MARKER="$(wm_mktemp_file)"
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id sn2 --type developer --objective y --repo /tmp --window wm-sn2 --session-id ssn2 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-sn2 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=1 WM_TEST_MARKER='$SN2_MARKER' bash '$COMPOSER_STUB'"
sleep 1
wm_age_status sn2
# WM_STALL_NUDGE_TTL is set generously and decoupled from WM_STALL_IDLE here:
# each attempt costs roughly one full WM_STALL_IDLE window of re-accumulated
# pane silence before it can fire (by design - 3.4), so at a compressed
# WM_STALL_IDLE this case's own two-attempt-plus-escalation timeline can
# otherwise approach the TTL's derived default and flake - that TTL-vs-timing
# interaction is TTL expiry's own concern (case 3 below), not this case's.
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  WM_STALL_NUDGE_TRIES=2 WM_STALL_NUDGE_TTL=120 \
  "$WF" >"$WINGMAN_HOME/sn2.log" 2>&1 &
sn2pid=$!
wm_track "$sn2pid"
nudgefile2="$WINGMAN_HOME/stall-sn2.nudged"
_wait=0
while [ ! -f "$nudgefile2" ] && [ "$_wait" -lt 30 ]; do sleep 1; _wait=$((_wait+1)); done
assert_true "the marker appears after attempt 1" "[ -f '$nudgefile2' ]"
assert_eq "attempt 1: marker state is pending" "$(marker_state "$nudgefile2")" "pending"
assert_eq "attempt 1: marker attempts is 1" "$(marker_attempts "$nudgefile2")" "1"
assert_true "watcher keeps blocking (flip gate closed during retry)" "kill -0 $sn2pid"
assert_contains "member is still working after attempt 1" \
  "$(wm_state crew-get --id sn2)" '"status": "working"'
sn2_clock1="$(marker_clock "$nudgefile2")"
sn2_enters1="$(grep -c ENTER "$SN2_MARKER")"

# Wait for the second, budget-exhausting attempt (attempts reaches TRIES=2).
_wait=0
while [ "$(marker_attempts "$nudgefile2")" != "2" ] && [ "$_wait" -lt 30 ]; do sleep 1; _wait=$((_wait+1)); done
assert_eq "attempt 2: marker attempts reaches the TRIES budget" "$(marker_attempts "$nudgefile2")" "2"
assert_eq "attempt 2: marker state is still pending (never confirmed)" "$(marker_state "$nudgefile2")" "pending"
assert_eq "the clock is never advanced by a retry" "$(marker_clock "$nudgefile2")" "$sn2_clock1"
sn2_enters2="$(grep -c ENTER "$SN2_MARKER")"
assert_true "a second attempt was genuinely made (more Enters than after attempt 1)" \
  "[ $sn2_enters2 -gt $sn2_enters1 ]"
assert_eq "nothing was ever actually submitted" "$(grep -c SUBMITTED "$SN2_MARKER")" "0"

# The give-up cleanup holds the send lock and fires a Ctrl-C once the budget is
# exhausted; the stub clears its buffer on ANY Ctrl-C (even under
# WM_TEST_SWALLOW=1), so an empty composer here proves the cleanup ran - NOT
# that a real wedged pane's composer is reliably cleared (docs/runbooks/
# incidents.md says as much to the operator).
sn2_region="$(wm_composer_text_in "$(wm_tmux_pane_text "$WM_TMUX_SESSION:wm-sn2")")"
sn2_empty=0; wm_composer_is_empty "$sn2_region" && sn2_empty=1
assert_eq "the give-up cleanup fired (composer empty, proving the clear ran)" "$sn2_empty" "1"

i=0; while kill -0 "$sn2pid" 2>/dev/null && [ "$i" -lt 45 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher exited once the budget-exhausted marker aged past threshold" "kill -0 $sn2pid"
sn2log="$(cat "$WINGMAN_HOME/sn2.log")"
assert_contains "cycle exits with the stalled reason" "$sn2log" "stalled: sn2"
assert_contains "reason states the submit was never confirmed" "$sn2log" "the submit was never confirmed"
assert_not_contains "reason does NOT claim a nudge already ran" "$sn2log" "even after a check-in nudge"
assert_not_contains "nudged_at was never stamped" "$(wm_state crew-get --id sn2)" '"nudged_at"'
kill "$sn2pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- case 3: TTL expiry (Defect B regression) - a stale marker never gates ---
# an unrelated later episode. Two sub-cases: a well-formed stale marker, and a
# legacy (pre-#236, empty) one - proving the migration path in the design is
# exercised, not merely assumed.
test_new_home
SN3_MARKER="$(wm_mktemp_file)"
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id sn3 --type developer --objective z --repo /tmp --window wm-sn3 --session-id ssn3 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-sn3 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$SN3_MARKER' bash '$COMPOSER_STUB'"
nudgefile3="$WINGMAN_HOME/stall-sn3.nudged"
printf 'confirmed 0 %d\n' "$(( $(date +%s) - 1000 ))" > "$nudgefile3"
sleep 1
wm_age_status sn3
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 WM_STALL_NUDGE_TTL=12 \
  "$WF" >"$WINGMAN_HOME/sn3.log" 2>&1 &
sn3pid=$!
wm_track "$sn3pid"
_wait=0
while [ "$(grep -c SUBMITTED "$SN3_MARKER" 2>/dev/null)" != "1" ] && [ "$_wait" -lt 30 ]; do sleep 1; _wait=$((_wait+1)); done
assert_eq "a fresh nudge was genuinely sent and confirmed" "$(grep -c SUBMITTED "$SN3_MARKER")" "1"
# The stub records SUBMITTED the instant Enter registers, slightly ahead of
# watch-fleet's own confirm-loop poll that observes the empty composer and
# writes the marker - give that a few extra polls to land.
_wait=0
while [ "$(marker_state "$nudgefile3")" != "confirmed" ] && [ "$_wait" -lt 10 ]; do sleep 1; _wait=$((_wait+1)); done
assert_eq "the reaped marker is rewritten as confirmed" "$(marker_state "$nudgefile3")" "confirmed"
sn3_clock="$(marker_clock "$nudgefile3")"
sn3_now="$(date +%s)"
assert_true "the marker's clock is current, not the stale one" "[ $((sn3_now - sn3_clock)) -lt 30 ]"
kill "$sn3pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_new_home
SN3B_MARKER="$(wm_mktemp_file)"
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id sn3b --type developer --objective z --repo /tmp --window wm-sn3b --session-id ssn3b >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-sn3b \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$SN3B_MARKER' bash '$COMPOSER_STUB'"
nudgefile3b="$WINGMAN_HOME/stall-sn3b.nudged"
: > "$nudgefile3b"
wm_age_path "$nudgefile3b" 1000
sleep 1
wm_age_status sn3b
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 WM_STALL_NUDGE_TTL=12 \
  "$WF" >"$WINGMAN_HOME/sn3b.log" 2>&1 &
sn3bpid=$!
wm_track "$sn3bpid"
_wait=0
while [ "$(grep -c SUBMITTED "$SN3B_MARKER" 2>/dev/null)" != "1" ] && [ "$_wait" -lt 30 ]; do sleep 1; _wait=$((_wait+1)); done
assert_eq "a stale legacy (empty) marker also gets a fresh confirmed nudge" \
  "$(grep -c SUBMITTED "$SN3B_MARKER")" "1"
_wait=0
while [ "$(marker_state "$nudgefile3b")" != "confirmed" ] && [ "$_wait" -lt 10 ]; do sleep 1; _wait=$((_wait+1)); done
assert_eq "the reaped legacy marker is rewritten as confirmed" "$(marker_state "$nudgefile3b")" "confirmed"
kill "$sn3bpid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- case 4: legacy marker, in flight - the upgrade-safety case --------------
# A legacy empty marker with a RECENT mtime is read exactly as a pre-#236
# 'confirmed' marker at that age, and flips on schedule with today's reason
# text - no re-nudge storm, no stuck member. No composer stub needed: since
# the marker already reads 'confirmed', no send is ever attempted here.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id sn4 --type developer --objective z --repo /tmp --window wm-sn4 --session-id ssn4 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-sn4 'trap "" INT; sleep 600'
nudgefile4="$WINGMAN_HOME/stall-sn4.nudged"
: > "$nudgefile4"
sleep 1
wm_age_status sn4
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  "$WF" >"$WINGMAN_HOME/sn4.log" 2>&1 &
sn4pid=$!
wm_track "$sn4pid"
i=0; while kill -0 "$sn4pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher flips the member using the legacy marker's own age" "kill -0 $sn4pid"
sn4log="$(cat "$WINGMAN_HOME/sn4.log")"
assert_contains "cycle exits with the stalled reason" "$sn4log" "stalled: sn4"
assert_contains "today's reason text is used - the migration path is transparent" \
  "$sn4log" "even after a check-in nudge"
assert_false "the pane never received any nudge text (marker already read confirmed)" \
  "tmux capture-pane -p -t '$WM_TMUX_SESSION:wm-sn4' | grep -q 'Checking in'"
kill "$sn4pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
