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

# --- regression: a self-report that lands between a caller's stale read and
# a later write is never clobbered by _stamp_nudged_at/_track_long_running
# (a reviewer-reported race on PR #156). A round trip through the CLI cannot
# actually exercise this: cmd_stall_check's own top-of-function gate already
# bails immediately once status != 'working', so calling `crew-set --status
# blocked` to completion BEFORE ever invoking `stall-check` never reaches
# either side-effect writer in the first place, on the buggy code or the
# fixed code alike - a first attempt at this regression test made exactly
# that mistake and was caught in re-review (it passed identically against
# both the pre-fix and post-fix commit). A genuine white-box repro instead
# calls the internal functions directly, the same way the original review
# reproduced the bug: capture a stale snapshot the way cmd_stall_check's own
# entry read would, let a self-report land, then prove (1) writing that
# stale snapshot straight back - exactly what the pre-fix code did - really
# does destroy the self-report, and (2) the current functions, even handed
# an equally stale snapshot by a caller, never do this, because they discard
# it and re-verify against a fresh, lock-protected read immediately before
# writing. ---------------------------------------------------------------
test_new_home
OUT="$(uv run --no-project --quiet python - "$TEST_REPO/bin/lib/wm-state.py" "$WINGMAN_HOME" <<'PYEOF'
import os, sys, importlib.util

wm_state_path, home = sys.argv[1], sys.argv[2]
os.environ["WINGMAN_HOME"] = home
spec = importlib.util.spec_from_file_location("wm_state_mod", wm_state_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.ensure_home()

cid = "race1"
path = mod.status_path(cid)
fail = False


def check(cond, msg):
    global fail
    if cond:
        print("PASS: %s" % msg)
    else:
        print("FAIL: %s" % msg)
        fail = True


def write(d):
    mod.write_json(path, d)


def read():
    return mod.read_json(path, None)


# --- Part 1: prove the pre-fix write shape is genuinely destructive ----------
write({"id": cid, "status": "working", "summary": "digging through logs", "updated": mod.now()})
stale_live = read()  # what cmd_stall_check's own entry read would have captured
check(stale_live["status"] == "working", "stale snapshot captured while status was working")

# A concurrent self-report lands - the member's own session reporting
# 'blocked' while a stall-check poll (holding the stale snapshot above) is
# still mid-flight.
write({"id": cid, "status": "blocked", "blocker": "need the human to install a library",
       "summary": "digging through logs", "updated": mod.now()})

# The exact pre-fix pattern: take the dict read BEFORE the self-report, add
# the field the old code would have added, write it straight back.
old_pattern_write = dict(stale_live)
old_pattern_write["nudged_at"] = mod.now()
write(old_pattern_write)
reverted = read()
check(reverted["status"] == "working",
      "the pre-fix write pattern genuinely reverts a concurrent blocked transition")
check(reverted.get("blocker") is None,
      "...and erases the blocker text along with it, with no trace")

# --- Part 2: the CURRENT functions never do this, even handed an equally
# stale snapshot by their caller -----------------------------------------------
write({"id": cid, "status": "working", "summary": "digging through logs", "updated": mod.now()})
stale_live2 = read()  # a second stale snapshot, same shape as Part 1's
check(stale_live2["status"] == "working", "second stale snapshot captured while status was working")

write({"id": cid, "status": "blocked", "blocker": "need the human to install a library",
       "summary": "digging through logs", "updated": mod.now()})

# The two real side-effect writers a single stall-check poll makes, called
# directly - neither is passed (nor has any use for) the stale snapshot
# above; both must independently re-verify against the file on disk.
mod._stamp_nudged_at(cid)
mod._track_long_running(cid, os.getpid(), 999999)

final = read()
check(final["status"] == "blocked", "_stamp_nudged_at/_track_long_running leave the blocked status intact")
check(final.get("blocker") == "need the human to install a library",
      "...and the blocker text survives intact")
check(final.get("nudged_at") is None,
      "_stamp_nudged_at made no write at all once status was no longer 'working'")
check("long_shell_pid" not in final,
      "_track_long_running made no write at all once status was no longer 'working'")

sys.exit(1 if fail else 0)
PYEOF
)"
rc=$?
assert_true "the white-box repro script ran to completion" "[ $rc -eq 0 ]"
assert_contains "pre-fix pattern reverts the blocked transition (proves the bug shape is real)" \
  "$OUT" "PASS: the pre-fix write pattern genuinely reverts a concurrent blocked transition"
assert_contains "pre-fix pattern erases the blocker too" \
  "$OUT" "PASS: ...and erases the blocker text along with it, with no trace"
assert_contains "current functions leave the blocked status intact" \
  "$OUT" "PASS: _stamp_nudged_at/_track_long_running leave the blocked status intact"
assert_contains "current functions leave the blocker text intact" \
  "$OUT" "PASS: ...and the blocker text survives intact"
assert_not_contains "no FAIL line anywhere in the script output" "$OUT" "FAIL:"

test_summary
