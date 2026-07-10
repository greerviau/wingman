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

# --- fires immediately when an event is already pending on arm ---------------
test_new_home
wm_state crew-add --id a1 --type analyst --objective x --repo /tmp --window wm-a1 --session-id s1 >/dev/null
wm_state crew-set --id a1 --status done --summary "finished x" >/dev/null
out="$("$WF" 2>/dev/null)"; rc=$?
assert_eq "arm fires and exits 0 when a member is already done" "$rc" "0"
assert_contains "fire prints the done reason line" "$out" "done: a1 finished x"
assert_contains "wake file names the member" "$(cat "$WINGMAN_HOME/wake")" "a1"

# --- blocks while the fleet is only working, then fires on the flip ----------
test_new_home
wm_state crew-add --id b1 --type analyst --objective y --repo /tmp --window wm-b1 --session-id s2 >/dev/null
wm_state crew-set --id b1 --status working --summary "in progress" >/dev/null
"$WF" >"$WINGMAN_HOME/out.log" 2>&1 &
wpid=$!
sleep 3
assert_true "watcher keeps blocking while member is working" "kill -0 $wpid"

# singleton: a second arm sees the live cycle and stands down as 'healthy'
out2="$("$WF" 2>&1)"; rc2=$?
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
out3="$("$WF" 2>/dev/null)"
assert_contains "blocked member fires with its reason" "$out3" "blocked: c1"

# --- fire carries the full picture: deltas + directive + roster ---------------
test_new_home
wm_state crew-add --id d1 --type analyst --objective a --repo /tmp --window wm-d1 --session-id s4 >/dev/null
wm_state crew-add --id d2 --type developer --objective b --repo /tmp --window wm-d2 --session-id s5 >/dev/null
wm_state crew-set --id d2 --status working --summary "still building" >/dev/null
wm_state crew-set --id d1 --status review --artifact /tmp/plan.md >/dev/null
out4="$("$WF" 2>/dev/null)"
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
out5="$("$WF" --owner lead-x 2>/dev/null)"
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
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z4 'printf "Do you want to proceed?\n> 1. Yes\n  2. No, and tell it what to do differently\n"; sleep 600'
wm_age_status z4
out6="$(WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2 "$WF" 2>/dev/null)"
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
sleep 6
assert_true "watcher keeps blocking on quoted prompt text" "kill -0 $qpid"
assert_contains "quoting member is never flagged" "$(wm_state crew-get --id z5)" '"status": "working"'
kill "$qpid" 2>/dev/null
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- no false positive on a live pane even with full prompt shape -------------
# Phrase and options both visible, but the pane keeps changing (a working
# session's status line ticks) - the stability condition must refuse it.
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z6 --type developer --objective j --repo /tmp --window wm-z6 --session-id s13 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z6 'printf "Do you want to proceed?\n  1. Yes\n"; while :; do echo tick; sleep 1; done'
WM_WATCH_INTERVAL=1 "$WF" >/dev/null 2>&1 &
lpid=$!
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
out8="$(WM_STALL_IDLE=3 WM_STALL_ROOT_GRACE=2 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "pre-aged freeze still fires as blocked" "$out8" "blocked: z8"
assert_false "pre-aged freeze is never misdiagnosed stalled" "printf '%s' \"\$out8\" | grep -q 'stalled: z8'"
assert_contains "pre-aged frozen member reads blocked" "$(wm_state crew-get --id z8)" '"status": "blocked"'
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# --- per-tool phrasing variants still match (edit/create gates) ---------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id z9 --type developer --objective m --repo /tmp --window wm-z9 --session-id s16 >/dev/null
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z9 'printf "Do you want to make this edit to foo.py?\n  1. Yes\n  2. No\n"; sleep 600'
out9="$(WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
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
out10="$(WM_WATCH_INTERVAL=1 "$WF" 2>/dev/null)"
assert_contains "trust dialog fires as blocked via its option row" "$out10" "blocked: z10"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

test_summary
