#!/usr/bin/env bash
# E2E: pr-eval's checks-passed decision. Drives bin/lib/pr-eval.py directly with
# canned PR JSON and a persistent cursor, proving checks-passed fires once when the
# PR settles (green or no-CI), stays quiet while nothing changes, re-arms after the
# rollup goes pending/failing and settles anew, and yields to a fresh comment.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

EVAL="$TEST_REPO/bin/lib/pr-eval.py"
D="$(mktemp -d)"
PRJ="$D/pr.json"; CUR="$D/cur.json"
ev() { uv run --no-project --quiet "$EVAL" --pr-json "$PRJ" --cursor "$CUR" --me me 2>/dev/null; }

# --- no CI at all: settles immediately, fires once ---------------------------
echo '{"number":1,"state":"OPEN","statusCheckRollup":[],"reviews":[],"comments":[]}' > "$PRJ"
assert_contains "a no-CI PR fires checks-passed on first poll" "$(ev)" "checks-passed: #1"
assert_eq "a settled no-CI PR does not re-fire" "$(ev)" ""

# --- pending -> green fires once, then quiet ---------------------------------
rm -f "$CUR"
echo '{"number":2,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"reviews":[],"comments":[]}' > "$PRJ"
assert_eq "a pending rollup is not an event" "$(ev)" ""
echo '{"number":2,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[]}' > "$PRJ"
assert_contains "the rollup going green fires checks-passed" "$(ev)" "checks-passed: #2"
assert_eq "a green rollup does not re-fire" "$(ev)" ""

# --- failing then green re-arms checks-passed --------------------------------
rm -f "$CUR"
echo '{"number":3,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}],"reviews":[],"comments":[]}' > "$PRJ"
assert_contains "a failing rollup fires ci-failed" "$(ev)" "ci-failed: #3"
echo '{"number":3,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[]}' > "$PRJ"
assert_contains "recovering to green re-arms checks-passed" "$(ev)" "checks-passed: #3"

# --- a fresh comment beats checks-passed ------------------------------------
rm -f "$CUR"
echo '{"number":4,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"reviews":[],"comments":[]}' > "$PRJ"
ev >/dev/null  # seed: pending, nothing fires, conv_hwm empty
echo '{"number":4,"state":"OPEN","statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[],"comments":[{"createdAt":"2026-07-10T12:00:00Z","author":{"login":"rev"}}]}' > "$PRJ"
assert_contains "a fresh comment wins over checks-passed" "$(ev)" "comment: #4"
assert_contains "checks-passed then fires once the comment is handled" "$(ev)" "checks-passed: #4"

test_summary
