#!/usr/bin/env bash
# E2E: hooks/pr-open-marker-tracker.sh (issue #50, "beyond merges"). When a
# `gh pr create` command actually succeeds (PostToolUse - a failing Bash
# command fires PostToolUseFailure instead, so this hook only ever sees a PR
# that actually opened) from a crew session, it prepends the same
# `<!-- wingman-crew:<id> -->` marker issue #118's pr-watch self-filter
# already uses to the new PR's body. A PR opened from a bare human session
# (no crew id) needs no marker and gets none. Writing to a PR is opt-in: the
# tracker only marks when the pr_comments run preference is `on`; off, unset,
# or with no run id it leaves the body untouched.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TRACKER="$TEST_REPO/hooks/pr-open-marker-tracker.sh"

SCRATCH="$(wm_mktemp_dir)"
mkdir -p "$SCRATCH/bin"
GH_LOG="$SCRATCH/gh.log"
: > "$GH_LOG"
PR_VIEW_JSON="$SCRATCH/pr-view.json"
echo '{"number":99,"body":"Problem/request..."}' > "$PR_VIEW_JSON"

# A fake `gh` that logs every invocation (one line, args space-joined) and
# answers `pr view ... --json number,body` with the contents of
# $PR_VIEW_JSON, so each test case can control what body/number the tracker
# sees just by overwriting that file.
cat > "$SCRATCH/bin/gh" <<SH
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
case "\$1 \$2" in
  "pr view") cat "$PR_VIEW_JSON" ;;
  *) ;;
esac
SH
chmod +x "$SCRATCH/bin/gh"
export PATH="$SCRATCH/bin:$PATH"

run_tracker() {
  # run_tracker <event> <command> [tool_response]
  uv run --no-project --quiet python -c '
import json, sys
data = {
    "hook_event_name": sys.argv[1],
    "tool_name": "Bash",
    "tool_input": {"command": sys.argv[2]},
    "cwd": sys.argv[3],
}
if len(sys.argv) > 4 and sys.argv[4]:
    data["tool_response"] = sys.argv[4]
print(json.dumps(data))
' "$1" "$2" "$SCRATCH" "${3:-}" | bash "$TRACKER"
}

test_new_home

# --- a bare human session (no crew id) needs no marker --------------------
unset WINGMAN_CREW_ID
: > "$GH_LOG"
run_tracker PostToolUse "gh pr create --title x --body y" "https://github.com/acme/widgets/pull/99"
assert_eq "non-crew PR open: no gh invocation is logged" "$(cat "$GH_LOG")" ""

# Writing to a PR is opt-in (pr_comments=on). Set it for the marker cases
# below; the off/unset cases at the end assert the tracker stays its hand.
export WINGMAN_CREW_ID=dev1
export WINGMAN_RUN_ID=run-marker
wm_state pref-set --run-id run-marker --key pr_comments --value on >/dev/null

# --- crew session, PR URL resolved from tool_response ----------------------
: > "$GH_LOG"
echo '{"number":99,"body":"Problem/request..."}' > "$PR_VIEW_JSON"
run_tracker PostToolUse "gh pr create --title x --body y" "https://github.com/acme/widgets/pull/99"
assert_contains "gh pr create resolved via tool_response: a pr view read happens" "$(cat "$GH_LOG")" "pr view https://github.com/acme/widgets/pull/99"
assert_contains "and a pr edit is issued on the resolved number" "$(cat "$GH_LOG")" "pr edit 99"
assert_contains "the new body starts with the marker" "$(cat "$GH_LOG")" "wingman-crew:dev1"
assert_contains "the new body still contains the original body text" "$(cat "$GH_LOG")" "Problem/request..."

# --- crew session, no usable tool_response: falls back to `gh pr view` in cwd
: > "$GH_LOG"
echo '{"number":42,"body":"Intent: ..."}' > "$PR_VIEW_JSON"
run_tracker PostToolUse "gh pr create --fill"
assert_contains "no tool_response falls back to a plain pr view in cwd" "$(cat "$GH_LOG")" "pr view --json number,body"
assert_contains "and edits the number pr view resolved" "$(cat "$GH_LOG")" "pr edit 42"

# --- idempotency: a body that already starts with a marker is left untouched
: > "$GH_LOG"
echo '{"number":99,"body":"<!-- wingman-crew:dev1 -->\n\nProblem/request..."}' > "$PR_VIEW_JSON"
run_tracker PostToolUse "gh pr create --title x --body y" "https://github.com/acme/widgets/pull/99"
assert_contains "an already-marked PR is still read once" "$(cat "$GH_LOG")" "pr view"
case "$(cat "$GH_LOG")" in
  *"pr edit"*) fail "an already-marked PR must not trigger a second gh pr edit" ;;
  *) ok "no second gh pr edit call on an already-marked PR" ;;
esac

# --- gh repo/gist/issue create never matches (only pr create does) ---------
: > "$GH_LOG"
echo '{"number":99,"body":"Problem/request..."}' > "$PR_VIEW_JSON"
run_tracker PostToolUse "gh repo create acme/widgets"
assert_eq "gh repo create posts no marker" "$(cat "$GH_LOG")" ""
run_tracker PostToolUse "gh issue create --title x"
assert_eq "gh issue create posts no marker" "$(cat "$GH_LOG")" ""

# --- an unrelated successful Bash command writes nothing -------------------
: > "$GH_LOG"
run_tracker PostToolUse "git push origin feature/foo"
assert_eq "an unrelated push posts nothing" "$(cat "$GH_LOG")" ""

# --- a failed PR-open attempt (PostToolUseFailure) is never marked ---------
: > "$GH_LOG"
run_tracker PostToolUseFailure "gh pr create --title x --body y"
assert_eq "a failed/denied PR-open attempt marks nothing" "$(cat "$GH_LOG")" ""

# --- cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56):
# command_segments() returns None rather than a partial segment list. This
# tracker is a best-effort PostToolUse recorder, not a deny-gate, so it must
# not crash on that - just mark nothing.
: > "$GH_LOG"
out="$(run_tracker PostToolUse "gh pr create --title 'oops")"
assert_eq "an unresolvable command does not crash the tracker (no output)" "$out" ""
assert_eq "an unresolvable command marks no PR" "$(cat "$GH_LOG")" ""

# --- pr_comments=off: writing to a PR is opt-in, so nothing is marked -------
: > "$GH_LOG"
echo '{"number":99,"body":"Problem/request..."}' > "$PR_VIEW_JSON"
wm_state pref-set --run-id run-marker --key pr_comments --value off >/dev/null
run_tracker PostToolUse "gh pr create --title x --body y" "https://github.com/acme/widgets/pull/99"
assert_eq "pr_comments=off: no gh invocation at all (PR body left untouched)" "$(cat "$GH_LOG")" ""
wm_state pref-set --run-id run-marker --key pr_comments --value on >/dev/null

# --- pr_comments unanswered for this run: conservative default is no mark ----
: > "$GH_LOG"
export WINGMAN_RUN_ID=run-unanswered
run_tracker PostToolUse "gh pr create --title x --body y" "https://github.com/acme/widgets/pull/99"
assert_eq "pr_comments unset for this run: nothing is marked" "$(cat "$GH_LOG")" ""
export WINGMAN_RUN_ID=run-marker

# --- no run id at all: conservative default is no mark -----------------------
: > "$GH_LOG"
unset WINGMAN_RUN_ID
run_tracker PostToolUse "gh pr create --title x --body y" "https://github.com/acme/widgets/pull/99"
assert_eq "no WINGMAN_RUN_ID: nothing is marked" "$(cat "$GH_LOG")" ""

unset WINGMAN_CREW_ID

test_summary
