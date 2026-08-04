#!/usr/bin/env bash
# E2E: bin/lib/merge-block-diagnose.sh's classification of a blocked/failed
# PR merge into wingman-gate / forge-gate / self-fix / both-gates / clear /
# unknown (issue #190). Drives the SHELL ENTRY POINT (not the .py directly),
# so the wm_py wrapper is covered too, with every dimension supplied via a
# fixture-injection flag so no `gh` call is ever made. Follows
# tests/pr-eval.test.sh's canned-JSON pattern.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

DIAG="$TEST_REPO/bin/lib/merge-block-diagnose.sh"
D="$(wm_mktemp_dir)"

# diag <args...> - runs the diagnostic, capturing combined stdout+stderr in
# $OUT and the exit code in $RC.
diag() {
  OUT="$("$DIAG" "$@" 2>&1)"
  RC=$?
}

write() { printf '%s' "$2" > "$1"; }

# --- case 1: CLEAN + allow_merge=true + a current APPROVED review from ------
# --- another login -> verdict: clear, exit 0 --------------------------------
write "$D/pr1.json" '{"number":1,"url":"https://github.com/o/r/pull/1","state":"OPEN","author":{"login":"me"},"baseRefName":"main","headRefOid":"sha1","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","author":{"login":"rev"},"commit":{"oid":"sha1"}}],"statusCheckRollup":[]}'
write "$D/rules-empty.json" '[]'
write "$D/crew1.json" '[{"id":"dev-1","delivery":"https://github.com/o/r/pull/1","allow_merge":true,"review_gate_waived":false}]'
diag --pr-json "$D/pr1.json" --rules-json "$D/rules-empty.json" --crew-record "$D/crew1.json" --me me
assert_contains "case 1: a current distinct-account approval with allow_merge clears both gates" "$OUT" "verdict: clear"
assert_eq "case 1: exit 0" "$RC" "0"

# --- case 2: CLEAN + allow_merge=false -> verdict: wingman-gate, exit 1, ----
# --- no forge: objection line ------------------------------------------------
write "$D/pr2.json" '{"number":2,"url":"https://github.com/o/r/pull/2","state":"OPEN","author":{"login":"me"},"baseRefName":"main","headRefOid":"sha2","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"REVIEW_REQUIRED","reviews":[],"statusCheckRollup":[]}'
write "$D/crew2.json" '[{"id":"dev-2","delivery":"https://github.com/o/r/pull/2","allow_merge":false,"review_gate_waived":false}]'
diag --pr-json "$D/pr2.json" --rules-json "$D/rules-empty.json" --crew-record "$D/crew2.json" --me me
assert_contains "case 2: no allow_merge fires wingman-gate" "$OUT" "verdict: wingman-gate"
assert_eq "case 2: exit 1" "$RC" "1"
assert_not_contains "case 2: a CLEAN PR carries no forge: objection line" "$OUT" "forge:"

# --- case 3 (the regression test for this issue): BLOCKED + required review -
# --- + allow_merge=true + review_gate_waived=true -> verdict: forge-gate, ---
# --- exit 1 - the waiver is granted and the verdict is STILL blocked, on the-
# --- forge line only ---------------------------------------------------------
write "$D/pr3.json" '{"number":3,"url":"https://github.com/o/r/pull/3","state":"OPEN","author":{"login":"someone-else"},"baseRefName":"main","headRefOid":"sha3","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"REVIEW_REQUIRED","reviews":[],"statusCheckRollup":[]}'
write "$D/rules-review1.json" '[{"type":"pull_request","parameters":{"required_approving_review_count":1,"allowed_merge_methods":["squash"]},"ruleset_id":9,"ruleset_source_type":"Repository"}]'
write "$D/crew3.json" '[{"id":"dev-3","delivery":"https://github.com/o/r/pull/3","allow_merge":true,"review_gate_waived":true}]'
diag --pr-json "$D/pr3.json" --rules-json "$D/rules-review1.json" --crew-record "$D/crew3.json" --me me
assert_contains "case 3: waiver granted but a forge rule still objects -> forge-gate" "$OUT" "verdict: forge-gate"
assert_eq "case 3: exit 1" "$RC" "1"
assert_not_contains "case 3: no wingman: line once the waiver clears that side" "$OUT" "wingman:"
assert_contains "case 3: the forge objection is required-review" "$OUT" "forge: required-review"

# --- case 4: case 3 with the PR author == --me and no APPROVED review ------
# --- -> the UNMEETABLE line is present --------------------------------------
write "$D/pr4.json" '{"number":4,"url":"https://github.com/o/r/pull/4","state":"OPEN","author":{"login":"me"},"baseRefName":"main","headRefOid":"sha4","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"REVIEW_REQUIRED","reviews":[],"statusCheckRollup":[]}'
write "$D/crew4.json" '[{"id":"dev-4","delivery":"https://github.com/o/r/pull/4","allow_merge":true,"review_gate_waived":true}]'
diag --pr-json "$D/pr4.json" --rules-json "$D/rules-review1.json" --crew-record "$D/crew4.json" --me me
assert_contains "case 4: PR author is the authenticated account -> UNMEETABLE" "$OUT" "UNMEETABLE"

# --- case 5: case 4 with a different PR author -> the UNMEETABLE line is ---
# --- absent (the determination is not fired by reviewDecision alone) -------
write "$D/pr5.json" '{"number":5,"url":"https://github.com/o/r/pull/5","state":"OPEN","author":{"login":"somebody-else"},"baseRefName":"main","headRefOid":"sha5","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"REVIEW_REQUIRED","reviews":[],"statusCheckRollup":[]}'
write "$D/crew5.json" '[{"id":"dev-5","delivery":"https://github.com/o/r/pull/5","allow_merge":true,"review_gate_waived":true}]'
diag --pr-json "$D/pr5.json" --rules-json "$D/rules-review1.json" --crew-record "$D/crew5.json" --me me
assert_not_contains "case 5: a different PR author -> no UNMEETABLE" "$OUT" "UNMEETABLE"

# --- case 6: BLOCKED + required review + allow_merge=false -> both-gates ----
# --- with both a forge: and a wingman: line ---------------------------------
write "$D/pr6.json" '{"number":6,"url":"https://github.com/o/r/pull/6","state":"OPEN","author":{"login":"someone-else"},"baseRefName":"main","headRefOid":"sha6","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"REVIEW_REQUIRED","reviews":[],"statusCheckRollup":[]}'
write "$D/crew6.json" '[{"id":"dev-6","delivery":"https://github.com/o/r/pull/6","allow_merge":false,"review_gate_waived":false}]'
diag --pr-json "$D/pr6.json" --rules-json "$D/rules-review1.json" --crew-record "$D/crew6.json" --me me
assert_contains "case 6: both gates object -> both-gates" "$OUT" "verdict: both-gates"
assert_contains "case 6: forge: line present" "$OUT" "forge: required-review"
assert_contains "case 6: wingman: line present" "$OUT" "wingman: no-allow-merge"

# --- case 7: bypass reporting never moves the verdict (M4) ------------------
write "$D/rulesets-always.json" '{"9":{"name":"main","current_user_can_bypass":"always"}}'
diag --pr-json "$D/pr3.json" --rules-json "$D/rules-review1.json" --crew-record "$D/crew3.json" --me me --rulesets-json "$D/rulesets-always.json"
assert_contains "case 7a: current_user_can_bypass=always -> bypass: AVAILABLE" "$OUT" 'bypass: AVAILABLE - current_user_can_bypass=always on ruleset "main"'
assert_contains "case 7a: verdict unmoved by bypass availability" "$OUT" "verdict: forge-gate"

write "$D/rulesets-never.json" '{"9":{"name":"main","current_user_can_bypass":"never"}}'
diag --pr-json "$D/pr3.json" --rules-json "$D/rules-review1.json" --crew-record "$D/crew3.json" --me me --rulesets-json "$D/rulesets-never.json"
assert_not_contains "case 7b: current_user_can_bypass=never -> not AVAILABLE" "$OUT" "AVAILABLE"
assert_contains "case 7b: verdict still forge-gate" "$OUT" "verdict: forge-gate"

write "$D/rulesets-empty.json" '{}'
diag --pr-json "$D/pr3.json" --rules-json "$D/rules-review1.json" --crew-record "$D/crew3.json" --me me --rulesets-json "$D/rulesets-empty.json"
assert_contains "case 7c: ruleset detail absent -> bypass: unknown" "$OUT" "bypass: unknown - could not read ruleset 9"
assert_contains "case 7c: verdict still forge-gate, never unknown, on a missing bypass line" "$OUT" "verdict: forge-gate"

# --- case 8: merge-method suggestion, asserted positively in both -----------
# --- directions, plus absent-key behavior (N4) ------------------------------
write "$D/rules-squash.json" '[{"type":"pull_request","parameters":{"required_approving_review_count":1,"allowed_merge_methods":["squash"]},"ruleset_id":9,"ruleset_source_type":"Repository"}]'
diag --pr-json "$D/pr3.json" --rules-json "$D/rules-squash.json" --crew-record "$D/crew3.json" --me me
assert_contains "case 8a: allowed_merge_methods:[squash] -> suggestion contains --squash" "$OUT" "gh pr merge --squash --admin"

write "$D/rules-merge-rebase.json" '[{"type":"pull_request","parameters":{"required_approving_review_count":1,"allowed_merge_methods":["merge","rebase"]},"ruleset_id":9,"ruleset_source_type":"Repository"}]'
diag --pr-json "$D/pr3.json" --rules-json "$D/rules-merge-rebase.json" --crew-record "$D/crew3.json" --me me
assert_contains "case 8b: allowed_merge_methods:[merge,rebase] -> suggestion contains --merge" "$OUT" "gh pr merge --merge --admin"
assert_not_contains "case 8b: --squash is never suggested when it is not allowed" "$OUT" "--squash"

write "$D/rules-no-methods.json" '[{"type":"pull_request","parameters":{"required_approving_review_count":1},"ruleset_id":9,"ruleset_source_type":"Repository"}]'
diag --pr-json "$D/pr3.json" --rules-json "$D/rules-no-methods.json" --crew-record "$D/crew3.json" --me me
assert_contains "case 8c: allowed_merge_methods key absent (all methods permitted) -> a suggestion is still produced" "$OUT" "gh pr merge --squash --admin"

# --- case 9: self-fixable classification (M3) - asserts the VERDICT, not ---
# --- just the objection string ----------------------------------------------
write "$D/pr-dirty.json" '{"number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","author":{"login":"me"},"baseRefName":"main","headRefOid":"sha7","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","reviewDecision":"REVIEW_REQUIRED","reviews":[],"statusCheckRollup":[]}'
write "$D/crew7.json" '[{"id":"dev-7","delivery":"https://github.com/o/r/pull/7","allow_merge":true,"review_gate_waived":true}]'
diag --pr-json "$D/pr-dirty.json" --rules-json "$D/rules-empty.json" --crew-record "$D/crew7.json" --me me
assert_contains "case 9a: DIRTY -> verdict: self-fix" "$OUT" "verdict: self-fix"
assert_contains "case 9a: DIRTY -> objection conflict" "$OUT" "forge: conflict"

write "$D/pr-behind.json" '{"number":8,"url":"https://github.com/o/r/pull/8","state":"OPEN","author":{"login":"me"},"baseRefName":"main","headRefOid":"sha8","mergeable":"MERGEABLE","mergeStateStatus":"BEHIND","reviewDecision":"REVIEW_REQUIRED","reviews":[],"statusCheckRollup":[]}'
write "$D/crew8.json" '[{"id":"dev-8","delivery":"https://github.com/o/r/pull/8","allow_merge":true,"review_gate_waived":true}]'
diag --pr-json "$D/pr-behind.json" --rules-json "$D/rules-empty.json" --crew-record "$D/crew8.json" --me me
assert_contains "case 9b: BEHIND -> verdict: self-fix" "$OUT" "verdict: self-fix"
assert_contains "case 9b: BEHIND -> objection behind" "$OUT" "forge: behind"

write "$D/pr-draft.json" '{"number":9,"url":"https://github.com/o/r/pull/9","state":"OPEN","author":{"login":"me"},"baseRefName":"main","headRefOid":"sha9","mergeable":"MERGEABLE","mergeStateStatus":"DRAFT","reviewDecision":"REVIEW_REQUIRED","reviews":[],"statusCheckRollup":[]}'
write "$D/crew9.json" '[{"id":"dev-9","delivery":"https://github.com/o/r/pull/9","allow_merge":true,"review_gate_waived":true}]'
diag --pr-json "$D/pr-draft.json" --rules-json "$D/rules-empty.json" --crew-record "$D/crew9.json" --me me
assert_contains "case 9c: DRAFT -> verdict: self-fix" "$OUT" "verdict: self-fix"
assert_contains "case 9c: DRAFT -> objection draft" "$OUT" "forge: draft"

# --- case 10: mergeStateStatus UNKNOWN -> verdict: unknown, exit 2 ---------
# --- (PR state is verdict-bearing) ------------------------------------------
write "$D/pr-unknown.json" '{"number":10,"url":"https://github.com/o/r/pull/10","state":"OPEN","author":{"login":"me"},"baseRefName":"main","headRefOid":"sha10","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","reviewDecision":"REVIEW_REQUIRED","reviews":[],"statusCheckRollup":[]}'
write "$D/crew10.json" '[{"id":"dev-10","delivery":"https://github.com/o/r/pull/10","allow_merge":true,"review_gate_waived":true}]'
diag --pr-json "$D/pr-unknown.json" --rules-json "$D/rules-empty.json" --crew-record "$D/crew10.json" --me me
assert_contains "case 10: mergeStateStatus UNKNOWN -> verdict: unknown" "$OUT" "verdict: unknown"
assert_eq "case 10: exit 2" "$RC" "2"

# --- case 11: required_status_checks naming a failing context, AND a -------
# --- required context absent from statusCheckRollup entirely (N2) ----------
write "$D/pr-checks-failing.json" '{"number":11,"url":"https://github.com/o/r/pull/11","state":"OPEN","author":{"login":"someone-else"},"baseRefName":"main","headRefOid":"sha11","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","author":{"login":"rev"},"commit":{"oid":"sha11"}}],"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]}'
write "$D/rules-checks.json" '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci"}]},"ruleset_id":9,"ruleset_source_type":"Repository"}]'
write "$D/crew11.json" '[{"id":"dev-11","delivery":"https://github.com/o/r/pull/11","allow_merge":true,"review_gate_waived":true}]'
diag --pr-json "$D/pr-checks-failing.json" --rules-json "$D/rules-checks.json" --crew-record "$D/crew11.json" --me me
assert_contains "case 11a: a failing required context is a required-checks objection" "$OUT" "forge: required-checks - required status check(s) not passing: ci"

write "$D/pr-checks-absent.json" '{"number":12,"url":"https://github.com/o/r/pull/12","state":"OPEN","author":{"login":"someone-else"},"baseRefName":"main","headRefOid":"sha12","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","author":{"login":"rev"},"commit":{"oid":"sha12"}}],"statusCheckRollup":[]}'
write "$D/crew12.json" '[{"id":"dev-12","delivery":"https://github.com/o/r/pull/12","allow_merge":true,"review_gate_waived":true}]'
diag --pr-json "$D/pr-checks-absent.json" --rules-json "$D/rules-checks.json" --crew-record "$D/crew12.json" --me me
assert_contains "case 11b: a required context absent from the rollup entirely also objects" "$OUT" "forge: required-checks - required status check(s) not passing: ci"

# --- case 12: crew-record resolution by delivery, not by $WINGMAN_CREW_ID --
# --- (M2) --------------------------------------------------------------------
write "$D/pr-resolve.json" '{"number":50,"url":"https://github.com/o/r/pull/50","state":"OPEN","author":{"login":"someone-else"},"baseRefName":"main","headRefOid":"sha50","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"REVIEW_REQUIRED","reviews":[],"statusCheckRollup":[]}'
write "$D/roster-a.json" '[{"id":"lead-1","allow_merge":false,"review_gate_waived":false,"updated":"2026-08-01T00:00:00Z"},{"id":"worker-1","delivery":"https://github.com/o/r/pull/50","allow_merge":true,"review_gate_waived":true,"updated":"2026-08-02T00:00:00Z"}]'
WINGMAN_CREW_ID=lead-1 diag --pr-json "$D/pr-resolve.json" --rules-json "$D/rules-empty.json" --crew-record "$D/roster-a.json" --me me
assert_contains "case 12a: the worker's record (matched by delivery) is used, not the caller's own" "$OUT" "crew-record: worker-1 (matched by delivery)"
assert_not_contains "case 12a: the worker holds both grants -> no wingman objection" "$OUT" "wingman:"

write "$D/roster-b.json" '[{"id":"lead-1","allow_merge":true,"review_gate_waived":true,"updated":"2026-08-01T00:00:00Z"},{"id":"worker-1","delivery":"https://github.com/o/r/pull/50","allow_merge":false,"review_gate_waived":false,"updated":"2026-08-02T00:00:00Z"}]'
WINGMAN_CREW_ID=lead-1 diag --pr-json "$D/pr-resolve.json" --rules-json "$D/rules-empty.json" --crew-record "$D/roster-b.json" --me me
assert_contains "case 12b: grants inverted - the delivery match (worker-1) is still used" "$OUT" "crew-record: worker-1 (matched by delivery)"
assert_contains "case 12b: the caller's own grants are NOT consulted when a delivery match exists" "$OUT" "wingman: no-allow-merge"

for form in "https://github.com/o/r/pull/50" "/pull/50" "#50" "50"; do
  write "$D/roster-form.json" "$(printf '[{"id":"worker-1","delivery":"%s","allow_merge":true,"review_gate_waived":true}]' "$form")"
  WINGMAN_CREW_ID= diag --pr-json "$D/pr-resolve.json" --rules-json "$D/rules-empty.json" --crew-record "$D/roster-form.json" --me me
  assert_contains "case 12c: delivery form '$form' matches" "$OUT" "crew-record: worker-1 (matched by delivery)"
done

diag --pr-json "$D/pr-resolve.json" --rules-json "$D/rules-empty.json" --crew-record "$D/roster-a.json" --me me --crew-id lead-1
assert_contains "case 12d: --crew-id overrides a delivery match" "$OUT" "crew-record: lead-1 (--crew-id)"

write "$D/roster-nomatch.json" '[{"id":"lead-1","allow_merge":false,"review_gate_waived":false}]'
WINGMAN_CREW_ID= diag --pr-json "$D/pr-resolve.json" --rules-json "$D/rules-empty.json" --crew-record "$D/roster-nomatch.json" --me me
assert_contains "case 12e: no match at all -> crew-record: none found" "$OUT" "crew-record: none found"
assert_contains "case 12e: no match at all -> the wingman dimension is unknown" "$OUT" "wingman: unknown"
assert_contains "case 12e: no match at all -> the overall verdict is unknown too (crew record is verdict-bearing)" "$OUT" "verdict: unknown"

# --- case 13: review staleness (M5) -----------------------------------------
write "$D/pr-stale.json" '{"number":60,"url":"https://github.com/o/r/pull/60","state":"OPEN","author":{"login":"someone-else"},"baseRefName":"main","headRefOid":"newsha","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"REVIEW_REQUIRED","reviews":[{"state":"APPROVED","author":{"login":"rev"},"commit":{"oid":"oldsha"}}],"statusCheckRollup":[]}'
write "$D/crew-stale.json" '[{"id":"dev-60","delivery":"https://github.com/o/r/pull/60","allow_merge":true,"review_gate_waived":false}]'
diag --pr-json "$D/pr-stale.json" --rules-json "$D/rules-empty.json" --crew-record "$D/crew-stale.json" --me me
assert_not_contains "case 13a: a stale APPROVED review does not clear the wingman side" "$OUT" "verdict: clear"
assert_contains "case 13a: it is reported as likely-stale, naming both SHAs" "$OUT" "review-evidence-likely-stale - rev's APPROVED review was submitted against commit oldsha, but the PR's current head is now newsha"

write "$D/pr-superseded.json" '{"number":61,"url":"https://github.com/o/r/pull/61","state":"OPEN","author":{"login":"someone-else"},"baseRefName":"main","headRefOid":"sha61","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","reviews":[{"state":"APPROVED","author":{"login":"rev"},"commit":{"oid":"sha61"}},{"state":"CHANGES_REQUESTED","author":{"login":"rev"},"commit":{"oid":"sha61"}}],"statusCheckRollup":[]}'
write "$D/crew-superseded.json" '[{"id":"dev-61","delivery":"https://github.com/o/r/pull/61","allow_merge":true,"review_gate_waived":false}]'
diag --pr-json "$D/pr-superseded.json" --rules-json "$D/rules-empty.json" --crew-record "$D/crew-superseded.json" --me me
assert_not_contains "case 13b: an APPROVED later superseded by CHANGES_REQUESTED from the same login does not clear (latest-per-login wins)" "$OUT" "verdict: clear"

# --- case 14: live-mode argument validation (N1) - a bare PR number with ----
# --- no --repo and no URL exits 2 with the instruction, and no gh ----------
# --- invocation is attempted (the check runs before any subprocess call) ---
diag --pr 334
assert_eq "case 14: exit 2" "$RC" "2"
assert_contains "case 14: names the exact remedy (full URL or --repo)" "$OUT" "full PR URL"
assert_contains "case 14: names --repo as the alternative" "$OUT" "--repo <owner>/name"

test_summary
