#!/usr/bin/env bash
# E2E: the wake loop's core arm/fire semantics. Proves the watcher blocks on a
# still-working fleet, fires and exits with a reason the instant a member
# becomes actionable, delivers a pending event on arm (at-least-once across
# re-arms), refuses to start a second live cycle (singleton), carries deltas +
# directive on stdout and the full owner-scoped roster in the wake file, and -
# with a real tmux session - flags a silently stalled member without
# false-positiving on busy or parked panes. Also covers the permission/prompt-
# freeze detector's own false-positive/false-negative matrix, SIGURG immunity,
# the concurrent-arm TOCTOU close, and the api-error nudge/escalation path.
# Split from a single, much larger file (then named tests/watch-fleet.test.sh)
# once it became ~92% of the CI test job's own wall clock (measured directly
# from CI logs, not estimated). Two sibling files continue this suite:
# tests/watch-fleet-recovery.test.sh (Remote Control/lock/outage/usage-limit
# recovery) and tests/watch-fleet-lifecycle.test.sh (ownership,
# self-correction, and the orphan-watcher-lifecycle self-checks).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
# For wm_composer_text_in/wm_composer_is_empty, used by z1/ae1/ae2 below to
# assert a real submission against the composer stub fixture (issue #236)
# rather than grepping tmux scrollback for text that may only have been typed.
. "$TEST_REPO/bin/lib/common.sh"

WF="$TEST_REPO/bin/watch-fleet"
COMPOSER_STUB="$TEST_REPO/tests/fixtures/composer-stub.sh"
export WM_WATCH_INTERVAL=1
# The watcher blocks until an event fires, so bound every foreground run with
# wm_timeout and reap any backgrounded one on exit (lib.sh's shared trap; every
# background pid here is registered via wm_track). A watcher that never fires
# can then never wedge this file or, through run.sh, the whole suite.

# --- fires immediately when an event is already pending on arm ---------------
test_new_home
wm_state crew-add --id a1 --type analyst --objective x --repo /tmp --window wm-a1 --session-id s1 >/dev/null
wm_state crew-set --id a1 --status done --summary "finished x" >/dev/null
out="$(wm_timeout 45 "$WF" 2>/dev/null)"; rc=$?
assert_eq "arm fires and exits 0 when a member is already done" "$rc" "0"
assert_contains "fire prints the done reason line" "$out" "done: a1 finished x"
assert_contains "wake file names the member" "$(cat "$WINGMAN_HOME/wake")" "a1"

# --- blocks while the fleet is only working, then fires on the flip ----------
test_new_home
# b1 is backed by a real tmux window (issue #209): reconcile now runs on every
# poll regardless of whether the crew session exists, so a LIVE_STATES fixture
# with no matching window would flip to died on the very first poll instead of
# staying working through this block's blocking-then-flip assertions.
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-b1 'sleep 600'
wm_state crew-add --id b1 --type analyst --objective y --repo /tmp --window wm-b1 --session-id s2 >/dev/null
wm_state crew-set --id b1 --status working --summary "in progress" >/dev/null
"$WF" >"$WINGMAN_HOME/out.log" 2>&1 &
wpid=$!
wm_track "$wpid"
sleep 3
assert_true "watcher keeps blocking while member is working" "kill -0 $wpid"

# singleton: a second arm sees the live cycle and stands down as 'healthy'
out2="$(wm_timeout 45 "$WF" 2>&1)"; rc2=$?
assert_eq "second arm exits 0" "$rc2" "0"
assert_contains "second arm reports healthy, does not start a rival" "$out2" "healthy"

# flip to done: the blocking watcher fires and exits within a cycle
wm_state crew-set --id b1 --status done --summary "done y" >/dev/null
sleep 3
assert_false "watcher exits after the member finishes" "kill -0 $wpid"
assert_contains "blocking watcher printed the fire reason" "$(cat "$WINGMAN_HOME/out.log")" "done: b1"
kill "$wpid" 2>/dev/null

# --- a blocked member is actionable too --------------------------------------
test_new_home
# c1 is backed by a real tmux window (issue #209): see b1's comment above.
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-c1 'sleep 600'
wm_state crew-add --id c1 --type developer --objective z --repo /tmp --window wm-c1 --session-id s3 >/dev/null
wm_state crew-set --id c1 --status blocked --blocker "need a decision" >/dev/null
out3="$(wm_timeout 45 "$WF" 2>/dev/null)"
assert_contains "blocked member fires with its reason" "$out3" "blocked: c1"

# --- fire carries the full picture: deltas + directive + roster ---------------
test_new_home
# d1 and d2 are backed by real tmux windows (issue #209): see b1's comment
# above. Both are LIVE_STATES fixtures here (d1 -> review, d2 -> working), and
# without real windows both flip to died together, producing a
# correlated:mass-death fire instead of the individual review fire this block
# actually tests for.
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-d1 'sleep 600'
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-d2 'sleep 600'
wm_state crew-add --id d1 --type analyst --objective a --repo /tmp --window wm-d1 --session-id s4 >/dev/null
wm_state crew-add --id d2 --type developer --objective b --repo /tmp --window wm-d2 --session-id s5 >/dev/null
wm_state crew-set --id d2 --status working --summary "still building" >/dev/null
wm_state crew-set --id d1 --status review --artifact /tmp/plan.md >/dev/null
out4="$(wm_timeout 45 "$WF" 2>/dev/null)"
assert_contains "fire prints the review reason line" "$out4" "review: d1 /tmp/plan.md"
assert_contains "stdout directs beyond the deltas" "$out4" "not the full picture"
assert_contains "directive names the wake file path" "$out4" "$WINGMAN_HOME/wake"
assert_contains "directive demands the roster report" "$out4" "roster status"
assert_contains "directive states the classify-first ordering (issue #197)" "$out4" "--classify"
wake4="$(cat "$WINGMAN_HOME/wake")"
assert_contains "wake file has a New events section" "$wake4" "## New events"
assert_contains "wake file names the flipped member" "$wake4" "d1"
assert_contains "wake file has the roster section" "$wake4" "## Full roster"
assert_contains "wake roster includes the still-working member" "$wake4" "d2"

# --- owner scoping: a lead's cycle reads and writes only its own scope --------
test_new_home
wm_state crew-add --id t1 --type analyst --objective c --repo /tmp --window wm-t1 --session-id s6 >/dev/null
wm_state crew-add --id w1 --type developer --objective d --repo /tmp --window wm-w1 --session-id s7 --parent lead-x >/dev/null
wm_state crew-set --id w1 --status done --summary "shipped" >/dev/null
out5="$(wm_timeout 45 "$WF" --owner lead-x 2>/dev/null)"
assert_contains "lead-scoped fire reports its own member" "$out5" "done: w1"
assert_contains "directive names the lead-keyed wake file" "$out5" "wake-lead-x"
wake5="$(cat "$WINGMAN_HOME/wake-lead-x")"
assert_contains "lead wake roster names the lead's member" "$wake5" "w1"
assert_false "lead wake file excludes the top-level member" "grep -q t1 '$WINGMAN_HOME/wake-lead-x'"

# --- stall fires end-to-end, but only after a single check-in nudge + wait (#61) --
# An errored/idle agent: a window running the composer stub (issue #236 - a
# real submission, not merely typed-but-unsubmitted text sitting in scrollback,
# which is exactly the blind spot this suite used to have) with WM_TEST_BUSY=0
# WM_TEST_SWALLOW=0 so the nudge registers cleanly. The general (non-api-error)
# path gets the same nudge + wait as the api-error path below, using the
# generic "checking in" wording since the pane shows no recognized error
# signature. The wait-before-flip is driven by WM_STALL_IDLE alone (#101) -
# there is no separate cooldown knob to also set.
test_new_home
Z1_MARKER="$(wm_mktemp_file)"
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z1 --type developer --objective e --repo /tmp --window wm-z1 --session-id s8 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z1 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$Z1_MARKER' bash '$COMPOSER_STUB'"
sleep 1
wm_age_status z1
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  "$WF" >"$WINGMAN_HOME/stall.log" 2>&1 &
spid=$!
wm_track "$spid"
nudgefile="$WINGMAN_HOME/stall-z1.nudged"
_wait=0
while [ ! -f "$nudgefile" ] && [ "$_wait" -lt 40 ]; do sleep 1; _wait=$((_wait+1)); done
assert_true "the generic check-in nudge marker appears" "[ -f '$nudgefile' ]"
assert_contains "the marker records a confirmed nudge" "$(cat "$nudgefile" 2>/dev/null)" "confirmed"
assert_eq "exactly one SUBMITTED line" "$(grep -c SUBMITTED "$Z1_MARKER")" "1"
assert_contains "the submission carries the generic check-in message, not the api-error one" \
  "$(cat "$Z1_MARKER")" "Checking in: if you're mid-task"
z1_region="$(wm_composer_text_in "$(wm_tmux_pane_text "$WM_TMUX_SESSION:wm-z1")")"
z1_empty=0; wm_composer_is_empty "$z1_region" && z1_empty=1
assert_eq "the composer region is empty after delivery" "$z1_empty" "1"
assert_true "watcher is still blocking right after the nudge (flip is deferred)" "kill -0 $spid"
assert_contains "the member is still working, not yet flipped stalled" \
  "$(wm_state crew-get --id z1)" '"status": "working"'
i=0; while kill -0 "$spid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher exited on the stall once the wait window elapsed" "kill -0 $spid"
assert_contains "cycle exits with the stalled reason" "$(cat "$WINGMAN_HOME/stall.log")" "stalled: z1"
assert_contains "the reason notes a check-in nudge already ran" \
  "$(cat "$WINGMAN_HOME/stall.log")" "even after a check-in nudge"
assert_contains "wake file names the stalled member" "$(cat "$WINGMAN_HOME/wake")" "z1"
assert_eq "the nudge landed exactly once through to the flip, never re-sent" \
  "$(grep -c SUBMITTED "$Z1_MARKER")" "1"
kill "$spid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- no false positive on a busy pane (never nominated) -----------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z2 --type developer --objective f --repo /tmp --window wm-z2 --session-id s9 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z2 'while :; do echo tick; sleep 1; done'
wm_age_status z2
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 \
  "$WF" >/dev/null 2>&1 &
bpid=$!
wm_track "$bpid"
sleep 8
assert_true "watcher keeps blocking on a busy pane" "kill -0 $bpid"
assert_contains "busy member is never flagged" "$(wm_state crew-get --id z2)" '"status": "working"'
kill "$bpid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- no false positive on a parked member (armed-watcher analog) --------------
# The pane is silent past the threshold, but its root holds a late-started
# sleeping child - the shape of a healthy member parked on an armed watcher.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z3 --type lead --objective g --repo /tmp --window wm-z3 --session-id s10 >/dev/null
# `& wait` keeps the pane root alive as the parent (a bare trailing command would
# be exec'd by the pane shell, collapsing the tree to one idle process).
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z3 'sleep 4; sleep 600 & wait'
wm_age_status z3
WM_STALL_IDLE=6 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 \
  "$WF" >/dev/null 2>&1 &
ppid=$!
wm_track "$ppid"
sleep 14
assert_true "watcher keeps blocking on a parked member" "kill -0 $ppid"
assert_contains "parked member is never flagged" "$(wm_state crew-get --id z3)" '"status": "working"'
kill "$ppid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #234: a parked lead with a live report is never nudged either ------
# Q4 inverted: the same armed-watcher shape as z3 above, but this time the
# member also owns a live report - the exact shape the D1 guard exists to
# exempt from stage 1 (the check-in nudge), not only stage 2 (the flip).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z3b --type lead --objective g --repo /tmp --window wm-z3b --session-id s10b >/dev/null
wm_state crew-set --id z3b --status working --summary "supervising the crew" >/dev/null
wm_state crew-add --id z3b-dev --type developer --objective gg --repo /tmp --window wm-z3b-dev \
  --session-id s10c --parent z3b >/dev/null
wm_state crew-set --id z3b-dev --status working --summary "implementing the fix" >/dev/null
# `& wait` keeps the pane root alive as the parent (a bare trailing command would
# be exec'd by the pane shell, collapsing the tree to one idle process). Armed
# at t=4, same as WM_STALL_IDLE below (6, matching sibling z3): candidacy must
# not open before the late-started descendant actually exists.
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z3b 'sleep 4; sleep 600 & wait'
wm_age_status z3b
WM_STALL_IDLE=6 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 \
  "$WF" >/dev/null 2>&1 &
qppid=$!
wm_track "$qppid"
# This case only pins the D1 guard if it gives an UN-guarded send enough time to
# actually land: the fixture pane emits no output at all, so wm_tmux_send_message's
# own wm_tmux_pane_ready (bin/lib/common.sh:680-712) would spin its full
# WM_READY_TRIES x WM_READY_POLL (~20s) before even attempting the type+submit,
# on top of the time to become a stall-idle candidate in the first place - a fixed
# `sleep 16` finishes well before that and would pass identically whether the
# guard exists or not (issue #234 review, PR #239 finding M1). Poll for the marker
# for up to 40s instead - the same budget the neighbouring z1 case already uses for
# its own (guarded-to-happen) nudge - so a guard-free build genuinely has time to
# stamp the marker and turn this red, while a guarded build times out clean.
_wait=0
while [ ! -f "$WINGMAN_HOME/stall-z3b.nudged" ] && [ "$_wait" -lt 40 ]; do sleep 1; _wait=$((_wait+1)); done
assert_true "watcher keeps blocking on a parked lead with a live report" "kill -0 $qppid"
assert_contains "parked lead with a live report is never flagged" \
  "$(wm_state crew-get --id z3b)" '"status": "working"'
assert_false "the stall nudge marker is never stamped" \
  "[ -f '$WINGMAN_HOME/stall-z3b.nudged' ]"
z3b_nudge_count="$(tmux capture-pane -p -S -1000 -t "$WM_TMUX_SESSION:wm-z3b" | grep -c "Checking in: if you're mid-task")"
assert_eq "the pane is never typed into with the check-in nudge" "$z3b_nudge_count" "0"
kill "$qppid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #244: forward-motion-check's real bin/watch-fleet wiring -----------
# Pins the tmux list-panes -s / --pane-pids-stdin plumbing itself, as distinct
# from the wm_state-layer tests in tests/forward-motion-check.test.sh (which
# exercise cmd_forward_motion_check directly with a hand-fed pid map, never
# going through bash/tmux at all). A lead with one working delegate whose real
# tmux pane is genuinely CPU-busy (a spin loop, not a sleep-based one - `ps`'s
# whole-second cputime resolution means a sleep-heavy pane would never show a
# measurable delta) is reprieved every time its window is re-approached and
# never flips.
#
# --probe-gap 3, not the module's own default 10 or a tighter 1-2: at gap=1-2
# the spin loop must cross a whole-second `ps -o time=` boundary inside a
# short window, which under this same file's own nproc-wide parallelism
# (holding a second dedicated spin loop of its own, at lead16 below) measurably
# fails often enough to flake this assertion - gap=3 was measured clean at
# every contention level tested (PR #266 review round 1).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id lead15 --type lead --objective g --repo /tmp --window wm-lead15 --session-id s15 >/dev/null
wm_state crew-set --id lead15 --status working --summary "leading the effort" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-lead15 'sleep 600'
wm_state crew-add --id dev15 --type developer --objective h --repo /tmp --window wm-dev15 \
  --session-id s15d --parent lead15 >/dev/null
wm_state crew-set --id dev15 --status working --summary "implementing the fix" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-dev15 'while :; do :; done'
WM_FORWARD_MOTION_SECS=6 WM_STALL_PROBE_GAP=3 WM_STALL_CPU_EPS=0.01 WM_WATCH_INTERVAL=2 \
  "$WF" >/dev/null 2>&1 &
fmpid=$!
wm_track "$fmpid"
sleep 16
assert_true "watcher keeps blocking on a lead with a genuinely busy delegate" "kill -0 $fmpid"
assert_contains "the lead with a busy delegate is never flagged" \
  "$(wm_state crew-get --id lead15)" '"status": "working"'
kill "$fmpid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #244: an idle armed-watcher delegate still lets the flip happen ----
# Same wiring, opposite fixture (the z3/z3b armed-watcher shape): a delegate
# merely parked on its own idle armed watcher must NOT reprieve the lead - the
# MF2/MF-A control at the watcher-integration layer, pairing the busy-delegate
# case immediately above.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id lead16 --type lead --objective g --repo /tmp --window wm-lead16 --session-id s16 >/dev/null
wm_state crew-set --id lead16 --status working --summary "leading the effort" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-lead16 'sleep 600'
wm_state crew-add --id dev16 --type developer --objective h --repo /tmp --window wm-dev16 \
  --session-id s16d --parent lead16 >/dev/null
wm_state crew-set --id dev16 --status working --summary "waiting on its own armed watcher" >/dev/null
# `& wait` keeps the pane root alive as the parent (a bare trailing command
# would be exec'd by the pane shell, collapsing the tree to one idle process).
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-dev16 'sleep 4; sleep 600 & wait'
out16="$(wm_timeout 45 env WM_FORWARD_MOTION_SECS=6 WM_STALL_PROBE_GAP=2 WM_STALL_CPU_EPS=0.01 \
  WM_WATCH_INTERVAL=2 "$WF" 2>/dev/null)"
assert_contains "an idle armed-watcher delegate does not reprieve: the lead still flips stalled" \
  "$out16" "stalled: lead16"
assert_contains "lead16 reads stalled" "$(wm_state crew-get --id lead16)" '"status": "stalled"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- permission freeze stays the more specific diagnosis ----------------------
# A real frozen dialog: question phrase + numbered options at the bottom of a
# static pane. Detection needs two identical polls, so the flip lands on the
# second cycle.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z4 --type developer --objective h --repo /tmp --window wm-z4 --session-id s11 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z4 'printf "Do you want to proceed?\n❯ 1. Yes\n  2. No, and tell it what to do differently\n"; sleep 600'
wm_age_status z4
out6="$(wm_timeout 45 env WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 "$WF" 2>/dev/null)"
assert_contains "permission prompt fires as blocked, not stalled" "$out6" "blocked: z4"
assert_contains "frozen member reads blocked" "$(wm_state crew-get --id z4)" '"status": "blocked"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- no false positive on transcript content that mentions a prompt -----------
# The incident shape: a static pane whose transcript quotes the full question
# phrase (a diff/plan/test fixture) but shows no options list - the UI-shape
# anchor must refuse it even though the pane is stable.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z5 --type developer --objective i --repo /tmp --window wm-z5 --session-id s12 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z5 'echo "the test fixture echoes: Do you want to proceed?"; sleep 600'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
qpid=$!
wm_track "$qpid"
sleep 6
assert_true "watcher keeps blocking on quoted prompt text" "kill -0 $qpid"
assert_contains "quoting member is never flagged" "$(wm_state crew-get --id z5)" '"status": "working"'
kill "$qpid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- no false positive on a live pane even with full prompt shape -------------
# Phrase and a full >=2-row option block both visible, but the pane keeps changing
# (a working session's status line ticks) - the stability condition must refuse it.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z6 --type developer --objective j --repo /tmp --window wm-z6 --session-id s13 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z6 'printf "Do you want to proceed?\n  1. Yes\n  2. No\n"; while :; do echo tick; sleep 1; done'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
lpid=$!
wm_track "$lpid"
sleep 6
assert_true "watcher keeps blocking on a live prompt-shaped pane" "kill -0 $lpid"
assert_contains "live member is never flagged" "$(wm_state crew-get --id z6)" '"status": "working"'
kill "$lpid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- no false positive on a parked pane discussing prompts --------------------
# The residual class: a byte-static (parked) pane whose transcript tail quotes
# the question phrase in prose with a numbered list starting two lines below -
# inside the adjacency window, so the line-start anchor is what must refuse it
# (stability cannot discriminate on a parked pane).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z7 --type developer --objective k --repo /tmp --window wm-z7 --session-id s14 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z7 'printf "test fixture that echoes: Do you want to proceed?\nthree conditions:\n1. anchor\n2. stability\n3. phrases\n"; sleep 600'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
kpid=$!
wm_track "$kpid"
sleep 6
assert_true "watcher keeps blocking on a parked prompt-discussing pane" "kill -0 $kpid"
assert_contains "parked discussing member is never flagged" "$(wm_state crew-get --id z7)" '"status": "working"'
kill "$kpid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a freeze older than WM_STALL_IDLE at first sighting is still blocked -----
# The dialog has been frozen past the stall threshold before the watcher's
# first-ever look (no prior pane hash); the prompt shape must hold the stall
# check off until stability confirms, so the diagnosis lands as blocked.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z8 --type developer --objective l --repo /tmp --window wm-z8 --session-id s15 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z8 'printf "Do you want to proceed?\n  1. Yes\n  2. No, and tell it what to do differently\n"; sleep 600'
wm_age_status z8
sleep 5   # let the frozen pane out-age WM_STALL_IDLE before the watcher ever looks
out8="$(wm_timeout 45 env WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "pre-aged freeze still fires as blocked" "$out8" "blocked: z8"
assert_false "pre-aged freeze is never misdiagnosed stalled" "printf '%s' \"\$out8\" | grep -q 'stalled: z8'"
assert_contains "pre-aged frozen member reads blocked" "$(wm_state crew-get --id z8)" '"status": "blocked"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- per-tool phrasing variants still match (edit/create gates) ---------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z9 --type developer --objective m --repo /tmp --window wm-z9 --session-id s16 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z9 'printf "Do you want to make this edit to foo.py?\n  1. Yes\n  2. No\n"; sleep 600'
out9="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "edit-gate phrasing fires as blocked" "$out9" "blocked: z9"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- the workspace-trust dialog still matches via its option row --------------
# Layout from a live capture (Claude Code v2.1.206): the question prose sits
# well above the options (outside the adjacency window) and varies across CLI
# versions, so detection rides on the stable "Yes, I trust this folder" option
# row with its sibling row adjacent.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z10 --type developer --objective n --repo /tmp --window wm-z10 --session-id s17 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z10 'printf "Quick safety check: Is this a project you created or one you trust?\nIf not, take a moment to review this folder first.\n\nSecurity guide\n\n 1. Yes, I trust this folder\n   2. No, exit\n\nEnter to confirm\n"; sleep 600'
out10="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "trust dialog fires as blocked via its option row" "$out10" "blocked: z10"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a worktree-add + in-worktree file touch renders no dialog at all (#60) ---
# Issue #60 hypothesized a path-based gap: a dialog freezing a pane during
# git-worktree setup goes undetected because the detector only covers the
# primary repo path. Reproduced end-to-end (a real developer crew member
# spawned against a fresh, never-before-trusted scratch repo, driven through
# `git worktree add` into a sibling directory and a Write-tool touch inside
# it): neither step rendered any workspace-trust, Bypass Permissions, or
# "outside your workspace" dialog - the sibling worktree path falls inside the
# session's already-granted access boundary, so there is no second dialog
# variant to add here. This fixture reproduces that exact captured pane text
# (no option rows at all) and locks in that it is never misclassified as a
# frozen prompt.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z15 --type developer --objective s --repo /tmp --window wm-z15 --session-id s23 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z15 'printf "Worktree created without any interactive dialog. Now writing the test file.\n\n  Write(~/scratch-repo-z15/touch-test.txt)\n  ⎿  Wrote 1 line to ../scratch-repo-z15/touch-test.txt\n      1 touched\n"; sleep 600'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
z15pid=$!
wm_track "$z15pid"
sleep 6
assert_true "watcher keeps blocking after a worktree-add + file-touch sequence" "kill -0 $z15pid"
assert_contains "worktree-touch member is never flagged" "$(wm_state crew-get --id z15)" '"status": "working"'
kill "$z15pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a single stray numbered item is not a gate (>=2-rows rejects it) ---------
# The PR-#6 residual variant: a parked, byte-static pane whose tail quotes a
# single numbered item whose text begins with a question phrase. Its option block
# is one row, below WM_PERM_MIN_OPTS, so the content discriminator refuses it even
# though the pane is stable.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z11 --type developer --objective o --repo /tmp --window wm-z11 --session-id s19 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z11 'printf "1. Do you want to proceed?\n"; sleep 600'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
z11pid=$!
wm_track "$z11pid"
sleep 6
assert_true "watcher keeps blocking on a single stray numbered item" "kill -0 $z11pid"
assert_contains "single-option member is never flagged" "$(wm_state crew-get --id z11)" '"status": "working"'
kill "$z11pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- a duplicated selection marker rejects the block (marker <=1) --------------
# A parked, byte-static pane quoting a full >=2-row dialog block, but with the
# selection glyph on more than one row - a real dialog highlights at most one, so
# the marker rule refuses the loose verbatim quote.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z12 --type developer --objective p --repo /tmp --window wm-z12 --session-id s20 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z12 'printf "Do you want to proceed?\n❯ 1. Yes\n❯ 2. No\n"; sleep 600'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
z12pid=$!
wm_track "$z12pid"
sleep 6
assert_true "watcher keeps blocking on a duplicated-marker block" "kill -0 $z12pid"
assert_contains "duplicated-marker member is never flagged" "$(wm_state crew-get --id z12)" '"status": "working"'
kill "$z12pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- an actively-working member is acquitted by the liveness veto --------------
# A byte-static pane quoting a full >=2-row dialog block (shape + stability both
# match), but the member has self-reported since spawn and within the liveness
# grace, so it is too fresh to be frozen and the blocked-flip is vetoed.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z13 --type developer --objective q --repo /tmp --window wm-z13 --session-id s21 >/dev/null
wm_state crew-set --id z13 --status working --summary "actively grepping the detector strings" >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z13 'printf "Do you want to proceed?\n  1. Yes\n  2. No\n"; sleep 600'
WM_WATCH_INTERVAL=1 WM_PERM_LIVENESS_GRACE=3600 "$WF" >/dev/null 2>&1 &
z13pid=$!
wm_track "$z13pid"
sleep 6
assert_true "watcher keeps blocking on a freshly self-reported member" "kill -0 $z13pid"
assert_contains "actively-working member is vetoed, not flagged" "$(wm_state crew-get --id z13)" '"status": "working"'
kill "$z13pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- the startup-gate freeze is never vetoed by its spawn stamp (N2) -----------
# A member frozen on the one-time startup gate never runs crew-set, so its
# status.updated is still the immutable spawn stamp. Even with a large liveness
# grace - which would veto on freshness alone - the spawn-stamp gate keeps the veto
# from applying, so the real freeze still fires as blocked.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z14 --type developer --objective r --repo /tmp --window wm-z14 --session-id s22 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z14 'printf "Do you want to proceed?\n  1. Yes\n  2. No\n"; sleep 600'
out14="$(wm_timeout 45 env WM_WATCH_INTERVAL=1 WM_PERM_LIVENESS_GRACE=3600 "$WF" 2>/dev/null)"
assert_contains "startup-gate freeze fires despite a large liveness grace" "$out14" "blocked: z14"
assert_contains "startup-gate frozen member reads blocked" "$(wm_state crew-get --id z14)" '"status": "blocked"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- the wake loop is immune to SIGURG (regression: spurious exit 144) --------
# The watcher is armed as a background task whose exit is the only channel that
# wakes an idle managing session. A stray SIGURG (signal 16) reaching it would
# terminate it (exit 144 = 128+16) and silently end that turn, so the loop
# explicitly ignores SIGURG. Lock the directive in place and prove a SIGURG burst
# neither kills the blocking loop nor stops it firing on the genuine event.
assert_true "watch-fleet ignores SIGURG explicitly" "grep -qE \"trap '' (URG|SIGURG)\" '$WF'"

test_new_home
# u1 is backed by a real tmux window (issue #209): see b1's comment above.
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-u1 'sleep 600'
wm_state crew-add --id u1 --type developer --objective u --repo /tmp --window wm-u1 --session-id s18 >/dev/null
wm_state crew-set --id u1 --status working --summary "in progress" >/dev/null
"$WF" >"$WINGMAN_HOME/urg.log" 2>&1 &
upid=$!
wm_track "$upid"
sleep 2
j=0; while [ "$j" -lt 40 ]; do
  kill -URG "$upid" 2>/dev/null
  for _c in $(pgrep -P "$upid" 2>/dev/null); do kill -URG "$_c" 2>/dev/null; done
  j=$((j+1))
done
sleep 1
assert_true "watcher survives a SIGURG burst and keeps blocking" "kill -0 $upid"
wm_state crew-set --id u1 --status done --summary "done u" >/dev/null
i=0; while kill -0 "$upid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher still fires on the real event after SIGURG" "kill -0 $upid"
assert_contains "post-SIGURG fire carries the reason" "$(cat "$WINGMAN_HOME/urg.log")" "done: u1"
kill "$upid" 2>/dev/null

# --- concurrent arms race safely (closes the TOCTOU gap, #12) ----------------
# Two near-simultaneous arms, backgrounded and raced with &: the mkdir claim
# lock must let exactly one win the claim, leaving exactly one live process and
# a pidfile that names it. Assert on each racer's own printed verdict (its
# first line of output), not on a `kill -0` process-liveness snapshot after a
# fixed wait - liveness-by-pid over a polling window is itself timing-sensitive
# under a shared, noisy host (a scheduling delay can make a losing racer look
# "still alive" well after it has already decided and is mid-exit), where the
# verdict each process writes the moment it decides is not.
test_new_home
wm_state crew-add --id race1 --type developer --objective race --repo /tmp --window wm-race1 --session-id sr1 >/dev/null
wm_state crew-set --id race1 --status working --summary "in progress" >/dev/null
"$WF" >"$WINGMAN_HOME/race-a.log" 2>&1 &
race_a=$!
wm_track "$race_a"
"$WF" >"$WINGMAN_HOME/race-b.log" 2>&1 &
race_b=$!
wm_track "$race_b"
# Wait (bounded) for both racers to have printed their verdict.
_race_i=0
while [ "$_race_i" -lt 60 ]; do
  [ -s "$WINGMAN_HOME/race-a.log" ] && [ -s "$WINGMAN_HOME/race-b.log" ] && break
  sleep 0.2
  _race_i=$((_race_i+1))
done
race_a_out="$(cat "$WINGMAN_HOME/race-a.log" 2>/dev/null)"
race_b_out="$(cat "$WINGMAN_HOME/race-b.log" 2>/dev/null)"
winners=0; winner_pid=""
case "$race_a_out" in *"watcher: armed pid="*) winners=$((winners+1)); winner_pid="$race_a" ;; esac
case "$race_b_out" in *"watcher: armed pid="*) winners=$((winners+1)); winner_pid="$race_b" ;; esac
losers=0
case "$race_a_out" in *"already armed"*) losers=$((losers+1)) ;; esac
case "$race_b_out" in *"already armed"*) losers=$((losers+1)) ;; esac
assert_eq "exactly one racer wins the claim and arms" "$winners" "1"
assert_eq "exactly one racer loses the claim and reports already-armed" "$losers" "1"
pidfile_pid="$(cat "$WINGMAN_HOME/watch.pid" 2>/dev/null)"
assert_true "the pidfile names a live process" "kill -0 $pidfile_pid"
assert_eq "the pidfile matches the winning racer's own pid" "$pidfile_pid" "$winner_pid"
kill "$race_a" "$race_b" 2>/dev/null

# --- --status is the scriptable liveness check (#12) --------------------------
test_new_home
assert_false "no live cycle: --status exits nonzero" "\"$WF\" --status >/dev/null 2>&1"
# st1 is backed by a real tmux window (issue #209): see b1's comment above.
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-st1 'sleep 600'
wm_state crew-add --id st1 --type developer --objective s --repo /tmp --window wm-st1 --session-id ss1 >/dev/null
wm_state crew-set --id st1 --status working --summary "in progress" >/dev/null
"$WF" >"$WINGMAN_HOME/status.log" 2>&1 &
stpid=$!
wm_track "$stpid"
sleep 2
assert_true "a live cycle: --status exits zero" "\"$WF\" --status >/dev/null 2>&1"
kill "$stpid" 2>/dev/null

# --- fire() collapses a correlated mass-death batch (#22) ----------------------
# Three simultaneous deaths at/above the default min-count and min-ratio collapse
# to one synthetic bullet naming every id; a fourth, unrelated death elsewhere
# stays a separate individual line (group-attention's own logic is unit-tested
# in group-attention.test.sh - this proves fire() is actually wired to it).
test_new_home
wm_state crew-add --id m1 --type developer --objective p --repo /tmp --window wm-m1 --session-id sm1 >/dev/null
wm_state crew-add --id m2 --type developer --objective q --repo /tmp --window wm-m2 --session-id sm2 >/dev/null
wm_state crew-add --id m3 --type developer --objective r --repo /tmp --window wm-m3 --session-id sm3 >/dev/null
wm_state crew-set --id m1 --status died >/dev/null
wm_state crew-set --id m2 --status died >/dev/null
wm_state crew-set --id m3 --status died >/dev/null
outm="$(wm_timeout 45 "$WF" 2>/dev/null)"
assert_contains "the collapsed bullet is a single correlated row" "$outm" "correlated:mass-death"
assert_contains "the collapsed row names the first member" "$outm" "m1"
assert_contains "the collapsed row names the second member" "$outm" "m2"
assert_contains "the collapsed row names the third member" "$outm" "m3"
case "$outm" in
  *"died: m1 "*) died_m1_solo=1 ;;
  *)             died_m1_solo=0 ;;
esac
assert_eq "no individual 'died: m1' line remains alongside the collapse" "$died_m1_solo" "0"
wakem="$(cat "$WINGMAN_HOME/wake")"
assert_contains "the wake file also shows the collapsed bullet" "$wakem" "correlated:mass-death"

# --- an api-error nudge fires once, ever, and is never re-sent (#23, #101) ----
# A pane whose tail matches WM_APIERR_RE, gone idle past STALL_IDLE, but with a
# busy (silent) sibling process so the execution probe finds activity and never
# confirms a stall - isolates the nudge behavior from the escalation path
# below. Sending is now gated on the marker's CONFIRMED state (#236, replacing
# #101's existence-only gate); the marker's content, not merely its mtime,
# proves it is never re-sent. The composer stub (issue #236) proves an actual
# submission was made, not merely that api-error text sat typed in the
# composer; a CPU-spinning sibling ('while :; do :; done &' before exec'ing
# into the stub - same pid, so the spinner survives as the stub's own child)
# keeps the execution probe from ever confirming a stall on its own.
test_new_home
AE1_MARKER="$(wm_mktemp_file)"
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id ae1 --type developer --objective h --repo /tmp --window wm-ae1 --session-id sae1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-ae1 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_TRANSCRIPT='Error: rate limit exceeded (429 Too Many Requests)' WM_TEST_MARKER='$AE1_MARKER' bash -c 'while :; do :; done & exec bash $COMPOSER_STUB'"
sleep 1
wm_age_status ae1
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  "$WF" >/dev/null 2>&1 &
napid=$!
wm_track "$napid"
nudgefile="$WINGMAN_HOME/stall-ae1.nudged"
_wait=0
while [ ! -f "$nudgefile" ] && [ "$_wait" -lt 25 ]; do sleep 1; _wait=$((_wait+1)); done
assert_true "the nudge marker file appears" "[ -f '$nudgefile' ]"
assert_contains "the marker records a confirmed nudge" "$(cat "$nudgefile" 2>/dev/null)" "confirmed"
assert_eq "exactly one SUBMITTED line" "$(grep -c SUBMITTED "$AE1_MARKER")" "1"
assert_contains "the submission carries the api-error-specific message, not the generic one" \
  "$(cat "$AE1_MARKER")" "This is usually transient"
assert_true "watcher keeps blocking (CPU activity suppresses the stall flip)" "kill -0 $napid"
assert_contains "the member stays working, not flipped stalled" \
  "$(wm_state crew-get --id ae1)" '"status": "working"'
first_content="$(cat "$nudgefile" 2>/dev/null)"
sleep 6
second_content="$(cat "$nudgefile" 2>/dev/null)"
assert_eq "the nudge marker is never re-touched once it exists" "$first_content" "$second_content"
assert_eq "the api-error message lands exactly once despite the member never flipping" \
  "$(grep -c SUBMITTED "$AE1_MARKER")" "1"
kill "$napid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- an unrecovered api-error escalates to stalled only after a nudge + wait --
test_new_home
AE2_MARKER="$(wm_mktemp_file)"
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id ae2 --type developer --objective i --repo /tmp --window wm-ae2 --session-id sae2 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-ae2 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_TRANSCRIPT='Error: connection error (ECONNRESET)' WM_TEST_MARKER='$AE2_MARKER' bash '$COMPOSER_STUB'"
sleep 1
wm_age_status ae2
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  "$WF" >"$WINGMAN_HOME/apierr.log" 2>&1 &
aepid=$!
wm_track "$aepid"
i=0; while kill -0 "$aepid" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher exited on the api-error stall" "kill -0 $aepid"
assert_contains "cycle exits with the stalled reason carrying api-error:" \
  "$(cat "$WINGMAN_HOME/apierr.log")" "stalled: ae2 api-error:"
# issue #214, §3.6 step 5: a genuine flip now clears the watcher's own
# stall-<id>.nudged sidecar (previously never cleared at all - a pre-existing
# gap this fix closes alongside the new refused-nudge counter) so a later,
# unrelated stall episode for the same id cannot inherit a stale marker and
# flip claiming a nudge that was never sent this time. The nudge having
# happened before the flip is proven below by the pane content instead (the
# marker's own existence is no longer evidence of that, by design).
assert_false "the nudge marker is cleared once the flip actually happens" \
  "[ -f '$WINGMAN_HOME/stall-ae2.nudged' ]"
assert_eq "exactly one SUBMITTED line" "$(grep -c SUBMITTED "$AE2_MARKER")" "1"
assert_contains "the submission carries the api-error-specific message, not the generic one" \
  "$(cat "$AE2_MARKER")" "This is usually transient"
kill "$aepid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null


test_summary
