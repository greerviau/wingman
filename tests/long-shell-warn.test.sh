#!/usr/bin/env bash
# E2E: the long-shell duration ceiling (#155 fix 2). `wm_state stall-check`
# tracks the elapsed time of the single longest-lived qualifying descendant
# process (the same branch-(a) proof-of-life test _probe_execution already
# uses) onto the member's own status JSON on every poll, independent of the
# idle-nomination gates - and a render step (crew-list/board.md) annotates a
# still-'working' member once that elapsed time crosses WM_LONG_SHELL_WARN
# (read fresh at render time, never baked into the tracked record). None of
# this ever causes a blocked/stalled flip - --threshold is set absurdly high
# throughout so the ordinary stall gates never trip.
#
# Covers: no qualifying descendant at all (no annotation), a tracked
# descendant under the render ceiling (no annotation, but the elapsed value IS
# persisted), the same descendant over the ceiling (annotation present, sane
# elapsed), and the tracked data clearing once the descendant is gone and the
# member is next probed without it.
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

# High threshold/nudge-age so the ordinary stall gates never fire in this
# file - only the long-shell side effect of stall-check is under test here.
CHECK="--threshold 9999 --root-grace 1 --probe-gap 1 --cpu-eps 0.5 --nudge-age -1"

# --- A: no qualifying descendant at all -> nothing tracked, no annotation ---
test_new_home
wm_state crew-add --id ls1 --type developer --objective a --repo /tmp --window wm-ls1 --session-id s1 >/dev/null
wm_state crew-set --id ls1 --status working --summary "building" >/dev/null
spawn_bg sh -c 'sleep 600 & wait'   # root and its only child start together
root1=$!
sleep 1
wm_state stall-check --id ls1 --pane-idle 0 --pane-pid "$root1" $CHECK >/dev/null
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
wm_state stall-check --id ls2 --pane-idle 0 --pane-pid "$root2" $CHECK >/dev/null
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
wm_state stall-check --id ls2 --pane-idle 0 --pane-pid "$root2" $CHECK >/dev/null
read -r pid2b elapsed2b <<<"$(long_shell_of ls2)"
assert_eq "long_shell_pid is cleared once the tracked tree is gone" "$pid2b" ""
assert_eq "long_shell_elapsed is cleared alongside it" "$elapsed2b" ""
roster_after="$(WM_LONG_SHELL_WARN=1 wm_state crew-list)"
assert_not_contains "the annotation disappears once cleared" "$roster_after" "longer than usual"

# --- tracking never flips status, regardless of ceiling ---------------------
assert_eq "ls2 is still working throughout" \
  "$(wm_py -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$WINGMAN_HOME/crew/ls2.json")" \
  "working"

test_summary
