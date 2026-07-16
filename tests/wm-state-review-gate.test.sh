#!/usr/bin/env bash
# E2E: review_gate_waived (issue #132) - the roster field, symmetric to
# allow_merge, that hooks/no-merge-guard.sh reads to decide whether the new
# review-evidence gate applies. Covers wm-state.py's crew-add/crew-set
# plumbing, the roster/board rendering that makes a waived effort as visible
# as a merge-authorized one, and bin/spawn-crew's --waive-review-gate wiring
# end-to-end (no-merge-guard.sh's own test file covers the hook's actual
# enforcement logic - this file only covers that the field lands correctly).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

field_of() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
v = json.load(sys.stdin).get(sys.argv[1])
print("" if v is None else ("true" if v else "false"))
' "$2"
}

test_new_home

# ============================================================================
# crew-add: --waive-review-gate sets review_gate_waived: true; omitted
# defaults to false, exactly like --allow-merge.
# ============================================================================
wm_state crew-add --id waived1 --type developer --repo /tmp \
  --window w1 --session-id s1 --waive-review-gate >/dev/null
assert_eq "crew-add --waive-review-gate records review_gate_waived: true" \
  "$(field_of waived1 review_gate_waived)" "true"

wm_state crew-add --id plain1 --type developer --repo /tmp \
  --window w2 --session-id s2 >/dev/null
assert_eq "crew-add without the flag defaults review_gate_waived to false" \
  "$(field_of plain1 review_gate_waived)" "false"

# allow_merge and review_gate_waived are independent fields - granting one
# must not imply the other.
wm_state crew-add --id merge-only --type developer --repo /tmp \
  --window w3 --session-id s3 --allow-merge >/dev/null
assert_eq "allow_merge alone does not imply review_gate_waived" \
  "$(field_of merge-only review_gate_waived)" "false"
assert_eq "...and allow_merge itself is still recorded" \
  "$(field_of merge-only allow_merge)" "true"

# ============================================================================
# crew-set: --review-gate-waived true/false grants/revokes mid-session,
# mirroring --allow-merge's own shape exactly.
# ============================================================================
wm_state crew-set --id plain1 --review-gate-waived true >/dev/null
assert_eq "crew-set --review-gate-waived true grants it mid-session" \
  "$(field_of plain1 review_gate_waived)" "true"

wm_state crew-set --id plain1 --review-gate-waived false >/dev/null
assert_eq "crew-set --review-gate-waived false revokes it" \
  "$(field_of plain1 review_gate_waived)" "false"

# An ordinary crew-set call that never mentions --review-gate-waived leaves
# the field untouched.
wm_state crew-set --id waived1 --review-gate-waived true >/dev/null
wm_state crew-set --id waived1 --status working --summary "on it" >/dev/null
assert_eq "an unrelated crew-set call does not clear review_gate_waived" \
  "$(field_of waived1 review_gate_waived)" "true"

# ============================================================================
# Roster/board rendering: a waived effort is exactly as visible as a
# merge-authorized one (issue #46's own "explicit, per-effort, and visible"
# precedent, extended to issue #132).
# ============================================================================
list="$(wm_state crew-list)"
assert_contains "crew-list shows the WAIVED marker for a waived effort" \
  "$list" "review gate: WAIVED for this effort (issue #132)"

tree="$(wm_state crew-list --tree)"
assert_contains "crew-list --tree shows the WAIVED marker too" \
  "$tree" "review gate: WAIVED for this effort (issue #132)"

board="$(cat "$WINGMAN_HOME/board.md")"
assert_contains "board.md marks a waived effort's id cell (review-waived)" \
  "$board" "waived1 (review-waived)"
assert_not_contains "board.md does not mark a non-waived effort's id cell" \
  "$(printf '%s\n' "$board" | grep 'plain1')" "(review-waived)"

# ============================================================================
# bin/spawn-crew: --waive-review-gate at spawn time (end-to-end, stub agent -
# no real claude launches, isolated tmux session).
# ============================================================================
SPAWN="$TEST_REPO/bin/spawn-crew"
WS="$(wm_mktemp_dir)/repo"
mkdir -p "$WS"
git -C "$WS" init -q
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$WS/../stub.sh"
chmod +x "$WS/../stub.sh"

export WM_AGENT="$WS/../stub.sh" WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 \
  WM_READY_TRIES=1 WM_READY_POLL=0 WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1
wm_trust_repo "$WS"

id="$("$SPAWN" --type developer --repo "$WS" --objective "test" --waive-review-gate 2>/dev/null | tail -1)"
assert_true "spawn-crew --waive-review-gate succeeds" "[ -n '$id' ]"
assert_eq "the spawned member's roster record carries review_gate_waived: true" \
  "$(field_of "$id" review_gate_waived)" "true"

id2="$("$SPAWN" --type developer --repo "$WS" --objective "test, no waiver" 2>/dev/null | tail -1)"
assert_true "a plain spawn-crew call (no waiver flag) succeeds" "[ -n '$id2' ]"
assert_eq "...and defaults review_gate_waived to false" \
  "$(field_of "$id2" review_gate_waived)" "false"

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

test_summary
