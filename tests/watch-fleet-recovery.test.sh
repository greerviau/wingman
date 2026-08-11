#!/usr/bin/env bash
# E2E: the wake loop's recovery/detection paths. Proves Remote Control
# auto-recovery (a settled disconnect banner gets an automatic
# `/remote-control` retry typed into the pane, wingman- and crew-side, with
# cooldown against re-sending into a still-unresolved banner) and its
# interaction with an already-blocked member's own unrelated blocker; a
# SIGKILL'd singleton-lock holder is safely reclaimed (including the
# corrupted/zero-owner and real-genuinely-live-claimant edge cases); the
# pane-tail cache and resume-from-summary/permission-dialog wording; and the
# fleet-wide outage-detected/outage-cleared and proactive usage-limit-quota
# detection (including the sweep of long-dead sessions' usage/*.json files).
# One of three sibling files split from a single, much larger file (then named
# tests/watch-fleet.test.sh) once it became ~92% of the CI test job's own wall
# clock - see docs/analysis/2026-08-11-test-suite-slowness-investigation.md.
# See tests/watch-fleet.test.sh for the wake loop's core arm/fire/stall/
# permission-freeze semantics, and tests/watch-fleet-lifecycle.test.sh for
# ownership, self-correction, and the orphan-watcher-lifecycle self-checks.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
# For wm_tmux_send_message, used by the Remote Control auto-recovery cases
# below to type a real `/remote-control` retry into a pane rather than
# grepping tmux scrollback for text that may only have been typed.
. "$TEST_REPO/bin/lib/common.sh"

WF="$TEST_REPO/bin/watch-fleet"
COMPOSER_STUB="$TEST_REPO/tests/fixtures/composer-stub.sh"
export WM_WATCH_INTERVAL=1
# The watcher blocks until an event fires, so bound every foreground run with
# wm_timeout and reap any backgrounded one on exit (lib.sh's shared trap; every
# background pid here is registered via wm_track). A watcher that never fires
# can then never wedge this file or, through run.sh, the whole suite.

# --- Remote Control auto-recovery, crew-side (ask 2) --------------------------
# A settled disconnect banner (stable across two polls, same rule as the checks
# above) gets an automatic `/remote-control` retry typed into the member's own
# pane - the real disconnect banner text the CLI emits, confirmed in the design
# investigation. The retry lands as real keystrokes (visible via terminal echo
# even though the pane's own foreground command never reads them), so the fixed
# points are checkable directly off the capture.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rc1 --type developer --objective rc --repo /tmp --window wm-rc1 --session-id src1 >/dev/null
wm_state crew-set --id rc1 --status working --summary "building" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rc1 'trap "" INT; printf "Remote Control disconnected - Transport closed: this connection is no longer usable\n"; sleep 600'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
rcpid=$!
wm_track "$rcpid"
_wait=0
while ! tmux capture-pane -p -t "$WM_TMUX_SESSION:wm-rc1" 2>/dev/null | grep -q '/remote-control' && [ "$_wait" -lt 20 ]; do sleep 1; _wait=$((_wait+1)); done
assert_contains "a settled disconnect banner gets a /remote-control retry typed into its pane" \
  "$(tmux capture-pane -p -t "$WM_TMUX_SESSION:wm-rc1")" "/remote-control"
# The .sent marker is written only after wm_tmux_send_message's full
# submit-confirm sequence returns, which can trail the pane text above by a
# couple of seconds (WM_SUBMIT_DELAY + its confirm-poll retries) - poll rather
# than assert immediately.
_wait=0
while [ ! -f "$WINGMAN_HOME/rcdrop-rc1.sent" ] && [ "$_wait" -lt 20 ]; do sleep 1; _wait=$((_wait+1)); done
assert_true "the recovery attempt is cooldown-marked" "[ -f '$WINGMAN_HOME/rcdrop-rc1.sent' ]"
assert_contains "the member stays working - this is a quiet self-heal, not a status flip" \
  "$(wm_state crew-get --id rc1)" '"status": "working"'
kill "$rcpid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- no false positive: a clean pane is never sent the retry -------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rc2 --type developer --objective rc --repo /tmp --window wm-rc2 --session-id src2 >/dev/null
wm_state crew-set --id rc2 --status working --summary "building" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rc2 'while :; do echo tick; sleep 1; done'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
rc2pid=$!
wm_track "$rc2pid"
sleep 6
assert_false "a clean pane never gets the /remote-control retry" \
  "tmux capture-pane -p -t '$WM_TMUX_SESSION:wm-rc2' | grep -q '/remote-control'"
assert_true "watcher keeps blocking on a clean pane" "kill -0 $rc2pid"
kill "$rc2pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- cooldown: a still-unresolved banner is not retried every cycle ------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rc3 --type developer --objective rc --repo /tmp --window wm-rc3 --session-id src3 >/dev/null
wm_state crew-set --id rc3 --status working --summary "building" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rc3 'trap "" INT; printf "Transport recovery exhausted (code 1006)\n"; sleep 600'
WM_RC_DROPPED_COOLDOWN=60 WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
rc3pid=$!
wm_track "$rc3pid"
_nudgefile="$WINGMAN_HOME/rcdrop-rc3.sent"
_wait=0
while [ ! -f "$_nudgefile" ] && [ "$_wait" -lt 20 ]; do sleep 1; _wait=$((_wait+1)); done
assert_true "the first retry is sent and marked" "[ -f '$_nudgefile' ]"
first_mtime="$(uv run --no-project --quiet python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$_nudgefile")"
sleep 5
second_mtime="$(uv run --no-project --quiet python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$_nudgefile")"
assert_eq "the retry is not re-sent within the cooldown window" "$first_mtime" "$second_mtime"
count="$(tmux capture-pane -p -t "$WM_TMUX_SESSION:wm-rc3" | grep -c '/remote-control')"
assert_eq "exactly one retry lands in the pane within the cooldown" "$count" "1"
kill "$rc3pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- Remote Control connection-state tracking, widened to review/stalled -----
# (issue #96). The pane-capture loop above was previously scoped to
# working/blocked only; bin/crew-standdown needs an already-vetted read for the
# actual population it hits (blocked/review/stalled), so the same
# stability-gated observation (PANE_STABLE, i.e. byte-identical across two
# consecutive polls) must also persist onto a `review` or `stalled` member's
# own roster record, not just working's auto-reconnect path.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rv1 --type developer --objective rv --repo /tmp --window wm-rv1 --session-id srv1 --remote-control >/dev/null
wm_state crew-set --id rv1 --status review --summary "plan ready" --artifact /tmp/plan.md >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rv1 'printf "Remote Control disconnected - Transport closed: this connection is no longer usable\n"; sleep 600'
# First cycle: the pilot-facing review delivery itself is the attention event
# and fires/exits immediately, before this poll's own capture can be confirmed
# stable (no prior hash exists yet) - remote_control_connected must be
# untouched (still true from spawn) after only one poll.
out_rv1="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "first cycle still fires on the pilot-facing review delivery" "$out_rv1" "review: rv1"
assert_contains "after only one poll, remote_control_connected is untouched (not yet flipped)" \
  "$(wm_state crew-get --id rv1)" '"remote_control_connected": true'
# Classify the first cycle's own unclassified fire before re-arming (issue
# #197: a bare re-arm over it now refuses instead of claiming).
cout_rv1="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "classify reports the pending review fire" "$cout_rv1" "fire"
# Second cycle: the review event is now acked (see fire()'s own ack step), so
# this run does not fire on it again and instead keeps blocking/looping - its
# very first internal iteration reuses the hash persisted by the first cycle
# above, confirming stability (PANE_STABLE=1) and persisting the drop.
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
rv1pid=$!
wm_track "$rv1pid"
sleep 4
assert_contains "a stable second sighting flips remote_control_connected to false for a review member" \
  "$(wm_state crew-get --id rv1)" '"remote_control_connected": false'
kill "$rv1pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# Same widened coverage for `stalled` (the other status crew-standdown might
# hit whose window is still alive).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id sl1 --type developer --objective sl --repo /tmp --window wm-sl1 --session-id ssl1 --remote-control >/dev/null
wm_state crew-set --id sl1 --status stalled --summary "no pane output, status update, running child process, or CPU activity" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-sl1 'printf "Transport recovery exhausted (code 1006)\n"; sleep 600'
out_sl1="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "first cycle still fires on the stalled event" "$out_sl1" "stalled: sl1"
assert_contains "after only one poll, remote_control_connected is untouched for a stalled member too" \
  "$(wm_state crew-get --id sl1)" '"remote_control_connected": true'
# Classify the first cycle's own unclassified fire before re-arming (issue
# #197: a bare re-arm over it now refuses instead of claiming).
cout_sl1="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "classify reports the pending stalled fire" "$cout_sl1" "fire"
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
sl1pid=$!
wm_track "$sl1pid"
sleep 4
assert_contains "a stable second sighting flips remote_control_connected to false for a stalled member" \
  "$(wm_state crew-get --id sl1)" '"remote_control_connected": false'
kill "$sl1pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# A member with remote_control=false (the crew-add default without
# --remote-control) is never touched, even with the identical banner and
# stable pane - the widened scan only writes the field when remote_control is
# actually true.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rv2 --type developer --objective rv --repo /tmp --window wm-rv2 --session-id srv2 >/dev/null
wm_state crew-set --id rv2 --status review --summary "plan ready" --artifact /tmp/plan2.md >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rv2 'printf "Remote Control disconnected - Transport closed: this connection is no longer usable\n"; sleep 600'
wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
rv2pid=$!
wm_track "$rv2pid"
sleep 4
assert_contains "remote_control=false is never touched by the widened scan" \
  "$(wm_state crew-get --id rv2)" '"remote_control_connected": null'
kill "$rv2pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# A `working` member's own successful auto-reconnect reflects back into the
# persisted field the same way a detected drop does - flipping it back to
# true, not just leaving the send itself as a quiet self-heal.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rc4 --type developer --objective rc --repo /tmp --window wm-rc4 --session-id src4 --remote-control >/dev/null
wm_state crew-set --id rc4 --status working --summary "building" >/dev/null
wm_state crew-set --id rc4 --remote-control-connected false >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rc4 'printf "Remote Control disconnected - Transport closed: this connection is no longer usable\n"; sleep 600'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
rc4pid=$!
wm_track "$rc4pid"
_wait=0
while [ ! -f "$WINGMAN_HOME/rcdrop-rc4.sent" ] && [ "$_wait" -lt 20 ]; do sleep 1; _wait=$((_wait+1)); done
assert_true "the reconnect attempt is sent and marked" "[ -f '$WINGMAN_HOME/rcdrop-rc4.sent' ]"
assert_contains "a successful self-heal flips remote_control_connected back to true" \
  "$(wm_state crew-get --id rc4)" '"remote_control_connected": true'
kill "$rc4pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- Remote Control disconnect, wingman-side (ask 2): detect-only, never inject --
# bin/wingman registers $TMUX_PANE into $WM_HOME/self-pane at startup; here the
# registration is simulated directly (the unit under test is watch-fleet's own
# read-only check, not bin/wingman's write). Scoped to the owner "" cycle only.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm_self_pane 'printf "Remote Control disconnected - Transport closed: this connection is no longer usable\n"; sleep 600'
printf '%s:wm_self_pane\n' "$WM_TMUX_SESSION" > "$WINGMAN_HOME/self-pane"
out_self="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "wingman's own disconnected pane fires the wake" "$out_self" "remote-control-dropped: wingman"
assert_contains "the wake file explains the reason" "$(cat "$WINGMAN_HOME/wake")" "Remote Control"
assert_false "wingman's own pane is never typed into (detect-only)" \
  "tmux capture-pane -p -t '$WM_TMUX_SESSION:wm_self_pane' | grep -q '^/remote-control$'"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- the wingman-side check fires once per distinct banner, not every cycle ----
# An unresolved, unchanging banner is surfaced once (hash-deduped against
# $WM_HOME/self-pane.fired) rather than re-waking wingman every cycle until the
# pilot acts - re-arming after the first fire on the SAME still-broken pane must
# not immediately refire.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm_self_pane2 'printf "Remote Control disconnected - Transport closed: this connection is no longer usable\n"; sleep 600'
printf '%s:wm_self_pane2\n' "$WM_TMUX_SESSION" > "$WINGMAN_HOME/self-pane"
wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1
# Classify the first cycle's own unclassified remote-control-dropped record
# before re-arming (issue #197: a bare re-arm over it now refuses instead of
# claiming).
cout_self="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "classify reports the pending remote-control-dropped fire" "$cout_self" "remote-control-dropped"
"$WF" >"$WINGMAN_HOME/rearm.log" 2>&1 &
rearm_pid=$!
wm_track "$rearm_pid"
sleep 5
assert_true "a second arm on the same unresolved banner keeps blocking, not re-firing" "kill -0 $rearm_pid"
kill "$rearm_pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- an already-blocked member also gets caught by a NEW dialog freeze --------
# The pane backstop used to scan only "working" members, so a member already
# blocked for an unrelated reason (e.g. awaiting a decision) that then freezes on
# a fresh permission/confirmation dialog was invisible - it never got a second
# look. This is a real incident shape: a developer already blocked on a
# reboot-approval question got frozen on a confirmation dialog afterward and
# nothing caught it. Proves the backstop now also scans "blocked" members and
# supersedes the stale blocker reason with the freeze diagnosis once the dialog
# shape is confirmed stable.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id zb1 --type developer --objective j --repo /tmp --window wm-zb1 --session-id s15 >/dev/null
wm_state crew-set --id zb1 --status blocked --blocker "need a decision about the reboot" >/dev/null
# Ack the original blocked event so only a genuinely NEW event (the freeze
# rewriting the blocker) is what the assertions below catch.
na_zb1="$(wm_state needs-attention)"
upd_zb1="$(printf '%s\n' "$na_zb1" | cut -f3)"
wm_state ack --id zb1 --updated "$upd_zb1" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-zb1 'printf "Do you want to proceed?\n❯ 1. Yes\n  2. No, and tell it what to do differently\n"; sleep 600'
out15="$(wm_timeout 45 env WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 "$WF" 2>/dev/null)"
assert_contains "an already-blocked member frozen on a NEW dialog still fires" "$out15" "blocked: zb1"
assert_contains "the fire carries the fresh freeze note, not the stale blocker" "$out15" "frozen on a permission/trust prompt"
assert_contains "the member's blocker is superseded by the freeze diagnosis" "$(wm_state crew-get --id zb1)" "frozen on a permission/trust prompt"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- an already-blocked member's unrelated blocker is left untouched ----------
# The flip side of the case above: when the check now also looks at blocked
# members, a blocked member whose pane shows no dialog must not have its existing
# blocker reason clobbered, and must not manufacture a spurious re-fire (no dialog
# shape present, so needs-attention has nothing new to report once the original
# event is acked).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id zb2 --type developer --objective k --repo /tmp --window wm-zb2 --session-id s16 >/dev/null
wm_state crew-set --id zb2 --status blocked --blocker "need a decision about the deploy window" >/dev/null
na_zb2="$(wm_state needs-attention)"
upd_zb2="$(printf '%s\n' "$na_zb2" | cut -f3)"
wm_state ack --id zb2 --updated "$upd_zb2" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-zb2 'printf "waiting on the pilot, nothing else to do here\n"; sleep 600'
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 \
  "$WF" >/dev/null 2>&1 &
zb2_pid=$!
wm_track "$zb2_pid"
sleep 8
assert_true "watcher keeps blocking on a blocked member with no dialog present" "kill -0 $zb2_pid"
assert_contains "the unrelated blocker reason is left untouched" "$(wm_state crew-get --id zb2)" "need a decision about the deploy window"
kill "$zb2_pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a SIGKILL'd lock holder is reclaimed, twice in a row, each proven by its
# own fresh event (the core regression case, issue #74) ------------------------
test_new_home
wm_state crew-add --id sk1 --type analyst --objective x --repo /tmp --window wm-sk1 --session-id ssk1 >/dev/null
wm_state crew-set --id sk1 --status done --summary "finished round one" >/dev/null

mkdir "$WINGMAN_HOME/watch.pid.lock"
( sleep 100 ) & holder=$!
wm_track "$holder"
echo "$holder" > "$WINGMAN_HOME/watch.pid.lock/owner"
kill -9 "$holder"
wait "$holder" 2>/dev/null

out="$(wm_timeout 45 "$WF" 2>"$WINGMAN_HOME/stale.err")"
assert_contains "round 1: arm recovers and fires its real reason, not just exits 0" "$out" "done: sk1 finished round one"
assert_contains "round 1: watcher logs that it cleared a stale claim lock" "$(cat "$WINGMAN_HOME/stale.err")" "clearing a stale claim lock"
assert_false "round 1: the stale claim lock directory is gone after recovery" "[ -d \"$WINGMAN_HOME/watch.pid.lock\" ]"

# Classify round 1's own unclassified fire before round 2 begins (issue #197:
# a bare re-arm over it now refuses instead of claiming).
cout_sk1="$(wm_timeout 10 "$WF" --classify 2>/dev/null)"
assert_eq "round 1's fire is classified before round 2 begins" "$cout_sk1" "fire"

# Round 2: mint a genuinely NEW, unacked event (bumping sk1's `updated` stamp
# via working -> done again) and fabricate a second, independent stale lock -
# proving recovery is repeatable, not a one-shot fluke tied to the first pid.
wm_state crew-set --id sk1 --status working --summary "back to work" >/dev/null
wm_state crew-set --id sk1 --status done --summary "finished round two" >/dev/null
mkdir "$WINGMAN_HOME/watch.pid.lock"
( sleep 100 ) & holder2=$!
wm_track "$holder2"
echo "$holder2" > "$WINGMAN_HOME/watch.pid.lock/owner"
kill -9 "$holder2"
wait "$holder2" 2>/dev/null

out2="$(wm_timeout 45 "$WF" 2>"$WINGMAN_HOME/stale2.err")"
assert_contains "round 2: a second, independent stale lock also recovers" "$out2" "done: sk1 finished round two"
assert_false "round 2: the stale claim lock directory is gone again" "[ -d \"$WINGMAN_HOME/watch.pid.lock\" ]"

# --- a genuinely live (slow) claimant is left alone, not clobbered (#74) -------
test_new_home
wm_state crew-add --id sk2 --type analyst --objective x --repo /tmp --window wm-sk2 --session-id ssk2 >/dev/null
mkdir "$WINGMAN_HOME/watch.pid.lock"
( sleep 100 ) & liveholder=$!
wm_track "$liveholder"
echo "$liveholder" > "$WINGMAN_HOME/watch.pid.lock/owner"
out2="$(wm_timeout 45 "$WF" 2>"$WINGMAN_HOME/live.err")"; rc2=$?
assert_eq "arm still dies loudly against a genuinely live holder" "$rc2" "1"
assert_contains "die message names the claim lock" "$(cat "$WINGMAN_HOME/live.err")" "could not acquire the claim lock"
assert_true "the live holder's lock directory is left in place, not clobbered" "[ -d \"$WINGMAN_HOME/watch.pid.lock\" ]"
kill "$liveholder" 2>/dev/null

# --- a lock past the hard-age override reclaims despite a live (reused/
# unrelated) owner pid (#74) ---------------------------------------------------
# WM_CLAIM_HARD_STALE_AGE is shrunk to a value well below its own 60s default -
# setting it to the default would be a no-op that proves nothing - and scoped
# to an explicit subshell so the assignment cannot leak into the rest of the
# test file (a bare `VAR=value wm_timeout ...` prefix is safe for an external
# command but is not a reliable scoping idiom for a shell function under
# bash, which wm_timeout is).
test_new_home
wm_state crew-add --id sk3 --type analyst --objective x --repo /tmp --window wm-sk3 --session-id ssk3 >/dev/null
wm_state crew-set --id sk3 --status done --summary "finished despite pid reuse" >/dev/null
mkdir "$WINGMAN_HOME/watch.pid.lock"
( sleep 100 ) & unrelated=$!
wm_track "$unrelated"
echo "$unrelated" > "$WINGMAN_HOME/watch.pid.lock/owner"
wm_age_path "$WINGMAN_HOME/watch.pid.lock" 30   # back-date well past the shrunk hard-stale-age (10s) below
(
  WM_CLAIM_HARD_STALE_AGE=10
  export WM_CLAIM_HARD_STALE_AGE
  wm_timeout 45 "$WF" >"$WINGMAN_HOME/reuse.out" 2>"$WINGMAN_HOME/reuse.err"
)
out3="$(cat "$WINGMAN_HOME/reuse.out")"
assert_contains "a lock past the hard-stale-age reclaims despite a live (reused) owner pid" "$out3" "done: sk3 finished despite pid reuse"
kill "$unrelated" 2>/dev/null

# --- a corrupted owner value is never handed to kill -0 as a literal pid (#74) -
test_new_home
wm_state crew-add --id sk4 --type analyst --objective x --repo /tmp --window wm-sk4 --session-id ssk4 >/dev/null
wm_state crew-set --id sk4 --status done --summary "finished despite corrupt owner stamp" >/dev/null
mkdir "$WINGMAN_HOME/watch.pid.lock"
echo "-1" > "$WINGMAN_HOME/watch.pid.lock/owner"
out4="$(wm_timeout 45 "$WF" 2>"$WINGMAN_HOME/corrupt.err")"
assert_contains "a corrupt (-1) owner stamp is treated as dead, not as a live process-group target" "$out4" "done: sk4 finished despite corrupt owner stamp"
assert_contains "corrupt-owner recovery is logged" "$(cat "$WINGMAN_HOME/corrupt.err")" "clearing a stale claim lock"

# --- an owner stamp of "0" is never handed to kill -0 as a process-group
# target (issue #87) ------------------------------------------------------------
test_new_home
wm_state crew-add --id sk4b --type analyst --objective x --repo /tmp --window wm-sk4b --session-id ssk4b >/dev/null
wm_state crew-set --id sk4b --status done --summary "finished despite owner-0 stamp" >/dev/null
mkdir "$WINGMAN_HOME/watch.pid.lock"
echo "0" > "$WINGMAN_HOME/watch.pid.lock/owner"
out4b="$(wm_timeout 45 "$WF" 2>"$WINGMAN_HOME/owner0.err")"
assert_contains "an owner-0 stamp is treated as dead, not as the caller's own process group" "$out4b" "done: sk4b finished despite owner-0 stamp"
assert_contains "owner-0 recovery is logged" "$(cat "$WINGMAN_HOME/owner0.err")" "clearing a stale claim lock"

# --- fidelity case: a real watch-fleet process, genuinely SIGKILL'd while
# holding the claim lock (#74) --------------------------------------------------
# Cases above fabricate the on-disk state directly; this proves that shape is
# what a real SIGKILL actually leaves behind. The poll below is bounded by
# wall-clock time (not iteration count): a freshly forked watch-fleet needs on
# the order of 200ms of real startup latency (fork/exec, sourcing common.sh,
# mode dispatch, then reaching the claim loop) before its owner stamp appears,
# so a fixed iteration count with no sleep can burn its whole budget before
# that latency has even elapsed.
test_new_home
wm_state crew-add --id fid1 --type analyst --objective x --repo /tmp --window wm-fid1 --session-id sfid1 >/dev/null
wm_state crew-set --id fid1 --status working --summary "in progress" >/dev/null

"$WF" >"$WINGMAN_HOME/fid-a.log" 2>&1 &
victim=$!
wm_track "$victim"

_fid_caught=0
for _fid_attempt in 1 2 3; do
  _fid_deadline=$(( $(date +%s) + 3 ))
  while [ "$(date +%s)" -lt "$_fid_deadline" ]; do
    if [ -s "$WINGMAN_HOME/watch.pid.lock/owner" ]; then
      kill -9 "$victim" 2>/dev/null
      wait "$victim" 2>/dev/null
      # Confirm the kill actually landed before the victim could release the
      # lock on its own - if the directory is already gone, the race was lost
      # despite catching the owner stamp; fall through to the retry below
      # exactly as if the poll had never caught it at all.
      [ -d "$WINGMAN_HOME/watch.pid.lock" ] && _fid_caught=1
      break
    fi
    sleep 0.01
  done
  [ "$_fid_caught" -eq 1 ] && break
  # Lost the race (the holder released before the poll noticed, or before the
  # kill signal was delivered) - retry with a fresh arm rather than flaking
  # the whole test.
  kill "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
  rm -rf "$WINGMAN_HOME/watch.pid" "$WINGMAN_HOME/watch.pid.lock"
  "$WF" >"$WINGMAN_HOME/fid-a.log" 2>&1 &
  victim=$!
  wm_track "$victim"
done
assert_true "caught a real watch-fleet mid-claim and killed it" "[ \"$_fid_caught\" -eq 1 ]"
assert_true "the real SIGKILL leaves the mkdir'd lock dir behind" "[ -d \"$WINGMAN_HOME/watch.pid.lock\" ]"
assert_true "the real SIGKILL leaves the owner stamp behind" "[ -s \"$WINGMAN_HOME/watch.pid.lock/owner\" ]"
assert_eq "the leaked owner stamp names the real killed watcher's own pid" "$(cat "$WINGMAN_HOME/watch.pid.lock/owner")" "$victim"

wm_state crew-set --id fid1 --status done --summary "finished for real" >/dev/null
out_fid="$(wm_timeout 45 "$WF" 2>"$WINGMAN_HOME/fid.err")"
assert_contains "the next real arm recovers from the real leaked lock" "$out_fid" "done: fid1 finished for real"
assert_contains "the recovery is logged" "$(cat "$WINGMAN_HOME/fid.err")" "clearing a stale claim lock"

# --- pane-tail cache is written for a live working member (#23, item 1) ------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id pt1 --type developer --objective pt --repo /tmp --window wm-pt1 --session-id spt1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-pt1 'echo "Error: overloaded_error (529)"; sleep 600'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
ptpid=$!
wm_track "$ptpid"
sleep 3
assert_true "the pane-tail cache file appears" "[ -f '$WINGMAN_HOME/pane-tail-pt1.txt' ]"
assert_contains "the pane-tail cache holds the pane's own tail text" \
  "$(cat "$WINGMAN_HOME/pane-tail-pt1.txt")" "overloaded_error"
kill "$ptpid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- the resume-from-summary prompt (#23/#30) is recognized as a distinct
# dialog shape, blocked with its own wording, never the generic permission
# wording ---------------------------------------------------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rp1 --type developer --objective rp --repo /tmp --window wm-rp1 --session-id srp1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rp1 'printf "We recommend resuming from a summary of the conversation.\n\n1. Resume from summary (recommended)\n2. Resume full session as-is\n3. Dont ask me again\n"; sleep 600'
wm_age_status rp1
out_rp="$(wm_timeout 45 env WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 "$WF" 2>/dev/null)"
assert_contains "resume-prompt freeze fires as blocked" "$out_rp" "blocked: rp1"
assert_contains "the blocker names issue #30 and the resume-from-summary prompt" \
  "$(wm_state crew-get --id rp1)" "resume-from-summary prompt (issue #30)"
assert_false "the blocker does NOT use the generic permission/trust wording" \
  "wm_state crew-get --id rp1 | grep -q 'permission/trust prompt'"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- an ordinary permission dialog still gets the generic wording, not the
# resume-from-summary wording (no cross-talk between the two phrase sets) -----
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id rp2 --type developer --objective rq --repo /tmp --window wm-rp2 --session-id srp2 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rp2 'printf "Do you want to proceed?\n❯ 1. Yes\n  2. No\n"; sleep 600'
wm_age_status rp2
out_rp2="$(wm_timeout 45 env WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 "$WF" 2>/dev/null)"
assert_contains "ordinary permission freeze still fires as blocked" "$out_rp2" "blocked: rp2"
assert_contains "the blocker keeps the generic permission/trust wording" \
  "$(wm_state crew-get --id rp2)" "permission/trust prompt"
assert_false "the blocker does NOT use the resume-from-summary wording" \
  "wm_state crew-get --id rp2 | grep -q 'resume-from-summary'"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- fleet-wide outage-detected/outage-cleared (#23, item 0) ------------------
# Owner "" is wingman's own top-level scope, exactly like every other test in
# this file (test_new_home already unsets WINGMAN_CREW_ID).

# Two of two live members showing the API-error signature crosses the default
# mass threshold (count>=2, ratio>=0.5) - the same collapse condition
# group-attention.test.sh exercises directly, here proven wired into the
# watcher's own blocking loop and fired as an ordinary `fire` (never a sixth
# --classify outcome).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id od1 --type developer --objective o --repo /tmp --window wm-od1 --session-id sod1 >/dev/null
wm_state crew-add --id od2 --type developer --objective p --repo /tmp --window wm-od2 --session-id sod2 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-od1 'echo "Error: overloaded_error (529)"; sleep 600'
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-od2 'echo "Error: overloaded_error (529)"; sleep 600'
out_od="$(wm_timeout 60 env WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 WM_OUTAGE_QUIET=3 "$WF" 2>/dev/null)"
assert_contains "outage-detected fires" "$out_od" "outage-detected:"
assert_contains "the fire note explains the pause" "$out_od" "new spawns paused"
assert_contains "outage state file flips to active" \
  "$(cat "$WINGMAN_HOME/api-outage-state.json")" '"state": "active"'
assert_contains "the wake file explains the outage" "$(cat "$WINGMAN_HOME/wake")" "API outage detected"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# issue #234 guard-placement check: the D1 liveness-probe guard must sit AFTER
# api_error_check, never above it, or _OUTAGE_API_SIGNALS silently stops
# counting a member the guard exempts from the nudge. od1/od2 above cannot
# tell a correct placement from an early one - neither of its fixtures holds a
# late-started descendant, so the guard never fires there. Here exactly one of
# two members (oe2) does, and the population size is load-bearing: the
# collapse condition is count>=2 AND ratio>=0.5, so with the guard correctly
# placed both members still signal (2 of 2, fires), while with the guard
# misplaced above api_error_check only oe1 signals (1 of 2 - count<2, does
# not fire). A third fixture added to od1/od2 instead would not discriminate
# (2 of 3 still satisfies both thresholds either way).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id oe1 --type developer --objective o --repo /tmp --window wm-oe1 --session-id soe1 >/dev/null
wm_state crew-add --id oe2 --type developer --objective p --repo /tmp --window wm-oe2 --session-id soe2 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-oe1 'echo "Error: overloaded_error (529)"; sleep 600'
# `& wait` keeps the pane root alive as the parent (a bare trailing command would
# be exec'd by the pane shell, collapsing the tree to one idle process).
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-oe2 'echo "Error: overloaded_error (529)"; sleep 4; sleep 600 & wait'
out_oe="$(wm_timeout 60 env WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 WM_OUTAGE_QUIET=3 "$WF" 2>/dev/null)"
assert_contains "outage-detected still fires with one exempt member counted" "$out_oe" "outage-detected:"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# active -> clear after WM_OUTAGE_QUIET seconds of zero signal, naming any
# outage-tagged died member(s) for the pre-authorized auto-resume.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id oc1 --type developer --objective q --repo /tmp --window wm-oc1 --session-id soc1 >/dev/null
# A live population is needed for the pre-seed's denominator (current_live +
# died-this-poll) to be nonzero - oc1 alone (already died, so out of
# LIVE_STATES) would otherwise divide by zero and never collapse regardless
# of --signal-working, exactly as cmd_outage_update's own `denom > 0` guard
# intends.
wm_state crew-add --id oc0 --type developer --objective r --repo /tmp --window wm-oc0 --session-id soc0 >/dev/null
wm_state crew-set --id oc1 --status died >/dev/null
uv run --no-project --quiet python -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for r in d:
    if r["id"] == "oc1":
        r["death_cause"] = "api-outage"
json.dump(d, open(p, "w"))
' "$WINGMAN_HOME/crew.json"
# Ack the pre-existing died event so the ordinary needs-attention/fire() path
# (which would otherwise re-surface oc1's own died status on iteration 1,
# racing ahead of the outage-cleared transition below - a real fleet would
# already have surfaced and acked this death long before the quiet window
# elapses) does not fire before the fleet-scoped outage-cleared check gets a
# chance to.
oc1_upd="$(wm_state crew-get --id oc1 | uv run --no-project --quiet python -c 'import json,sys; print(json.load(sys.stdin)["updated"])')"
wm_state ack --id oc1 --updated "$oc1_upd" >/dev/null
wm_state outage-update --owner "" --signal-working 5 --died "" \
  --mass-min-count 2 --mass-min-ratio 0.5 --quiet-seconds 3 >/dev/null
# oc0's own window must actually be live in tmux, or reconcile flips it to
# died too on the very first poll (defeating its purpose as the live
# population that keeps the denominator nonzero).
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-oc0 'sleep 600'
out_oc="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 WM_OUTAGE_QUIET=3 "$WF" 2>/dev/null)"
assert_contains "outage-cleared fires" "$out_oc" "outage-cleared:"
assert_contains "the fire note names the outage-tagged died member" "$out_oc" "oc1"
assert_contains "the fire note points at the pre-authorized resume" "$out_oc" "bin/crew-resume --all-died"
assert_contains "outage state file flips back to clear" \
  "$(cat "$WINGMAN_HOME/api-outage-state.json")" '"state": "clear"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- proactive usage-limit-quota detection (#24) ------------------------------
# Owner "" is wingman's own top-level scope, exactly like the outage tests
# above. Unlike outage detection, the signal here comes from
# $WM_HOME/usage/<session-id>.json files (written by the installed
# statusLine command), not pane text, so no tmux window content needs to
# match anything - only that a tmux session exists at all for the rest of
# the loop's own liveness checks to proceed normally.

# A fresh usage/*.json reading above the default 80% threshold, with a
# resets_at still in the future, fires usage-limit-approaching.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
mkdir -p "$WINGMAN_HOME/usage"
_ul_future=$(( $(date +%s) + 3600 ))
_ul_now_iso="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
cat > "$WINGMAN_HOME/usage/ul-sess1.json" <<EOF
{"five_hour": {"used_percentage": 85, "resets_at": $_ul_future}, "captured_at": "$_ul_now_iso"}
EOF
out_ua="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "usage-limit-approaching fires" "$out_ua" "usage-limit-approaching:"
assert_contains "the fire note names the 5-hour window" "$out_ua" "5-hour"
assert_contains "the fire note explains the pause" "$out_ua" "new spawns paused"
assert_contains "usage state file flips to approaching" \
  "$(cat "$WINGMAN_HOME/usage-limit-state.json")" '"state": "approaching"'
assert_contains "the wake file explains the approach" "$(cat "$WINGMAN_HOME/wake")" "Usage-limit quota approaching"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# approaching -> clear the moment resets_at passes, firing usage-limit-reset -
# advanced here by seeding the state file directly with an already-past
# resets_at (the same technique the auto-clear unit tests use), rather than
# waiting out a real wall-clock window inside the watcher loop.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
_ul_past=$(( $(date +%s) - 5 ))
cat > "$WINGMAN_HOME/usage-limit-state.json" <<EOF
{"state": "paused", "window": "five_hour", "used_percentage": 90, "resets_at": $_ul_past, "since": "2026-07-15T00:00:00.000000Z", "decided_at": "2026-07-15T00:05:00.000000Z"}
EOF
out_ur="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "usage-limit-reset fires" "$out_ur" "usage-limit-reset:"
assert_contains "usage state file flips back to clear" \
  "$(cat "$WINGMAN_HOME/usage-limit-state.json")" '"state": "clear"'
assert_contains "the wake file explains the reset" "$(cat "$WINGMAN_HOME/wake")" "Usage-limit window reset"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# A reading whose resets_at is ALREADY in the past at write time never fires
# usage-limit-approaching, even though used_percentage is well above
# threshold and the file itself is freshly written this instant.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
mkdir -p "$WINGMAN_HOME/usage"
_ul_past2=$(( $(date +%s) - 5 ))
_ul_now_iso2="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
cat > "$WINGMAN_HOME/usage/ul-sess2.json" <<EOF
{"five_hour": {"used_percentage": 99, "resets_at": $_ul_past2}, "captured_at": "$_ul_now_iso2"}
EOF
out_stale="$(wm_timeout 6 env WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_not_contains "an already-reset reading never fires usage-limit-approaching" "$out_stale" "usage-limit-approaching"
assert_contains "usage state file stays clear" \
  "$(cat "$WINGMAN_HOME/usage-limit-state.json")" '"state": "clear"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- usage/*.json sweep of long-dead sessions' files (#125, follow-up to #24) --
# The same aggregation pass removes usage/*.json files whose owning session
# has long since ended, so $WM_HOME/usage/ doesn't grow unboundedly for the
# lifetime of $WM_HOME.

# A file whose captured_at is older than a (test-overridden, small)
# WM_USAGE_SWEEP_SECS is removed by one poll cycle.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
mkdir -p "$WINGMAN_HOME/usage"
_ul_sweep_future=$(( $(date +%s) + 3600 ))
_ul_sweep_old_iso="$(uv run --no-project --quiet python -c '
import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=10)).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
')"
cat > "$WINGMAN_HOME/usage/ul-sweep-old.json" <<EOF
{"five_hour": {"used_percentage": 10, "resets_at": $_ul_sweep_future}, "captured_at": "$_ul_sweep_old_iso"}
EOF
wm_timeout 45 env WM_WATCH_INTERVAL=1 WM_USAGE_SWEEP_SECS=1 "$WF" >/dev/null 2>&1
assert_true "an old usage file (captured_at beyond WM_USAGE_SWEEP_SECS) is swept" \
  "[ ! -e \"$WINGMAN_HOME/usage/ul-sweep-old.json\" ]"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# A fresh file (current captured_at) survives a poll cycle under the default
# WM_USAGE_SWEEP_SECS (24h) - nowhere near old enough to sweep.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
mkdir -p "$WINGMAN_HOME/usage"
_ul_sweep_fresh_iso="$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"
cat > "$WINGMAN_HOME/usage/ul-sweep-fresh.json" <<EOF
{"five_hour": {"used_percentage": 10, "resets_at": $_ul_sweep_future}, "captured_at": "$_ul_sweep_fresh_iso"}
EOF
wm_timeout 6 env WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1
assert_true "a fresh usage file survives the sweep" \
  "[ -e \"$WINGMAN_HOME/usage/ul-sweep-fresh.json\" ]"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# A well-formed JSON dict with a missing/malformed captured_at can never
# contribute to the aggregate (captured is None), so it is swept the same as
# a too-old file - regardless of WM_USAGE_SWEEP_SECS.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
mkdir -p "$WINGMAN_HOME/usage"
cat > "$WINGMAN_HOME/usage/ul-sweep-bad.json" <<EOF
{"five_hour": {"used_percentage": 10, "resets_at": $_ul_sweep_future}, "captured_at": "not-a-timestamp"}
EOF
wm_timeout 6 env WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1
assert_true "a usage file with an unparseable captured_at is swept" \
  "[ ! -e \"$WINGMAN_HOME/usage/ul-sweep-bad.json\" ]"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# The sweep does not change what value ends up aggregated: with a swept-away
# old file and a fresh in-window file both present, usage-limit-approaching
# still fires off the fresh reading exactly as it does with no sweep in play.
# WM_USAGE_SWEEP_SECS is set well above the old file's age but well below
# the fresh file's, so the watcher's own poll latency can't accidentally
# sweep the fresh reading out from under the test before it gets aggregated.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
mkdir -p "$WINGMAN_HOME/usage"
_ul_sweep_old2_iso="$(uv run --no-project --quiet python -c '
import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=120)).strftime("%Y-%m-%dT%H:%M:%S.%fZ"))
')"
cat > "$WINGMAN_HOME/usage/ul-sweep-old2.json" <<EOF
{"five_hour": {"used_percentage": 10, "resets_at": $_ul_sweep_future}, "captured_at": "$_ul_sweep_old2_iso"}
EOF
cat > "$WINGMAN_HOME/usage/ul-sweep-fresh2.json" <<EOF
{"five_hour": {"used_percentage": 85, "resets_at": $_ul_sweep_future}, "captured_at": "$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)"}
EOF
out_sweep_agg="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 WM_USAGE_SWEEP_SECS=30 "$WF" 2>/dev/null)"
assert_contains "usage-limit-approaching still fires off the fresh reading" "$out_sweep_agg" "usage-limit-approaching:"
assert_true "the swept-away old file is gone" \
  "[ ! -e \"$WINGMAN_HOME/usage/ul-sweep-old2.json\" ]"
assert_true "the fresh in-window file survives" \
  "[ -e \"$WINGMAN_HOME/usage/ul-sweep-fresh2.json\" ]"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null
rm -f "$WINGMAN_HOME"/watch.pid "$WINGMAN_HOME"/watch.beat


test_summary
