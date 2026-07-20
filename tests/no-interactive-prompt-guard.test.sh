#!/usr/bin/env bash
# E2E: hooks/no-interactive-prompt-guard.sh (issue #155). Denies
# AskUserQuestion/EnterPlanMode/ExitPlanMode outright for every crew session
# (WINGMAN_CREW_ID set, worker or lead) - nobody watches a crew pane in real
# time to answer an interactive prompt - and stays inactive for wingman's own
# top-level session (no WINGMAN_CREW_ID at all) and for every other tool.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/no-interactive-prompt-guard.sh"

run_hook() {
  # run_hook <tool_name>
  uv run --no-project --quiet python -c '
import json, sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": {}}))
' "$1" | bash "$HOOK"
}

# --- top-level wingman (no WINGMAN_CREW_ID at all): every tool passes -------
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

out="$(run_hook AskUserQuestion)"
assert_eq "top-level: AskUserQuestion is not denied" "$out" ""

out="$(run_hook EnterPlanMode)"
assert_eq "top-level: EnterPlanMode is not denied" "$out" ""

out="$(run_hook ExitPlanMode)"
assert_eq "top-level: ExitPlanMode is not denied" "$out" ""

# --- a worker crew session (developer): all three are denied ----------------
export WINGMAN_CREW_ID=dev-1
unset WINGMAN_CREW_TYPE

out="$(run_hook AskUserQuestion)"
assert_contains "developer: AskUserQuestion is denied" "$out" '"permissionDecision": "deny"'
assert_contains "developer: denial names the tool" "$out" "AskUserQuestion is not yours to call"
assert_contains "developer: denial names the blocked escalation" "$out" "--status blocked"
assert_contains "developer: denial cites the issue" "$out" "issue #155"

out="$(run_hook EnterPlanMode)"
assert_contains "developer: EnterPlanMode is denied" "$out" '"permissionDecision": "deny"'
assert_contains "developer: EnterPlanMode denial names the tool" "$out" "EnterPlanMode is not yours to call"

out="$(run_hook ExitPlanMode)"
assert_contains "developer: ExitPlanMode is denied" "$out" '"permissionDecision": "deny"'
assert_contains "developer: ExitPlanMode denial names the tool" "$out" "ExitPlanMode is not yours to call"

# --- a lead's own crew session: also denied (a lead is a crew session too) --
export WINGMAN_CREW_ID=lead-1
export WINGMAN_CREW_TYPE=lead

out="$(run_hook AskUserQuestion)"
assert_contains "lead: AskUserQuestion is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook EnterPlanMode)"
assert_contains "lead: EnterPlanMode is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook ExitPlanMode)"
assert_contains "lead: ExitPlanMode is denied" "$out" '"permissionDecision": "deny"'

unset WINGMAN_CREW_TYPE

# --- every other tool passes through untouched, even inside a crew session -
out="$(run_hook Bash)"
assert_eq "developer: Bash is untouched" "$out" ""

out="$(run_hook Edit)"
assert_eq "developer: Edit is untouched" "$out" ""

out="$(run_hook Read)"
assert_eq "developer: Read is untouched" "$out" ""

out="$(run_hook TaskCreate)"
assert_eq "developer: TaskCreate is untouched" "$out" ""

unset WINGMAN_CREW_ID

test_summary
