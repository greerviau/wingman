#!/usr/bin/env bash
# E2E: pr-eval's checks-passed decision. Drives bin/lib/pr-eval.py directly with
# canned PR JSON and a persistent cursor, proving checks-passed fires once when the
# PR settles (green or no-CI), stays quiet while nothing changes, re-arms after the
# rollup goes pending/failing and settles anew, and yields to a fresh comment.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

EVAL="$TEST_REPO/bin/lib/pr-eval.py"
D="$(wm_mktemp_dir)"
PRJ="$D/pr.json"; CUR="$D/cur.json"
ev() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --me me 2>/dev/null; }

# All fixtures below carry an explicit mergeable=MERGEABLE/mergeStateStatus=CLEAN
# pair, matching what a real `gh pr view --json ...,mergeable,mergeStateStatus`
# call always returns (never an absent field), so these CI-focused cases exercise
# checks-passed without also exercising the mergeability gate (covered in its own
# section below).

# --- no CI at all: settles immediately, fires once ---------------------------
echo '{"number":1,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a no-CI PR fires checks-passed on first poll" "$(ev)" "checks-passed: #1"
assert_eq "a settled no-CI PR does not re-fire" "$(ev)" ""

# --- pending -> green fires once, then quiet ---------------------------------
rm -f "$CUR"
echo '{"number":2,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_eq "a pending rollup is not an event" "$(ev)" ""
echo '{"number":2,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "the rollup going green fires checks-passed" "$(ev)" "checks-passed: #2"
assert_eq "a green rollup does not re-fire" "$(ev)" ""

# --- failing then green re-arms checks-passed --------------------------------
rm -f "$CUR"
echo '{"number":3,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a failing rollup fires ci-failed" "$(ev)" "ci-failed: #3"
echo '{"number":3,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "recovering to green re-arms checks-passed" "$(ev)" "checks-passed: #3"

# --- a fresh comment beats checks-passed ------------------------------------
rm -f "$CUR"
echo '{"number":4,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
ev >/dev/null  # seed: pending, nothing fires, conv_hwm empty
echo '{"number":4,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[{"createdAt":"2026-07-10T12:00:00Z","author":{"login":"rev"}}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a fresh comment wins over checks-passed" "$(ev)" "comment: #4"
assert_contains "checks-passed then fires once the comment is handled" "$(ev)" "checks-passed: #4"

# --- mergeability: CONFLICTING fires once, re-feeding does not re-fire -------
rm -f "$CUR"
echo '{"number":5,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' > "$PRJ"
assert_contains "a CONFLICTING/DIRTY reading fires conflict" "$(ev)" "conflict: #5"
assert_eq "the same CONFLICTING reading does not re-fire" "$(ev)" ""

# --- resolving clears the cursor silently; re-conflicting fires a NEW event --
echo '{"number":5,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "a MERGEABLE reading clears the conflict cursor via checks-passed, not a conflict event" "$(ev)" "checks-passed: #5"
echo '{"number":5,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' > "$PRJ"
assert_contains "resolve-then-reconflict fires a NEW conflict event" "$(ev)" "conflict: #5"
# A follow-up poll of the same still-conflicting state falls through to the ready
# gate (mirrors the `ci` cursor: the transition itself returns early, a later
# unchanged-bad poll is what resets ready_fired) - same fixture, no event.
assert_eq "a follow-up poll of the same still-conflicting state stays quiet" "$(ev)" ""

# --- UNKNOWN neither fires nor clears an existing conflict, nor satisfies ready
echo '{"number":5,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}' > "$PRJ"
assert_eq "an UNKNOWN reading after CONFLICTING neither fires nor clears" "$(ev)" ""
assert_eq "a second UNKNOWN poll still does not fire checks-passed" "$(ev)" ""
echo '{"number":5,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "resolving after the UNKNOWN gap still fires checks-passed once" "$(ev)" "checks-passed: #5"
assert_eq "checks-passed does not re-fire once settled" "$(ev)" ""

# --- checks-passed withholds while conflicting, even with all checks green ---
rm -f "$CUR"
echo '{"number":6,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' > "$PRJ"
assert_contains "a conflicting PR fires conflict, not checks-passed, even with green checks" "$(ev)" "conflict: #6"
case "$(ev)" in *checks-passed*) fail "checks-passed must not fire while still conflicting" ;; *) ok "checks-passed withheld while still conflicting" ;; esac
echo '{"number":6,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' > "$PRJ"
assert_contains "checks-passed fires once mergeability resolves with checks still green" "$(ev)" "checks-passed: #6"

# --- priority: a co-occurring ci-failed and conflict fires ci-failed first, ---
# --- conflict still surfaces on the next poll ---------------------------------
rm -f "$CUR"
echo '{"number":7,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}],"reviews":[],"comments":[],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' > "$PRJ"
assert_contains "ci-failed takes priority over a co-occurring conflict" "$(ev)" "ci-failed: #7"
assert_contains "the co-occurring conflict still surfaces on the next poll" "$(ev)" "conflict: #7"

test_summary
