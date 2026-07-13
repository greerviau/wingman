#!/usr/bin/env bash
# E2E: hooks/merge-attribution-tracker.sh (issue #46 / #50). When a merge
# command actually succeeds (PostToolUse - a failing Bash command fires
# PostToolUseFailure instead, so this hook only ever sees a merge that went
# through) from a crew session, it posts a PR comment attributing the merge
# to the crew member. A merge from a bare pilot session (no crew id) needs no
# attribution and gets none.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TRACKER="$TEST_REPO/hooks/merge-attribution-tracker.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/bin"
GH_LOG="$SCRATCH/gh.log"
: > "$GH_LOG"

# A fake `gh` that logs every invocation (one line, args space-joined) and
# answers `pr view --json number -q .number` (the no-ref-given resolution
# path) with a fixed current-PR number.
cat > "$SCRATCH/bin/gh" <<SH
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "pr view") echo "99" ;;
  *) ;;
esac
SH
chmod +x "$SCRATCH/bin/gh"
export PATH="$SCRATCH/bin:$PATH"

run_tracker() {
  # run_tracker <event> <command>
  uv run --no-project --quiet python -c '
import json, sys
data = {
    "hook_event_name": sys.argv[1],
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[2]},
    "cwd": sys.argv[3],
}
print(json.dumps(data))
' "$1" "$2" "$SCRATCH" | bash "$TRACKER"
}

test_new_home

# --- a bare pilot session (no crew id) needs no attribution --------------
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE
: > "$GH_LOG"
run_tracker PostToolUse "gh pr merge 46"
assert_eq "non-crew merge: no gh invocation is logged" "$(cat "$GH_LOG")" ""

# --- crew session, an explicit PR ref -------------------------------------
export WINGMAN_CREW_ID=dev1
export WINGMAN_CREW_TYPE=developer
: > "$GH_LOG"
run_tracker PostToolUse "gh pr merge 46"
assert_contains "gh pr merge 46: a pr comment is posted on 46" "$(cat "$GH_LOG")" "pr comment 46"
assert_contains "the comment identifies the crew id" "$(cat "$GH_LOG")" "dev1"
assert_contains "the comment identifies the crew type" "$(cat "$GH_LOG")" "developer"
assert_contains "the comment says it is not the pilot" "$(cat "$GH_LOG")" "not by the pilot"

# --- crew session, no ref given: resolved via `gh pr view` ----------------
: > "$GH_LOG"
run_tracker PostToolUse "gh pr merge --squash"
assert_contains "gh pr merge with no ref resolves the current PR" "$(cat "$GH_LOG")" "pr view"
assert_contains "and comments on the resolved number (99)" "$(cat "$GH_LOG")" "pr comment 99"

# --- crew session, REST merge endpoint ------------------------------------
: > "$GH_LOG"
run_tracker PostToolUse "gh api -X PUT repos/acme/widgets/pulls/7/merge"
assert_contains "a REST merge comments on the parsed owner/repo/number URL" "$(cat "$GH_LOG")" "pr comment https://github.com/acme/widgets/pull/7"

# --- crew session, graphql mergePullRequest mutation ----------------------
: > "$GH_LOG"
run_tracker PostToolUse 'gh api graphql -f query='"'"'mutation{mergePullRequest(input:{pullRequestId:"PR_kwABC"}){clientMutationId}}'"'"''
assert_contains "a graphql merge posts via addComment with the extracted node id" "$(cat "$GH_LOG")" "id=PR_kwABC"
assert_contains "the addComment mutation targets addComment" "$(cat "$GH_LOG")" "addComment"

# --- a failed merge attempt (PostToolUseFailure) is never attributed -----
: > "$GH_LOG"
run_tracker PostToolUseFailure "gh pr merge 46"
assert_eq "a failed/denied merge attempt posts nothing" "$(cat "$GH_LOG")" ""

# --- an unrelated successful Bash command writes nothing ------------------
: > "$GH_LOG"
run_tracker PostToolUse "git push origin feature/foo"
assert_eq "an unrelated push posts nothing" "$(cat "$GH_LOG")" ""

: > "$GH_LOG"
run_tracker PostToolUse "git status"
assert_eq "a totally unrelated command posts nothing" "$(cat "$GH_LOG")" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

test_summary
