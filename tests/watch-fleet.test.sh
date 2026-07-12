#!/usr/bin/env bash
# E2E: the wake loop. Proves the watcher blocks on a still-working fleet, fires
# and exits with a reason the instant a member becomes actionable, delivers a
# pending event on arm (at-least-once across re-arms), refuses to start a second
# live cycle (singleton), carries deltas + directive on stdout and the full
# owner-scoped roster in the wake file, and - with a real tmux session - flags a
# silently stalled member without false-positiving on busy or parked panes.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
export WM_WATCH_INTERVAL=1
# The watcher blocks until an event fires, so bound every foreground run with
# wm_timeout and reap any backgrounded one on exit; a watcher that never fires can
# then never wedge this file or, through run.sh, the whole suite.
trap wm_kill_tracked EXIT

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
wm_state crew-add --id c1 --type developer --objective z --repo /tmp --window wm-c1 --session-id s3 >/dev/null
wm_state crew-set --id c1 --status blocked --blocker "need a decision" >/dev/null
out3="$(wm_timeout 45 "$WF" 2>/dev/null)"
assert_contains "blocked member fires with its reason" "$out3" "blocked: c1"

# --- fire carries the full picture: deltas + directive + roster ---------------
test_new_home
wm_state crew-add --id d1 --type analyst --objective a --repo /tmp --window wm-d1 --session-id s4 >/dev/null
wm_state crew-add --id d2 --type developer --objective b --repo /tmp --window wm-d2 --session-id s5 >/dev/null
wm_state crew-set --id d2 --status working --summary "still building" >/dev/null
wm_state crew-set --id d1 --status review --artifact /tmp/plan.md >/dev/null
out4="$(wm_timeout 45 "$WF" 2>/dev/null)"
assert_contains "fire prints the review reason line" "$out4" "review: d1 /tmp/plan.md"
assert_contains "stdout directs beyond the deltas" "$out4" "not the full picture"
assert_contains "directive names the wake file path" "$out4" "$WINGMAN_HOME/wake"
assert_contains "directive demands the roster report" "$out4" "roster status"
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

# --- stall fires end-to-end (tmux integration) --------------------------------
# An errored/idle agent: a window running a bare sleep - no output, no
# late-started children, no CPU - with a stale status file.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z1 --type developer --objective e --repo /tmp --window wm-z1 --session-id s8 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z1 'sleep 600'
wm_age_status z1
WM_STALL_IDLE=6 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 \
  "$WF" >"$WINGMAN_HOME/stall.log" 2>&1 &
spid=$!
wm_track "$spid"
i=0; while kill -0 "$spid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher exited on the stall" "kill -0 $spid"
assert_contains "cycle exits with the stalled reason" "$(cat "$WINGMAN_HOME/stall.log")" "stalled: z1"
assert_contains "wake file names the stalled member" "$(cat "$WINGMAN_HOME/wake")" "z1"
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

# --- an api-error nudge fires once, not again within the cooldown (#23) -------
# A pane whose tail matches WM_APIERR_RE, gone idle past STALL_IDLE, but with a
# busy (silent) child so the execution probe finds activity and never confirms a
# stall - isolates the nudge behavior from the escalation path below.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id ae1 --type developer --objective h --repo /tmp --window wm-ae1 --session-id sae1 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-ae1 'echo "Error: rate limit exceeded (429 Too Many Requests)"; while :; do :; done'
wm_age_status ae1
WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_APIERR_NUDGE_COOLDOWN=60 WM_WATCH_INTERVAL=1 \
  "$WF" >/dev/null 2>&1 &
napid=$!
wm_track "$napid"
nudgefile="$WINGMAN_HOME/apierr-ae1.nudged"
_wait=0
while [ ! -f "$nudgefile" ] && [ "$_wait" -lt 25 ]; do sleep 1; _wait=$((_wait+1)); done
assert_true "the nudge marker file appears" "[ -f '$nudgefile' ]"
assert_true "watcher keeps blocking (CPU activity suppresses the stall flip)" "kill -0 $napid"
assert_contains "the member stays working, not flipped stalled" \
  "$(wm_state crew-get --id ae1)" '"status": "working"'
first_mtime="$(uv run --no-project --quiet python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$nudgefile")"
sleep 6
second_mtime="$(uv run --no-project --quiet python -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$nudgefile")"
assert_eq "the nudge is not re-sent within the cooldown window" "$first_mtime" "$second_mtime"
kill "$napid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- an unrecovered api-error escalates to stalled with the api-error reason ---
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id ae2 --type developer --objective i --repo /tmp --window wm-ae2 --session-id sae2 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-ae2 'echo "Error: connection error (ECONNRESET)"; sleep 600'
wm_age_status ae2
WM_STALL_IDLE=6 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 \
  "$WF" >"$WINGMAN_HOME/apierr.log" 2>&1 &
aepid=$!
wm_track "$aepid"
i=0; while kill -0 "$aepid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 1; i=$((i+1)); done
assert_false "watcher exited on the api-error stall" "kill -0 $aepid"
assert_contains "cycle exits with the stalled reason carrying api-error:" \
  "$(cat "$WINGMAN_HOME/apierr.log")" "stalled: ae2 api-error:"
assert_true "the nudge marker file was written before escalating" \
  "[ -f '$WINGMAN_HOME/apierr-ae2.nudged' ]"
kill "$aepid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
