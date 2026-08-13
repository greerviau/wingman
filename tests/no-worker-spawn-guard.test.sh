#!/usr/bin/env bash
# E2E: hooks/no-worker-spawn-guard.sh (issue #212, recommendation 3). Denies
# bin/spawn-crew (any invocation form) from a worker-type crew session, and
# denies a LEAD spawning a further lead too; allows a lead spawning a
# worker, and allows wingman's own top-level session (no WINGMAN_CREW_ID at
# all) to spawn anything.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/no-worker-spawn-guard.sh"

run_hook() {
  # run_hook <command>
  uv run --no-project --quiet python -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$1" | bash "$HOOK"
}

# --- wingman's own top-level session (no WINGMAN_CREW_ID at all): allowed ---
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE
out="$(run_hook "bin/spawn-crew --type lead --repo x --objective y")"
assert_eq "top-level: spawning a lead is allowed (no output)" "$out" ""
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "top-level: spawning a developer is allowed (no output)" "$out" ""

# --- a lead: spawning a worker is allowed, bare and qualified type alike ----
export WINGMAN_CREW_ID=lead1 WINGMAN_CREW_TYPE=lead
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "lead: spawning a developer is allowed (no output)" "$out" ""

export WINGMAN_CREW_TYPE=common/lead
out="$(run_hook "bin/spawn-crew --type reviewer --repo x --objective y")"
assert_eq "qualified-type lead (common/lead): spawning a reviewer is allowed (no output)" "$out" ""

# --- a lead spawning a FURTHER LEAD is denied - the other half of the depth
# cap (CLAUDE.md: "a lead spawns workers but not further leads"), bare and
# qualified target-type alike. -----------------------------------------------
export WINGMAN_CREW_TYPE=lead
out="$(run_hook "bin/spawn-crew --type lead --repo x --objective y")"
assert_contains "lead: spawning a further lead is denied" "$out" '"permissionDecision": "deny"'
assert_contains "lead-spawns-lead denial names the depth cap" "$out" "A lead may not spawn a further lead"

out="$(run_hook "bin/spawn-crew --type common/lead --repo x --objective y")"
assert_contains "lead: spawning a qualified-type further lead (common/lead) is denied" "$out" '"permissionDecision": "deny"'

# --- every worker crew type: denied outright, for any target type ----------
for wtype in developer architect reviewer software-analyst research; do
  export WINGMAN_CREW_ID=w1 WINGMAN_CREW_TYPE="$wtype"

  out="$(run_hook "bin/spawn-crew --type reviewer --repo x --objective y")"
  assert_contains "$wtype: spawning a reviewer is denied" "$out" '"permissionDecision": "deny"'
  assert_contains "$wtype: denial names the restriction" "$out" "Spawning crew is not yours to do from a"
  assert_contains "$wtype: denial points at --status blocked" "$out" "--status blocked"

  # $WINGMAN_BIN/spawn-crew form (a lead's own objective-composition idiom) -
  # recognized identically, resolve_command reduces it to "spawn-crew".
  out="$(run_hook '$WINGMAN_BIN/spawn-crew --type reviewer --repo x --objective y')"
  assert_contains "$wtype: \$WINGMAN_BIN/spawn-crew is denied too" "$out" '"permissionDecision": "deny"'

  # A worker attempting to spawn a LEAD (escalating its own depth) is denied
  # exactly the same as spawning any other worker type - the worker check
  # runs before the target-type check.
  out="$(run_hook "bin/spawn-crew --type lead --repo x --objective y")"
  assert_contains "$wtype: spawning a lead is denied too" "$out" '"permissionDecision": "deny"'

  # Chained in a longer command - the spawn-crew segment must still be caught.
  out="$(run_hook "cd /tmp && bin/spawn-crew --type reviewer --repo x --objective y")"
  assert_contains "$wtype: spawn-crew mid-chain is still denied" "$out" '"permissionDecision": "deny"'

  # An unrelated command is untouched.
  out="$(run_hook "gh pr list")"
  assert_eq "$wtype: an unrelated command is allowed (no output)" "$out" ""
done

# --- a real crew session with WINGMAN_CREW_ID set but WINGMAN_CREW_TYPE
# unset: fails CLOSED (treated as a worker), the opposite fallback from
# no-direct-edit-guard.sh's same-shaped case. -------------------------------
export WINGMAN_CREW_ID=w2
unset WINGMAN_CREW_TYPE
out="$(run_hook "bin/spawn-crew --type reviewer --repo x --objective y")"
assert_contains "unset crew type on a real session: spawn-crew is denied (fail closed)" "$out" '"permissionDecision": "deny"'

# --- cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56),
# but only when the unresolvable command actually mentions spawn-crew. ------
export WINGMAN_CREW_ID=w3 WINGMAN_CREW_TYPE=developer
out="$(run_hook "spawn-crew 'oops")"
assert_contains "an unresolvable command mentioning spawn-crew is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "echo 'oops")"
assert_eq "an unresolvable command with no spawn-crew mention is allowed (pre-gate skips it)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

test_summary
