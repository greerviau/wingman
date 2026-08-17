#!/usr/bin/env bash
# E2E: cmd_roster_terminal_check (Class D2) - wakes a `working` lead whose
# roster has fully closed out (no direct report left in LIVE_STATES) to
# re-evaluate its own terminal condition, with a distinct reason
# ('roster-unreaped') whenever a closed-out roster still carries an un-reaped
# `done` report. Modeled structurally on tests/forward-motion-check.test.sh -
# state layer only, no tmux/watch-fleet involved here (see
# tests/roster-terminal-wake.test.sh for the wiring).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

wm_py() { uv run --no-project --quiet python "$@"; }

status_of() {
  wm_state crew-get --id "$1" | wm_py -c 'import json,sys; print(json.load(sys.stdin)["status"])'
}
field_of() {
  wm_state crew-get --id "$1" | wm_py -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"
}

# roster-terminal.json's per-candidate anchor "at" stamp.
anchor_at() {
  wm_py -c '
import json, sys, os
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
print((d.get(sys.argv[2]) or {}).get("at", ""))
' "$WINGMAN_HOME/roster-terminal.json" "$1"
}

board_mtime() {
  stat -c %Y "$WINGMAN_HOME/board.md" 2>/dev/null || stat -f %m "$WINGMAN_HOME/board.md"
}

# --- 1. baseline: silent before the window, fires exactly once after it -----
test_new_home
wm_state crew-add --id lead1 --type lead --objective x --repo /tmp --window wm-lead1 --session-id s1 >/dev/null
wm_state crew-set --id lead1 --status working --summary "leading" >/dev/null
wm_state crew-add --id r1a --type developer --objective x --repo /tmp --window wm-r1a --session-id s-r1a --parent lead1 >/dev/null
wm_state crew-set --id r1a --status stood-down --summary done >/dev/null
wm_state crew-add --id r1b --type developer --objective x --repo /tmp --window wm-r1b --session-id s-r1b --parent lead1 >/dev/null
wm_state crew-set --id r1b --status stood-down --summary done >/dev/null

out1a="$(wm_state roster-terminal-check --self lead1 --window-secs 2)"
assert_eq "silent on the very first check (anchor just established)" "$out1a" ""
sleep 1
out1b="$(wm_state roster-terminal-check --self lead1 --window-secs 2)"
assert_eq "silent just under the window" "$out1b" ""
sleep 1.5
out1c="$(wm_state roster-terminal-check --self lead1 --window-secs 2)"
assert_contains "fires roster-terminal once the window elapses" "$out1c" "roster-terminal lead1 2 0"

# --- 2. silent on immediate re-check; fires again after a second window -----
out2a="$(wm_state roster-terminal-check --self lead1 --window-secs 2)"
assert_eq "silent on an immediate re-check right after firing" "$out2a" ""
sleep 1
out2b="$(wm_state roster-terminal-check --self lead1 --window-secs 2)"
assert_eq "still silent just under the second window" "$out2b" ""
sleep 1.5
out2c="$(wm_state roster-terminal-check --self lead1 --window-secs 2)"
assert_contains "fires again after a fresh full window" "$out2c" "roster-terminal lead1 2 0"

# --- 3. a live report blocks candidacy, at any elapsed time ------------------
for live_status in review stalled; do
  test_new_home
  wm_state crew-add --id lead3 --type lead --objective x --repo /tmp --window wm-lead3 --session-id s3 >/dev/null
  wm_state crew-set --id lead3 --status working --summary "leading" >/dev/null
  wm_state crew-add --id r3a --type developer --objective x --repo /tmp --window wm-r3a --session-id s-r3a --parent lead3 >/dev/null
  wm_state crew-set --id r3a --status stood-down --summary done >/dev/null
  wm_state crew-add --id r3b --type developer --objective x --repo /tmp --window wm-r3b --session-id s-r3b --parent lead3 >/dev/null
  wm_state crew-set --id r3b --status "$live_status" --summary "still going" >/dev/null

  wm_state roster-terminal-check --self lead3 --window-secs 1 >/dev/null
  sleep 1.5
  out3="$(wm_state roster-terminal-check --self lead3 --window-secs 1)"
  assert_eq "a report in '$live_status' blocks candidacy, even past the window" "$out3" ""
done

# --- 4. zero reports -> never a candidate -------------------------------------
test_new_home
wm_state crew-add --id lead4 --type lead --objective x --repo /tmp --window wm-lead4 --session-id s4 >/dev/null
wm_state crew-set --id lead4 --status working --summary "leading, nothing spawned yet" >/dev/null

wm_state roster-terminal-check --self lead4 --window-secs 1 >/dev/null
sleep 1.5
out4="$(wm_state roster-terminal-check --self lead4 --window-secs 1)"
assert_eq "a lead with no reports of its own is never a candidate" "$out4" ""

# --- 5. the candidate's own status gates candidacy ----------------------------
for cand_status in review blocked stalled; do
  test_new_home
  wm_state crew-add --id lead5 --type lead --objective x --repo /tmp --window wm-lead5 --session-id s5 >/dev/null
  wm_state crew-set --id lead5 --status "$cand_status" --summary "not working" >/dev/null
  wm_state crew-add --id r5a --type developer --objective x --repo /tmp --window wm-r5a --session-id s-r5a --parent lead5 >/dev/null
  wm_state crew-set --id r5a --status stood-down --summary done >/dev/null

  wm_state roster-terminal-check --self lead5 --window-secs 1 >/dev/null
  sleep 1.5
  out5="$(wm_state roster-terminal-check --self lead5 --window-secs 1)"
  assert_eq "a candidate itself in '$cand_status' never fires" "$out5" ""
done

# --- 6. stood-down/died counts are separate and correctly ordered ------------
test_new_home
wm_state crew-add --id lead6 --type lead --objective x --repo /tmp --window wm-lead6 --session-id s6 >/dev/null
wm_state crew-set --id lead6 --status working --summary "leading" >/dev/null
wm_state crew-add --id r6a --type developer --objective x --repo /tmp --window wm-r6a --session-id s-r6a --parent lead6 >/dev/null
wm_state crew-set --id r6a --status stood-down --summary done >/dev/null
wm_state crew-add --id r6b --type developer --objective x --repo /tmp --window wm-r6b --session-id s-r6b --parent lead6 >/dev/null
wm_state crew-set --id r6b --status died --summary "window gone" >/dev/null
wm_state crew-add --id r6c --type developer --objective x --repo /tmp --window wm-r6c --session-id s-r6c --parent lead6 >/dev/null
wm_state crew-set --id r6c --status died --summary "window gone" >/dev/null

wm_state roster-terminal-check --self lead6 --window-secs 1 >/dev/null
sleep 1.5
out6="$(wm_state roster-terminal-check --self lead6 --window-secs 1)"
assert_contains "one stood-down and two died report exactly '1 2'" "$out6" "roster-terminal lead6 1 2"

# --- 7. an all-died roster still fires, with n-stood-down reported as 0 ------
test_new_home
wm_state crew-add --id lead7 --type lead --objective x --repo /tmp --window wm-lead7 --session-id s7 >/dev/null
wm_state crew-set --id lead7 --status working --summary "leading" >/dev/null
wm_state crew-add --id r7a --type developer --objective x --repo /tmp --window wm-r7a --session-id s-r7a --parent lead7 >/dev/null
wm_state crew-set --id r7a --status died --summary "window gone" >/dev/null
wm_state crew-add --id r7b --type developer --objective x --repo /tmp --window wm-r7b --session-id s-r7b --parent lead7 >/dev/null
wm_state crew-set --id r7b --status died --summary "window gone" >/dev/null

wm_state roster-terminal-check --self lead7 --window-secs 1 >/dev/null
sleep 1.5
out7="$(wm_state roster-terminal-check --self lead7 --window-secs 1)"
assert_contains "an all-died roster still fires roster-terminal" "$out7" "roster-terminal lead7 0 2"

# --- 8. a done report yields roster-unreaped, never roster-terminal ----------
test_new_home
wm_state crew-add --id lead8 --type lead --objective x --repo /tmp --window wm-lead8 --session-id s8 >/dev/null
wm_state crew-set --id lead8 --status working --summary "leading" >/dev/null
wm_state crew-add --id r8a --type developer --objective x --repo /tmp --window wm-r8a --session-id s-r8a --parent lead8 >/dev/null
wm_state crew-set --id r8a --status done --artifact "plan.md" --summary "handed off" >/dev/null
wm_state crew-add --id r8b --type developer --objective x --repo /tmp --window wm-r8b --session-id s-r8b --parent lead8 >/dev/null
wm_state crew-set --id r8b --status stood-down --summary closed >/dev/null

wm_state roster-terminal-check --self lead8 --window-secs 1 >/dev/null
sleep 1.5
out8="$(wm_state roster-terminal-check --self lead8 --window-secs 1)"
assert_contains "one un-reaped done report yields roster-unreaped with count 1" "$out8" "roster-unreaped lead8 1"
case "$out8" in
  roster-terminal*) fail "roster-unreaped never mislabeled as roster-terminal" ;;
  *) ok "roster-unreaped never mislabeled as roster-terminal" ;;
esac

# --- 9. closing the done report out resets the clock -------------------------
wm_state crew-set --id r8a --status stood-down --summary closed >/dev/null
out9a="$(wm_state roster-terminal-check --self lead8 --window-secs 2)"
assert_eq "closing the done report resets the clock: no immediate fire" "$out9a" ""
sleep 1
out9b="$(wm_state roster-terminal-check --self lead8 --window-secs 2)"
assert_eq "still silent shy of a fresh full window" "$out9b" ""
sleep 1.5
out9c="$(wm_state roster-terminal-check --self lead8 --window-secs 2)"
assert_contains "a fresh full window after the reset fires roster-terminal, not roster-unreaped" "$out9c" "roster-terminal lead8 2 0"

# --- 10. the candidate's own --park item resets the anchor -------------------
test_new_home
wm_state crew-add --id lead10 --type lead --objective x --repo /tmp --window wm-lead10 --session-id s10 >/dev/null
wm_state crew-set --id lead10 --status working --summary "leading" >/dev/null
wm_state crew-add --id r10a --type developer --objective x --repo /tmp --window wm-r10a --session-id s-r10a --parent lead10 >/dev/null
wm_state crew-set --id r10a --status stood-down --summary done >/dev/null

wm_state roster-terminal-check --self lead10 --window-secs 2 >/dev/null
sleep 1
wm_state crew-set --id lead10 --park "99:need a call" >/dev/null
out10a="$(wm_state roster-terminal-check --self lead10 --window-secs 2)"
assert_eq "adding a --park item resets the anchor: no immediate fire" "$out10a" ""
sleep 1.5
out10b="$(wm_state roster-terminal-check --self lead10 --window-secs 2)"
assert_eq "still no fire shortly after (fresh window required from the reset point)" "$out10b" ""

# --- 11. no side effects: candidate record and board.md are untouched -------
test_new_home
wm_state crew-add --id lead11 --type lead --objective x --repo /tmp --window wm-lead11 --session-id s11 >/dev/null
wm_state crew-set --id lead11 --status working --summary "leading" >/dev/null
wm_state crew-add --id r11a --type developer --objective x --repo /tmp --window wm-r11a --session-id s-r11a --parent lead11 >/dev/null
wm_state crew-set --id r11a --status stood-down --summary done >/dev/null

wm_state roster-terminal-check --self lead11 --window-secs 1 >/dev/null
sleep 1.5
status_before="$(status_of lead11)"
updated_before="$(field_of lead11 updated)"
announced_before="$(field_of lead11 announced)"
summary_before="$(field_of lead11 summary)"
board_before="$(board_mtime)"
sleep 1.1   # let the filesystem clock move past a 1s-resolution mtime
out11="$(wm_state roster-terminal-check --self lead11 --window-secs 1)"
assert_contains "case 11's own fire happens as expected" "$out11" "roster-terminal lead11"
assert_eq "the candidate's status is unchanged after a fire" "$(status_of lead11)" "$status_before"
assert_eq "the candidate's updated stamp is unchanged after a fire" "$(field_of lead11 updated)" "$updated_before"
assert_eq "the candidate's announced stamp is unchanged after a fire" "$(field_of lead11 announced)" "$announced_before"
assert_eq "the candidate's summary is unchanged after a fire" "$(field_of lead11 summary)" "$summary_before"
assert_eq "board.md's mtime is unchanged after a fire" "$(board_mtime)" "$board_before"

# --- 12. --self "" never fires, even with an all-terminal roster under owner "" ---
test_new_home
wm_state crew-add --id r12a --type developer --objective x --repo /tmp --window wm-r12a --session-id s-r12a >/dev/null
wm_state crew-set --id r12a --status stood-down --summary done >/dev/null

out12a="$(wm_state roster-terminal-check --self "" --window-secs 1)"
assert_eq "--self '' never fires against an ordinary owner-'' roster" "$out12a" ""

# A record whose own id is literally "" can never arise from a real spawn
# (bin/spawn-crew always derives a non-empty id) - so this is the only
# fixture that can tell "the guard is present" from "the guard is removed"
# apart: without the `if not self_id: return` check, the candidate lookup
# below would find THIS record by id=="" and treat it as a real self, with
# r12a (parent == "") as one of its reports. Its OWN parent is deliberately
# a non-"" placeholder - "" would make it a report of itself too (parent_of
# also resolves to ""), which would self-block on rule 5 (its own status is
# 'working', a LIVE_STATES member) and mask the very mutation this fixture
# exists to catch.
wm_py -c '
import json, sys
p = sys.argv[1]
rows = json.load(open(p))
rows.append({"id": "", "type": "lead", "parent": "not-a-real-owner", "status": "working",
             "objective": "x", "repo": "/tmp", "window": "wm-empty-id",
             "session_id": "s-empty-id", "updated": "2026-01-01T00:00:00.000000Z"})
json.dump(rows, open(p, "w"))
' "$WINGMAN_HOME/crew.json"
wm_state roster-terminal-check --self "" --window-secs 1 >/dev/null   # establish the anchor
sleep 1.5
out12b="$(wm_state roster-terminal-check --self "" --window-secs 1)"
assert_eq "--self '' never fires even against a malformed id==\"\" record, past the window" "$out12b" ""

test_summary
