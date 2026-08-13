#!/usr/bin/env bash
# E2E: wm-state loop-wedge-check (issue #268, layer B) - the hand-rolled
# foreground polling-loop detection backstop. Shares wedge-check's own
# anchor-tracking/pane-continuity/TOCTOU machinery (issue #202) via
# _wedge_check_common, generalized to a second --proc-re pattern (a
# while/until keyword followed by a sleep invocation in a descendant's own
# `ps` args - WM_LOOP_WEDGE_PROC_RE_DEFAULT). Driven directly against
# synthetic process trees, exactly like tests/wedge-check.test.sh - the pane
# observations arrive as arguments, so no tmux is needed.
#
# threshold=3s, pane-gap=5s (matching wedge-check.test.sh's own values so the
# suite stays fast). --proc-re is left to default through
# WM_LOOP_WEDGE_PROC_RE_DEFAULT (never passed explicitly), matching bin/
# watch-fleet's own real call site.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

wm_py() { uv run --no-project --quiet python "$@"; }

status_of() {
  wm_py -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' \
    "$WINGMAN_HOME/crew/$1.json"
}

roster_status_of() {
  wm_py -c '
import json, sys
for r in json.load(open(sys.argv[1])):
    if r["id"] == sys.argv[2]:
        print(r["status"])
' "$WINGMAN_HOME/crew.json" "$1"
}

blocker_of() {
  wm_py -c 'import json,sys; print(json.load(open(sys.argv[1])).get("blocker") or "")' \
    "$WINGMAN_HOME/crew/$1.json"
}

stall_field() {
  wm_py -c '
import json, sys
d = json.load(open(sys.argv[1])).get("stall") or {}
v = d.get(sys.argv[2])
print(v if v is not None else "")
' "$WINGMAN_HOME/crew/$1.json" "$2"
}

spawn_bg() { "$@" & wm_track "$!"; }

# A matching root: the child is a DISTINCT, stable-pid shell process forked
# to run the backgrounded "while :; do sleep 100; done" compound command,
# whose own `ps` args are literally "sh -c while :; do sleep 100; done &
# wait" - matching WM_LOOP_WEDGE_PROC_RE_DEFAULT (a while/until keyword
# followed by a sleep invocation, in that order, anywhere in the text). The
# root's OWN args also happen to contain the same text (it is the same -c
# string), but _wedge_descendant excludes pid == pane_pid unconditionally,
# so this can never self-match.
spawn_matching_root() { spawn_bg sh -c 'while :; do sleep 100; done & wait'; }
# A non-matching root: its child execs directly into `sleep 100` (a plain
# long-running sleep, no while/until keyword anywhere in its own args), so
# it satisfies the existing (issue #202) wedge-check's own default pattern
# but never this one.
spawn_nonmatching_root() { spawn_bg sh -c 'sleep 100 & wait'; }

CHECK="--root-grace 1 --threshold 3 --pane-gap 5"

# =====================================================================
# 1. THE FLIP: continuous pane + stale record + a matching while/sleep
#    descendant -> flips to stalled with stall.source == "loop", reusing
#    the same shared machinery wedge-check's own tests already cover in
#    depth (anchoring, TOCTOU, idempotence) - this file focuses on what is
#    NEW here: the second pattern and its own provenance/reason text.
# =====================================================================
test_new_home
wm_state crew-add --id loop1 --type developer --objective a --repo /tmp --window wm-loop1 --session-id s1 >/dev/null
wm_state crew-set --id loop1 --status working --summary "waiting on a suite to finish" >/dev/null
spawn_matching_root
loop1_root=$!

out="$(wm_state loop-wedge-check --id loop1 --pane-idle 0 --pane-pid "$loop1_root" $CHECK)"
assert_eq "first poll only anchors, does not flip" "$out" ""
assert_eq "still working after the anchoring poll" "$(status_of loop1)" "working"

sleep 3.3
out="$(wm_state loop-wedge-check --id loop1 --pane-idle 0 --pane-pid "$loop1_root" $CHECK)"
assert_eq "continuous pane + stale record + matching descendant flips" "$out" "stalled loop1"
assert_eq "status file reads stalled" "$(status_of loop1)" "stalled"
assert_eq "roster mirrors stalled" "$(roster_status_of loop1)" "stalled"

loop1_json="$(cat "$WINGMAN_HOME/crew/loop1.json")"
assert_contains "reason names the hand-rolled polling loop signature" "$loop1_json" "hand-rolled foreground polling loop"
assert_contains "reason names the missing timeout" "$loop1_json" "no independent timeout"
assert_contains "reason names the takeover/standdown remedy" "$loop1_json" "crew-takeover loop1"
assert_not_contains "reason does NOT use the watch-fleet/pr-watch wedge wording" "$loop1_json" "blocking watcher"
assert_eq "stall.source records 'loop', not 'wedge'" "$(stall_field loop1 source)" "loop"
assert_true "stall.wedge_pid is a positive integer naming the matched descendant" \
  "[ '$(stall_field loop1 wedge_pid)' -gt 0 ] 2>/dev/null"

# Idempotence: a second call after the flip is a no-op.
out="$(wm_state loop-wedge-check --id loop1 --pane-idle 0 --pane-pid "$loop1_root" $CHECK)"
assert_eq "a second call once already stalled is a silent no-op" "$out" ""

# needs-attention surfaces the loop reason as the note.
att="$(wm_state needs-attention)"
note="$(printf '%s\n' "$att" | awk -F'\t' '$1=="loop1" {print $4}')"
assert_contains "needs-attention note is the loop-wedge reason" "$note" "hand-rolled foreground polling loop"

# =====================================================================
# 2. Not flipped: continuously active pane + stale record but NO matching
#    descendant (a plain long-running sleep, no while/until keyword) - the
#    residual-gap boundary this detector's own pattern is meant to respect.
# =====================================================================
test_new_home
wm_state crew-add --id nomatch1 --type developer --objective b --repo /tmp --window wm-nomatch1 --session-id s2 >/dev/null
wm_state crew-set --id nomatch1 --status working --summary "reading" >/dev/null
spawn_nonmatching_root
nomatch1_root=$!

wm_state loop-wedge-check --id nomatch1 --pane-idle 0 --pane-pid "$nomatch1_root" $CHECK >/dev/null
sleep 3.3
out="$(wm_state loop-wedge-check --id nomatch1 --pane-idle 0 --pane-pid "$nomatch1_root" $CHECK)"
assert_eq "no matching descendant: never flips, however long the window" "$out" ""
assert_eq "nomatch1 stays working" "$(status_of nomatch1)" "working"

# =====================================================================
# 3. Not flipped: pane idle past --pane-gap resets the anchor, however long
#    the matching descendant has already been alive - the fresh anchor can
#    still eventually flip on its own once continuity is genuinely observed.
# =====================================================================
test_new_home
wm_state crew-add --id idle1 --type developer --objective c --repo /tmp --window wm-idle1 --session-id s3 >/dev/null
wm_state crew-set --id idle1 --status working --summary "building" >/dev/null
spawn_matching_root
idle1_root=$!

out="$(wm_state loop-wedge-check --id idle1 --pane-idle 0 --pane-pid "$idle1_root" $CHECK)"
assert_eq "poll 1 (live): anchors, no flip" "$out" ""
sleep 1
out="$(wm_state loop-wedge-check --id idle1 --pane-idle 999 --pane-pid "$idle1_root" $CHECK)"
assert_eq "poll 2 (idle past pane-gap): resets the anchor, no flip" "$out" ""
sleep 4
out="$(wm_state loop-wedge-check --id idle1 --pane-idle 0 --pane-pid "$idle1_root" $CHECK)"
assert_eq "poll 3 (live again): freshly re-anchored, not yet past threshold" "$out" ""
assert_eq "still working - the reset actually held" "$(status_of idle1)" "working"
sleep 3.3
out="$(wm_state loop-wedge-check --id idle1 --pane-idle 0 --pane-pid "$idle1_root" $CHECK)"
assert_eq "poll 4: the fresh anchor can still eventually flip on its own" "$out" "stalled idle1"

# =====================================================================
# 4. Revert path: after a "loop"-sourced stall, kill the matched descendant
#    pid and run stall-recheck across --confirmations polls -> reverts,
#    restoring prev_status/prev_blocker losslessly - exactly as the existing
#    "wedge" revert test already verifies for the watcher case
#    (tests/stall-recheck.test.sh), now exercising the shared
#    _wedge_pid_contradicted path for source == "loop".
# =====================================================================
test_new_home
wm_state crew-add --id revert1 --type developer --objective d --repo /tmp --window wm-revert1 --session-id s4 >/dev/null
wm_state crew-set --id revert1 --status blocked --blocker "should we retry or bail?" >/dev/null

# A reapable matching descendant: the ROOT backgrounds one directly-killable
# child (a distinct "sh -c while :; do sleep 1; done" process - no further
# forking of its own, since the loop runs un-backgrounded within it, so its
# own pid is stable and it can be killed cleanly), waits specifically for
# it, and falls into its own self-bounding keep-alive loop once that child
# dies - so killing the recorded descendant never orphans anything and
# never touches the root itself, matching tests/stall-recheck.test.sh's own
# spawn_reapable_matching_root pattern.
spawn_bg sh -c 'sh -c "while :; do sleep 1; done" & child=$!; wait $child; while :; do sleep 1; done'
revert1_root=$!

wm_state loop-wedge-check --id revert1 --pane-idle 0 --pane-pid "$revert1_root" $CHECK >/dev/null
sleep 3.3
wm_state loop-wedge-check --id revert1 --pane-idle 0 --pane-pid "$revert1_root" $CHECK >/dev/null
assert_eq "revert1 flipped to stalled via the loop detector" "$(status_of revert1)" "stalled"
assert_eq "stall.source is 'loop'" "$(stall_field revert1 source)" "loop"
revert1_desc_pid="$(stall_field revert1 wedge_pid)"
assert_true "the recorded descendant pid is a positive integer" "[ '$revert1_desc_pid' -gt 0 ] 2>/dev/null"

kill "$revert1_desc_pid" 2>/dev/null

out="$(wm_state stall-recheck --id revert1 --pane-pid "$revert1_root" --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "revert1: first recheck poll after the kill does not yet revert" "$out" ""
out="$(wm_state stall-recheck --id revert1 --pane-pid "$revert1_root" --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "revert1: second recheck poll reverts" "$out" "revert1 loop cleared after 2 polls"
assert_eq "status reverts to blocked" "$(status_of revert1)" "blocked"
assert_eq "the blocker is restored losslessly" "$(blocker_of revert1)" "should we retry or bail?"

test_summary
