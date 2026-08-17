#!/usr/bin/env bash
# E2E: the roster-terminal wake wiring inside bin/watch-fleet's own poll loop
# (Class D2) - a lead whose whole roster has closed out (or whose closed-out
# roster still carries an un-reaped `done` report) gets woken by its OWN
# cycle's exit, never by its parent's. State-layer candidate selection is
# already covered by tests/roster-terminal.test.sh; this file proves the
# wiring: the reason line, the wake file's own content and variant choice,
# that nothing on the lead's own record is touched, that a live report
# blocks it, and the owner scoping.
#
# Read this before writing any case here: the roster wake block sits AFTER
# the fire() call in bin/watch-fleet, and that is deliberate (§5.3 - a
# genuine crew event must always take precedence over a self-directed
# prompt). fire() exits the process, so a fixture holding any report in
# ATTENTION_STATES (blocked, review, done, died, stalled) makes
# cmd_needs_attention surface it and the watcher exit on the FIRST poll,
# long before the roster block is ever reached. Two cases below (#5's died
# reports and #7's done report) are exactly that shape, and need a two-arm
# sequence:
#   1. Arm once and let the announcement fire.
#   2. Consume it: run "$WF" --owner <lead> --classify - bin/watch-fleet
#      refuses a bare re-arm while an unclassified record is pending, so
#      skipping this step makes the second arm die with that refusal rather
#      than reaching anything.
#   3. Arm again. fire() acks every surfaced (id, updated) BEFORE writing
#      $EXITFILE, so this second arm finds the announcement deduped by
#      --suppress-on ack, falls through the fire line, and reaches the
#      roster block. _terminal_check_last resets to 0 on a fresh process, so
#      the first poll of the new arm is always due.
# Do NOT "fix" a case that cannot reach the roster block by moving that
# block above the fire line - that inverts the precedence this design
# depends on and destroys the cross-scope ack guarantee case 3 protects.
# The fixture or the arm sequence is what's wrong, never the placement.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
export WM_WATCH_INTERVAL=1
export WM_TERMINAL_CHECK_EVERY=1
export WM_ROSTER_TERMINAL_SECS=2

wm_py() { uv run --no-project --quiet python "$@"; }
field_of() {
  wm_state crew-get --id "$1" | wm_py -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"
}

# --- #1/#2/#3: a working lead with one stood-down report - no ATTENTION_STATES
# event of its own, so this needs only a single arm ---------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-lead1 'sleep 600'
wm_state crew-add --id lead1 --type lead --objective x --repo /tmp --window wm-lead1 --session-id s1 >/dev/null
wm_state crew-set --id lead1 --status working --summary "leading" >/dev/null
wm_state crew-add --id r1 --type developer --objective x --repo /tmp --window wm-r1 --session-id s-r1 --parent lead1 >/dev/null
wm_state crew-set --id r1 --status stood-down --summary closed >/dev/null

lead1_updated_before="$(field_of lead1 updated)"
acked_before="$(cat "$WINGMAN_HOME/acked.json" 2>/dev/null || echo '{}')"

out1="$(wm_timeout 20 "$WF" --owner lead1 2>/dev/null)"; rc1=$?
assert_eq "case1: the arm exits 0" "$rc1" "0"
assert_contains "case1: prints a roster-terminal: reason line" "$out1" "roster-terminal:"
assert_contains "case1: the reason carries the stood-down count" "$out1" "1 stood-down"
cls1="$(wm_timeout 10 "$WF" --owner lead1 --classify 2>/dev/null)"
assert_eq "case1: --classify reports fire" "$cls1" "fire"

wake1="$(cat "$WINGMAN_HOME/wake-lead1" 2>/dev/null)"
assert_contains "case2: the wake file has the re-evaluation instruction" "$wake1" "re-evaluate"
assert_contains "case2: the wake file's roster section names r1 by id" "$wake1" "r1"

assert_eq "case3: the lead's own status is unchanged" "$(field_of lead1 status)" "working"
assert_eq "case3: the lead's own updated stamp is unchanged" "$(field_of lead1 updated)" "$lead1_updated_before"
assert_eq "case3: acked.json is byte-identical (no cross-scope ack)" \
  "$(cat "$WINGMAN_HOME/acked.json" 2>/dev/null || echo '{}')" "$acked_before"

# --- #4: a live report (working, real window) blocks the wake --------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-lead4 'sleep 600'
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-r4 'sleep 600'
wm_state crew-add --id lead4 --type lead --objective x --repo /tmp --window wm-lead4 --session-id s4 >/dev/null
wm_state crew-set --id lead4 --status working --summary "leading" >/dev/null
wm_state crew-add --id r4 --type developer --objective x --repo /tmp --window wm-r4 --session-id s-r4 --parent lead4 >/dev/null
wm_state crew-set --id r4 --status working --summary "coding" >/dev/null

"$WF" --owner lead4 >"$WINGMAN_HOME/wf4.log" 2>&1 &
w4pid=$!
wm_track "$w4pid"
# Comfortably past WM_ROSTER_TERMINAL_SECS=2, even accounting for the several
# `uv run` subprocess calls (reconcile, stall-check, forward-motion-check,
# needs-attention, review-resurface-check, terminal-nudge-check) each real
# poll pays beyond the 1s WM_WATCH_INTERVAL sleep.
sleep 10
assert_true "case4: the arm keeps blocking - a live report blocks the wake" "kill -0 $w4pid"
kill "$w4pid" 2>/dev/null
wait "$w4pid" 2>/dev/null

# --- #5: an all-died roster - variant B, names crew-resume, dead reports first
# (needs the two-arm sequence: died is an ATTENTION_STATE) ------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-lead5 'sleep 600'
wm_state crew-add --id lead5 --type lead --objective x --repo /tmp --window wm-lead5 --session-id s5 >/dev/null
wm_state crew-set --id lead5 --status working --summary "leading" >/dev/null
wm_state crew-add --id r5a --type developer --objective x --repo /tmp --window wm-r5a --session-id s-r5a --parent lead5 >/dev/null
wm_state crew-set --id r5a --status died --summary gone >/dev/null
wm_state crew-add --id r5b --type developer --objective x --repo /tmp --window wm-r5b --session-id s-r5b --parent lead5 >/dev/null
wm_state crew-set --id r5b --status died --summary gone >/dev/null

out5a="$(wm_timeout 20 "$WF" --owner lead5 2>/dev/null)"; rc5a=$?
assert_eq "case5 arm1: exits 0 on the died announcement" "$rc5a" "0"
wm_timeout 10 "$WF" --owner lead5 --classify >/dev/null 2>&1

out5b="$(wm_timeout 20 "$WF" --owner lead5 2>/dev/null)"; rc5b=$?
assert_eq "case5 arm2: exits 0 on the roster wake" "$rc5b" "0"
assert_contains "case5: reason line is roster-terminal:" "$out5b" "roster-terminal:"
assert_contains "case5: the reason carries the died count" "$out5b" "2 of them died"
wake5="$(cat "$WINGMAN_HOME/wake-lead5" 2>/dev/null)"
assert_contains "case5: variant B names crew-resume" "$wake5" "crew-resume"
_dead_line5="$(printf '%s\n' "$wake5" | grep -n "Start with the dead reports" | head -1 | cut -d: -f1)"
_handoff_line5="$(printf '%s\n' "$wake5" | grep -n "write your closing handoff" | head -1 | cut -d: -f1)"
assert_true "case5: dead-reports instruction is present" "[ -n '$_dead_line5' ]"
assert_true "case5: closing-handoff instruction is present" "[ -n '$_handoff_line5' ]"
assert_true "case5: the dead-reports instruction comes BEFORE the closing-handoff one" \
  "[ '$_dead_line5' -lt '$_handoff_line5' ]"

# --- #6: an all-stood-down roster - variant A, never mentions crew-resume or
# crew-standdown -------------------------------------------------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-lead6 'sleep 600'
wm_state crew-add --id lead6 --type lead --objective x --repo /tmp --window wm-lead6 --session-id s6 >/dev/null
wm_state crew-set --id lead6 --status working --summary "leading" >/dev/null
wm_state crew-add --id r6 --type developer --objective x --repo /tmp --window wm-r6 --session-id s-r6 --parent lead6 >/dev/null
wm_state crew-set --id r6 --status stood-down --summary closed >/dev/null

out6="$(wm_timeout 20 "$WF" --owner lead6 2>/dev/null)"; rc6=$?
assert_eq "case6: the arm exits 0" "$rc6" "0"
assert_contains "case6: reason line is roster-terminal:" "$out6" "roster-terminal:"
wake6="$(cat "$WINGMAN_HOME/wake-lead6" 2>/dev/null)"
assert_not_contains "case6: variant A never mentions crew-resume" "$wake6" "crew-resume"
assert_not_contains "case6: variant A never mentions crew-standdown" "$wake6" "crew-standdown"

# --- #7: an un-reaped done roster - roster-unreaped:, names the done report
# (needs the two-arm sequence: done is an ATTENTION_STATE) ------------------
test_new_home
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-lead7 'sleep 600'
wm_state crew-add --id lead7 --type lead --objective x --repo /tmp --window wm-lead7 --session-id s7 >/dev/null
wm_state crew-set --id lead7 --status working --summary "leading" >/dev/null
wm_state crew-add --id r7a --type developer --objective x --repo /tmp --window wm-r7a --session-id s-r7a --parent lead7 >/dev/null
wm_state crew-set --id r7a --status done --artifact "plan.md" --summary "handed off" >/dev/null
wm_state crew-add --id r7b --type developer --objective x --repo /tmp --window wm-r7b --session-id s-r7b --parent lead7 >/dev/null
wm_state crew-set --id r7b --status stood-down --summary closed >/dev/null

out7a="$(wm_timeout 20 "$WF" --owner lead7 2>/dev/null)"; rc7a=$?
assert_eq "case7 arm1: exits 0 on the done announcement" "$rc7a" "0"
wm_timeout 10 "$WF" --owner lead7 --classify >/dev/null 2>&1

out7b="$(wm_timeout 20 "$WF" --owner lead7 2>/dev/null)"; rc7b=$?
assert_eq "case7 arm2: exits 0 on the roster wake" "$rc7b" "0"
assert_contains "case7: reason line is roster-unreaped:" "$out7b" "roster-unreaped:"
wake7="$(cat "$WINGMAN_HOME/wake-lead7" 2>/dev/null)"
assert_contains "case7: the wake file names the un-reaped report by id" "$wake7" "r7a"
_standdown_line7="$(printf '%s\n' "$wake7" | grep -n "Close them out now" | head -1 | cut -d: -f1)"
_handoff_line7="$(printf '%s\n' "$wake7" | grep -n "write your closing handoff" | head -1 | cut -d: -f1)"
assert_true "case7: the close-them-out instruction is present" "[ -n '$_standdown_line7' ]"
assert_true "case7: the closing-handoff instruction is present" "[ -n '$_handoff_line7' ]"
assert_true "case7: the wake file's FIRST instruction is to close the done report out" \
  "[ '$_standdown_line7' -lt '$_handoff_line7' ]"

# --- #8: OWNER="" (the top-level cycle) never produces either reason, even
# with an all-terminal roster under owner "" ---------------------------------
# The shell-side `[ -n "$OWNER" ]` guard at the call site is, by construction,
# unreachable to discriminate on its own: cmd_roster_terminal_check's own
# `--self ""` guard returns immediately regardless of roster contents (it
# checks self_id emptiness before reading the roster at all), so no roster
# shape can ever make "remove the shell guard" and "keep it" differ in
# observable behavior. This mirrors the accepted, documented $_tc_due
# belt-and-braces situation elsewhere in this plan - the guard stays for
# defense in depth, and this case still proves the OBSERVABLE behavior
# (never fires under owner "") even though it cannot discriminate that one
# specific redundant line.
test_new_home
wm_state crew-add --id r8 --type developer --objective x --repo /tmp --window wm-r8 --session-id s-r8 >/dev/null
wm_state crew-set --id r8 --status stood-down --summary closed >/dev/null

"$WF" >"$WINGMAN_HOME/wf8.log" 2>&1 &
w8pid=$!
wm_track "$w8pid"
sleep 5
assert_true "case8: the top-level cycle keeps blocking, never fires a roster wake" "kill -0 $w8pid"
kill "$w8pid" 2>/dev/null
wait "$w8pid" 2>/dev/null

test_summary
