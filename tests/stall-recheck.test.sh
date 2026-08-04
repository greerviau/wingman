#!/usr/bin/env bash
# E2E: wm-state stall-recheck (issue #235) - the per-detector clearing
# predicates that end a 'stalled' classification's one-way-latch behavior.
# Driven directly against synthetic process trees and rosters, exactly like
# tests/stall-check.test.sh/wedge-check.test.sh/forward-motion-check.test.sh -
# no tmux needed. Each of the three sources is flipped via its OWN real flip
# command (stall-check / wedge-check / forward-motion-check) first, so every
# case here exercises the real provenance a live flip actually writes, not a
# hand-rolled stand-in.
#
# The "not-cleared" cases (5-9, 15-20) are the point of this file: a naive,
# uniform-liveness or membership-only spelling of each predicate fails
# exactly one of them (see the plan's "The governing invariant: fail
# closed") - each is listed separately, on purpose, rather than folded into
# one assertion.
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

announced_of() {
  wm_py -c 'import json,sys; print(json.load(open(sys.argv[1])).get("announced") or "")' \
    "$WINGMAN_HOME/crew/$1.json"
}

blocker_of() {
  wm_py -c 'import json,sys; print(json.load(open(sys.argv[1])).get("blocker") or "")' \
    "$WINGMAN_HOME/crew/$1.json"
}

has_stall() {
  wm_py -c 'import json,sys; print("1" if json.load(open(sys.argv[1])).get("stall") is not None else "0")' \
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

stall_has_key() {
  wm_py -c '
import json, sys
d = json.load(open(sys.argv[1])).get("stall") or {}
print("1" if sys.argv[2] in d else "0")
' "$WINGMAN_HOME/crew/$1.json" "$2"
}

json_of() { cat "$WINGMAN_HOME/crew/$1.json"; }

strip_stall_field() {  # $1=id  $2=field name to pop from stall
  wm_py -c '
import json, sys
p, field = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["stall"].pop(field, None)
json.dump(d, open(p, "w"))
' "$WINGMAN_HOME/crew/$1.json" "$2"
}

corrupt_stall() {  # $1=id  $2=field  $3=new value (JSON literal, e.g. '"bogus"' or 'null')
  wm_py -c '
import json, sys
p, field, val = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
d["stall"][field] = json.loads(val)
json.dump(d, open(p, "w"))
' "$WINGMAN_HOME/crew/$1.json" "$2" "$3"
}

# Directly fabricate a 'stalled' record with no `stall` object at all - the
# pre-migration shape (a record flipped before this feature shipped).
make_migration_stall() {  # $1=id
  wm_py -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["status"] = "stalled"
d.pop("stall", None)
json.dump(d, open(p, "w"))
' "$WINGMAN_HOME/crew/$1.json"
}

spawn_bg() { "$@" & wm_track "$!"; }

# A wedge root whose descendant CAN BE KILLED WITHOUT LEAVING A ZOMBIE and
# without killing the root itself: the root explicitly `wait`s on its one
# background child (reaping it the instant it dies) before falling into a
# SELF-BOUNDING keep-alive loop (1s sleeps, forever) rather than one long
# sleep - so if the root itself is later killed (case 16) or simply never
# reaped by this file's own cleanup, whatever single short-lived descendant
# it happens to be inside at that moment dies on its own within ~1s instead
# of surviving as a long-lived orphan (empirically confirmed: a single long
# `sleep 10000` tail command left exactly that kind of orphan behind and
# hung a manually-piped test run). The FIRST descendant (below) is bounded
# to 60s for the identical reason: if the root is killed while still
# blocked in that initial `wait $child` (a test that deliberately never
# kills the descendant itself, e.g. cases 5/15/17), the child orphans too -
# bounded at 60s rather than the 600s+ this suite's OTHER fixtures use
# elsewhere is what keeps that worst case cheap. Verified empirically that
# after killing the ORIGINAL child, it disappears from `ps -ax` entirely
# within well under a second, while the root pid stays resolvable and
# un-terminated. The root's OWN command line contains the literal text
# "sleep 60" too, but _wedge_descendant excludes pid == pane_pid
# unconditionally (see tests/wedge-check.test.sh's own comment), so this
# can never self-match --proc-re.
spawn_reapable_matching_root() {
  spawn_bg sh -c 'sleep 60 & child=$!; wait $child; while :; do sleep 1; done'
}

WEDGECHECK="--root-grace 1 --threshold 3 --pane-gap 5 --proc-re sleep"
LIVECHECK="--threshold 1 --root-grace 1 --probe-gap 1 --cpu-eps 0.5 --nudge-age 999"

# Flip via a real wedge-check cycle (two polls, threshold 3s) against a
# spawn_reapable_matching_root. Leaves $wedge_root_pid / $wedge_desc_pid set.
flip_wedge() {  # $1=id
  spawn_reapable_matching_root
  wedge_root_pid=$!
  wm_state wedge-check --id "$1" --pane-idle 0 --pane-pid "$wedge_root_pid" $WEDGECHECK >/dev/null
  sleep 3.3
  wm_state wedge-check --id "$1" --pane-idle 0 --pane-pid "$wedge_root_pid" $WEDGECHECK >/dev/null
  wedge_desc_pid="$(stall_field "$1" wedge_pid)"
}

# Kill the recorded wedge descendant (reaped by the root's own `wait`, no
# zombie left behind) while keeping the root alive.
kill_wedge_descendant() {  # $1=id (unused, kept for readability at call sites)
  kill "$wedge_desc_pid" 2>/dev/null
  sleep 1
}

# Flip via a real stall-check cycle (bare, no descendant, genuinely idle) -
# leaves $live_pid set to the idle root.
flip_liveness() {  # $1=id
  wm_state crew-add --id "$1" --type developer --objective x --repo /tmp --window "wm-$1" --session-id "s-$1" >/dev/null
  wm_state crew-set --id "$1" --status working --summary "digging" >/dev/null
  sleep 1.2
  spawn_bg sleep 600
  live_pid=$!
  wm_state stall-check --id "$1" --pane-idle 999 --pane-pid "$live_pid" $LIVECHECK >/dev/null
}

# A tree with a late-started descendant (root_grace 1s) - the "recovered
# pane" shape (armed watcher / in-flight tool shell). Leaves $recovered_pid
# set. The final command is a BOUNDED sleep (45s, not 600s+) - if teardown's
# own kill of the root pid does not cascade to this forked-not-exec'd final
# child (confirmed empirically that it does not), the worst case is a 45s-
# lived orphan, not one lasting minutes to hours.
spawn_late_descendant_tree() {
  spawn_bg sh -c 'sleep 4; sleep 45'
  recovered_pid=$!
  sleep 5   # let the late child exist and lag the root well past root-grace 1
}

# Flip via a real forward-motion-check cycle (lead + one review child).
# Leaves $fm_child set to the child's id.
flip_forward_motion() {  # $1=lead-id  $2=window-secs
  fm_child="${1}-dev"
  wm_state crew-add --id "$1" --type developer --objective x --repo /tmp --window "wm-$1" --session-id "s-$1" >/dev/null
  wm_state crew-set --id "$1" --status working --summary "leading" >/dev/null
  wm_state crew-add --id "$fm_child" --type developer --objective x --repo /tmp --window "wm-$fm_child" --session-id "s-$fm_child" --parent "$1" >/dev/null
  wm_state crew-set --id "$fm_child" --status review --summary "PR up" --delivery "https://gh/pr/$1" >/dev/null
  wm_state forward-motion-check --owner "" --window-secs "$2" >/dev/null
  sleep "$(($2 + 1))"
  wm_state forward-motion-check --owner "" --window-secs "$2" >/dev/null
}

# =====================================================================
# 1. liveness clearing: bare tree at flip time, then a tree with a
#    late-started descendant - one recheck streak 1/2, a second clears.
# =====================================================================
test_new_home
flip_liveness lv1
assert_eq "1: flipped to stalled" "$(status_of lv1)" "stalled"
spawn_late_descendant_tree
out="$(wm_state stall-recheck --id lv1 --pane-pid "$recovered_pid" --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "1: first contradicting poll does not revert (streak 1/2)" "$out" ""
assert_eq "1: clear_polls is 1" "$(stall_field lv1 clear_polls)" "1"
out="$(wm_state stall-recheck --id lv1 --pane-pid "$recovered_pid" --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "1: second contradicting poll reverts" "$out" "lv1 liveness cleared after 2 polls"
assert_eq "1: status back to working" "$(status_of lv1)" "working"
assert_eq "1: roster mirrors working" "$(roster_status_of lv1)" "working"

# =====================================================================
# 2. liveness clearing via pane activity alone (still-bare process tree).
# =====================================================================
test_new_home
flip_liveness lv2
out="$(wm_state stall-recheck --id lv2 --pane-pid "$live_pid" --pane-changed 1 --root-grace 1 --confirmations 2)"
assert_eq "2: first pane-changed poll does not revert" "$out" ""
out="$(wm_state stall-recheck --id lv2 --pane-pid "$live_pid" --pane-changed 1 --root-grace 1 --confirmations 2)"
assert_eq "2: second pane-changed poll reverts, tree still bare" "$out" "lv2 liveness cleared after 2 polls"
assert_eq "2: status back to working" "$(status_of lv2)" "working"

# =====================================================================
# 3. wedge clearing: the wedging descendant is killed (and reaped, no
#    zombie), the root pane stays alive -> two rechecks -> cleared.
# =====================================================================
test_new_home
wm_state crew-add --id wg3 --type developer --objective x --repo /tmp --window wm-wg3 --session-id s-wg3 >/dev/null
wm_state crew-set --id wg3 --status working --summary "building" >/dev/null
flip_wedge wg3
assert_eq "3: flipped to stalled" "$(status_of wg3)" "stalled"
kill_wedge_descendant
out="$(wm_state stall-recheck --id wg3 --pane-pid "$wedge_root_pid" --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "3: first poll after the kill does not revert" "$out" ""
out="$(wm_state stall-recheck --id wg3 --pane-pid "$wedge_root_pid" --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "3: second poll reverts" "$out" "wg3 wedge cleared after 2 polls"
assert_eq "3: status back to working" "$(status_of wg3)" "working"

# =====================================================================
# 4. forward-motion clearing: a child's status change -> two rechecks -> cleared.
# =====================================================================
test_new_home
flip_forward_motion fm4 2
assert_eq "4: flipped to stalled" "$(status_of fm4)" "stalled"
wm_state crew-set --id "$fm_child" --status blocked --blocker "need a call" >/dev/null
out="$(wm_state stall-recheck --id fm4 --pane-pid 0 --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "4: first poll after the child moved does not revert" "$out" ""
out="$(wm_state stall-recheck --id fm4 --pane-pid 0 --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "4: second poll reverts" "$out" "fm4 forward-motion cleared after 2 polls"
assert_eq "4: status back to working" "$(status_of fm4)" "working"

# =====================================================================
# 5. REGRESSION GUARD: a wedge stall is NOT cleared by liveness evidence -
#    the wedging descendant stays alive and the pane is "repainting"
#    (--pane-changed 1) for ten consecutive rechecks.
# =====================================================================
test_new_home
wm_state crew-add --id wg5 --type developer --objective x --repo /tmp --window wm-wg5 --session-id s-wg5 >/dev/null
wm_state crew-set --id wg5 --status working --summary "building" >/dev/null
flip_wedge wg5
before="$(json_of wg5)"
for i in 1 2 3 4 5 6 7 8 9 10; do
  out="$(wm_state stall-recheck --id wg5 --pane-pid "$wedge_root_pid" --pane-changed 1 --root-grace 1 --confirmations 2)"
  assert_eq "5: poll $i - liveness evidence never clears a wedge" "$out" ""
done
assert_eq "5: still stalled after ten rechecks" "$(status_of wg5)" "stalled"
assert_eq "5: the record is untouched (no streak was ever started)" "$(json_of wg5)" "$before"

# =====================================================================
# 6. REGRESSION GUARD: a forward-motion stall is NOT cleared by liveness
#    evidence - an armed late-started descendant present, no child moved.
# =====================================================================
test_new_home
flip_forward_motion fm6 2
spawn_late_descendant_tree
before="$(json_of fm6)"
for i in 1 2 3 4 5 6 7 8 9 10; do
  out="$(wm_state stall-recheck --id fm6 --pane-pid "$recovered_pid" --pane-changed 1 --root-grace 1 --confirmations 2)"
  assert_eq "6: poll $i - liveness evidence never clears a forward-motion stall" "$out" ""
done
assert_eq "6: still stalled after ten rechecks" "$(status_of fm6)" "stalled"
assert_eq "6: the record is untouched (no streak was ever started)" "$(json_of fm6)" "$before"

# =====================================================================
# 7. liveness NOT cleared while genuinely dead: bare tree, --pane-changed 0,
#    ten rechecks -> still stalled, and clear_polls never appears.
# =====================================================================
test_new_home
flip_liveness lv7
before="$(json_of lv7)"
for i in 1 2 3 4 5 6 7 8 9 10; do
  out="$(wm_state stall-recheck --id lv7 --pane-pid "$live_pid" --pane-changed 0 --root-grace 1 --confirmations 2)"
  assert_eq "7: poll $i - genuinely dead is never contradicted" "$out" ""
done
assert_eq "7: still stalled after ten rechecks" "$(status_of lv7)" "stalled"
assert_eq "7: stall.clear_polls never appeared" "$(stall_has_key lv7 clear_polls)" "0"
assert_eq "7: the record is byte-identical throughout" "$(json_of lv7)" "$before"

# =====================================================================
# 8. Streak reset: contradict, agree, contradict -> still stalled (the
#    intervening agreeing poll deletes the streak).
# =====================================================================
test_new_home
flip_liveness lv8
out="$(wm_state stall-recheck --id lv8 --pane-pid "$live_pid" --pane-changed 1 --root-grace 1 --confirmations 2)"
assert_eq "8: contradicting poll 1/2" "$out" ""
assert_eq "8: clear_polls is 1" "$(stall_field lv8 clear_polls)" "1"
out="$(wm_state stall-recheck --id lv8 --pane-pid "$live_pid" --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "8: an agreeing poll does not revert" "$out" ""
assert_eq "8: the streak is deleted" "$(stall_has_key lv8 clear_polls)" "0"
out="$(wm_state stall-recheck --id lv8 --pane-pid "$live_pid" --pane-changed 1 --root-grace 1 --confirmations 2)"
assert_eq "8: a fresh contradicting poll restarts at 1/2, no revert" "$out" ""
assert_eq "8: clear_polls is back to 1, not 2" "$(stall_field lv8 clear_polls)" "1"
assert_eq "8: still stalled - the reset actually held" "$(status_of lv8)" "stalled"

# =====================================================================
# 9. Confirmation floor: --confirmations 1 still requires two polls.
# =====================================================================
test_new_home
flip_liveness lv9
out="$(wm_state stall-recheck --id lv9 --pane-pid "$live_pid" --pane-changed 1 --root-grace 1 --confirmations 1)"
assert_eq "9: confirmations=1 still defers on the first contradicting poll" "$out" ""
assert_eq "9: still stalled after one contradicting poll" "$(status_of lv9)" "stalled"
out="$(wm_state stall-recheck --id lv9 --pane-pid "$live_pid" --pane-changed 1 --root-grace 1 --confirmations 1)"
assert_eq "9: the second poll is what actually reverts (hard floor of 2)" "$out" "lv9 liveness cleared after 2 polls"

# =====================================================================
# 10. State integrity - lossless restore.
# =====================================================================
# 10a. A wedge flip from 'blocked' restores prev_blocker verbatim and
#      advances `announced`.
test_new_home
wm_state crew-add --id wg10a --type developer --objective x --repo /tmp --window wm-wg10a --session-id s-wg10a >/dev/null
wm_state crew-set --id wg10a --status blocked --blocker "which approach?" >/dev/null
flip_wedge wg10a
assert_eq "10a: blocker text survived into the new summary" "$(status_of wg10a)" "stalled"
pre_announced="$(announced_of wg10a)"
kill_wedge_descendant
wm_state stall-recheck --id wg10a --pane-pid "$wedge_root_pid" --pane-changed 0 --root-grace 1 --confirmations 2 >/dev/null
wm_state stall-recheck --id wg10a --pane-pid "$wedge_root_pid" --pane-changed 0 --root-grace 1 --confirmations 2 >/dev/null
assert_eq "10a: status restored to blocked" "$(status_of wg10a)" "blocked"
assert_eq "10a: blocker restored verbatim" "$(blocker_of wg10a)" "which approach?"
post_announced="$(announced_of wg10a)"
assert_true "10a: announced ADVANCED (a restored blocker re-surfaces once)" "[ '$pre_announced' != '$post_announced' ]"

# 10b. A wedge flip from 'working' reverts to working and leaves `announced`
#      untouched.
test_new_home
wm_state crew-add --id wg10b --type developer --objective x --repo /tmp --window wm-wg10b --session-id s-wg10b >/dev/null
wm_state crew-set --id wg10b --status working --summary "building" >/dev/null
flip_wedge wg10b
pre_announced="$(announced_of wg10b)"
kill_wedge_descendant
wm_state stall-recheck --id wg10b --pane-pid "$wedge_root_pid" --pane-changed 0 --root-grace 1 --confirmations 2 >/dev/null
wm_state stall-recheck --id wg10b --pane-pid "$wedge_root_pid" --pane-changed 0 --root-grace 1 --confirmations 2 >/dev/null
assert_eq "10b: status restored to working" "$(status_of wg10b)" "working"
post_announced="$(announced_of wg10b)"
assert_eq "10b: announced left UNTOUCHED" "$post_announced" "$pre_announced"

# =====================================================================
# 11. cmd_crew_set drops `stall` on the member's own self-report, and
#     leaves it alone on a pure bookkeeping write (--worktree).
# =====================================================================
test_new_home
flip_liveness sr11
assert_eq "11: has a stall object right after the flip" "$(has_stall sr11)" "1"
wm_state crew-set --id sr11 --worktree /tmp/somewhere >/dev/null
assert_eq "11: a pure bookkeeping write leaves stall alone" "$(has_stall sr11)" "1"
assert_eq "11: status is unaffected by the bookkeeping write" "$(status_of sr11)" "stalled"
wm_state crew-set --id sr11 --status working --summary "resumed" >/dev/null
assert_eq "11: the member's own self-report drops stall" "$(has_stall sr11)" "0"
assert_eq "11: status reflects the self-report" "$(status_of sr11)" "working"

# =====================================================================
# 12. Migration: a `stalled` record with no `stall` object is never
#     reverted by any number of rechecks, and renders from `updated`.
# =====================================================================
test_new_home
wm_state crew-add --id mig12 --type developer --objective x --repo /tmp --window wm-mig12 --session-id s-mig12 >/dev/null
wm_state crew-set --id mig12 --status working --summary "old-style flip" >/dev/null
make_migration_stall mig12
assert_eq "12: fabricated as stalled with no stall object" "$(status_of mig12)" "stalled"
assert_eq "12: no stall object present" "$(has_stall mig12)" "0"
for i in 1 2 3; do
  out="$(wm_state stall-recheck --id mig12 --pane-pid 0 --pane-changed 1 --root-grace 1 --confirmations 2)"
  assert_eq "12: recheck $i is a no-op" "$out" ""
done
assert_eq "12: still stalled" "$(status_of mig12)" "stalled"
wm_age_status mig12 6
rendered="$(wm_state crew-list | grep mig12)"
assert_contains "12: renders an age annotation derived from updated" "$rendered" "flagged"
assert_contains "12: age annotation reflects the ~6 minute back-date" "$rendered" "6m ago"

# =====================================================================
# 13. Rendering.
# =====================================================================
test_new_home
flip_liveness rn13
rendered1="$(wm_state crew-list | grep rn13)"
assert_contains "13: crew-list shows 'flagged ... ago'" "$rendered1" "stalled (flagged"
assert_not_contains "13: no mid-streak clause before any recheck" "$rendered1" "showing activity"
wm_state stall-recheck --id rn13 --pane-pid "$live_pid" --pane-changed 1 --root-grace 1 --confirmations 3 >/dev/null
rendered2="$(wm_state crew-list | grep rn13)"
assert_contains "13: mid-streak shows the 'showing activity' clause" "$rendered2" "showing activity for"
assert_contains "13: mid-streak clause names the staleness warning" "$rendered2" "classification may be stale"

# A working member's existing nudge/long-shell annotations are unaffected by
# any of this (issue #155 rendering, untouched by #235).
wm_state crew-add --id rn13w --type developer --objective x --repo /tmp --window wm-rn13w --session-id s-rn13w >/dev/null
wm_state crew-set --id rn13w --status working --summary "busy" >/dev/null
wm_state stall-check --id rn13w --pane-idle 0 --pane-pid 1 --threshold 999999 --root-grace 1 --probe-gap 1 --cpu-eps 0.5 --nudge-age -1 --just-nudged 1 >/dev/null
rendered3="$(wm_state crew-list | grep rn13w)"
assert_contains "13: a working member's nudge annotation is unaffected" "$rendered3" "self-heal nudge sent"

# =====================================================================
# 14. Non-'stalled' statuses are a no-op.
# =====================================================================
test_new_home
wm_state crew-add --id np14w --type developer --objective x --repo /tmp --window wm-np14w --session-id s1 >/dev/null
wm_state crew-set --id np14w --status working --summary "a" >/dev/null
wm_state crew-add --id np14b --type developer --objective x --repo /tmp --window wm-np14b --session-id s2 >/dev/null
wm_state crew-set --id np14b --status blocked --blocker "b" >/dev/null
wm_state crew-add --id np14r --type developer --objective x --repo /tmp --window wm-np14r --session-id s3 >/dev/null
wm_state crew-set --id np14r --status review --artifact /tmp/x.md >/dev/null
wm_state crew-add --id np14d --type developer --objective x --repo /tmp --window wm-np14d --session-id s4 >/dev/null
wm_state crew-set --id np14d --status done --delivery "https://gh/pr/1" >/dev/null
for id in np14w np14b np14r np14d; do
  before="$(json_of "$id")"
  out="$(wm_state stall-recheck --id "$id" --pane-pid 0 --pane-changed 1 --root-grace 1 --confirmations 2)"
  assert_eq "14: $id is a no-op" "$out" ""
  assert_eq "14: $id record untouched" "$(json_of "$id")" "$before"
done

# =====================================================================
# 15. FAIL-CLOSED: --pane-pid 0 against a wedge stall never contradicts,
#     however long the actual wedging process runs.
# =====================================================================
test_new_home
wm_state crew-add --id wg15 --type developer --objective x --repo /tmp --window wm-wg15 --session-id s-wg15 >/dev/null
wm_state crew-set --id wg15 --status working --summary "building" >/dev/null
flip_wedge wg15
for i in 1 2 3 4 5 6 7 8 9 10; do
  out="$(wm_state stall-recheck --id wg15 --pane-pid 0 --pane-changed 0 --root-grace 1 --confirmations 2)"
  assert_eq "15: poll $i - pane-pid 0 is a first-class 'cannot tell'" "$out" ""
done
assert_eq "15: still stalled after ten rechecks against pid 0" "$(status_of wg15)" "stalled"
assert_eq "15: clear_polls never appeared" "$(stall_has_key wg15 clear_polls)" "0"

# =====================================================================
# 16. FAIL-CLOSED: a wedge stall whose PANE ROOT resolves to a vanished
#     (reaped) process - same empty-tree shape as 15, reached differently.
# =====================================================================
test_new_home
wm_state crew-add --id wg16 --type developer --objective x --repo /tmp --window wm-wg16 --session-id s-wg16 >/dev/null
wm_state crew-set --id wg16 --status working --summary "building" >/dev/null
flip_wedge wg16
kill "$wedge_root_pid" 2>/dev/null
wait "$wedge_root_pid" 2>/dev/null
out="$(wm_state stall-recheck --id wg16 --pane-pid "$wedge_root_pid" --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "16: a vanished pane root is never contradicted" "$out" ""
assert_eq "16: still stalled" "$(status_of wg16)" "stalled"

# =====================================================================
# 17. FAIL-CLOSED: a wedge stall's `stall` object has no `wedge_pid` ->
#     never contradicted, even against the still-live matching descendant.
# =====================================================================
test_new_home
wm_state crew-add --id wg17 --type developer --objective x --repo /tmp --window wm-wg17 --session-id s-wg17 >/dev/null
wm_state crew-set --id wg17 --status working --summary "building" >/dev/null
flip_wedge wg17
strip_stall_field wg17 wedge_pid
for i in 1 2 3 4 5 6 7 8 9 10; do
  out="$(wm_state stall-recheck --id wg17 --pane-pid "$wedge_root_pid" --pane-changed 0 --root-grace 1 --confirmations 2)"
  assert_eq "17: poll $i - no wedge_pid means no baseline, never contradicted" "$out" ""
done
assert_eq "17: still stalled after ten rechecks" "$(status_of wg17)" "stalled"

# =====================================================================
# 18. FAIL-CLOSED: a forward-motion stall's `stall` object has no
#     `children_sig` -> never contradicted.
# =====================================================================
test_new_home
flip_forward_motion fm18 2
strip_stall_field fm18 children_sig
wm_state crew-set --id "$fm_child" --status blocked --blocker "moved" >/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do
  out="$(wm_state stall-recheck --id fm18 --pane-pid 0 --pane-changed 0 --root-grace 1 --confirmations 2)"
  assert_eq "18: poll $i - no children_sig means no baseline, never contradicted" "$out" ""
done
assert_eq "18: still stalled after ten rechecks" "$(status_of fm18)" "stalled"

# =====================================================================
# 19. FAIL-CLOSED: a forward-motion stall evaluated against an UNREADABLE
#     roster - crew.json truncated to invalid JSON, so the candidate's own
#     record is absent from the read - is never contradicted. The companion
#     POSITIVE case: children legitimately finish while crew.json still
#     contains the candidate itself DOES clear.
# =====================================================================
test_new_home
flip_forward_motion fm19a 2
wm_state crew-set --id "$fm_child" --status done --delivery "https://gh/pr/x" >/dev/null
cp "$WINGMAN_HOME/crew.json" "$WINGMAN_HOME/crew.json.bak"
printf 'not valid json{{{' > "$WINGMAN_HOME/crew.json"
out="$(wm_state stall-recheck --id fm19a --pane-pid 0 --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "19: an unreadable roster is never contradicted, even with a genuine child change" "$out" ""
assert_eq "19: still stalled against a broken roster" "$(status_of fm19a)" "stalled"
cp "$WINGMAN_HOME/crew.json.bak" "$WINGMAN_HOME/crew.json"

# Companion positive: same setup, but the roster read is intact (contains
# fm19b itself) - the finished child is genuine forward motion and clears.
test_new_home
flip_forward_motion fm19b 2
wm_state crew-set --id "$fm_child" --status done --delivery "https://gh/pr/y" >/dev/null
out="$(wm_state stall-recheck --id fm19b --pane-pid 0 --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "19: first poll after the finish does not revert yet" "$out" ""
out="$(wm_state stall-recheck --id fm19b --pane-pid 0 --pane-changed 0 --root-grace 1 --confirmations 2)"
assert_eq "19: a genuinely finished report clears with an intact roster" "$out" "fm19b forward-motion cleared after 2 polls"
assert_eq "19: status back to working" "$(status_of fm19b)" "working"

# =====================================================================
# 20. FAIL-CLOSED: a malformed `stall` object (unknown source, unparseable
#     `since`, or a `prev_status` outside working/blocked) is never
#     reverted, and stall.clear_polls never appears on it.
# =====================================================================
test_new_home
flip_liveness mf20a
corrupt_stall mf20a source '"bogus-source"'
for i in 1 2 3; do
  out="$(wm_state stall-recheck --id mf20a --pane-pid "$live_pid" --pane-changed 1 --root-grace 1 --confirmations 2)"
  assert_eq "20a: unknown source, poll $i is a no-op" "$out" ""
done
assert_eq "20a: still stalled" "$(status_of mf20a)" "stalled"
assert_eq "20a: clear_polls never appeared" "$(stall_has_key mf20a clear_polls)" "0"

test_new_home
flip_liveness mf20b
corrupt_stall mf20b since '"not-a-timestamp"'
for i in 1 2 3; do
  out="$(wm_state stall-recheck --id mf20b --pane-pid "$live_pid" --pane-changed 1 --root-grace 1 --confirmations 2)"
  assert_eq "20b: unparseable since, poll $i is a no-op" "$out" ""
done
assert_eq "20b: still stalled" "$(status_of mf20b)" "stalled"
assert_eq "20b: clear_polls never appeared" "$(stall_has_key mf20b clear_polls)" "0"

test_new_home
flip_liveness mf20c
corrupt_stall mf20c prev_status '"stalled"'
for i in 1 2 3; do
  out="$(wm_state stall-recheck --id mf20c --pane-pid "$live_pid" --pane-changed 1 --root-grace 1 --confirmations 2)"
  assert_eq "20c: prev_status outside working/blocked, poll $i is a no-op" "$out" ""
done
assert_eq "20c: still stalled" "$(status_of mf20c)" "stalled"
assert_eq "20c: clear_polls never appeared" "$(stall_has_key mf20c clear_polls)" "0"

test_summary
