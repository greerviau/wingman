#!/usr/bin/env bash
# E2E: the crew-level PR watcher. Drives bin/pr-watch with a FAKE forge CLI (via
# WM_GH) so no real gh/GitHub is needed, and proves it fires the right single event
# per class, suppresses an already-handled event via its on-disk cursor, and never
# wakes on the crew's own replies. Uses --once (a single poll) so the blocking loop
# is not exercised here. Also proves pr-watch reads its own crew.json record fresh
# every poll (via `wm_state crew-get`) so merge-ready fires instead of
# checks-passed once allow_merge is granted - both when it is already granted at
# settle time, and when the grant lands after the PR already settled.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PRWATCH="$TEST_REPO/bin/pr-watch"

# A fake `gh`: dispatches on args and serves canned JSON from files named by
# environment. `gh api user` -> the crew's own login; `gh pr view` -> $FAKE_PR;
# `gh repo view` -> a fixed owner/repo; `gh api .../comments` -> $FAKE_RC or [];
# `gh api graphql` (the checkSuite forge signal, issue #259) -> $FAKE_CS or "" -
# or, when $FAKE_CS_ERROR is set, a GraphQL error BODY on stdout with exit 1,
# matching what the real `gh` actually does on a GraphQL/HTTP error (round-1
# review, M1) - as opposed to writing nothing to stdout at all.
make_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "api user")   echo "botuser" ;;
  "pr view")    cat "$FAKE_PR" ;;
  "repo view")  echo "owner/repo" ;;
  "api repos/owner/repo/pulls/42/comments") [ -n "${FAKE_RC:-}" ] && cat "$FAKE_RC" || echo "[]" ;;
  "api graphql")
    if [ -n "${FAKE_CS_ERROR:-}" ]; then
      echo '{"errors":[{"type":"RATE_LIMITED","message":"boom"}]}'
      exit 1
    fi
    [ -n "${FAKE_CS:-}" ] && cat "$FAKE_CS" || echo ""
    ;;
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
# Pin has-ci detection to an empty fixture dir, not this repo's own real
# .github/workflows/ - every existing fixture below represents a generic
# repo with no CI signal established, and must keep doing so regardless of
# which repo the test suite itself happens to run inside (issue #274).
export WM_PR_WATCH_WORKFLOWS_DIR="$D/no-workflows"

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

# 9. allow_merge already granted at spawn time -> settling fires merge-ready,
#    not checks-passed (pr-watch reads its own crew.json record via crew-get).
test_new_home
export WINGMAN_CREW_ID=pw4
wm_state crew-add --id pw4 --type developer --repo /tmp --window wm-pw4 \
  --session-id sess-pw4 --allow-merge >/dev/null
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"reviews":[],"comments":[],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_contains "allow_merge already granted: settling fires merge-ready" "$(run)" "merge-ready: #42"
assert_eq "a settled merge-ready PR does not re-fire" "$(run)" ""

# 10. a mid-flight allow_merge grant, arriving AFTER the PR already settled
#     (checks-passed already fired), fires merge-ready on the very next poll -
#     no PR-side change at all. This is the exact gap the investigation into
#     the silent-parking incident identified.
test_new_home
export WINGMAN_CREW_ID=pw5
wm_state crew-add --id pw5 --type developer --repo /tmp --window wm-pw5 \
  --session-id sess-pw5 >/dev/null
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"reviews":[],"comments":[],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
assert_contains "not yet granted: settling fires ordinary checks-passed" "$(run)" "checks-passed: #42"
wm_state crew-set --id pw5 --allow-merge true >/dev/null
assert_contains "granting allow_merge afterward fires merge-ready, no PR change needed" "$(run)" "merge-ready: #42"
assert_eq "merge-ready does not re-fire while still settled" "$(run)" ""

# --- has-ci-config detection end-to-end (issue #274): a fixture dir WITH a
# --- workflow file makes pr-watch withhold checks-passed on an empty rollup
# --- for an already-confirmed head; the file-wide no-workflows override
# --- (this file's own setup, above) already covers the "no CI" path in
# --- every case before this one, so this section only needs to add the
# --- "has CI" path. ------------------------------------------------------
# Fresh crew id + a fresh $WM_HOME (round-2 review finding): without this,
# this section inherits WINGMAN_CREW_ID=pw5 and its never-revoked
# allow_merge:true grant from the immediately-preceding merge-ready section
# (:192-207) - the cursor and the crew record both carry over, so the last
# assertion below fires "merge-ready: #42" instead of the expected
# "checks-passed: #42". pw5b (not pw6 - already used by section 11 below).
test_new_home
export WINGMAN_CREW_ID=pw5b
mkdir -p "$D/has-workflows"
printf 'name: ci\non: [pull_request]\n' > "$D/has-workflows/ci.yml"
run_with_ci() { WM_PR_WATCH_WORKFLOWS_DIR="$D/has-workflows" "$PRWATCH" --pr 42 --once 2>/dev/null; }

# seed: CI healthy on the current head, using run_with_ci() from the start so
# the cursor's recorded head_ref_oid comes from a poll that already had
# --has-ci-config set - exactly the pre-outage condition the bug needs (the
# head must already be confirmed BEFORE the rollup goes empty).
echo '{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"IN_PROGRESS"}],
 "reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-live"}' > "$FAKE_PR"
assert_eq "seed: CI healthy on current head (has-workflows dir)" "$(run_with_ci)" ""

# outage begins: same head, rollup empties out. Must NOT fire checks-passed -
# this is PR #271's own reported shape, driven through the real bin/pr-watch
# script end-to-end, not just pr-eval.py in isolation.
echo '{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[],"reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-live"}' > "$FAKE_PR"
assert_eq "repo has CI configured (fixture workflow file present): an outage-empty rollup on the same confirmed head does NOT fire checks-passed" "$(run_with_ci)" ""
assert_eq "outage persisting across a further poll still does not fire" "$(run_with_ci)" ""

# the outage clears and CI genuinely reports green - checks-passed fires on
# the real signal, proving the gate withholds only the false reading, not
# every reading.
echo '{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}],
 "reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-live"}' > "$FAKE_PR"
assert_contains "outage clears, CI genuinely reports green - checks-passed fires" "$(run_with_ci)" "checks-passed: #42"

# --- checkSuite forge signal end-to-end (issue #259): a fixture where the
# --- rollup stays empty across several polls while the fake graphql response
# --- reports a registered checkSuite for the SAME head - must withhold
# --- checks-passed the whole time, firing only once the rollup genuinely
# --- resolves. -------------------------------------------------------------
test_new_home
export WINGMAN_CREW_ID=pw7
export FAKE_CS="$D/cs.json"
echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"oid":"sha-live2","checkSuites":{"totalCount":1}}}]}}}}}' > "$FAKE_CS"

cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"reviews":[],"comments":[],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-live2"}
JSON
assert_eq "poll 1: head unconfirmed (the pre-existing #257 gate)" "$(run)" ""
assert_eq "poll 2: head confirmed, checkSuite registered per the forge, rollup still empty - withheld" "$(run)" ""
assert_eq "poll 3: still withheld, not the plain #257 one-poll settle" "$(run)" ""

cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}],
 "reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-live2"}
JSON
assert_contains "poll 4: CI genuinely reports - checks-passed fires" "$(run)" "checks-passed: #42"
unset FAKE_CS

# --- checkSuite forge signal (issue #259) M1 regression: the once-per-arm
# --- warning must fire when `gh api graphql` genuinely fails with an error
# --- BODY on stdout plus a non-zero exit - what the real `gh` actually does
# --- on a GraphQL/HTTP error - not just when it writes nothing at all.
# --- Round-1 review found the first draft branched on stdout emptiness alone
# --- (with a trailing `|| true` swallowing the exit status), so it silently
# --- treated an error body as a successful response and never warned - the
# --- exact failures (missing scope, NOT_FOUND, rate-limit) this diagnostic
# --- exists for. Driven through the REAL blocking loop, not --once, so the
# --- once-per-arm latch is genuinely exercised across several polls, each of
# --- which fails identically. -----------------------------------------------
test_new_home
export WINGMAN_CREW_ID=pw8
export FAKE_CS_ERROR=1
export WM_PR_WATCH_INTERVAL=1
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"reviews":[],"comments":[],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"sha-live3"}
JSON
CSLOG="$WINGMAN_HOME/pw8.log"
"$PRWATCH" --pr 42 >"$CSLOG" 2>&1 &
bgpid=$!
wm_track "$bgpid"
sleep 4.5   # several 1s poll intervals, each failing the graphql call identically
kill "$bgpid" 2>/dev/null
wait "$bgpid" 2>/dev/null || true
_warns="$(grep -c 'checkSuite forge signal unavailable' "$CSLOG" 2>/dev/null || echo 0)"
assert_eq "the once-per-arm warning fires exactly once across several polls, even though gh api graphql fails EVERY poll with a genuine error body + exit 1" "$_warns" "1"
unset FAKE_CS_ERROR
unset WM_PR_WATCH_INTERVAL

# 11. the liveness beacon (issue #187): --once never touches it, but the real
#     blocking loop does - the signal wm_state review-resurface-check (see
#     tests/review-resurface.test.sh) relies on to tell "something is
#     actively polling this member's PR" from "nothing is".
test_new_home
export WINGMAN_CREW_ID=pw6
BEAT="$WINGMAN_HOME/pr-watch-pw6.beat"
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,"statusCheckRollup":[],"reviews":[],"comments":[],
 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
"$PRWATCH" --pr 42 --once >/dev/null 2>&1
assert_false "--once never touches the beacon" "[ -f '$BEAT' ]"

"$PRWATCH" --pr 42 >/dev/null 2>&1 &
bgpid=$!
wm_track "$bgpid"
_i=0
while [ "$_i" -lt 20 ]; do
  [ -f "$BEAT" ] && break
  sleep 0.2; _i=$((_i+1))
done
assert_true "the real blocking loop touches its own beacon" "[ -f '$BEAT' ]"
kill "$bgpid" 2>/dev/null

# --- singleton guard: a second arm on the same PR stands down, not a rival ---
# (issue #180) Before the fix, bin/pr-watch has no check at all before starting
# its blocking loop, so a second arm on the same PR/crew id starts a second,
# fully independent `while :; do ... done` - proven here by actually launching
# two real (non---once) background cycles against a PR fixture that never
# settles (a permanently in-progress check, so neither cycle ever fires and
# exits on its own) and observing whether the second one keeps running.
test_new_home
export WINGMAN_CREW_ID=sg1
D3="$(wm_mktemp_dir)"
GH3="$D3/gh"; make_fake_gh "$GH3"
export WM_GH="$GH3"
export FAKE_PR="$D3/pr.json"
export WM_PR_WATCH_INTERVAL=1
cat > "$FAKE_PR" <<'JSON'
{"number":42,"state":"OPEN","mergedAt":null,
 "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"IN_PROGRESS"}],
 "reviews":[],"comments":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON

PIDF="$WINGMAN_HOME/pr-watch-sg1.pid"
BEAT="$WINGMAN_HOME/pr-watch-sg1.beat"

"$PRWATCH" --pr 42 >"$WINGMAN_HOME/loop1.log" 2>&1 &
pid1=$!
wm_track "$pid1"
_i=0
while [ "$_i" -lt 20 ]; do
  [ -f "$BEAT" ] && break
  sleep 0.2; _i=$((_i+1))
done
assert_true "the first cycle is live and beating" "kill -0 $pid1"

"$PRWATCH" --pr 42 >"$WINGMAN_HOME/loop2.log" 2>&1 &
pid2=$!
wm_track "$pid2"

# Give the second arm every chance to exit on its own if it's going to - well
# past both WM_PR_WATCH_INTERVAL (1s) and WM_PR_WATCH_GRACE (90s default is
# irrelevant here; the guard's liveness check runs once, at arm time, so this
# only needs to outlast a few poll cycles for a second REAL loop to prove
# itself alive, not the grace window itself).
_i=0
while [ "$_i" -lt 25 ]; do
  kill -0 "$pid2" 2>/dev/null || break
  sleep 0.2; _i=$((_i+1))
done
assert_false "a second arm on the same PR does not start a rival loop - it exits" "kill -0 $pid2"
assert_contains "the second arm reports the live cycle as healthy" "$(cat "$WINGMAN_HOME/loop2.log")" "healthy"
assert_true "the first cycle is still the one live watcher" "kill -0 $pid1"
assert_eq "the surviving pidfile still names the first cycle's pid" "$(cat "$PIDF" 2>/dev/null)" "$pid1"

kill "$pid1" 2>/dev/null

test_summary
