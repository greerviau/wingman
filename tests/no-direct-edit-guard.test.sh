#!/usr/bin/env bash
# E2E: the PreToolUse guard (#17). Denies direct Edit/Write/NotebookEdit
# against files inside a git repo, and direct test-runner Bash calls, at the
# orchestrator layer (wingman's own top-level session, or a lead) - and stays
# inactive for every worker crew type, for any unrelated Claude Code session
# elsewhere on the machine, and for Edit/Write targets outside any git repo
# (e.g. the auto-memory files under ~/.claude/projects/**/memory/).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/no-direct-edit-guard.sh"

run_hook() {
  # run_hook <tool_name> <command-or-empty> [file_path]
  if [ -n "${2:-}" ]; then
    printf '{"tool_name":"%s","tool_input":{"command":"%s"}}' "$1" "$2" | bash "$HOOK"
  else
    fp="${3:-$TEST_REPO/x.py}"
    printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$fp" | bash "$HOOK"
  fi
}

# run_bash_command <command> - like run_hook Bash <command>, but the command
# is JSON-encoded via python (not %s-interpolated), so embedded quotes,
# backslashes, and newlines (multi-line commands, heredocs) survive intact
# instead of corrupting the hand-built JSON literal above.
run_bash_command() {
  uv run --no-project --quiet python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$1" | bash "$HOOK"
}

OUTSIDE_DIR="$(wm_mktemp_dir)"
if git -C "$OUTSIDE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "test setup: OUTSIDE_DIR ($OUTSIDE_DIR) is unexpectedly inside a git repo"
fi

# --- top-level wingman (no WINGMAN_CREW_ID at all), launched from this repo --
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE
export CLAUDE_PROJECT_DIR="$TEST_REPO"

out="$(run_hook Edit)"
assert_contains "top-level: Edit is denied" "$out" '"permissionDecision": "deny"'
assert_contains "top-level: Edit denial names the tool" "$out" "Direct Edit calls"
assert_contains "top-level: Edit denial redirects to spawn-crew" "$out" "bin/spawn-crew"
assert_contains "top-level: Edit denial cites the issue" "$out" "issue #17"

out="$(run_hook Write)"
assert_contains "top-level: Write is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook NotebookEdit)"
assert_contains "top-level: NotebookEdit is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "pytest tests/")"
assert_contains "top-level: pytest is denied" "$out" '"permissionDecision": "deny"'
assert_contains "top-level: pytest denial mentions the test suite" "$out" "test suite"

out="$(run_hook Bash "npm test")"
assert_contains "top-level: npm test is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "go test ./...")"
assert_contains "top-level: go test is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "bash tests/run.sh")"
assert_contains "top-level: tests/run.sh is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "bash tests/stop-guard.test.sh")"
assert_contains "top-level: a tests/*.test.sh invocation is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "npm run test")"
assert_contains "top-level: npm run test is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "cargo test")"
assert_contains "top-level: cargo test is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "make test")"
assert_contains "top-level: make test is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "uv run pytest")"
assert_contains "top-level: uv run pytest is denied" "$out" '"permissionDecision": "deny"'

# uv's own leading option flags must be skipped before resolving the wrapped
# command (the shared cmd_match.py resolver) - the flag-bearing form must be
# recognized exactly like the bare one.
out="$(run_hook Bash "uv run --no-project --quiet pytest")"
assert_contains "top-level: uv run --no-project --quiet pytest is denied" "$out" '"permissionDecision": "deny"'

# The regression fence around cmd_match's Python-interpreter unwrap: an
# interpreter in front of a *script* resolves to that script, but `-m` (a module)
# is deliberately never unwrapped - this guard detects a test runner on exactly
# the un-unwrapped shape (basename python/python3 with `-m` in argv), so both the
# bare and the uv-wrapped module forms must keep resolving to the interpreter.
out="$(run_hook Bash "python3 -m pytest")"
assert_contains "top-level: python3 -m pytest is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "uv run --no-project python -m pytest")"
assert_contains "top-level: uv run --no-project python -m pytest is denied" "$out" '"permissionDecision": "deny"'

# Generic Bash - the orchestration wingman itself depends on - must stay open.
for cmd in "gh pr view 26" "git status" "ls -la" "grep -rn foo ." "cat README.md" \
           "bin/crew-list" "bin/spawn-crew --list-types"; do
  out="$(run_hook Bash "$cmd")"
  assert_eq "top-level: '$cmd' is allowed (no output)" "$out" ""
done

# A test-runner word appearing as someone else's argument (not the command
# actually being invoked) must not trip the guard - #27 review finding.
for cmd in "cat tests/run.sh" "grep -rn pytest ." "git log --grep=fix go test flake" \
           "gh pr view 26 | grep -i npm test" "pip install pytest-mock" \
           "echo run make test later"; do
  out="$(run_hook Bash "$cmd")"
  assert_eq "top-level: '$cmd' (runner word as argument, not invocation) is allowed" "$out" ""
done

# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56).
# This guard has NO cheap substring pre-gate (unlike no-merge-guard.sh and the
# Artifact-publish contract hooks) - it reaches command_segments() for every
# Bash call, so it must deny on an unresolvable command, and must NOT
# false-deny legitimate multi-line shapes (a crew-set continuation, a
# multi-line commit message, a heredoc used to build up a PR body, including
# one nested inside a substitution).
out="$(run_bash_command "echo 'oops")"
assert_contains "top-level: a genuinely unterminated quote is denied" "$out" '"permissionDecision": "deny"'
assert_contains "top-level: the parse-failure denial names the heredoc-quoting remedy verbatim" \
  "$out" "<<'EOF'"

CONTINUATION="$(printf '$WINGMAN_STATE crew-set --id foo \\\n  --status working \\\n  --summary "on it"')"
out="$(run_bash_command "$CONTINUATION")"
assert_eq "top-level: the documented multi-line crew-set continuation is allowed (no output)" "$out" ""

COMMIT_MSG="$(printf 'git commit -m "First line\nSecond line with an apostrophe: don'"'"'t worry"')"
out="$(run_bash_command "$COMMIT_MSG")"
assert_eq "top-level: a multi-line git commit -m message is allowed (no output)" "$out" ""

BARE_HEREDOC="$(printf 'cat <<EOF\nThis doesn'"'"'t push to main.\nEOF\n')"
out="$(run_bash_command "$BARE_HEREDOC")"
assert_eq "top-level: a bare heredoc body with an apostrophe is allowed (no output)" "$out" ""

GUARDED_MENTION="$(printf "cat <<'EOF'\nDon't run pytest directly.\nEOF\n")"
out="$(run_bash_command "$GUARDED_MENTION")"
assert_eq "top-level: a quoted-delimiter heredoc merely documenting pytest is allowed (no output)" "$out" ""

# The r4 idiom: a heredoc nested inside a substitution, body containing both
# an apostrophe and an unbalanced paren, in all three substitution forms -
# must stay allowed in every one.
NESTED_BODY="This doesn't (have both."
for form in double-quoted unquoted backtick; do
  case "$form" in
    double-quoted)
      cmd="$(printf 'gh pr create --body "$(cat <<'"'"'EOF'"'"'\n%s\nEOF\n)"' "$NESTED_BODY")" ;;
    unquoted)
      cmd="$(printf 'gh pr create --body $(cat <<'"'"'EOF'"'"'\n%s\nEOF\n)' "$NESTED_BODY")" ;;
    backtick)
      cmd="$(printf 'gh pr create --body `cat <<'"'"'EOF'"'"'\n%s\nEOF\n`' "$NESTED_BODY")" ;;
  esac
  out="$(run_bash_command "$cmd")"
  assert_eq "top-level: nested heredoc in a $form substitution (apostrophe+paren body) is allowed (no output)" "$out" ""
done

# PR #72 review, finding 1 (must-fix): a here-string (<<<) must never be
# misparsed as a heredoc - it never spans lines and must stay allowed, not
# hard-denied as an "unterminated heredoc".
for cmd in 'grep x <<< "$v"' 'read a b <<< "$line"' 'jq . <<< "$json"' 'grep x <<< "$out"'; do
  out="$(run_bash_command "$cmd")"
  assert_eq "top-level: '$cmd' (here-string, not a heredoc) is allowed (no output)" "$out" ""
done

# PR #72 review, finding 2 (should-fix): a trailing `#` comment is inert -
# an apostrophe, $(...), a backtick, or << inside it must never corrupt the
# scan into a false-deny.
out="$(run_bash_command "echo hi  # don't")"
assert_eq "top-level: a trailing comment with an apostrophe is allowed (no output)" "$out" ""

out="$(run_bash_command 'echo hi  # $(foo) `bar` << baz')"
assert_eq "top-level: a trailing comment with \$(, a backtick, and << is allowed (no output)" "$out" ""

# Edit/Write outside any git repo passes through untouched even while active -
# the guard's intent is to stop direct edits to code, not every Write/Edit
# regardless of target (e.g. wingman's own auto-memory files).
out="$(run_hook Edit "" "$OUTSIDE_DIR/note.md")"
assert_eq "top-level: Edit outside any git repo is allowed (no output)" "$out" ""

out="$(run_hook Write "" "$OUTSIDE_DIR/note.md")"
assert_eq "top-level: Write outside any git repo is allowed (no output)" "$out" ""

# --- cwd scoping: an unset WINGMAN_CREW_ID means "wingman's own top-level
# session" only when this session's project root actually is this checkout.
# Every unrelated Claude Code session elsewhere on the machine also has no
# WINGMAN_CREW_ID, and must never be affected. ------------------------------
export CLAUDE_PROJECT_DIR="$OUTSIDE_DIR"

out="$(run_hook Edit)"
assert_eq "top-level-shaped env outside this repo: Edit is allowed (no output)" "$out" ""

out="$(run_hook Bash "pytest tests/")"
assert_eq "top-level-shaped env outside this repo: pytest is allowed (no output)" "$out" ""

unset CLAUDE_PROJECT_DIR
out="$(run_hook Edit)"
assert_eq "top-level-shaped env with no CLAUDE_PROJECT_DIR: Edit is allowed (no output)" "$out" ""

# --- a lead is also an orchestrator: guarded the same as top-level, and
# unconditionally regardless of cwd - WINGMAN_CREW_TYPE=lead is a
# wingman-specific signal that is never a false positive for an unrelated
# session, so it needs no repo check. ----------------------------------------
export WINGMAN_CREW_ID=lead1 WINGMAN_CREW_TYPE=lead
unset CLAUDE_PROJECT_DIR

out="$(run_hook Edit)"
assert_contains "lead: Edit is denied with no CLAUDE_PROJECT_DIR at all" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "pytest -k foo")"
assert_contains "lead: pytest is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "git status")"
assert_eq "lead: generic Bash is allowed (no output)" "$out" ""

export CLAUDE_PROJECT_DIR="$OUTSIDE_DIR"
out="$(run_hook Edit)"
assert_contains "lead: Edit is denied from outside this repo" "$out" '"permissionDecision": "deny"'

out="$(run_hook Edit "" "$OUTSIDE_DIR/note.md")"
assert_eq "lead: Edit outside any git repo is allowed (no output)" "$out" ""

unset CLAUDE_PROJECT_DIR

# --- worker crew types are workers: the guard must stay fully inactive -------
for wtype in developer architect reviewer software-analyst research; do
  export WINGMAN_CREW_ID=w1 WINGMAN_CREW_TYPE="$wtype"

  out="$(run_hook Edit)"
  assert_eq "$wtype: Edit is allowed (no output)" "$out" ""

  out="$(run_hook Write)"
  assert_eq "$wtype: Write is allowed (no output)" "$out" ""

  out="$(run_hook NotebookEdit)"
  assert_eq "$wtype: NotebookEdit is allowed (no output)" "$out" ""

  out="$(run_hook Bash "pytest tests/")"
  assert_eq "$wtype: pytest is allowed (no output)" "$out" ""
done

# A crew member with WINGMAN_CREW_ID set but no WINGMAN_CREW_TYPE at all (should
# not happen post-fix, but must fail safe as a worker, not silently guard).
export WINGMAN_CREW_ID=w2
unset WINGMAN_CREW_TYPE
out="$(run_hook Edit)"
assert_eq "unset crew type: Edit is allowed (no output)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE CLAUDE_PROJECT_DIR

test_summary
