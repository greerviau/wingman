#!/usr/bin/env bash
# E2E: hooks/api-outage-spawn-guard.sh (issue #23, item 2). Denies
# bin/spawn-crew (any invocation form) while the fleet outage-state reads
# "active", allows it once "clear" (or with no state file at all - fail
# open), and always allows it regardless of state when the one call itself
# carries --force-during-outage. Modeled directly on
# tests/no-merge-guard.test.sh's own run_hook helper and structure.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/api-outage-spawn-guard.sh"

run_hook() {
  # run_hook <command> [cwd]
  uv run --no-project --quiet python -c '
import json, sys
data = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}
print(json.dumps(data))
' "$1" "${2:-$TEST_REPO}" | bash "$HOOK"
}

set_outage_state() {
  # set_outage_state <state>
  printf '{"state": "%s", "since": "2026-07-15T00:00:00.000000Z", "last_signal": null, "signal_count": 0}\n' "$1" \
    > "$WINGMAN_HOME/api-outage-state.json"
}

# ============================================================================
# No state file at all (fresh install): fail open, spawn-crew allowed.
# ============================================================================
test_new_home

out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "no outage-state file: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# State clear: allowed.
# ============================================================================
set_outage_state clear
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "state clear: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# State active: denied, with the reason naming the outage and the escape hatches.
# ============================================================================
set_outage_state active

out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_contains "state active: spawn-crew is denied" "$out" '"permissionDecision": "deny"'
assert_contains "denial cites issue #23" "$out" "issue #23"
assert_contains "denial tells the caller already-running crew are untouched" "$out" "NOT affected by this pause"
assert_contains "denial names the --force-during-outage escape hatch" "$out" "--force-during-outage"

out="$(run_hook "bin/spawn-crew --type developer --scope global --objective y")"
assert_contains "state active: a --scope global spawn is denied too" "$out" '"permissionDecision": "deny"'

# The $WINGMAN_BIN/spawn-crew path form (the shape a lead's own objective
# typically uses) is recognized identically - resolve_command already
# reduces it to the basename "spawn-crew".
out="$(run_hook '$WINGMAN_BIN/spawn-crew --type developer --repo x --objective y')"
assert_contains "state active: \$WINGMAN_BIN/spawn-crew is denied too" "$out" '"permissionDecision": "deny"'

# A command chained with something else - the spawn-crew segment must still
# be caught.
out="$(run_hook "cd /tmp && bin/spawn-crew --type developer --repo x --objective y")"
assert_contains "state active: spawn-crew mid-chain is still denied" "$out" '"permissionDecision": "deny"'

# ============================================================================
# State active, --force-during-outage on the call: always allowed.
# ============================================================================
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y --force-during-outage")"
assert_eq "state active, --force-during-outage: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# State active: an unrelated command is untouched by this guard.
# ============================================================================
out="$(run_hook "gh pr list")"
assert_eq "state active: an unrelated command is allowed (no output)" "$out" ""

out="$(run_hook '$WINGMAN_STATE crew-set --id dev1 --status working --summary "on it"')"
assert_eq "state active: an ordinary crew-set is allowed (no output)" "$out" ""

# ============================================================================
# A malformed state file (unreadable JSON) fails open, matching
# cmd_outage_update's own default for a corrupt/missing file.
# ============================================================================
printf 'not json' > "$WINGMAN_HOME/api-outage-state.json"
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "a malformed state file fails open: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56) -
# this hook must deny on that too, mirroring hooks/no-merge-guard.sh's own
# posture, but only when the unresolvable command actually mentions
# spawn-crew (the substring pre-gate scopes this for every other command).
# ============================================================================
set_outage_state active
out="$(run_hook "spawn-crew 'oops")"
assert_contains "an unresolvable command mentioning spawn-crew is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "echo 'oops")"
assert_eq "an unresolvable command with no spawn-crew mention is allowed (pre-gate skips it)" "$out" ""

test_summary
