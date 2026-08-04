#!/usr/bin/env bash
# E2E: the long-shell duration ceiling (#155 fix 2). `wm_state wedge-check`
# tracks the elapsed time of the single longest-lived qualifying descendant
# process (the same branch-(a) proof-of-life test _probe_execution already
# uses) onto the member's own status JSON on every poll, independent of every
# other gate - and a render step (crew-list/board.md) annotates a still-
# 'working' OR 'blocked' member once that elapsed time crosses
# WM_LONG_SHELL_WARN (read fresh at render time, never baked into the tracked
# record). None of this ever causes a blocked/stalled flip - --threshold and
# --pane-gap are set absurdly high throughout so wedge-check's own flip gates
# never trip.
#
# _track_long_running was relocated here from `wm_state stall-check` by issue
# #202 (a bare stall-check no longer maintains long_shell_* at all - every
# assertion in this file drives wedge-check instead), and widened at the same
# time to cover 'blocked' members, not just 'working' ones - see section E.
#
# Covers: no qualifying descendant at all (no annotation), a tracked
# descendant under the render ceiling (no annotation, but the elapsed value IS
# persisted), the same descendant over the ceiling (annotation present, sane
# elapsed), the tracked data clearing once the descendant is gone and the
# member is next probed without it, and the same tracking/annotation for a
# 'blocked' member.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

wm_py() { uv run --no-project --quiet python "$@"; }

long_shell_of() {
  wm_py -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("long_shell_pid") or "", d.get("long_shell_elapsed") if d.get("long_shell_elapsed") is not None else "")
' "$WINGMAN_HOME/crew/$1.json"
}

spawn_bg() { "$@" & wm_track "$!"; }

# High threshold/pane-gap so wedge-check's own flip gates never trip in this
# file - only the long-shell side effect (_track_long_running, relocated here
# by issue #202) is under test.
CHECK="--root-grace 1 --threshold 9999 --pane-gap 9999"

# --- A: no qualifying descendant at all -> nothing tracked, no annotation ---
test_new_home
wm_state crew-add --id ls1 --type developer --objective a --repo /tmp --window wm-ls1 --session-id s1 >/dev/null
wm_state crew-set --id ls1 --status working --summary "building" >/dev/null
spawn_bg sh -c 'sleep 600 & wait'   # root and its only child start together
root1=$!
sleep 1
wm_state wedge-check --id ls1 --pane-idle 0 --pane-pid "$root1" $CHECK >/dev/null
read -r pid1 elapsed1 <<<"$(long_shell_of ls1)"
assert_eq "no qualifying descendant means nothing tracked" "$pid1" ""
assert_eq "no elapsed value is tracked alongside it" "$elapsed1" ""
roster1="$(WM_LONG_SHELL_WARN=5 wm_state crew-list)"
assert_not_contains "no annotation with nothing tracked" "$roster1" "longer than usual"

# --- B/C: a late-started descendant is tracked; the SAME persisted elapsed
# renders with no annotation above the ceiling and WITH one below it --------
test_new_home
wm_state crew-add --id ls2 --type developer --objective b --repo /tmp --window wm-ls2 --session-id s2 >/dev/null
wm_state crew-set --id ls2 --status working --summary "building" >/dev/null
# sleep 2 delays the tracked child well past --root-grace 1; sleep 300 keeps
# the root itself alive independent of the tracked child's own lifetime.
spawn_bg sh -c 'sleep 2; sleep 6 & sleep 300'
root2=$!
sleep 3.5   # root elapsed ~3.5s; the backgrounded "sleep 6" child ~1.5s old
wm_state wedge-check --id ls2 --pane-idle 0 --pane-pid "$root2" $CHECK >/dev/null
read -r pid2 elapsed2 <<<"$(long_shell_of ls2)"
assert_true "a late-started descendant is tracked" "[ -n \"$pid2\" ]"
assert_true "tracked elapsed is a small positive number" "[ \"${elapsed2%.*}\" -ge 0 ] 2>/dev/null"

roster_high="$(WM_LONG_SHELL_WARN=120 wm_state crew-list)"
assert_not_contains "under the ceiling: no annotation" "$roster_high" "longer than usual"

roster_low="$(WM_LONG_SHELL_WARN=1 wm_state crew-list)"
assert_contains "over the ceiling: annotation present" "$roster_low" "longer than usual"
assert_contains "annotation mentions a running shell" "$roster_low" "1 shell running"

# --- D: once the tracked descendant (and its root) are gone, the next probe
# clears the tracked fields and the annotation disappears --------------------
kill -9 "$root2" 2>/dev/null
pkill -9 -P "$root2" 2>/dev/null
wait "$root2" 2>/dev/null
sleep 1
wm_state wedge-check --id ls2 --pane-idle 0 --pane-pid "$root2" $CHECK >/dev/null
read -r pid2b elapsed2b <<<"$(long_shell_of ls2)"
assert_eq "long_shell_pid is cleared once the tracked tree is gone" "$pid2b" ""
assert_eq "long_shell_elapsed is cleared alongside it" "$elapsed2b" ""
roster_after="$(WM_LONG_SHELL_WARN=1 wm_state crew-list)"
assert_not_contains "the annotation disappears once cleared" "$roster_after" "longer than usual"

# --- tracking never flips status, regardless of ceiling ---------------------
assert_eq "ls2 is still working throughout" \
  "$(wm_py -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$WINGMAN_HOME/crew/ls2.json")" \
  "working"

# --- E (issue #202): the SAME tracking and annotation now apply to a
# 'blocked' member too - the contract change _track_long_running/
# _stall_annotation's docstrings describe. A blocked member with a
# qualifying long-running descendant is evidence, not itself a wedge
# indicator (see _stall_annotation's docstring) - this section only proves
# the annotation renders; it never flips status. --------------------------
test_new_home
wm_state crew-add --id ls3 --type lead --objective c --repo /tmp --window wm-ls3 --session-id s3 >/dev/null
wm_state crew-set --id ls3 --status blocked --blocker "need a decision" >/dev/null
spawn_bg sh -c 'sleep 2; sleep 6 & sleep 300'
root3=$!
sleep 3.5
wm_state wedge-check --id ls3 --pane-idle 0 --pane-pid "$root3" $CHECK >/dev/null
read -r pid3 elapsed3 <<<"$(long_shell_of ls3)"
assert_true "a blocked member's late-started descendant is tracked too" "[ -n \"$pid3\" ]"

roster_blocked_high="$(WM_LONG_SHELL_WARN=120 wm_state crew-list)"
assert_not_contains "blocked, under the ceiling: no annotation" "$roster_blocked_high" "longer than usual"

roster_blocked_low="$(WM_LONG_SHELL_WARN=1 wm_state crew-list)"
assert_contains "blocked, over the ceiling: annotation present" "$roster_blocked_low" "longer than usual"
assert_eq "the blocked member is untouched by the annotation itself" \
  "$(wm_py -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$WINGMAN_HOME/crew/ls3.json")" \
  "blocked"

# --- issue #235 regression: _stall_annotation's gate was RESTRUCTURED (not
# widened) to dispatch 'stalled' to its own _stalled_annotation - a leftover
# long_shell_elapsed on a 'stalled' record must never show the working/
# blocked-only long-shell annotation, however low WM_LONG_SHELL_WARN is set.
test_new_home
wm_state crew-add --id ls4 --type developer --objective d --repo /tmp --window wm-ls4 --session-id s4 >/dev/null
wm_state crew-set --id ls4 --status working --summary "building" >/dev/null
wm_py -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["status"] = "stalled"
d["long_shell_pid"] = 99999
d["long_shell_elapsed"] = 99999
json.dump(d, open(p, "w"))
' "$WINGMAN_HOME/crew/ls4.json"
roster_stalled="$(WM_LONG_SHELL_WARN=1 wm_state crew-list)"
assert_not_contains "a stalled member never shows the long-shell annotation" "$roster_stalled" "longer than usual"
assert_contains "a stalled member still gets its own dedicated annotation" "$roster_stalled" "stalled (flagged"

test_summary
