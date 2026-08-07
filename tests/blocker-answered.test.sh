#!/usr/bin/env bash
# E2E: a bounded muffle window for an answered `blocked` row (issue #194). A
# delegate that acts on its owner's answer but never transitions back to
# `working` leaves a resolved question sitting in `blocker`/`blocked`, and
# needs-attention re-surfaces it as if it were still open. wm_state
# record-delivery (called by bin/crew-say and wm_outbox_try_redeliver on every
# CONFIRMED delivery) plus cmd_needs_attention's own muffle-window check close
# this: a `blocked` row is withheld while blocker_set_at <= last_delivered[owner],
# updated > last_delivered[owner] (the record actually ran a turn on the reply,
# not just that a message landed in its pane), and elapsed time since the
# reply is under WM_BLOCKER_ANSWER_GRACE - past the window it resurfaces with a
# STALE? prefix rather than staying silenced forever. No real tmux/claude needed
# - this file drives wm_state directly.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

field() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python3 -c "
import json, sys
v = json.load(sys.stdin).get('$2')
print(v if v is not None else '')
"
}

blocked_ids() { printf '%s\n' "$1" | cut -f1; }
note_for() { printf '%s\n' "$1" | awk -F'\t' -v id="$2" '$1==id{print $4}'; }

# --- 1/2/3/4/5/6: the direct-blocker lifecycle --------------------------------
test_new_home
wm_state crew-add --id b1 --type developer --objective x --repo /tmp --window wm-b1 --session-id s1 >/dev/null
wm_state crew-set --id b1 --status blocked --blocker "q1" >/dev/null

bset1="$(field b1 blocker_set_at)"
assert_true "blocker_set_at is stamped on a fresh blocked escalation" "[ -n '$bset1' ]"

na1="$(wm_state needs-attention --owner "")"
assert_contains "an unanswered blocker surfaces via needs-attention" "$(blocked_ids "$na1")" "b1"

wm_state record-delivery --to b1 --from "" >/dev/null
na2="$(wm_state needs-attention --owner "")"
assert_contains "a delivery with no subsequent self-report must not muffle" "$(blocked_ids "$na2")" "b1"

wm_state crew-set --id b1 --status blocked --summary "still working the question" >/dev/null
bset2="$(field b1 blocker_set_at)"
assert_eq "an unchanged-blocker refresh does not re-arm blocker_set_at" "$bset2" "$bset1"

na3="$(wm_state needs-attention --owner "")"
assert_not_contains "a self-report after the owner's reply muffles the row" "$(blocked_ids "$na3")" "b1"

export WM_BLOCKER_ANSWER_GRACE=2
sleep 2.5
na4="$(wm_state needs-attention --owner "")"
assert_contains "the row resurfaces once the grace window elapses" "$(blocked_ids "$na4")" "b1"
n4="$(note_for "$na4" b1)"
case "$n4" in
  "STALE? ("*) ok "the resurfaced note starts with the STALE? ( marker" ;;
  *)           fail "the resurfaced note must start with STALE? (" ;;
esac
unset WM_BLOCKER_ANSWER_GRACE

wm_state crew-set --id b1 --status blocked --blocker "q2" >/dev/null
na5="$(wm_state needs-attention --owner "")"
assert_contains "a fresh blocker with different text is never muffled" "$(blocked_ids "$na5")" "b1"

# --- 7: a delivery from someone other than the record's own owner never muffles
test_new_home
wm_state crew-add --id b2 --type developer --objective x --repo /tmp --window wm-b2 --session-id s2 >/dev/null
wm_state crew-set --id b2 --status blocked --blocker "q1" >/dev/null
wm_state record-delivery --to b2 --from "some-other-sibling-id" >/dev/null
wm_state crew-set --id b2 --status blocked --summary "unrelated refresh" >/dev/null
na6="$(wm_state needs-attention --owner "")"
assert_contains "a delivery attributed to a non-owner sender never muffles" "$(blocked_ids "$na6")" "b2"

# --- 8: a composed/parked blocker is stamped and muffles identically to direct
test_new_home
wm_state crew-add --id b3 --type lead --objective x --repo /tmp --window wm-b3 --session-id s3 >/dev/null
wm_state crew-set --id b3 --status blocked --park "a:x" --park "b:y" >/dev/null
bset3="$(field b3 blocker_set_at)"
assert_true "a composed (parked) blocker is stamped identically to a direct one" "[ -n '$bset3' ]"

wm_state record-delivery --to b3 --from "" >/dev/null
wm_state crew-set --id b3 --status blocked --summary "still parked" >/dev/null
na7="$(wm_state needs-attention --owner "")"
assert_not_contains "a composed blocker muffles after a self-report following the reply" "$(blocked_ids "$na7")" "b3"

test_summary
