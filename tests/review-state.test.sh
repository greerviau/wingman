#!/usr/bin/env bash
# E2E: the `review` state - a deliverable ready and in review. It must (1) surface
# to wingman once, like blocked, so the pilot is told "ready for review"; (2) keep
# the member LIVE (Active list, counts as active, reconciles to died if its window
# dies) rather than reaping it; (3) stay quiet on the follow-up work the member does
# under `working`, so a build member fixing CI / addressing comments never
# re-announces "ready". No real crew/tmux/claude needed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- review surfaces once, then is quiet once acked ---------------------------
test_new_home
wm_state crew-add --id r1 --type build --objective x --repo /tmp --window wm-r1 --session-id s1 >/dev/null
wm_state crew-set --id r1 --status review --delivery "https://gh/pr/1" --summary "PR open" >/dev/null

na="$(wm_state needs-attention)"
assert_contains "needs-attention surfaces a review member" "$na" "r1"
assert_contains "the surfaced note carries the delivery pointer" "$na" "https://gh/pr/1"
st="$(printf '%s\n' "$na" | head -n1 | cut -f2)"
assert_eq "the surfaced status is review" "$st" "review"

upd="$(printf '%s\n' "$na" | head -n1 | cut -f3)"
wm_state ack --id r1 --updated "$upd" >/dev/null
assert_eq "acked review event no longer surfaces" "$(wm_state needs-attention)" ""

# --- a review member is LIVE, not terminal -----------------------------------
assert_contains "a review member counts as active" \
  "$(wm_state crew-list --active --json)" '"id": "r1"'
assert_contains "the board lists a review member under Active" \
  "$(awk '/## Active/{f=1} /## Closed/{f=0} f' "$WINGMAN_HOME/board.md")" "r1"

# --- follow-up work under `working` does not re-announce ----------------------
wm_state crew-set --id r1 --status working --summary "fixing CI" >/dev/null
assert_eq "dropping to working after review stays quiet" "$(wm_state needs-attention)" ""
wm_state crew-set --id r1 --status working --summary "still fixing CI" >/dev/null
assert_eq "a working summary refresh stays quiet" "$(wm_state needs-attention)" ""

# --- reaching done (PR merged/closed) surfaces the terminal outcome ----------
wm_state crew-set --id r1 --status done --summary "merged" >/dev/null
assert_contains "done after review surfaces the terminal outcome" "$(wm_state needs-attention)" "r1"

# --- a windowless review member reconciles to died ---------------------------
test_new_home
wm_state crew-add --id r2 --type build --objective y --repo /tmp --window wm-r2 --session-id s2 >/dev/null
wm_state crew-set --id r2 --status review --delivery "https://gh/pr/2" >/dev/null
wm_state reconcile --windows "" >/dev/null   # no live windows
assert_contains "a review member whose window is gone reconciles to died" \
  "$(wm_state crew-get --id r2)" '"status": "died"'

test_summary
