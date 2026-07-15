#!/usr/bin/env bash
# E2E: hooks/lib/spawn_pause_guard.py, the shared implementation behind
# every "pause new bin/spawn-crew calls while a fleet-wide condition holds"
# PreToolUse hook (issue #24) - factored out of hooks/api-outage-spawn-
# guard.sh's own original logic (issue #23) so hooks/usage-limit-spawn-
# guard.sh does not duplicate it.
#
# Exercised here through a minimal, throwaway fixture guard
# (tests/fixtures/generic-spawn-pause-guard.sh) with its own synthetic
# state shape ({"blocked": true/false}), override flag (--force-test), and
# message - independent of either real guard's own business rules, so this
# file proves the SHARED machinery works on its own terms: segment
# resolution, parse-fail-closed handling, and fail-open-on-missing/malformed
# state file. tests/api-outage-spawn-guard.test.sh continues to pass
# unmodified as a behavioral-equivalence check that factoring this module
# out of it changed nothing observable.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/tests/fixtures/generic-spawn-pause-guard.sh"
STATE_FILE_DIR="$(wm_mktemp_dir)"
export WM_TEST_STATE_FILE="$STATE_FILE_DIR/state.json"

run_hook() {
  # run_hook <command> [cwd]
  uv run --no-project --quiet python -c '
import json, sys
data = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}
print(json.dumps(data))
' "$1" "${2:-$TEST_REPO}" | bash "$HOOK"
}

set_state() { printf '%s' "$1" > "$WM_TEST_STATE_FILE"; }

# ============================================================================
# No state file at all: fail open, spawn-crew allowed.
# ============================================================================
rm -f "$WM_TEST_STATE_FILE"
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "no state file: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# A malformed (unreadable JSON) state file also fails open.
# ============================================================================
set_state 'not json at all'
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "malformed state file: spawn-crew is allowed (no output)" "$out" ""

# A state file that IS valid JSON but not an object (e.g. a bare list) also
# fails open - is_blocking_state is never even called on a non-dict.
set_state '[1, 2, 3]'
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "non-object state file: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# state.blocked == false: allowed.
# ============================================================================
set_state '{"blocked": false}'
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "blocked=false: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# state.blocked == true: denied, with the caller-supplied message and the
# override flag it was given.
# ============================================================================
set_state '{"blocked": true}'
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_contains "blocked=true: spawn-crew is denied" "$out" '"permissionDecision": "deny"'
assert_contains "the denial carries the caller's own message" "$out" "TEST_DENY"

# Segment resolution: every shape the real guards rely on is caught here too.
out="$(run_hook "bin/spawn-crew --type developer --scope global --objective y")"
assert_contains "a --scope global spawn is denied too" "$out" '"permissionDecision": "deny"'

out="$(run_hook '$WINGMAN_BIN/spawn-crew --type developer --repo x --objective y')"
assert_contains "the \$WINGMAN_BIN/spawn-crew path form is denied too" "$out" '"permissionDecision": "deny"'

out="$(run_hook "cd /tmp && bin/spawn-crew --type developer --repo x --objective y")"
assert_contains "spawn-crew mid-chain is still denied" "$out" '"permissionDecision": "deny"'

# ============================================================================
# The caller-supplied override flag lifts the denial, per-call.
# ============================================================================
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y --force-test")"
assert_eq "the caller's own override flag lifts the denial (no output)" "$out" ""

# A DIFFERENT override flag (not the one this caller registered) does NOT
# lift the denial - proves the flag name is a real parameter, not a hardcoded
# constant leaking from either real guard.
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y --force-during-outage")"
assert_contains "an unrelated override flag does not lift the denial" "$out" '"permissionDecision": "deny"'

# ============================================================================
# blocked=true: an unrelated command is untouched.
# ============================================================================
out="$(run_hook "gh pr list")"
assert_eq "an unrelated command is allowed (no output)" "$out" ""

# ============================================================================
# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56) -
# denied only when the unresolvable command actually mentions spawn-crew.
# ============================================================================
out="$(run_hook "spawn-crew 'oops")"
assert_contains "an unresolvable command mentioning spawn-crew is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "echo 'oops")"
assert_eq "an unresolvable command with no spawn-crew mention is allowed" "$out" ""

test_summary
