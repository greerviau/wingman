#!/usr/bin/env bash
# E2E: the crew-level PR watcher. Drives bin/pr-watch with a FAKE forge CLI (via
# WM_GH) so no real gh/GitHub is needed, and proves it fires the right single event
# per class, suppresses an already-handled event via its on-disk cursor, and never
# wakes on the crew's own replies. Uses --once (a single poll) so the blocking loop
# is not exercised here.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PRWATCH="$TEST_REPO/bin/pr-watch"

# A fake `gh`: dispatches on args and serves canned JSON from files named by
# environment. `gh api user` -> the crew's own login; `gh pr view` -> $FAKE_PR;
# `gh repo view` -> a fixed owner/repo; `gh api .../comments` -> $FAKE_RC or [].
make_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "api user")   echo "botuser" ;;
  "pr view")    cat "$FAKE_PR" ;;
  "repo view")  echo "owner/repo" ;;
  "api repos/owner/repo/pulls/42/comments") [ -n "${FAKE_RC:-}" ] && cat "$FAKE_RC" || echo "[]" ;;
  *)            echo "" ;;
esac
SH
  chmod +x "$1"
}

test_new_home
export WINGMAN_CREW_ID=pw1
D="$(wm_mktemp_dir)"
GH="$D/gh"; make_fake_gh "$GH"
export WM_GH="$GH"
export FAKE_PR="$D/pr.json"

run() { "$PRWATCH" --pr 42 --once 2>/dev/null; }

# All fixtures below carry an explicit mergeable=MERGEABLE/mergeStateStatus=CLEAN
# pair, matching what a real `gh pr view --json ...,mergeable,mergeStateStatus`
# call always returns (never an absent field) now that pr-watch requests it.

# 1. open PR with a failing check -> ci-failed
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE"}],
 "reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_contains "a failing check fires ci-failed" "$(run)" "ci-failed: #42"

# 2. same failing check again -> cursor suppresses, no event
assert_eq "the same failing check does not re-fire" "$(run)" ""

# 3. CI green + a reviewer comment -> comment
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}],
 "reviews":[],
 "comments":[{"author":{"login":"reviewer1"},"body":"nit","createdAt":"2026-07-10T10:00:00Z"}],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_contains "a new reviewer comment fires comment" "$(run)" "comment: #42"
# with the comment handled and the checks green, the PR has settled -> checks-passed
# (once), then it goes quiet: neither the handled comment nor the green rollup re-fire.
assert_contains "a settled-green PR then fires checks-passed" "$(run)" "checks-passed: #42"
assert_eq "a green PR with no new events stays quiet" "$(run)" ""

# 4. a review requesting changes beats a plain comment
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}],
 "reviews":[{"author":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","submittedAt":"2026-07-10T11:00:00Z"}],
 "comments":[{"author":{"login":"reviewer1"},"body":"nit","createdAt":"2026-07-10T10:00:00Z"}],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_contains "a changes-requested review fires changes-requested" "$(run)" "changes-requested: #42"

# 5. the crew's own reply, marked with THIS session's own crew id at the body's
#    start, must never wake it (the reply-loop guard).
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}],
 "reviews":[{"author":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","submittedAt":"2026-07-10T11:00:00Z"}],
 "comments":[{"author":{"login":"botuser"},"body":"<!-- wingman-crew:pw1 --> fixed, PTAL","createdAt":"2026-07-10T12:00:00Z"}],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_eq "the crew's own marked reply does not fire" "$(run)" ""

# 5b. a same-login comment with NO marker at all must fire - issue #118's repro
#     shape (the operator's genuine comment, sharing the crew's login).
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}],
 "reviews":[{"author":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","submittedAt":"2026-07-10T11:00:00Z"}],
 "comments":[{"author":{"login":"botuser"},"body":"<!-- wingman-crew:pw1 --> fixed, PTAL","createdAt":"2026-07-10T12:00:00Z"},
             {"author":{"login":"botuser"},"body":"actually, one more thing","createdAt":"2026-07-10T13:00:00Z"}],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_contains "a same-login comment with no marker fires comment (issue #118)" "$(run)" "comment: #42"

# 5c. a same-login comment marked by a DIFFERENT crew id must fire - issue #59's
#     repro shape (a different crew session's genuine comment, sharing the login).
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}],
 "reviews":[{"author":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","submittedAt":"2026-07-10T11:00:00Z"}],
 "comments":[{"author":{"login":"botuser"},"body":"<!-- wingman-crew:pw1 --> fixed, PTAL","createdAt":"2026-07-10T12:00:00Z"},
             {"author":{"login":"botuser"},"body":"actually, one more thing","createdAt":"2026-07-10T13:00:00Z"},
             {"author":{"login":"botuser"},"body":"<!-- wingman-crew:reviewer-9 --> concerned about X","createdAt":"2026-07-10T14:00:00Z"}],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_contains "a same-login comment marked by a different crew id fires comment (issue #59)" "$(run)" "comment: #42"

# 5d. a same-login comment carrying pw1's OWN marker, but only quoted (not at the
#     body's start) must fire - the round-1 must-fix's repro shape (a human's
#     GitHub "Quote reply" to a developer's own marked reply).
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}],
 "reviews":[{"author":{"login":"reviewer1"},"state":"CHANGES_REQUESTED","submittedAt":"2026-07-10T11:00:00Z"}],
 "comments":[{"author":{"login":"botuser"},"body":"<!-- wingman-crew:pw1 --> fixed, PTAL","createdAt":"2026-07-10T12:00:00Z"},
             {"author":{"login":"botuser"},"body":"actually, one more thing","createdAt":"2026-07-10T13:00:00Z"},
             {"author":{"login":"botuser"},"body":"<!-- wingman-crew:reviewer-9 --> concerned about X","createdAt":"2026-07-10T14:00:00Z"},
             {"author":{"login":"botuser"},"body":"> <!-- wingman-crew:pw1 --> fixed, PTAL\n\nOne more note before merging.","createdAt":"2026-07-10T15:00:00Z"}],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_contains "a same-login comment with pw1's own marker only quoted fires comment (round-1 must-fix)" "$(run)" "comment: #42"

# 6. merged wins and fires the terminal event
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"MERGED","mergedAt":"2026-07-10T13:00:00Z","statusCheckRollup":[],"reviews":[],"comments":[],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_contains "a merged PR fires merged" "$(run)" "merged: #42"

# 7. first arm on a no-CI PR settles straight to review; a pre-existing comment is
#    treated as seen (it must not fire as a comment) ...
test_new_home
export WINGMAN_CREW_ID=pw2
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"reviews":[],
 "comments":[{"author":{"login":"reviewer1"},"body":"old","createdAt":"2026-07-10T13:00:00Z"}],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
r7="$(run)"
assert_contains "first arm on a no-CI PR fires checks-passed" "$r7" "checks-passed: #42"
case "$r7" in *comment*) fail "a comment already present at first arm must not fire as a comment" ;; *) ok "a comment already present at first arm is seen, not fired" ;; esac

# ... and a later inline review-thread comment (REST shape) then fires
export FAKE_RC="$D/rc.json"
cat > "$FAKE_RC" <<'JSON'
[{"user":{"login":"reviewer1"},"body":"inline nit","created_at":"2026-07-10T14:00:00Z","path":"a.py","line":3}]
JSON
assert_contains "a later inline review-thread comment fires comment" "$(run)" "comment: #42"

# 8. mergeability drift: a real poll_once call fires conflict: on CONFLICTING,
#    then goes quiet once mergeability resolves back to MERGEABLE (no other change).
test_new_home
export WINGMAN_CREW_ID=pw3
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"reviews":[],"comments":[],
 "mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}
JSON
assert_contains "a conflicting PR fires conflict: via a real poll_once call" "$(run)" "conflict: #42"
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"reviews":[],"comments":[],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_contains "resolving fires checks-passed, not a second conflict event" "$(run)" "checks-passed: #42"
assert_eq "no further event once settled" "$(run)" ""

test_summary
