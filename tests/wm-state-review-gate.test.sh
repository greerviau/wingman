#!/usr/bin/env bash
# E2E: review_gate_waived (issue #132) - the roster field, symmetric to
# allow_merge, that hooks/no-merge-guard.sh reads to decide whether the new
# review-evidence gate applies. Covers wm-state.py's crew-add/crew-set
# plumbing, the roster/board rendering that makes a waived effort as visible
# as a merge-authorized one, and bin/spawn-crew's --waive-review-gate wiring
# end-to-end (no-merge-guard.sh's own test file covers the hook's actual
# enforcement logic - this file only covers that the field lands correctly).
#
# Also covers the review_commit_approve/review_commit_request_changes/
# review_delivery_bound roster fields (issue #135's spawn-time hash-
# commitment scheme) at the same state-engine level: crew-add --review-token,
# review-sign, and crew-set --regenerate-review-token/--delivery-driven
# regeneration. The hook's actual proof-marker verification, and the
# self-grant restriction on --regenerate-review-token, are covered end-to-end
# in tests/no-merge-guard.test.sh instead, per this file's own scope line
# above.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

field_of() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
v = json.load(sys.stdin).get(sys.argv[1])
print("" if v is None else ("true" if v else "false"))
' "$2"
}

# Like field_of, but returns the raw string value (not coerced to true/false)
# - needed for review_commit_approve/review_delivery_bound, which are hex
# strings or PR URLs, not booleans.
raw_field_of() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
v = json.load(sys.stdin).get(sys.argv[1])
print("" if v is None else v)
' "$2"
}

random_token() {
  uv run --no-project --quiet python -c 'import secrets; print(secrets.token_hex(32))'
}

sha256_hex() {
  uv run --no-project --quiet python -c 'import sys, hashlib; print(hashlib.sha256(bytes.fromhex(sys.argv[1])).hexdigest())' "$1"
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

# ============================================================================
# issue #135: spawn-time per-verdict hash commitments. This file covers only
# that the fields land correctly at the state-engine level - no-merge-guard.
# test.sh's own "issue #135" section covers the hook's actual enforcement
# (the paired end-to-end half for tests 14-16 below, mirroring how tests 7/7a
# there already pair with tests 14/15 here for the earlier rounds of this
# same fix).
# ============================================================================

# --- test 10: crew-add --review-token stores only the derived commitments, -
# never the raw token itself.
TOKEN10="$(random_token)"
wm_state crew-add --id rev10 --type reviewer --repo /tmp \
  --window w10 --session-id s10 --review-token "$TOKEN10" >/dev/null
COMMIT10="$(raw_field_of rev10 review_commit_approve)"
assert_true "crew-add --review-token stores a review_commit_approve commitment" \
  "[ -n '$COMMIT10' ]"
assert_true "...and a review_commit_request_changes commitment too" \
  "[ -n '$(raw_field_of rev10 review_commit_request_changes)' ]"
RAW_DUMP="$(wm_state crew-get --id rev10)"
assert_not_contains "the raw token itself never appears anywhere in crew-get's output" \
  "$RAW_DUMP" "$TOKEN10"

# A reviewer spawned with NO token leaves both commitment fields None -
# unchanged, backward-compatible default.
wm_state crew-add --id rev10-notoken --type reviewer --repo /tmp \
  --window w10b --session-id s10b >/dev/null
assert_eq "crew-add with no --review-token leaves review_commit_approve empty" \
  "$(raw_field_of rev10-notoken review_commit_approve)" ""

# A non-reviewer type is unaffected even if --review-token is somehow passed.
wm_state crew-add --id dev10 --type developer --repo /tmp \
  --window w10c --session-id s10c --review-token "$(random_token)" >/dev/null
assert_eq "--review-token on a non-reviewer type is a no-op (no commitment stored)" \
  "$(raw_field_of dev10 review_commit_approve)" ""

# --- test 11: review-sign reproduces the exact commitment crew-add derived -
# (round-trip), and --token overrides the environment value.
PREIMAGE10="$(WM_REVIEW_TOKEN="$TOKEN10" WINGMAN_CREW_ID=rev10 wm_state review-sign --verdict approve)"
assert_eq "review-sign's preimage round-trips to the commitment crew-add derived" \
  "$(sha256_hex "$PREIMAGE10")" "$COMMIT10"

TOKEN11B="$(random_token)"
PREIMAGE_OVERRIDE="$(WM_REVIEW_TOKEN="$TOKEN10" WINGMAN_CREW_ID=rev10 wm_state review-sign --token "$TOKEN11B" --verdict approve)"
PREIMAGE_FROM_TOKEN11B_DIRECT="$(WM_REVIEW_TOKEN="$TOKEN11B" WINGMAN_CREW_ID=rev10 wm_state review-sign --verdict approve)"
assert_eq "review-sign --token overrides \$WM_REVIEW_TOKEN" \
  "$PREIMAGE_OVERRIDE" "$PREIMAGE_FROM_TOKEN11B_DIRECT"
assert_true "...and the override genuinely changes the output (different token, different preimage)" \
  "[ '$PREIMAGE_OVERRIDE' != '$PREIMAGE10' ]"

# --- test 12: review-sign with no token anywhere exits nonzero, never -----
# silently producing a bogus value.
if err="$(WINGMAN_CREW_ID=rev10 wm_state review-sign --verdict approve 2>&1 >/dev/null)"; then
  assert_true "review-sign with no WM_REVIEW_TOKEN/--token must fail, not succeed" "false"
else
  assert_contains "review-sign's failure message names what's missing" \
    "$err" "WM_REVIEW_TOKEN"
fi

# --- test 13: crew-set --regenerate-review-token overwrites both commitment
# fields; a proof derived from the OLD token no longer matches.
TOKEN13_OLD="$(random_token)"
wm_state crew-add --id rev13 --type reviewer --repo /tmp \
  --window w13 --session-id s13 --review-token "$TOKEN13_OLD" >/dev/null
COMMIT13_OLD="$(raw_field_of rev13 review_commit_approve)"
PREIMAGE13_OLD="$(WM_REVIEW_TOKEN="$TOKEN13_OLD" WINGMAN_CREW_ID=rev13 wm_state review-sign --verdict approve)"

TOKEN13_NEW="$(random_token)"
wm_state crew-set --id rev13 --regenerate-review-token "$TOKEN13_NEW" >/dev/null
COMMIT13_NEW="$(raw_field_of rev13 review_commit_approve)"
assert_true "--regenerate-review-token changes the commitment on record" \
  "[ '$COMMIT13_OLD' != '$COMMIT13_NEW' ]"
assert_true "a proof derived from the OLD token no longer matches the NEW commitment" \
  "[ '$(sha256_hex "$PREIMAGE13_OLD")' != '$COMMIT13_NEW' ]"
PREIMAGE13_NEW="$(WM_REVIEW_TOKEN="$TOKEN13_NEW" WINGMAN_CREW_ID=rev13 wm_state review-sign --verdict approve)"
assert_eq "...but a proof derived from the NEW token does match" \
  "$(sha256_hex "$PREIMAGE13_NEW")" "$COMMIT13_NEW"

# --- test 14: delivery-change auto-regeneration ----------------------------
TOKEN14="$(random_token)"
wm_state crew-add --id rev14 --type reviewer --repo /tmp \
  --window w14 --session-id s14 --review-token "$TOKEN14" >/dev/null
COMMIT14_INITIAL="$(raw_field_of rev14 review_commit_approve)"

# First-ever delivery set: leaves the commitment untouched (it was never
# PR-specific to begin with) and sets review_delivery_bound.
wm_state crew-set --id rev14 --delivery "https://github.com/acme/widgets/pull/701" >/dev/null
assert_eq "a first-ever --delivery does not regenerate the commitment" \
  "$(raw_field_of rev14 review_commit_approve)" "$COMMIT14_INITIAL"
assert_eq "...and sets review_delivery_bound" \
  "$(raw_field_of rev14 review_delivery_bound)" "https://github.com/acme/widgets/pull/701"

# A SECOND, different delivery regenerates both commitment fields, advances
# review_delivery_bound, and prints a review-token line.
regen_out="$(wm_state crew-set --id rev14 --delivery "https://github.com/acme/widgets/pull/702")"
assert_contains "a genuine delivery CHANGE prints a review-token line" \
  "$regen_out" "review-token: "
COMMIT14_AFTER="$(raw_field_of rev14 review_commit_approve)"
assert_true "...and the commitment actually changed" \
  "[ '$COMMIT14_INITIAL' != '$COMMIT14_AFTER' ]"
assert_eq "...and review_delivery_bound advanced to the new value" \
  "$(raw_field_of rev14 review_delivery_bound)" "https://github.com/acme/widgets/pull/702"

# A REPEATED delivery (same value already on record) is an idempotent no-op.
COMMIT14_BEFORE_REPEAT="$COMMIT14_AFTER"
wm_state crew-set --id rev14 --delivery "https://github.com/acme/widgets/pull/702" >/dev/null
assert_eq "re-setting the SAME delivery value does not regenerate the commitment" \
  "$(raw_field_of rev14 review_commit_approve)" "$COMMIT14_BEFORE_REPEAT"

# --- test 15: review_delivery_bound survives a clear (round 2 regression) --
TOKEN15="$(random_token)"
wm_state crew-add --id rev15 --type reviewer --repo /tmp \
  --window w15 --session-id s15 --review-token "$TOKEN15" >/dev/null
wm_state crew-set --id rev15 --delivery "https://github.com/acme/widgets/pull/801" >/dev/null
assert_eq "review_delivery_bound is set on the first delivery" \
  "$(raw_field_of rev15 review_delivery_bound)" "https://github.com/acme/widgets/pull/801"

wm_state crew-set --id rev15 --delivery "" >/dev/null
assert_eq "clearing --delivery empties the live delivery field" \
  "$(field_of rev15 delivery)" ""
assert_eq "...but review_delivery_bound is UNCHANGED by the clear (round 2 fix)" \
  "$(raw_field_of rev15 review_delivery_bound)" "https://github.com/acme/widgets/pull/801"

COMMIT15_BEFORE="$(raw_field_of rev15 review_commit_approve)"
wm_state crew-set --id rev15 --delivery "https://github.com/acme/widgets/pull/802" >/dev/null
assert_true "a delivery set AFTER a clear still regenerates against the pre-clear bound" \
  "[ '$COMMIT15_BEFORE' != '$(raw_field_of rev15 review_commit_approve)' ]"
assert_eq "...and review_delivery_bound advances to the new value" \
  "$(raw_field_of rev15 review_delivery_bound)" "https://github.com/acme/widgets/pull/802"

# --- test 16: --regenerate-review-token backfills review_delivery_bound for
# a legacy-first-commitment reviewer (round 3 regression). Pure state-engine
# here (round-4 should-fix 2) - the paired end-to-end assertion (a resumed
# reviewer's stale PR-X proof denied on PR-Y) lives in no-merge-guard.
# test.sh, which alone has the gh-fixture/run_hook machinery this file's own
# header comment scopes out.
wm_state crew-add --id rev16 --type reviewer --repo /tmp \
  --window w16 --session-id s16 >/dev/null
assert_eq "a legacy (no-token) reviewer has no commitment yet" \
  "$(raw_field_of rev16 review_commit_approve)" ""

wm_state crew-set --id rev16 --delivery "https://github.com/acme/widgets/pull/901" >/dev/null
assert_eq "...and setting --delivery while still uncommitted leaves it uncommitted" \
  "$(raw_field_of rev16 review_commit_approve)" ""
# The delivery-driven trigger is itself gated on an EXISTING commitment
# (review_commit_approve truthy) - an untokened record has nothing to
# invalidate yet, so review_delivery_bound stays untouched (None) here too.
# This is exactly the gap --regenerate-review-token's backfill exists to
# close, asserted next.
assert_eq "review_delivery_bound is NOT tracked yet for an uncommitted record" \
  "$(raw_field_of rev16 review_delivery_bound)" ""

# Simulate bin/crew-resume regenerating this pre-existing, already-delivery-
# set record's first-ever commitment.
TOKEN16="$(random_token)"
wm_state crew-set --id rev16 --regenerate-review-token "$TOKEN16" >/dev/null
assert_true "regenerate-review-token mints the first-ever commitment" \
  "[ -n '$(raw_field_of rev16 review_commit_approve)' ]"
assert_eq "...and BACKFILLS review_delivery_bound to the pre-existing delivery (round 3 fix)" \
  "$(raw_field_of rev16 review_delivery_bound)" "https://github.com/acme/widgets/pull/901"

# A following delivery CHANGE is now correctly read as a genuine change (not
# a first-ever assignment) and regenerates.
COMMIT16_BEFORE="$(raw_field_of rev16 review_commit_approve)"
wm_state crew-set --id rev16 --delivery "https://github.com/acme/widgets/pull/902" >/dev/null
assert_true "the next delivery CHANGE after a resume-backfill correctly regenerates" \
  "[ '$COMMIT16_BEFORE' != '$(raw_field_of rev16 review_commit_approve)' ]"

# --- test 17: a 3+-step clear/reset sequence (round 3 nice-to-have) --------
TOKEN17="$(random_token)"
wm_state crew-add --id rev17 --type reviewer --repo /tmp \
  --window w17 --session-id s17 --review-token "$TOKEN17" >/dev/null
wm_state crew-set --id rev17 --delivery "https://github.com/acme/widgets/pull/X" >/dev/null
COMMIT17_X="$(raw_field_of rev17 review_commit_approve)"

wm_state crew-set --id rev17 --delivery "" >/dev/null
wm_state crew-set --id rev17 --delivery "" >/dev/null
assert_eq "a repeated clear is a no-op on review_delivery_bound" \
  "$(raw_field_of rev17 review_delivery_bound)" "https://github.com/acme/widgets/pull/X"

# Re-setting the SAME value as the still-tracked bound is an idempotent
# no-op, even after intervening clears.
wm_state crew-set --id rev17 --delivery "https://github.com/acme/widgets/pull/X" >/dev/null
assert_eq "re-asserting the same bound value (after clears) does not regenerate" \
  "$(raw_field_of rev17 review_commit_approve)" "$COMMIT17_X"

wm_state crew-set --id rev17 --delivery "" >/dev/null
wm_state crew-set --id rev17 --delivery "https://github.com/acme/widgets/pull/Y" >/dev/null
assert_true "a genuinely different delivery, several steps later, still regenerates" \
  "[ '$COMMIT17_X' != '$(raw_field_of rev17 review_commit_approve)' ]"
assert_eq "...and review_delivery_bound reaches the final value" \
  "$(raw_field_of rev17 review_delivery_bound)" "https://github.com/acme/widgets/pull/Y"

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# issue #138: review-sign --commit derives and persists a per-commit
# commitment (review_commit_approve_sha) onto the calling session's own
# roster record, and _apply_review_token resets it whenever
# review_commit_approve itself is regenerated. hooks/no-merge-guard.sh's own
# test file covers the hook's actual staleness enforcement - this file only
# covers that the fields land correctly, mirroring how it already scopes the
# rest of the issue #135 fields above.
# ============================================================================

# --- test 18: review-sign --commit derives and persists a fresh, commit-bound
# commitment onto the calling session's OWN roster record.
TOKEN18="$(random_token)"
wm_state crew-add --id rev18 --type reviewer --repo /tmp \
  --window w18 --session-id s18 --review-token "$TOKEN18" >/dev/null
COMMIT18_INITIAL="$(raw_field_of rev18 review_commit_approve)"
assert_eq "a fresh reviewer record has no commit-bound sha yet" \
  "$(raw_field_of rev18 review_commit_approve_sha)" ""
SHA18_A="deadbeef00000000000000000000000000000001"

PREIMAGE18_A="$(WM_REVIEW_TOKEN="$TOKEN18" WINGMAN_CREW_ID=rev18 wm_state review-sign --verdict approve --commit "$SHA18_A")"
assert_true "review-sign --commit changes review_commit_approve from its crew-add-time value" \
  "[ '$COMMIT18_INITIAL' != '$(raw_field_of rev18 review_commit_approve)' ]"
assert_eq "...and review_commit_approve_sha now equals the signed commit" \
  "$(raw_field_of rev18 review_commit_approve_sha)" "$SHA18_A"
COMMIT18_AFTER_A="$(raw_field_of rev18 review_commit_approve)"

# --- test 19: a second review-sign --commit <different-sha> overwrites both
# fields again; a preimage derived against the FIRST commit no longer
# round-trips to the current commitment.
SHA18_B="deadbeef00000000000000000000000000000002"
WM_REVIEW_TOKEN="$TOKEN18" WINGMAN_CREW_ID=rev18 wm_state review-sign --verdict approve --commit "$SHA18_B" >/dev/null
COMMIT18_AFTER_B="$(raw_field_of rev18 review_commit_approve)"
assert_true "a second review-sign --commit <different-sha> changes the commitment again" \
  "[ '$COMMIT18_AFTER_A' != '$COMMIT18_AFTER_B' ]"
assert_eq "...and review_commit_approve_sha advances to the new value" \
  "$(raw_field_of rev18 review_commit_approve_sha)" "$SHA18_B"
assert_true "a preimage derived against the FIRST commit no longer round-trips to the current commitment" \
  "[ '$(sha256_hex "$PREIMAGE18_A")' != '$COMMIT18_AFTER_B' ]"

# --- test 20: review-sign --verdict "request changes" --commit <sha> is a
# no-op on review_commit_approve/review_commit_approve_sha - --commit only
# takes effect for approve.
COMMIT18_BEFORE_RC="$(raw_field_of rev18 review_commit_approve)"
SHA18_BEFORE_RC="$(raw_field_of rev18 review_commit_approve_sha)"
RC_COMMIT_BEFORE="$(raw_field_of rev18 review_commit_request_changes)"
PREIMAGE_RC="$(WM_REVIEW_TOKEN="$TOKEN18" WINGMAN_CREW_ID=rev18 wm_state review-sign --verdict "request changes" --commit "deadbeef00000000000000000000000000000003")"
assert_eq "review-sign request-changes --commit does not touch review_commit_approve" \
  "$(raw_field_of rev18 review_commit_approve)" "$COMMIT18_BEFORE_RC"
assert_eq "...or review_commit_approve_sha" \
  "$(raw_field_of rev18 review_commit_approve_sha)" "$SHA18_BEFORE_RC"
assert_eq "...and review_commit_request_changes is unchanged too (no roster write at all)" \
  "$(raw_field_of rev18 review_commit_request_changes)" "$RC_COMMIT_BEFORE"
assert_eq "the printed preimage matches the pre-#138 request-changes preimage exactly" \
  "$(sha256_hex "$PREIMAGE_RC")" "$RC_COMMIT_BEFORE"

# --- test 21: review-sign with no --commit reproduces exactly today's #135
# behavior - no roster write at all, preimage round-trips against whatever
# commitment was already on file. Uses a FRESH record that has never been
# commit-bound (rev18 no longer qualifies after tests 18-19 rebound its
# review_commit_approve to a commit-bound value) so the pre-#138,
# non-commit-bound preimage is the thing actually on file to round-trip
# against.
TOKEN21="$(random_token)"
wm_state crew-add --id rev21 --type reviewer --repo /tmp \
  --window w21 --session-id s21 --review-token "$TOKEN21" >/dev/null
COMMIT21_BEFORE="$(raw_field_of rev21 review_commit_approve)"
SHA21_BEFORE="$(raw_field_of rev21 review_commit_approve_sha)"
PREIMAGE21="$(WM_REVIEW_TOKEN="$TOKEN21" WINGMAN_CREW_ID=rev21 wm_state review-sign --verdict approve)"
assert_eq "review-sign with no --commit does not change review_commit_approve" \
  "$(raw_field_of rev21 review_commit_approve)" "$COMMIT21_BEFORE"
assert_eq "...or review_commit_approve_sha" \
  "$(raw_field_of rev21 review_commit_approve_sha)" "$SHA21_BEFORE"
assert_eq "...and its preimage round-trips against whatever commitment was already on file" \
  "$(sha256_hex "$PREIMAGE21")" "$COMMIT21_BEFORE"

# --- test 22: _apply_review_token resets review_commit_approve_sha to None -
# both a delivery-change regeneration and an explicit
# --regenerate-review-token must clear a stale commit-bound sha, not just a
# stale commitment.
TOKEN22="$(random_token)"
wm_state crew-add --id rev22 --type reviewer --repo /tmp \
  --window w22 --session-id s22 --review-token "$TOKEN22" >/dev/null
wm_state crew-set --id rev22 --delivery "https://github.com/acme/widgets/pull/950" >/dev/null
SHA22="deadbeef00000000000000000000000000000009"
WM_REVIEW_TOKEN="$TOKEN22" WINGMAN_CREW_ID=rev22 wm_state review-sign --verdict approve --commit "$SHA22" >/dev/null
assert_eq "rev22 is commit-bound before the delivery-change regeneration" \
  "$(raw_field_of rev22 review_commit_approve_sha)" "$SHA22"

wm_state crew-set --id rev22 --delivery "https://github.com/acme/widgets/pull/951" >/dev/null
assert_eq "a delivery-change regeneration resets review_commit_approve_sha to None" \
  "$(raw_field_of rev22 review_commit_approve_sha)" ""

# Re-bind, then verify --regenerate-review-token resets it too.
SHA22B="deadbeef0000000000000000000000000000000a"
WM_REVIEW_TOKEN="$TOKEN22" WINGMAN_CREW_ID=rev22 wm_state review-sign --verdict approve --commit "$SHA22B" >/dev/null
assert_eq "rev22 is commit-bound again before the resume regeneration" \
  "$(raw_field_of rev22 review_commit_approve_sha)" "$SHA22B"
wm_state crew-set --id rev22 --regenerate-review-token "$(random_token)" >/dev/null
assert_eq "--regenerate-review-token also resets review_commit_approve_sha to None" \
  "$(raw_field_of rev22 review_commit_approve_sha)" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

test_summary
