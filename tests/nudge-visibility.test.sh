#!/usr/bin/env bash
# E2E: the nudged_at visibility layer (#155 fix 1). Proves `wm_state stall-
# check --just-nudged 1` (the same per-poll call bin/watch-fleet already
# makes for every candidate - see its own comment on why this rides that call
# rather than a second subprocess) stamps nudged_at without touching summary/
# status, that crew-list/render_tree_text/board.md all render a "self-heal
# nudge sent Xs ago" annotation on a still-'working' member while it is set,
# that the member's own next self-report clears it (but a pure bookkeeping
# write, e.g. --remote-control-connected, does not), and that a genuine stall
# flip clears it too. Driven directly against `wm_state crew-set`/`stall-
# check` - no tmux needed; the end-to-end nudge-then-wait timing itself is
# already covered by tests/watch-fleet.test.sh.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

wm_py() { uv run --no-project --quiet python "$@"; }

nudged_at_of() {
  wm_py -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("nudged_at") or "")' \
    "$WINGMAN_HOME/crew/$1.json"
}

spawn_bg() { "$@" & wm_track "$!"; }

# A harmless, childless pane pid - --just-nudged and the long-shell tracking
# it rides alongside both run unconditionally, so a huge --threshold here just
# keeps this file's calls from ever flipping the member while under test.
NUDGE_CHECK="--pane-idle 0 --threshold 9999 --root-grace 2 --probe-gap 1 --cpu-eps 0.5 --nudge-age -1"

test_new_home
wm_state crew-add --id n1 --type developer --objective x --repo /tmp --window wm-n1 --session-id s1 >/dev/null
wm_state crew-set --id n1 --status working --summary "digging through logs" >/dev/null
spawn_bg sleep 600
pane1=$!

# --- --just-nudged stamps nudged_at, leaves summary/status untouched -------
wm_state stall-check --id n1 --pane-pid "$pane1" --just-nudged 1 $NUDGE_CHECK >/dev/null
after="$(wm_state crew-get --id n1)"
assert_true "nudged_at is now set" "[ -n \"$(nudged_at_of n1)\" ]"
assert_contains "status is untouched by --just-nudged" "$after" '"status": "working"'
assert_contains "summary is untouched by --just-nudged" "$after" "digging through logs"

# --- crew-list annotates the still-working member ---------------------------
roster="$(wm_state crew-list)"
assert_contains "crew-list shows the nudge annotation" "$roster" "self-heal nudge sent"
assert_contains "crew-list annotation is parenthetical, alongside working" "$roster" "working (self-heal nudge sent"

tree="$(wm_state crew-list --tree)"
assert_contains "tree view also shows the nudge annotation" "$tree" "self-heal nudge sent"

wm_state render-board >/dev/null
board="$(cat "$WINGMAN_HOME/board.md")"
assert_contains "board.md also shows the nudge annotation" "$board" "self-heal nudge sent"

# --- a pure bookkeeping write (remote-control-connected) never clears it ----
wm_state crew-set --id n1 --remote-control-connected false >/dev/null
assert_true "nudged_at survives a bookkeeping-only crew-set call" "[ -n \"$(nudged_at_of n1)\" ]"

# --- the member's own next self-report clears it -----------------------------
wm_state crew-set --id n1 --status working --summary "back at it" >/dev/null
assert_eq "nudged_at is cleared by the member's own self-report" "$(nudged_at_of n1)" ""
roster2="$(wm_state crew-list)"
assert_not_contains "crew-list no longer shows the annotation" "$roster2" "self-heal nudge sent"

# --- a genuine stall flip also clears it -------------------------------------
wm_state stall-check --id n1 --pane-pid "$pane1" --just-nudged 1 $NUDGE_CHECK >/dev/null
assert_true "nudged_at set again ahead of the stall flip" "[ -n \"$(nudged_at_of n1)\" ]"
wm_age_status n1
spawn_bg sleep 600
idle_pid=$!
out="$(wm_state stall-check --id n1 --pane-idle 999 --pane-pid "$idle_pid" \
  --threshold 5 --root-grace 2 --probe-gap 2 --cpu-eps 0.5 --nudge-age 999)"
assert_eq "the member flips to stalled" "$out" "stalled"
assert_eq "nudged_at is cleared by the stall flip" "$(nudged_at_of n1)" ""

# --- the annotation never shows for a non-'working' status, even if
# nudged_at is directly present in the record (isolates the render gate from
# cmd_crew_set's own clear-on-self-report logic, which would otherwise have
# already cleared it before this point) ---------------------------------------
test_new_home
wm_state crew-add --id n2 --type developer --objective y --repo /tmp --window wm-n2 --session-id s2 >/dev/null
wm_state crew-set --id n2 --status blocked --blocker "need a decision" >/dev/null
wm_py -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["nudged_at"] = d["updated"]
json.dump(d, open(p, "w"))
' "$WINGMAN_HOME/crew/n2.json"
roster3="$(wm_state crew-list)"
assert_not_contains "a blocked member is never annotated even with nudged_at present" "$roster3" "self-heal nudge sent"

# --- regression: a self-report that lands ahead of a stall-check side-effect
# write is never clobbered by it (a reviewer-reported race on PR #156: the
# original --just-nudged/long-shell-tracker writes reused a `live` dict read
# at cmd_stall_check's own function entry and wrote it back later with no
# re-read or lock, so a concurrent self-report landing in between was
# silently reverted - status, summary, and blocker all erased with no trace.
# Both writers now take the same per-member with_locked(status_path(id)) and
# re-read fresh immediately before writing, so whichever completes first is
# never undone by the other) -------------------------------------------------
test_new_home
wm_state crew-add --id race1 --type developer --objective z --repo /tmp --window wm-race1 --session-id s3 >/dev/null
wm_state crew-set --id race1 --status working --summary "digging through logs" >/dev/null
# A real qualifying descendant (not just a bare pid) - so the assertion below
# proves the status-gate inside _track_long_running is why nothing gets
# written, not merely that there was nothing to track.
spawn_bg sh -c 'sleep 2; sleep 600 & wait'
race_pid=$!
sleep 3.5
# The self-report that must survive - lands on disk before either side-effect
# write below runs.
wm_state crew-set --id race1 --status blocked --blocker "need the human to install a library" >/dev/null
# Both writers a single poll would have made against this member, exercised
# directly - neither must revert the blocked transition above.
wm_state stall-check --id race1 --pane-pid "$race_pid" --just-nudged 1 \
  --pane-idle 0 --threshold 9999 --root-grace 1 --probe-gap 1 --cpu-eps 0.5 --nudge-age -1 >/dev/null
after_race="$(wm_state crew-get --id race1)"
assert_contains "the self-report survives a same-poll --just-nudged write" "$after_race" '"status": "blocked"'
assert_contains "the blocker text survives intact" "$after_race" "need the human to install a library"
assert_not_contains "the long-shell tracker skips a no-longer-working member, even with a qualifying descendant present" "$after_race" '"long_shell_pid"'

test_summary
