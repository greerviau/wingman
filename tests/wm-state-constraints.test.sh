#!/usr/bin/env bash
# E2E: the `constraints` roster field (issue #192) - durable, per-effort record
# of what the pilot personally said about how an effort must be run, captured
# at crew-add time and mutable via crew-set, symmetric in shape to allow_merge/
# review_gate_waived but carrying no self-grant restriction (see the issue
# #192 plan's "Rejected alternatives" for why). bin/crew-say's own
# --ack-constraints gate is covered separately in
# tests/crew-say-constraints.test.sh, which has the tmux/window machinery this
# file's own scope (state-engine + rendering) does not need.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

constraints_of() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
r = json.load(sys.stdin)
print(json.dumps(r.get("constraints")))
'
}

test_new_home

# --- crew-add: --constraint (repeatable) seeds the field; omitted -> [] -----
wm_state crew-add --id c1 --type lead --objective big --repo /tmp \
  --window w1 --session-id s1 \
  --constraint "go one at a time" --constraint "never merge without review" >/dev/null
c1_constraints="$(constraints_of c1)"
assert_contains "crew-add --constraint (repeated) records both texts" "$c1_constraints" '"go one at a time"'
assert_contains "...and the second one too" "$c1_constraints" '"never merge without review"'
assert_contains "each entry carries a set_at stamp" "$c1_constraints" '"set_at"'

wm_state crew-add --id c2 --type developer --objective x --repo /tmp \
  --window w2 --session-id s2 >/dev/null
assert_eq "crew-add with no --constraint defaults constraints to an empty list" \
  "$(constraints_of c2)" "[]"

# --- crew-set: --add-constraint appends; an unrelated call leaves it alone --
wm_state crew-set --id c2 --add-constraint "one issue at a time" >/dev/null
assert_contains "crew-set --add-constraint adds mid-session" \
  "$(constraints_of c2)" '"one issue at a time"'

wm_state crew-set --id c2 --status working --summary "on it" >/dev/null
assert_contains "an unrelated crew-set call does not clear an existing constraint" \
  "$(constraints_of c2)" '"one issue at a time"'

wm_state crew-set --id c2 --add-constraint "second constraint" >/dev/null
c2_after_two="$(constraints_of c2)"
assert_contains "a second --add-constraint call APPENDS, not replaces" "$c2_after_two" '"one issue at a time"'
assert_contains "...both are present" "$c2_after_two" '"second constraint"'

# --- crew-set: --clear-constraints on a NON-EMPTY record is refused without -
# --confirm-clear (review round 1 fix) - the record this whole mechanism
# depends on must never be silently emptied by the same actor (wingman's own
# session) both real incidents implicate, and no identity-based self-grant
# restriction (unlike allow_merge/review_gate_waived) could help here since it
# would have to exempt exactly that actor. The refusal must exit nonzero AND
# leave the record untouched, and must name the actual constraint text being
# protected - an exit-code-only assertion would pass even if the refusal
# accidentally cleared the record anyway before exiting.
if err="$(wm_state crew-set --id c2 --clear-constraints 2>&1 >/dev/null)"; then
  assert_true "a non-empty --clear-constraints with no --confirm-clear must fail, not succeed" "false"
else
  assert_contains "the refusal names what would be erased" "$err" "one issue at a time"
  assert_contains "...and points at the remedy" "$err" "--confirm-clear"
fi
assert_contains "the record is UNCHANGED after the refused clear attempt" \
  "$(constraints_of c2)" '"one issue at a time"'

# --- --confirm-clear alongside --clear-constraints succeeds, empties the ----
# live list, and traces what was cleared into constraints_cleared.
wm_state crew-set --id c2 --clear-constraints --confirm-clear >/dev/null
assert_eq "--clear-constraints --confirm-clear empties the live list" "$(constraints_of c2)" "[]"
cleared_c2="$(wm_state crew-get --id c2 | uv run --no-project --quiet python -c '
import sys, json
print(json.dumps(json.load(sys.stdin).get("constraints_cleared")))
')"
assert_contains "constraints_cleared traces what was erased" "$cleared_c2" '"one issue at a time"'
assert_contains "...and each entry carries a cleared_at stamp" "$cleared_c2" '"cleared_at"'

# --- clearing an ALREADY-EMPTY record needs no --confirm-clear (nothing to --
# hide a clear behind) - must not spuriously refuse a no-op.
wm_state crew-set --id c2 --clear-constraints >/dev/null
assert_true "clearing an already-empty record needs no --confirm-clear" "[ $? -eq 0 ]"

# --- --clear-constraints and --add-constraint together: clear runs FIRST, so
# the two combine into a clean replace, not a no-op clear-then-append-onto-
# nothing-then-somehow-still-there bug. Still requires --confirm-clear, exactly
# like a bare clear, since it is still erasing an existing constraint.
wm_state crew-add --id c3 --type developer --objective x --repo /tmp \
  --window w3 --session-id s3 --constraint "old constraint" >/dev/null
if err="$(wm_state crew-set --id c3 --clear-constraints --add-constraint "fresh constraint" 2>&1 >/dev/null)"; then
  assert_true "combined clear+add without --confirm-clear must also fail" "false"
else
  assert_contains "...naming the old constraint it would have erased" "$err" "old constraint"
fi
wm_state crew-set --id c3 --clear-constraints --confirm-clear --add-constraint "fresh constraint" >/dev/null
c3_after="$(constraints_of c3)"
assert_not_contains "confirmed combined clear+add drops the old constraint from the live list" "$c3_after" "old constraint"
assert_contains "...and the new one lands" "$c3_after" '"fresh constraint"'

# --- rendering: crew-list / --tree / board.md mark a constrained effort -----
list="$(wm_state crew-list)"
assert_contains "crew-list shows the constraints marker for c1" "$list" "constraints (from the pilot"
assert_contains "...and the constraint text itself" "$list" "go one at a time"

tree="$(wm_state crew-list --tree)"
assert_contains "crew-list --tree shows the constraints marker too" "$tree" "constraints (from the pilot"

board="$(cat "$WINGMAN_HOME/board.md")"
assert_contains "board.md marks a constrained effort's id cell" "$board" "c1 (constrained)"
assert_not_contains "board.md does not mark an unconstrained effort's id cell" \
  "$(printf '%s\n' "$board" | grep 'c2 ')" "(constrained)"

# --- bin/spawn-crew: --constraint at spawn time (stub agent, no real claude) -
SPAWN="$TEST_REPO/bin/spawn-crew"
WS="$(wm_mktemp_dir)/repo"
mkdir -p "$WS"
git -C "$WS" init -q
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$WS/../stub.sh"
chmod +x "$WS/../stub.sh"

export WM_AGENT="$WS/../stub.sh" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 \
  WM_READY_TRIES=4 WM_READY_POLL=0 WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1
wm_trust_repo "$WS"

id="$("$SPAWN" --type developer --repo "$WS" --objective "test" \
  --constraint "go one at a time" 2>/dev/null | tail -1)"
assert_true "spawn-crew --constraint succeeds" "[ -n '$id' ]"
assert_contains "the spawned member's roster record carries the constraint" \
  "$(constraints_of "$id")" '"go one at a time"'

sysprompt="$WINGMAN_HOME/crew/$id.sysprompt.md"
assert_true "a sysprompt file was written" "[ -f '$sysprompt' ]"
assert_contains "the sysprompt itself carries the constraint as a labeled section, not just inside the objective" \
  "$(cat "$sysprompt")" "Standing constraints from the human"
assert_contains "...including the literal constraint text" "$(cat "$sysprompt")" "go one at a time"

id2="$("$SPAWN" --type developer --repo "$WS" --objective "test, no constraint" 2>/dev/null | tail -1)"
assert_true "a plain spawn-crew call (no --constraint) succeeds" "[ -n '$id2' ]"
assert_eq "...and defaults constraints to an empty list" "$(constraints_of "$id2")" "[]"

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

test_summary
