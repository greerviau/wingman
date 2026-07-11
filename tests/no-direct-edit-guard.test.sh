#!/usr/bin/env bash
# E2E: the PreToolUse guard (#17). Denies direct Edit/Write/NotebookEdit and
# direct test-runner Bash calls at the orchestrator layer (wingman's top-level,
# or a lead), and stays inactive for every worker crew type.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/no-direct-edit-guard.sh"

run_hook() {
  # run_hook <tool_name> <command-or-empty>
  if [ -n "${2:-}" ]; then
    printf '{"tool_name":"%s","tool_input":{"command":"%s"}}' "$1" "$2" | bash "$HOOK"
  else
    printf '{"tool_name":"%s","tool_input":{"file_path":"x.py"}}' "$1" | bash "$HOOK"
  fi
}

# --- top-level wingman (no WINGMAN_CREW_ID at all) ---------------------------
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

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

out="$(run_hook Bash "python3 -m pytest")"
assert_contains "top-level: python3 -m pytest is denied" "$out" '"permissionDecision": "deny"'

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

# --- a lead is also an orchestrator: guarded the same as top-level -----------
export WINGMAN_CREW_ID=lead1 WINGMAN_CREW_TYPE=lead

out="$(run_hook Edit)"
assert_contains "lead: Edit is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "pytest -k foo")"
assert_contains "lead: pytest is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook Bash "git status")"
assert_eq "lead: generic Bash is allowed (no output)" "$out" ""

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

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

test_summary
