#!/usr/bin/env bash
# E2E: wm-state wedge-check (issue #202, layer B) - the foreground-watcher
# wedge detector. Driven directly against synthetic process trees, exactly
# like tests/stall-check.test.sh - the pane observations arrive as arguments,
# so no tmux is needed. A root process (spawned via `sh -c '... & wait'`, so
# the root and its one background child are DISTINCT pids - the root's own
# args never match --proc-re, only the child's do) stands in for a pane's
# root pid; --pane-pid is that root's pid throughout.
#
# threshold=3s, pane-gap=5s (small so the suite stays fast); a "live" poll
# passes --pane-idle 0, an "idle" poll passes something far past pane-gap.
# Two live polls spaced under pane-gap apart keep the SAME anchor (`since`
# does not move), so `now - since >= threshold` becomes true; a live poll
# preceded by a gap OVER pane-gap (no poll during it) re-anchors instead.
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

spawn_bg() { "$@" & wm_track "$!"; }

# A matching root: the child's args are literally "sleep 600", matched by
# --proc-re sleep (a plain substring, no spaces needed in the pattern - kept
# argument-splitting-safe on purpose). The root's own OWN args ("sh -c ...")
# also happen to contain the literal text "sleep 600", but _wedge_descendant
# excludes pid == pane_pid unconditionally, so this can never self-match.
spawn_matching_root() { spawn_bg sh -c 'sleep 600 & wait'; }
# A non-matching root: its child's args are "cat", which never matches
# --proc-re sleep.
spawn_nonmatching_root() { spawn_bg sh -c 'cat & wait'; }

CHECK="--root-grace 1 --threshold 3 --pane-gap 5 --proc-re sleep"

# =====================================================================
# 1. THE INCIDENT'S OWN ORDERING (the primary assertion, revision 1's own
#    failure case): a blocked member is answered, self-reports ONCE in
#    acknowledgment, then goes silent while its pane stays continuously
#    active and a matching descendant runs -> flips to stalled.
# =====================================================================
test_new_home
wm_state crew-add --id inc1 --type developer --objective a --repo /tmp --window wm-inc1 --session-id s1 >/dev/null
wm_state crew-set --id inc1 --status blocked --blocker "should we use approach A or B?" >/dev/null
# The one self-report acknowledging the answer, per the incident's own
# ordering (receive answer -> crew-set -> act) - status stays 'blocked'.
wm_state crew-set --id inc1 --status blocked --summary "thanks - resuming, will re-arm my watcher" >/dev/null
spawn_matching_root
inc1_root=$!

out="$(wm_state wedge-check --id inc1 --pane-idle 0 --pane-pid "$inc1_root" $CHECK)"
assert_eq "first poll only anchors, does not flip" "$out" ""
assert_eq "still blocked after the anchoring poll" "$(status_of inc1)" "blocked"

sleep 3.3
out="$(wm_state wedge-check --id inc1 --pane-idle 0 --pane-pid "$inc1_root" $CHECK)"
assert_eq "continuous pane + stale record + matching descendant flips" "$out" "stalled inc1"
assert_eq "status file reads stalled" "$(status_of inc1)" "stalled"
assert_eq "roster mirrors stalled" "$(roster_status_of inc1)" "stalled"

inc1_json="$(cat "$WINGMAN_HOME/crew/inc1.json")"
assert_contains "reason names the FOREGROUND wedge signature" "$inc1_json" "FOREGROUND"
assert_contains "reason names the matched descendant" "$inc1_json" "sleep 600"
assert_contains "reason names the takeover/standdown remedy" "$inc1_json" "crew-takeover inc1"
assert_contains "reason names issue #202" "$inc1_json" "issue #202"
assert_contains "the blocker TEXT survives in the new summary" "$inc1_json" "should we use approach A or B?"
assert_contains "the last summary is carried too" "$inc1_json" "thanks - resuming"
assert_not_contains "the blocker FIELD itself is cleared" "$inc1_json" '"blocker"'

# needs-attention surfaces the stall reason as the note, never the old
# blocker text on its own.
att="$(wm_state needs-attention)"
note="$(printf '%s\n' "$att" | awk -F'\t' '$1=="inc1" {print $4}')"
assert_contains "needs-attention note is the stall reason" "$note" "FOREGROUND"

# --- Idempotence: a second call after the flip is a no-op -------------------
out="$(wm_state wedge-check --id inc1 --pane-idle 0 --pane-pid "$inc1_root" $CHECK)"
assert_eq "a second call once already stalled is a silent no-op" "$out" ""
assert_eq "status is unchanged by the idempotent call" "$(status_of inc1)" "stalled"

# =====================================================================
# 2. The same for a WORKING member (the residual-gap case this plan closes -
#    cmd_stall_check never covered 'blocked' either, but wedge-check covers
#    both from day one).
# =====================================================================
test_new_home
wm_state crew-add --id inc2 --type developer --objective b --repo /tmp --window wm-inc2 --session-id s2 >/dev/null
wm_state crew-set --id inc2 --status working --summary "digging through logs" >/dev/null
spawn_matching_root
inc2_root=$!

wm_state wedge-check --id inc2 --pane-idle 0 --pane-pid "$inc2_root" $CHECK >/dev/null
sleep 3.3
out="$(wm_state wedge-check --id inc2 --pane-idle 0 --pane-pid "$inc2_root" $CHECK)"
assert_eq "a working member wedges the same way and flips" "$out" "stalled inc2"
inc2_json="$(cat "$WINGMAN_HOME/crew/inc2.json")"
assert_not_contains "no blocker clause when there was no blocker" "$inc2_json" "unanswered question was"
assert_contains "the prior summary is still carried" "$inc2_json" "digging through logs"

# =====================================================================
# 3. Not flipped: pane idle past --pane-gap at ANY point in the window -
#    the anchor resets, however long the descendant has already been alive.
#    (This is also the shape a healthy member idle at its prompt produces.)
# =====================================================================
test_new_home
wm_state crew-add --id idle1 --type developer --objective c --repo /tmp --window wm-idle1 --session-id s3 >/dev/null
wm_state crew-set --id idle1 --status working --summary "building" >/dev/null
spawn_matching_root
idle1_root=$!

out="$(wm_state wedge-check --id idle1 --pane-idle 0 --pane-pid "$idle1_root" $CHECK)"
assert_eq "poll 1 (live): anchors, no flip" "$out" ""
sleep 1
out="$(wm_state wedge-check --id idle1 --pane-idle 999 --pane-pid "$idle1_root" $CHECK)"
assert_eq "poll 2 (idle past pane-gap): resets the anchor, no flip" "$out" ""
sleep 4
out="$(wm_state wedge-check --id idle1 --pane-idle 0 --pane-pid "$idle1_root" $CHECK)"
assert_eq "poll 3 (live again): freshly re-anchored, not yet past threshold" "$out" ""
assert_eq "still working - the reset actually held" "$(status_of idle1)" "working"
sleep 3.3
out="$(wm_state wedge-check --id idle1 --pane-idle 0 --pane-pid "$idle1_root" $CHECK)"
assert_eq "poll 4: the fresh anchor can still eventually flip on its own" "$out" "stalled idle1"

# =====================================================================
# 4. Not flipped: a LEAD parked with its own correctly-armed background
#    watcher - a stale record (30+ min, routine) and an unboundedly long
#    matching descendant satisfy gates 5 and 6 EXACTLY like a real wedge;
#    only gate 3 (pane continuity) separates them, and a healthy parked
#    lead's pane is intermittently idle (never continuously live), so the
#    anchor can never accumulate. If gate 3 is ever "simplified" down to
#    descendant duration alone, this assertion must start failing.
# =====================================================================
test_new_home
wm_state crew-add --id lead1 --type lead --objective d --repo /tmp --window wm-lead1 --session-id s4 >/dev/null
wm_state crew-set --id lead1 --status blocked --blocker "waiting on crew" >/dev/null
wm_age_status lead1 40   # 30+ minutes stale is routine for a parked lead
spawn_matching_root       # stands in for the lead's own unbounded watch-fleet cycle
lead1_root=$!

out="$(wm_state wedge-check --id lead1 --pane-idle 999 --pane-pid "$lead1_root" $CHECK)"
assert_eq "idle pane, poll 1: not flipped" "$out" ""
sleep 4
out="$(wm_state wedge-check --id lead1 --pane-idle 999 --pane-pid "$lead1_root" $CHECK)"
assert_eq "idle pane, poll 2: still not flipped" "$out" ""
sleep 3.3
out="$(wm_state wedge-check --id lead1 --pane-idle 999 --pane-pid "$lead1_root" $CHECK)"
assert_eq "a healthy parked lead is never flipped, however long its watcher has run" "$out" ""
assert_eq "lead1 stays blocked throughout" "$(status_of lead1)" "blocked"

# =====================================================================
# 5. Not flipped: loss of watcher coverage (MF2) - the anchor is
#    established, then a gap LONGER than --pane-gap passes with NO call at
#    all, then a live observation arrives: the entry must re-anchor, so a
#    healthy member observed live on both sides of a watcher outage never
#    accumulates credit for the gap itself.
# =====================================================================
test_new_home
wm_state crew-add --id cov1 --type developer --objective e --repo /tmp --window wm-cov1 --session-id s5 >/dev/null
wm_state crew-set --id cov1 --status working --summary "compiling" >/dev/null
spawn_matching_root
cov1_root=$!

out="$(wm_state wedge-check --id cov1 --pane-idle 0 --pane-pid "$cov1_root" $CHECK)"
assert_eq "poll 1: anchors" "$out" ""
# Simulate a watcher outage: a gap longer than --pane-gap (5s) with NO call
# at all in between - unlike test 3's idle-pane reset, coverage is lost here
# without any poll ever observing the pane as idle; the drop happens purely
# because last_seen itself has aged past --pane-gap by the time the next
# poll arrives.
sleep 6
out="$(wm_state wedge-check --id cov1 --pane-idle 0 --pane-pid "$cov1_root" $CHECK)"
assert_eq "poll 2, after an unwatched gap: re-anchors, no flip" "$out" ""
sleep 3.3
out="$(wm_state wedge-check --id cov1 --pane-idle 0 --pane-pid "$cov1_root" $CHECK)"
assert_eq "poll 3: the re-anchor can still eventually flip on its own" "$out" "stalled cov1"

# =====================================================================
# 6. Not flipped: continuously active pane + stale record but NO matching
#    descendant (an ordinary long foreground task doing something else).
# =====================================================================
test_new_home
wm_state crew-add --id nomatch1 --type developer --objective f --repo /tmp --window wm-nomatch1 --session-id s6 >/dev/null
wm_state crew-set --id nomatch1 --status working --summary "reading" >/dev/null
spawn_nonmatching_root
nomatch1_root=$!

wm_state wedge-check --id nomatch1 --pane-idle 0 --pane-pid "$nomatch1_root" $CHECK >/dev/null
sleep 3.3
out="$(wm_state wedge-check --id nomatch1 --pane-idle 0 --pane-pid "$nomatch1_root" $CHECK)"
assert_eq "no matching descendant: never flips, however long the window" "$out" ""
assert_eq "nomatch1 stays working" "$(status_of nomatch1)" "working"

# =====================================================================
# 7. Not flipped: continuously active pane + matching descendant, but the
#    member self-reported INSIDE the window - a fresh crew-set defeats
#    gate 5 even though gates 3 and 6 both hold.
# =====================================================================
test_new_home
wm_state crew-add --id selfreport1 --type developer --objective g --repo /tmp --window wm-selfreport1 --session-id s7 >/dev/null
wm_state crew-set --id selfreport1 --status working --summary "starting" >/dev/null
spawn_matching_root
sr1_root=$!

wm_state wedge-check --id selfreport1 --pane-idle 0 --pane-pid "$sr1_root" $CHECK >/dev/null
sleep 1.5
wm_state crew-set --id selfreport1 --status working --summary "still going, just checked in" >/dev/null
sleep 1.8
out="$(wm_state wedge-check --id selfreport1 --pane-idle 0 --pane-pid "$sr1_root" $CHECK)"
assert_eq "a self-report inside the window defeats the flip" "$out" ""
assert_eq "selfreport1 stays working" "$(status_of selfreport1)" "working"

# =====================================================================
# 8. Not flipped: inside the window on either clock (not enough real time
#    has passed yet - a plain "second call always flips" bug would trip
#    this).
# =====================================================================
test_new_home
wm_state crew-add --id early1 --type developer --objective h --repo /tmp --window wm-early1 --session-id s8 >/dev/null
wm_state crew-set --id early1 --status working --summary "just started" >/dev/null
spawn_matching_root
early1_root=$!

wm_state wedge-check --id early1 --pane-idle 0 --pane-pid "$early1_root" $CHECK >/dev/null
sleep 1.5   # half of --threshold 3
out="$(wm_state wedge-check --id early1 --pane-idle 0 --pane-pid "$early1_root" $CHECK)"
assert_eq "well inside the threshold window: not flipped" "$out" ""
assert_eq "early1 stays working" "$(status_of early1)" "working"

# =====================================================================
# 9. Anchor resets when --pane-pid changes (the tmux pane/session was
#    restarted) - even with a continuously live, matching new root.
# =====================================================================
test_new_home
wm_state crew-add --id restart1 --type developer --objective i --repo /tmp --window wm-restart1 --session-id s9 >/dev/null
wm_state crew-set --id restart1 --status working --summary "working" >/dev/null
spawn_matching_root
restart1_rootA=$!
wm_state wedge-check --id restart1 --pane-idle 0 --pane-pid "$restart1_rootA" $CHECK >/dev/null
sleep 3.3
spawn_matching_root
restart1_rootB=$!
out="$(wm_state wedge-check --id restart1 --pane-idle 0 --pane-pid "$restart1_rootB" $CHECK)"
assert_eq "a changed pane-pid re-anchors instead of inheriting the old since" "$out" ""
sleep 3.3
out="$(wm_state wedge-check --id restart1 --pane-idle 0 --pane-pid "$restart1_rootB" $CHECK)"
assert_eq "the new pid's own anchor can still eventually flip" "$out" "stalled restart1"

# =====================================================================
# 10. Owner/scope: wedge-check is per-id - a flip never touches any other
#     record on the roster.
# =====================================================================
test_new_home
wm_state crew-add --id target1 --type developer --objective j --repo /tmp --window wm-target1 --session-id s10 >/dev/null
wm_state crew-set --id target1 --status working --summary "target" >/dev/null
wm_state crew-add --id bystander1 --type developer --objective k --repo /tmp --window wm-bystander1 --session-id s11 >/dev/null
wm_state crew-set --id bystander1 --status working --summary "untouched" >/dev/null
bystander_json_before="$(cat "$WINGMAN_HOME/crew/bystander1.json")"

spawn_matching_root
target1_root=$!
wm_state wedge-check --id target1 --pane-idle 0 --pane-pid "$target1_root" $CHECK >/dev/null
sleep 3.3
wm_state wedge-check --id target1 --pane-idle 0 --pane-pid "$target1_root" $CHECK >/dev/null

assert_eq "the target flipped" "$(status_of target1)" "stalled"
assert_eq "the bystander is completely untouched" "$(cat "$WINGMAN_HOME/crew/bystander1.json")" "$bystander_json_before"
assert_eq "the bystander's roster status is unchanged" "$(roster_status_of bystander1)" "working"

test_summary
