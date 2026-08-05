#!/usr/bin/env bash
# E2E: the wake loop. Proves the watcher blocks on a still-working fleet, fires
# and exits with a reason the instant a member becomes actionable, delivers a
# pending event on arm (at-least-once across re-arms), refuses to start a second
# live cycle (singleton), carries deltas + directive on stdout and the full
# owner-scoped roster in the wake file, and - with a real tmux session - flags a
# silently stalled member without false-positiving on busy or parked panes.
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

# --- run-id ownership (#162): healthy is run-scoped, a foreign cycle is
# --- replaced rather than adopted --------------------------------------------
test_new_home
# r1 is backed by a real tmux window (issue #209): see b1's comment above.
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-r1 'sleep 600'
wm_state crew-add --id r1 --type analyst --objective e --repo /tmp --window wm-r1 --session-id s20 >/dev/null
wm_state crew-set --id r1 --status working --summary "busy" >/dev/null
WINGMAN_RUN_ID=run-old "$WF" >"$WINGMAN_HOME/old.log" 2>&1 &
oldpid=$!
wm_track "$oldpid"
sleep 3
assert_true "run-old's cycle is live and blocking" "kill -0 $oldpid"
assert_eq "cycle stamps its arming run id" "$(cat "$WINGMAN_HOME/watch.run")" "run-old"

# Same run id: healthy, nothing replaced.
outsame="$(WINGMAN_RUN_ID=run-old wm_timeout 45 "$WF" 2>&1)"
assert_contains "same-run re-arm reports healthy" "$outsame" "healthy"
assert_true "same-run re-arm leaves the cycle running" "kill -0 $oldpid"

# No run id on the arming side: ownership cannot be certified, legacy healthy.
# env -u makes this genuinely run-id-less regardless of what the invoking
# session exports (issue #170) - test_new_home already unsets WINGMAN_RUN_ID,
# but this test's whole point is the run-id-less path, so it asserts the
# precondition directly rather than relying on that unset holding by the time
# execution reaches here.
outnone="$(wm_timeout 45 env -u WINGMAN_RUN_ID "$WF" 2>&1)"
assert_contains "run-id-less arm keeps legacy healthy" "$outnone" "healthy"
assert_true "run-id-less arm leaves the cycle running" "kill -0 $oldpid"

# Different run id: the live foreign cycle is stopped and replaced in place.
WINGMAN_RUN_ID=run-new "$WF" >"$WINGMAN_HOME/new.log" 2>&1 &
newpid=$!
wm_track "$newpid"
sleep 3
assert_false "the foreign cycle was stopped by the new run's arm" "kill -0 $oldpid"
assert_true "the new run's own cycle is live and blocking" "kill -0 $newpid"
assert_contains "the arm announced the replacement" "$(cat "$WINGMAN_HOME/new.log")" "Replacing it with a cycle this run tracks"
assert_contains "the arm printed armed, never healthy" "$(cat "$WINGMAN_HOME/new.log")" "watcher: armed"
assert_eq "the run stamp now names the new run" "$(cat "$WINGMAN_HOME/watch.run")" "run-new"

# The replacement cycle is a fully functional watcher: it still fires.
wm_state crew-set --id r1 --status done --summary "done e" >/dev/null
sleep 3
assert_false "the replacement cycle fires normally" "kill -0 $newpid"
assert_contains "the replacement cycle printed the fire reason" "$(cat "$WINGMAN_HOME/new.log")" "done: r1"

# --- issue #214 §3.6: a nudge that can never be delivered still eventually --
# flips the member stalled, via the refused-nudge escape hatch, rather than
# exempting it from stall escalation forever. Simulated with a contended send
# lock (rc 4) - deterministic and trivial to hold open, unlike a genuinely
# busy pane (rc 6): a pane repainting fast enough for wm_tmux_send_message to
# read it "busy" would also read unstable to watch-fleet's own PANE_STABLE
# check above and never reach this block at all (§3.6's own note on why rc 2
# is unreachable here applies just as much to a real rc 6).
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id nu1 --type developer --objective f --repo /tmp --window wm-nu1 --session-id snu1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-nu1 'trap "" INT; sleep 600'
wm_age_status nu1
# Pre-hold the per-pane send lock (bin/lib/common.sh's own mkdir-based
# convention) so every attempted nudge this test drives refuses with rc 4
# rather than ever actually typing. WM_SEND_LOCK_STALE is set far longer than
# this test runs so the lock is never reclaimed out from under it.
_nu1_target="$(printf '=%s:=%s' "$WM_TMUX_SESSION" "wm-nu1")"
_nu1_lock="$WINGMAN_HOME/send-$(printf '%s' "$_nu1_target" | tr -c 'A-Za-z0-9._-' '_').lock"
mkdir -p "$_nu1_lock"
export WM_NUDGE_REFUSED_MAX=2
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  WM_SEND_LOCK_WAIT=1 WM_SEND_LOCK_STALE=9999 \
  "$WF" >"$WINGMAN_HOME/nu1.log" 2>&1 &
nupid=$!
wm_track "$nupid"
# issue #236: .nudge-refused now carries "<count> <clock>" (extended from the
# bare-count shape #214 originally shipped) so the escape hatch's own
# --nudge-age can be derived from its own first-refusal clock rather than by
# stamping a synthetic .nudged the #236 confirm/retry parser would otherwise
# have to special-case. The two sidecars are therefore fully decoupled: .nudged
# is never touched by an undelivered-nudge episode (nothing was ever typed),
# only .nudge-refused is.
refusedfile="$WINGMAN_HOME/stall-nu1.nudge-refused"
refused_count_of() { awk '{print $1}' "$refusedfile" 2>/dev/null; }
_wait=0
while { [ ! -f "$refusedfile" ] || [ "$(refused_count_of)" -lt 2 ]; } && [ "$_wait" -lt 30 ]; do
  sleep 1; _wait=$((_wait+1))
done
assert_eq "the refused-nudge counter reaches WM_NUDGE_REFUSED_MAX before any nudge is ever delivered" \
  "$(refused_count_of)" "2"
nudgefile="$WINGMAN_HOME/stall-nu1.nudged"
assert_false "the escape hatch never stamps .nudged - that sidecar stays #236's alone" "[ -f '$nudgefile' ]"
assert_false "the escape hatch never sets nudged_at (it would render a false 'nudge sent' on the board)" \
  "wm_state crew-get --id nu1 | grep -q nudged_at"
i=0; while kill -0 "$nupid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher exited on the stall once the aged marker crossed the threshold" "kill -0 $nupid"
assert_contains "cycle exits with the stalled reason" "$(cat "$WINGMAN_HOME/nu1.log")" "stalled: nu1"
assert_contains "the reason names the undelivered nudge explicitly, not the generic template" \
  "$(cat "$WINGMAN_HOME/nu1.log")" "could not deliver a check-in nudge in 2 attempts"
kill "$nupid" 2>/dev/null
rmdir "$_nu1_lock" 2>/dev/null
unset WM_NUDGE_REFUSED_MAX
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #235: a stalled classification is self-correcting, and silently --
# Inverted reproduction of the incident behind #235
# (docs/plans/2026-08-04-issue-235-stalled-latch-plan.md, Appendix): a member
# is genuinely flipped stalled by a real watch-fleet cycle, comes back to
# unambiguous life (pane repainting continuously + a late-started descendant -
# the exact signal that was ABSENT at flip time), and a FRESH real
# watch-fleet cycle reverts it within a bounded number of polls - silently:
# the watcher never exits, the wake file is never rewritten, and no fire
# reason is ever printed naming it - while a genuinely still-dead sibling in
# the same fleet stays stalled throughout (the recheck never touches a
# record it has no evidence about). The only durable trace of the revert is
# a line in stall-recheck.log.
crew_status() { wm_state crew-get --id "$1" | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])"; }
crew_updated() { wm_state crew-get --id "$1" | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['updated'])"; }

test_new_home
RV1_MARKER="$(wm_mktemp_file)"
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle

# rv1: flipped first, alone (so its own nudge-then-wait timing matches the
# proven single-candidate budget above, unslowed by any other candidate
# sharing the same poll cycle) - then recovers.
wm_state crew-add --id rv1 --type developer --objective e --repo /tmp --window wm-rv1 --session-id srv1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rv1 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$RV1_MARKER' bash '$COMPOSER_STUB'"
sleep 1
wm_age_status rv1

WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  "$WF" >"$WINGMAN_HOME/rv-p1.log" 2>&1 &
flip1_pid=$!
wm_track "$flip1_pid"
i=0; while kill -0 "$flip1_pid" 2>/dev/null && [ "$i" -lt 70 ]; do sleep 1; i=$((i+1)); done
kill "$flip1_pid" 2>/dev/null
assert_contains "rv1 flipped to stalled" "$(wm_state crew-get --id rv1)" '"status": "stalled"'

# Classify + ack the pending fire (matching the plan's own repro) so the next
# cycle genuinely POLLS this still-pending event instead of re-firing on arm.
"$WF" --classify >/dev/null 2>&1
rv1_updated_flip="$(crew_updated rv1)"
wm_state ack --id rv1 --updated "$rv1_updated_flip" >/dev/null

# dead2: a genuinely idle control that never recovers - added only now (after
# rv1's own flip is settled and acked) so it does not slow down rv1's own
# single-candidate flip timing above, and flipped by its own dedicated cycle
# for the identical reason. Backed by the SAME composer-stub fixture as rv1
# (not a bare `sleep 600`, and confirmed empirically why): a 'working'
# candidate always gets a check-in nudge typed into its pane before stall-
# check is even allowed to flip it, and a bare `sleep` has no composer to
# absorb that - the nudge's own keystrokes kill the pane's foreground
# process outright, closing the window and producing 'died', not 'stalled'.
DEAD2_MARKER="$(wm_mktemp_file)"
wm_state crew-add --id dead2 --type developer --objective f --repo /tmp --window wm-dead2 --session-id sdead2 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-dead2 \
  "WM_TEST_BUSY=0 WM_TEST_SWALLOW=0 WM_TEST_MARKER='$DEAD2_MARKER' bash '$COMPOSER_STUB'"
sleep 1
wm_age_status dead2

WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  "$WF" >"$WINGMAN_HOME/rv-p1b.log" 2>&1 &
flip2_pid=$!
wm_track "$flip2_pid"
i=0; while kill -0 "$flip2_pid" 2>/dev/null && [ "$i" -lt 70 ]; do sleep 1; i=$((i+1)); done
kill "$flip2_pid" 2>/dev/null
assert_contains "dead2 flipped to stalled" "$(wm_state crew-get --id dead2)" '"status": "stalled"'
"$WF" --classify >/dev/null 2>&1
wm_state ack --id dead2 --updated "$(crew_updated dead2)" >/dev/null

# rv1 comes back to unambiguous life: same window name, a pane that repaints
# continuously and holds a late-started descendant.
tmux kill-window -t "$WM_TMUX_SESSION:wm-rv1" 2>/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-rv1 \
  'sh -c "sleep 4; while :; do echo tick; sleep 1; done"'
sleep 6

wake_before="$(cat "$WINGMAN_HOME/wake" 2>/dev/null || true)"

WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 \
  WM_STALL_RECHECK_CONFIRMS=2 \
  "$WF" >"$WINGMAN_HOME/rv-p2.log" 2>&1 &
rv2_pid=$!
wm_track "$rv2_pid"
i=0
while [ "$i" -lt 20 ]; do
  [ "$(crew_status rv1)" = working ] && break
  sleep 1; i=$((i+1))
done

assert_eq "rv1 reverted to working within a bounded number of polls" "$(crew_status rv1)" working
assert_true "the fix actually fixed the reported thing: updated is no longer the flip stamp" \
  "[ '$(crew_updated rv1)' != '$rv1_updated_flip' ]"
assert_eq "dead2 stays stalled throughout - the recheck never touches an unrelated record" \
  "$(crew_status dead2)" stalled

assert_true "the watcher NEVER EXITS across the silent revert - it keeps blocking" "kill -0 $rv2_pid"
assert_eq "the wake file is byte-identical - never rewritten for a silent auto-clear" \
  "$(cat "$WINGMAN_HOME/wake" 2>/dev/null || true)" "$wake_before"
assert_not_contains "no fire reason is ever printed for rv1's revert" "$(cat "$WINGMAN_HOME/rv-p2.log")" "rv1"

assert_true "stall-recheck.log recorded the clear" "[ -f '$WINGMAN_HOME/stall-recheck.log' ]"
assert_contains "the log line names rv1 and the liveness source" \
  "$(cat "$WINGMAN_HOME/stall-recheck.log")" "rv1 liveness cleared after"

kill "$rv2_pid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- issue #235: a wedge revert to 'blocked' DOES fire once ------------------
# The one exemption to the silent-clear rule: the restored blocker is a
# genuinely open question nobody answered, so it re-announces exactly once
# through the ordinary needs-attention path - not through anything the
# recheck itself does.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id wb1 --type developer --objective x --repo /tmp --window wm-wb1 --session-id swb1 >/dev/null
wm_state crew-set --id wb1 --status blocked --blocker "which approach?" >/dev/null
# Ack the pre-existing 'blocked' state itself before the flip watcher ever
# starts - otherwise the FIRST cycle fires immediately on THIS already-
# actionable event (needs-attention has no notion of "wait for wedge-check
# to get a look first"), before the wedge signature below ever gets a chance
# to run any poll at all.
wm_state ack --id wb1 --updated "$(crew_updated wb1)" >/dev/null
# A pane that repaints continuously (never idle at a prompt) and holds a
# `sleep`-matching descendant - the FOREGROUND-watcher wedge signature (issue
# #202). The descendant is reaped by a waiting subshell the instant it dies
# (verified empirically, mirroring tests/stall-recheck.test.sh's own fixture)
# so killing it later leaves no zombie for _ps_tree to still see. proc-re is
# narrowed to `sleep` (not the production default) purely to keep the
# fixture simple.
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-wb1 \
  'sleep 600 & child=$!; ( wait $child ) 2>/dev/null & while :; do echo tick; sleep 1; done'
sleep 1

WM_WEDGE_SECS=3 WM_WEDGE_PANE_GAP=5 WM_WEDGE_PROC_RE=sleep WM_WATCH_INTERVAL=1 \
  "$WF" >"$WINGMAN_HOME/wb-p1.log" 2>&1 &
wbflip_pid=$!
wm_track "$wbflip_pid"
i=0; while kill -0 "$wbflip_pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i+1)); done
kill "$wbflip_pid" 2>/dev/null
assert_contains "the wedge flip fires with the FOREGROUND signature" "$(cat "$WINGMAN_HOME/wb-p1.log")" "stalled: wb1"
assert_contains "wb1 flipped to stalled" "$(wm_state crew-get --id wb1)" '"status": "stalled"'
"$WF" --classify >/dev/null 2>&1
wm_state ack --id wb1 --updated "$(crew_updated wb1)" >/dev/null

# Kill the wedging descendant so its pane's process tree no longer holds it -
# the wedge clearing predicate's own evidence.
wedge_pid="$(wm_state crew-get --id wb1 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['stall']['wedge_pid'])")"
kill "$wedge_pid" 2>/dev/null
sleep 1

out="$(wm_timeout 45 env WM_WEDGE_SECS=3 WM_WEDGE_PANE_GAP=5 WM_WEDGE_PROC_RE=sleep \
  WM_STALL_RECHECK_CONFIRMS=2 WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "the revert to blocked fires once, naming the restored blocker" "$out" "blocked: wb1"
assert_contains "the fire carries the restored blocker text" "$out" "which approach?"
assert_contains "wb1 is genuinely back to blocked" "$(wm_state crew-get --id wb1)" '"status": "blocked"'

tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# ============================================================================
# issue #237: orphan-watcher-lifecycle - the owner-scoped self-checks (Fix 2),
# the identity-verified singleton lock and hard-staleness takeover (Fix 3)
# ============================================================================

wait_for_owner_status() {
  _wos_i=0
  while [ "$_wos_i" -lt 50 ]; do
    "$WF" --owner "$1" --status >/dev/null 2>&1 && return 0
    sleep 0.2
    _wos_i=$((_wos_i + 1))
  done
  return 1
}

wait_for_pid_gone() {
  _wpg_i=0
  while [ "$_wpg_i" -lt 75 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
    _wpg_i=$((_wpg_i + 1))
  done
  return 1
}

# --- Fix 2a: a cycle armed from a worktree that has since been removed -------
# self-stops within one poll, with no standdown ever involved - the incident's
# own single most distinctive fact ("the worktree ... no longer existed").
# $0 is resolved from inside a throwaway directory (mirroring this plan's own
# reproduction), which is then removed out from under the running cycle.
test_new_home
WT_PARENT="$(wm_mktemp_dir)"
WT_DIR="$WT_PARENT/fake-worktree"
mkdir -p "$WT_DIR"
cp "$WF" "$WT_DIR/watch-fleet"
chmod +x "$WT_DIR/watch-fleet"
ln -s "$TEST_REPO/bin/lib" "$WT_DIR/lib"
wm_state crew-add --id wt1 --type lead --objective x --repo /tmp --window wm-wt1 --session-id swt1 >/dev/null
wm_state crew-set --id wt1 --status working --summary "in progress" >/dev/null
"$WT_DIR/watch-fleet" --owner wt1 >"$WINGMAN_HOME/wt1.log" 2>&1 &
wt1pid=$!
wm_track "$wt1pid"
assert_true "the cycle armed from the throwaway worktree comes up live" "wait_for_owner_status wt1"
rm -rf "$WT_PARENT"
assert_true "the cycle self-exits once its own worktree directory is gone" "wait_for_pid_gone $wt1pid"
wtclassify="$(wm_timeout 10 "$WF" --owner wt1 --classify 2>/dev/null)"
assert_eq "the worktree-removal self-stop classifies as a deliberate stop, not a spurious failure" "$wtclassify" "stopped"

# --- Fix 2b: a cycle self-stops once its owner is irrecoverably died, with no
# standdown ever called (a crashed lead nobody has stood down yet) -----------
test_new_home
wm_state crew-add --id dead1 --type lead --objective x --repo /tmp --window wm-dead1 --session-id sdead1 >/dev/null
wm_state crew-set --id dead1 --status working --summary "in progress" >/dev/null
"$WF" --owner dead1 >"$WINGMAN_HOME/dead1.log" 2>&1 &
dead1pid=$!
wm_track "$dead1pid"
assert_true "dead1's scoped cycle comes up live" "wait_for_owner_status dead1"
wm_state crew-set --id dead1 --status died >/dev/null
assert_true "the cycle self-stops once its owner is irrecoverably died" "wait_for_pid_gone $dead1pid"
deadclassify="$(wm_timeout 10 "$WF" --owner dead1 --classify 2>/dev/null)"
assert_eq "the died-owner self-stop classifies as a deliberate stop" "$deadclassify" "stopped"

# --- Fix 2b: died-but-RESUMABLE does NOT self-stop (issue #254 interaction) --
# A died member's session transcript surviving on disk is exactly the case
# #254's own takeover path exists for - self-stopping the watcher here would
# strand that recovery path's own wake channel.
test_new_home
PROJDIR="$(wm_mktemp_dir)"
export WM_CLAUDE_PROJECTS_DIR="$PROJDIR"
RESUME_SLUG="$(printf '%s' /tmp | sed -E 's/[^A-Za-z0-9-]/-/g')"
mkdir -p "$PROJDIR/$RESUME_SLUG"
: > "$PROJDIR/$RESUME_SLUG/sresume1.jsonl"
wm_state crew-add --id resume1 --type lead --objective x --repo /tmp --window wm-resume1 --session-id sresume1 >/dev/null
wm_state crew-set --id resume1 --status working --summary "in progress" >/dev/null
"$WF" --owner resume1 >"$WINGMAN_HOME/resume1.log" 2>&1 &
resume1pid=$!
wm_track "$resume1pid"
assert_true "resume1's scoped cycle comes up live" "wait_for_owner_status resume1"
wm_state crew-set --id resume1 --status died >/dev/null
assert_contains "resume1 is genuinely resumable (transcript on disk)" "$(wm_state crew-get --id resume1)" '"resumable": true'
sleep 4
assert_true "a resumable died owner's cycle keeps polling, not self-stopped" "kill -0 $resume1pid"
kill "$resume1pid" 2>/dev/null
unset WM_CLAUDE_PROJECTS_DIR

# --- Fix 2b: a genuinely vanished-from-roster owner self-stops, debounced ----
# wm_state has no delete subcommand; bin/crew-prune (via `wm_state prune`)
# removes fully-closed (stood-down) records, reaching the genuinely-missing-
# record path with no hand-crafted fixture.
test_new_home
wm_state crew-add --id gone1 --type lead --objective x --repo /tmp --window wm-gone1 --session-id sgone1 >/dev/null
wm_state standdown --id gone1 >/dev/null
wm_state prune >/dev/null
assert_eq "gone1's record is genuinely gone from the roster" "$(wm_state crew-get --id gone1 2>/dev/null)" ""
"$WF" --owner gone1 >"$WINGMAN_HOME/gone1.log" 2>&1 &
gone1pid=$!
wm_track "$gone1pid"
assert_true "the vanished-owner cycle self-stops (debounced) once confirmed gone" "wait_for_pid_gone $gone1pid"
goneclassify="$(wm_timeout 10 "$WF" --owner gone1 --classify 2>/dev/null)"
assert_eq "the vanished-owner self-stop classifies as a deliberate stop" "$goneclassify" "stopped"

# --- Fix 2b SF1: a crew-get failure does not immediately self-stop a healthy
# owner's watcher - it debounces across WM_OWNER_MISSING_CONFIRMS consecutive
# ambiguous reads before acting -----------------------------------------------
test_new_home
wm_state crew-add --id sf1 --type lead --objective x --repo /tmp --window wm-sf1 --session-id ssf1 >/dev/null
wm_state crew-set --id sf1 --status working --summary "in progress" >/dev/null

STUB_A="$(wm_mktemp_file)"
COUNTER_A="$(wm_mktemp_file)"; rm -f "$COUNTER_A"
cat > "$STUB_A" <<STUBEOF
#!/usr/bin/env bash
case "\$1" in
  */wm-state.py)
    if [ "\$2" = "crew-get" ] && [ "\$3" = "--id" ] && [ "\$4" = "sf1" ]; then
      n="\$(cat "$COUNTER_A" 2>/dev/null)"; case "\$n" in ''|*[!0-9]*) n=0 ;; esac
      n=\$((n+1))
      printf '%s\n' "\$n" > "$COUNTER_A"
      [ "\$n" -le 2 ] && exit 1
    fi
    ;;
esac
exec uv run --no-project --quiet "\$@"
STUBEOF
chmod +x "$STUB_A"
WM_UV="$STUB_A" "$WF" --owner sf1 >"$WINGMAN_HOME/sf1.log" 2>&1 &
sf1pid=$!
wm_track "$sf1pid"
assert_true "sf1's cycle comes up live despite a failing stub in place" "wait_for_owner_status sf1"
# Poll (bounded, generous) for the stub to have actually been called at
# least 3 times - i.e. genuinely past its own 2-failure window - rather than
# a fixed sleep: every wm_py/wm_state call in this cycle routes through the
# stub (WM_UV is process-wide), so poll cadence is not assumed.
_sf1_i=0
while { _sf1_n="$(cat "$COUNTER_A" 2>/dev/null)"; case "$_sf1_n" in ''|*[!0-9]*) _sf1_n=0 ;; esac; [ "$_sf1_n" -lt 3 ]; } \
  && [ "$_sf1_i" -lt 100 ]; do
  sleep 0.2; _sf1_i=$((_sf1_i + 1))
done
assert_true "the stub was actually exercised past its own 2-failure window" "[ \"\$(cat '$COUNTER_A' 2>/dev/null)\" -ge 3 ]"
assert_true "two transient ambiguous reads (below the confirm threshold) never self-stop a healthy owner" "kill -0 $sf1pid"
kill "$sf1pid" 2>/dev/null

# The genuinely-and-persistently-ambiguous case: the stub fails every poll,
# standing in for a sustained inability to resolve the owner's status - the
# same debounce applies, but self-stop follows once the confirm threshold
# (WM_OWNER_MISSING_CONFIRMS, default 3) is actually reached.
test_new_home
wm_state crew-add --id sf2 --type lead --objective x --repo /tmp --window wm-sf2 --session-id ssf2 >/dev/null
wm_state crew-set --id sf2 --status working --summary "in progress" >/dev/null

STUB_B="$(wm_mktemp_file)"
cat > "$STUB_B" <<STUBEOF
#!/usr/bin/env bash
case "\$1" in
  */wm-state.py)
    if [ "\$2" = "crew-get" ] && [ "\$3" = "--id" ] && [ "\$4" = "sf2" ]; then
      exit 1
    fi
    ;;
esac
exec uv run --no-project --quiet "\$@"
STUBEOF
chmod +x "$STUB_B"
WM_UV="$STUB_B" "$WF" --owner sf2 >"$WINGMAN_HOME/sf2.log" 2>&1 &
sf2pid=$!
wm_track "$sf2pid"
assert_true "sf2's cycle comes up live" "wait_for_owner_status sf2"
assert_true "a persistently ambiguous owner read self-stops once the confirm threshold is reached" "wait_for_pid_gone $sf2pid"
sf2classify="$(wm_timeout 10 "$WF" --owner sf2 --classify 2>/dev/null)"
assert_eq "the confirmed-gone self-stop classifies as a deliberate stop" "$sf2classify" "stopped"

# --- Fix 3 MF2: a stall under the hard-grace threshold is never stolen from -
# (mirrors this plan's own repro 2, at the new, coarser threshold)
test_new_home
wm_state crew-add --id hg1 --type lead --objective x --repo /tmp --window wm-hg1 --session-id shg1 >/dev/null
wm_state crew-set --id hg1 --status working --summary "in progress" >/dev/null
export WM_WATCH_HARD_GRACE=20
"$WF" --owner hg1 >"$WINGMAN_HOME/hg1.log" 2>&1 &
hg1pid=$!
wm_track "$hg1pid"
assert_true "hg1's cycle comes up live" "wait_for_owner_status hg1"
kill -STOP "$hg1pid"
sleep 3   # well under the 20s hard grace
before_pid="$(cat "$WINGMAN_HOME/watch-hg1.pid" 2>/dev/null)"
out2="$(wm_timeout 15 "$WF" --owner hg1 2>&1)"
assert_contains "a stall under hard grace reports healthy, not a takeover" "$out2" "healthy"
after_pid="$(cat "$WINGMAN_HOME/watch-hg1.pid" 2>/dev/null)"
assert_eq "the pidfile is unchanged - no rival claim while under hard grace" "$after_pid" "$before_pid"
kill -CONT "$hg1pid" 2>/dev/null
kill "$hg1pid" 2>/dev/null
unset WM_WATCH_HARD_GRACE

# --- Fix 3 MF2 (round-2 MF-A): a wedge beyond hard grace is taken over, ------
# escalating SIGTERM -> SIGKILL, since a genuinely SIGSTOPped process cannot
# process a SIGTERM until it is continued or killed outright - the same
# unresponsive-to-SIGTERM shape a cycle wedged in a blocking foreground child
# (e.g. a hung tmux call) exhibits, per this plan's own repro 3.
test_new_home
wm_state crew-add --id hg2 --type lead --objective x --repo /tmp --window wm-hg2 --session-id shg2 >/dev/null
wm_state crew-set --id hg2 --status working --summary "in progress" >/dev/null
export WM_WATCH_HARD_GRACE=2
"$WF" --owner hg2 >"$WINGMAN_HOME/hg2.log" 2>&1 &
hg2pid=$!
wm_track "$hg2pid"
assert_true "hg2's cycle comes up live" "wait_for_owner_status hg2"
kill -STOP "$hg2pid"
sleep 4   # past the 2s hard grace
# NOT wm_timeout: a winning takeover falls through into "claim the cycle" and
# then BLOCKS (it is the fresh live cycle), so it never exits on its own -
# capturing it via a bounded foreground wm_timeout would only ever return
# once wm_timeout's own deadline force-kills it, discarding the very pid this
# block needs to assert is genuinely live. Background it instead, exactly
# like every other "arm a cycle" case in this suite, and poll its own log for
# its own "watcher: armed" line - the takeover completing (the old holder
# actually dying) is a strict PREFIX of that, so waiting for "armed" directly
# is the correct completion signal; waiting only for the old pid's death
# races ahead of the fresh claimant finishing its own claim sequence
# (teardown, OWNERLOCK creation, etc.) afterward.
"$WF" --owner hg2 >"$WINGMAN_HOME/hg2-takeover.log" 2>&1 &
newhg2pid=$!
wm_track "$newhg2pid"
_hg2_i=0
while ! grep -q "watcher: armed" "$WINGMAN_HOME/hg2-takeover.log" 2>/dev/null && [ "$_hg2_i" -lt 100 ]; do
  sleep 0.2; _hg2_i=$((_hg2_i + 1))
done
assert_true "the wedged (SIGSTOPped) holder is actually reaped by the takeover" "! kill -0 $hg2pid 2>/dev/null"
out3="$(cat "$WINGMAN_HOME/hg2-takeover.log")"
assert_contains "the arm detects the wedge and announces a takeover" "$out3" "treating as wedged and taking over"
assert_contains "the takeover claims a fresh cycle (armed, not healthy)" "$out3" "watcher: armed"
assert_true "the fresh claimant's pid is genuinely live" "kill -0 $newhg2pid"
assert_eq "the pidfile now names the fresh claimant" "$(cat "$WINGMAN_HOME/watch-hg2.pid" 2>/dev/null)" "$newhg2pid"
kill "$newhg2pid" 2>/dev/null
unset WM_WATCH_HARD_GRACE

# --- Fix 3 MF1: a reused pid does not falsely pass identity verification ----
# Pre-seeds $OWNERLOCK with the test harness's own live pid ($$) and a
# mismatched start-time stamp - the cheapest available stand-in for a
# reboot-inherited reused pid, since it is trivially live but is not a
# watch-fleet cycle at all.
test_new_home
wm_state crew-add --id ri1 --type lead --objective x --repo /tmp --window wm-ri1 --session-id sri1 >/dev/null
wm_state crew-set --id ri1 --status working --summary "in progress" >/dev/null
mkdir "$WINGMAN_HOME/watch-ri1.pid.owner"
printf '%s\n%s\n' "$$" "not-a-real-start-time" > "$WINGMAN_HOME/watch-ri1.pid.owner/owner"
out4="$(wm_timeout 15 "$WF" --owner ri1 2>&1)"
assert_contains "a fresh arm claims normally over a reused-pid stamp mismatch" "$out4" "watcher: armed"
assert_not_contains "the fresh arm never reports healthy against the mismatched stamp" "$out4" "healthy"
assert_not_contains "no takeover is attempted against the harness's own process" "$out4" "taking over"
assert_true "the test harness's own process ($$) is left untouched" "kill -0 $$"
riclean_pid="$(cat "$WINGMAN_HOME/watch-ri1.pid" 2>/dev/null)"
kill "$riclean_pid" 2>/dev/null

# --- Fix 3 MF3 (round-2 MF-B): $OWNERLOCK creation is verified end-to-end ----
# and fatal on failure - never a silently-unprotected cycle. The obstruction
# is chmod 500 on the pre-created $OWNERLOCK directory itself (with a file
# already inside it), which genuinely survives the code's own unconditional
# `rm -rf "$OWNERLOCK"` (removing that inner file needs write permission ON
# $OWNERLOCK, which is denied) - unlike a bare pre-created regular file, whose
# removal only needs write on ITS PARENT and is therefore silently cleared by
# that same rm -rf, which is exactly why the original form of this test could
# never fail.
test_new_home
wm_state crew-add --id ol1 --type lead --objective x --repo /tmp --window wm-ol1 --session-id sol1 >/dev/null
wm_state crew-set --id ol1 --status working --summary "in progress" >/dev/null
mkdir "$WINGMAN_HOME/watch-ol1.pid.owner"
: > "$WINGMAN_HOME/watch-ol1.pid.owner/owner"
chmod 500 "$WINGMAN_HOME/watch-ol1.pid.owner"
out5="$(wm_timeout 15 "$WF" --owner ol1 2>&1)"; rc5=$?
chmod 700 "$WINGMAN_HOME/watch-ol1.pid.owner" 2>/dev/null
assert_true "the arm dies loudly rather than proceeding with an unwritable owner lock" "[ $rc5 -ne 0 ]"
assert_contains "the die message names the owner lock" "$out5" "failed to create the owner lock"
assert_false "no pidfile is left behind" "[ -f '$WINGMAN_HOME/watch-ol1.pid' ]"
assert_false "no blocking loop was entered (beat file untouched)" "[ -f '$WINGMAN_HOME/watch-ol1.beat' ]"

test_summary
