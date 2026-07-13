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

OUTSIDE_DIR="$(mktemp -d)"
trap 'rm -rf "$OUTSIDE_DIR"' EXIT
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
