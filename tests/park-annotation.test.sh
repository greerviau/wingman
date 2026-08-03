#!/usr/bin/env bash
# E2E: per-issue blocking vs whole-effort blocking (issue #203) - the `parked`
# roster field and its crew-set/crew-list plumbing, per
# docs/plans/2026-08-03-issue-203-per-issue-blocking-plan.md.
#
# A lead owning several independent units of work needs a way to record "this
# one unit needs a decision" without flipping its own `status` to `blocked`
# (which would stop it from dispatching everything else it can still
# progress). This covers: the --park/--unpark/--parked-clear mechanism itself
# (cases 1-10); the auto-composed `blocker` text a --status blocked
# transition derives from (lead-in, current parked list), and its
# idempotency/self-clearing guarantees (cases 11-16, following plan review
# findings B1/B4); and display/filtering across crew-list --parked,
# render_roster_text/render_tree_text/render_board, and crew-get --json
# (cases 17-20, including the stood-down exclusion from finding B3).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

raw_field_of() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
v = json.load(sys.stdin).get(sys.argv[1])
print("" if v is None else v)
' "$2"
}

# Sorted, comma-joined list of currently-parked refs for $1 - order-independent
# so a test never depends on dict/list insertion order.
parked_refs() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
v = json.load(sys.stdin).get("parked") or []
print(",".join(sorted(p.get("ref", "") for p in v)))
'
}

# The note recorded against ref $2 on record $1 ("" if that ref is not parked).
parked_note() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
v = json.load(sys.stdin).get("parked") or []
for p in v:
    if p.get("ref") == sys.argv[1]:
        print(p.get("note") or "")
        break
else:
    print("")
' "$2"
}

# The `since` stamp recorded against ref $2 on record $1 ("" if not parked).
parked_since() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python -c '
import sys, json
v = json.load(sys.stdin).get("parked") or []
for p in v:
    if p.get("ref") == sys.argv[1]:
        print(p.get("since") or "")
        break
else:
    print("")
' "$2"
}

# ============================================================================
# 1-8: the --park/--unpark/--parked-clear mechanism itself.
# ============================================================================
test_new_home

# --- case 1: --park adds an entry --------------------------------------
wm_state crew-add --id lead1 --type lead --repo /tmp --window w1 --session-id s1 >/dev/null
wm_state crew-set --id lead1 --park "303:need product call" >/dev/null
assert_eq "case1: --park adds an entry for the given ref" \
  "$(parked_refs lead1)" "303"
assert_eq "case1: ...with the note recorded verbatim" \
  "$(parked_note lead1 303)" "need product call"
assert_true "case1: ...and a non-null since stamp" \
  "[ -n '$(parked_since lead1 303)' ]"

# --- case 2: re-parking the same ref updates the note but preserves since --
SINCE1="$(parked_since lead1 303)"
wm_state crew-set --id lead1 --park "303:updated question text" >/dev/null
assert_eq "case2: re-parking the same ref updates the note" \
  "$(parked_note lead1 303)" "updated question text"
assert_eq "case2: ...but preserves the original since stamp" \
  "$(parked_since lead1 303)" "$SINCE1"

# --- case 3: --park is repeatable in one call ---------------------------
wm_state crew-add --id lead2 --type lead --repo /tmp --window w2 --session-id s2 >/dev/null
wm_state crew-set --id lead2 --park "303:a" --park "320:b" >/dev/null
assert_eq "case3: two --park flags in one call produce both entries" \
  "$(parked_refs lead2)" "303,320"

# --- case 4: --unpark removes by ref, leaving other entries untouched --
wm_state crew-set --id lead2 --unpark "303" >/dev/null
assert_eq "case4: --unpark removes only the named ref" \
  "$(parked_refs lead2)" "320"
assert_eq "case4: ...leaving the other entry's note untouched" \
  "$(parked_note lead2 320)" "b"

# --- case 5: --parked-clear empties the list ----------------------------
wm_state crew-set --id lead2 --parked-clear >/dev/null
assert_eq "case5: --parked-clear empties the parked list" \
  "$(parked_refs lead2)" ""

# --- case 6: parking never touches status -------------------------------
wm_state crew-add --id lead3 --type lead --repo /tmp --window w3 --session-id s3 >/dev/null
wm_state crew-set --id lead3 --status working --summary "triaging the backlog" >/dev/null
wm_state crew-set --id lead3 --park "303:need product call" >/dev/null
assert_eq "case6: --park with no --status leaves status untouched" \
  "$(raw_field_of lead3 status)" "working"

# --- case 7: --park without a colon fails loudly ------------------------
if err="$(wm_state crew-set --id lead3 --park "nocolonhere" 2>&1 >/dev/null)"; then
  assert_true "case7: --park without a colon must fail, not silently mis-parse" "false"
else
  assert_contains "case7: the failure names the expected 'ref:note' format" \
    "$err" "ref:note"
fi

# --- case 8: --park "ref:" (empty note) fails loudly --------------------
if err="$(wm_state crew-set --id lead3 --park "303:" 2>&1 >/dev/null)"; then
  assert_true "case8: --park with an empty note must fail" "false"
else
  assert_contains "case8: the failure names the empty note" \
    "$err" "empty note"
fi

# ============================================================================
# 9-10: crew-list --parked filtering, including --owner scoping through the
# real bin/crew-list wrapper (round-1 review finding N6).
# ============================================================================
test_new_home

# --- case 9: --parked filters to records with nonempty parked, including a
# working-status record, and excludes a working record with none ----------
wm_state crew-add --id lead4 --type lead --repo /tmp --window w4 --session-id s4 >/dev/null
wm_state crew-set --id lead4 --status working --summary "nothing parked" >/dev/null
wm_state crew-add --id lead5 --type lead --repo /tmp --window w5 --session-id s5 >/dev/null
wm_state crew-set --id lead5 --status working --summary "one item parked" >/dev/null
wm_state crew-set --id lead5 --park "410:needs a call" >/dev/null

parked_list="$(wm_state crew-list --parked)"
assert_contains "case9: crew-list --parked includes a working record with a parked item" \
  "$parked_list" "lead5"
assert_not_contains "case9: crew-list --parked excludes a working record with none" \
  "$parked_list" "lead4"

# --- case 10: --parked combined with --owner scopes end to end, via the
# real bin/crew-list wrapper script (exercises its arg-loop passthrough) --
wm_state crew-add --id teamA-lead --type lead --repo /tmp --window wA --session-id sA --parent teamA >/dev/null
wm_state crew-add --id teamB-lead --type lead --repo /tmp --window wB --session-id sB --parent teamB >/dev/null
wm_state crew-set --id teamA-lead --status working --summary "a" >/dev/null
wm_state crew-set --id teamB-lead --status working --summary "b" >/dev/null
wm_state crew-set --id teamA-lead --park "500:teamA question" >/dev/null
wm_state crew-set --id teamB-lead --park "600:teamB question" >/dev/null

owner_scoped="$("$TEST_REPO/bin/crew-list" --owner teamA --parked)"
assert_contains "case10: bin/crew-list --owner teamA --parked includes teamA's record" \
  "$owner_scoped" "teamA-lead"
assert_not_contains "case10: ...and excludes teamB's record" \
  "$owner_scoped" "teamB-lead"

# ============================================================================
# 11-16: the auto-composed `blocker` idempotency/self-clearing guarantee
# (plan review findings B1, B4).
# ============================================================================
test_new_home

# --- case 11: two consecutive crew-set calls while already blocked, no new
# --park/--blocker, leave blocker byte-identical (the documented anti-stall
# --summary-only refresh must not grow the composed text) ------------------
wm_state crew-add --id lead11 --type lead --repo /tmp --window w11 --session-id s11 >/dev/null
wm_state crew-set --id lead11 --status working --summary "triaging" >/dev/null
wm_state crew-set --id lead11 --park "303:need product call" --park "320:need spawn approval" >/dev/null
wm_state crew-set --id lead11 --status blocked --blocker "2 decisions blocking further progress:" >/dev/null
BLOCKER11_BEFORE="$(raw_field_of lead11 blocker)"
wm_state crew-set --id lead11 --summary "still here" >/dev/null
assert_eq "case11: a bare --summary refresh while blocked leaves blocker byte-identical" \
  "$(raw_field_of lead11 blocker)" "$BLOCKER11_BEFORE"

# --- case 12: unparking every item and returning to working leaves no
# composed residue on blocker -----------------------------------------------
wm_state crew-set --id lead11 --unpark "303" --unpark "320" --status working >/dev/null
assert_eq "case12: unparking everything and returning to working clears blocker" \
  "$(raw_field_of lead11 blocker)" ""

# --- case 13: a later, unrelated escalation's blocker contains only the
# currently-parked items - no leakage from the earlier, resolved episode ---
wm_state crew-set --id lead11 --park "410:unrelated new question" >/dev/null
wm_state crew-set --id lead11 --status blocked >/dev/null
BLOCKER13="$(raw_field_of lead11 blocker)"
assert_contains "case13: the new escalation mentions the current ref" "$BLOCKER13" "410"
assert_not_contains "case13: ...and does not leak the earlier, resolved ref 303" \
  "$BLOCKER13" "303"
assert_not_contains "case13: ...or 320" "$BLOCKER13" "320"

# --- case 14: cmd_needs_attention's emitted note matches blocker exactly
# for the scenario in case 13 - this is the string the requester actually
# reads, so the assertion belongs on that path too -------------------------
NOTE14="$(wm_state needs-attention --owner "" | awk -F'\t' '$1=="lead11"{print $4}')"
assert_eq "case14: needs-attention's note matches blocker exactly" "$NOTE14" "$BLOCKER13"

# --- case 15: an empty parked list leaves blocker exactly as passed (no
# 'parked: ' suffix ever appears with nothing parked), and an explicit
# --blocker lead-in is prefixed, not replaced, when parked items exist -----
wm_state crew-add --id lead15a --type lead --repo /tmp --window w15a --session-id s15a >/dev/null
wm_state crew-set --id lead15a --status blocked --blocker "genuinely nothing left to dispatch" >/dev/null
assert_eq "case15a: blocker with no parked items is passed through verbatim" \
  "$(raw_field_of lead15a blocker)" "genuinely nothing left to dispatch"
assert_not_contains "case15a: ...with no 'parked:' suffix appended" \
  "$(raw_field_of lead15a blocker)" "parked:"

wm_state crew-add --id lead15b --type lead --repo /tmp --window w15b --session-id s15b >/dev/null
wm_state crew-set --id lead15b --park "700:need approval" >/dev/null
wm_state crew-set --id lead15b --status blocked --blocker "3 decisions blocking:" >/dev/null
assert_eq "case15b: an explicit lead-in is prefixed to the composed parked list" \
  "$(raw_field_of lead15b blocker)" "3 decisions blocking: | parked: [700] need approval"

# --- case 16: an explicit, fresh --blocker survives a call that also leaves
# blocked, on a record whose current blocker was composed (round-2 review,
# finding B4 - the clearing branch's original, unconditional form nulled
# this) - plus the companion case: a record that never parks keeps its
# explicit blocker through a full blocked -> refresh -> working cycle -----
wm_state crew-set --id lead11 --status working --blocker "a fresh explicit note" --summary "moving on" >/dev/null
assert_eq "case16a: a fresh explicit --blocker survives a call that also leaves blocked" \
  "$(raw_field_of lead11 blocker)" "a fresh explicit note"

wm_state crew-add --id dev16b --type developer --repo /tmp --window w16b --session-id s16b >/dev/null
wm_state crew-set --id dev16b --status blocked --blocker "need a decision" >/dev/null
wm_state crew-set --id dev16b --summary "still waiting" >/dev/null
assert_eq "case16b: an unrelated summary refresh leaves an explicit blocker untouched" \
  "$(raw_field_of dev16b blocker)" "need a decision"
wm_state crew-set --id dev16b --status working --summary "unblocked, moving on" >/dev/null
assert_eq "case16b: a record that never parks keeps its explicit blocker across the full blocked -> working cycle" \
  "$(raw_field_of dev16b blocker)" "need a decision"

# ============================================================================
# 17-20: display and filtering.
# ============================================================================
test_new_home

# --- case 17: render_roster_text/render_tree_text/render_board include a
# parked[...] line/cell for a record with parked items, and omit it entirely
# for one without (the same record, before vs after) -----------------------
wm_state crew-add --id pk17 --type lead --repo /tmp --window w17 --session-id s17 >/dev/null
wm_state crew-set --id pk17 --status working --summary "not parked yet" >/dev/null
roster_no_park="$(wm_state crew-list)"
assert_not_contains "case17: no parked[ line for a record with nothing parked" \
  "$roster_no_park" "parked["

wm_state crew-set --id pk17 --park "900:needs an answer" >/dev/null
roster_with_park="$(wm_state crew-list)"
assert_contains "case17: render_roster_text includes a parked[...] line once parked" \
  "$roster_with_park" "parked[900]: needs an answer"

tree_with_park="$(wm_state crew-list --tree)"
assert_contains "case17: render_tree_text includes a parked[...] line too" \
  "$tree_with_park" "parked[900]: needs an answer"

board_with_park="$(wm_state render-board)"
assert_contains "case17: render_board includes a parked cell" \
  "$board_with_park" "[900] needs an answer"

# --- case 18: merged()/crew-get --json surfaces parked as a present, empty
# list ([]) - never an absent key - after --parked-clear, and as a present,
# populated list after --park (round-1 review, N7) -------------------------
wm_state crew-add --id pk18 --type lead --repo /tmp --window w18 --session-id s18 >/dev/null
wm_state crew-set --id pk18 --parked-clear >/dev/null
parked18_empty="$(wm_state crew-get --id pk18 | uv run --no-project --quiet python -c '
import sys, json
d = json.load(sys.stdin)
print("present" if "parked" in d else "absent", json.dumps(d.get("parked")))
')"
assert_eq "case18: parked-clear leaves parked present and an empty list" \
  "$parked18_empty" "present []"

wm_state crew-set --id pk18 --park "111:some note" >/dev/null
parked18_populated="$(wm_state crew-get --id pk18 | uv run --no-project --quiet python -c '
import sys, json
d = json.load(sys.stdin)
v = d.get("parked")
print("present" if "parked" in d else "absent", len(v) if isinstance(v, list) else -1)
')"
assert_eq "case18: after --park, parked is present and populated" \
  "$parked18_populated" "present 1"

# --- case 19: blocker_note/blocker_composed never appear in crew-get's JSON
# output for a record that has gone through composition --------------------
wm_state crew-add --id pk19 --type lead --repo /tmp --window w19 --session-id s19 >/dev/null
wm_state crew-set --id pk19 --park "222:need approval" >/dev/null
wm_state crew-set --id pk19 --status blocked --blocker "lead-in text" >/dev/null
RAW19="$(wm_state crew-get --id pk19)"
assert_not_contains "case19: blocker_note never appears in crew-get's JSON" \
  "$RAW19" "blocker_note"
assert_not_contains "case19: blocker_composed never appears in crew-get's JSON" \
  "$RAW19" "blocker_composed"

# --- case 20: crew-list --parked excludes a stood-down record that still
# carries a nonempty parked list (round-1 review, finding B3) --------------
wm_state crew-add --id pk20 --type lead --repo /tmp --window w20 --session-id s20 >/dev/null
wm_state crew-set --id pk20 --status working --summary "about to stand down" >/dev/null
wm_state crew-set --id pk20 --park "333:pending call" >/dev/null
wm_state standdown --id pk20 >/dev/null
assert_eq "case20: standdown leaves status stood-down without touching parked" \
  "$(raw_field_of pk20 status)" "stood-down"
assert_eq "case20: ...and parked itself survives the standdown verbatim" \
  "$(parked_refs pk20)" "333"
parked_after_standdown="$(wm_state crew-list --parked)"
assert_not_contains "case20: crew-list --parked excludes the stood-down record anyway" \
  "$parked_after_standdown" "pk20"

test_summary
