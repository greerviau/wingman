#!/usr/bin/env bash
# E2E: hooks/usage-limit-spawn-guard.sh (issue #24). Denies bin/spawn-crew
# (any invocation form) while the fleet usage-quota-approach state reads
# "approaching" or "paused", allows it once "clear"/"acknowledged" (or with
# no state file at all - fail open), and always allows it regardless of
# state when the one call itself carries --force-during-usage-limit.
# Modeled directly on tests/api-outage-spawn-guard.test.sh's own run_hook
# helper and structure - the twin guard this one shares its machinery with
# (hooks/lib/spawn_pause_guard.py).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/usage-limit-spawn-guard.sh"

run_hook() {
  # run_hook <command> [cwd]
  uv run --no-project --quiet python -c '
import json, sys
data = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}
print(json.dumps(data))
' "$1" "${2:-$TEST_REPO}" | bash "$HOOK"
}

set_usage_state() {
  # set_usage_state <state> [window]
  printf '{"state": "%s", "window": "%s", "used_percentage": 85, "resets_at": 9999999999, "since": "2026-07-15T00:00:00.000000Z", "decided_at": null}\n' \
    "$1" "${2:-five_hour}" > "$WINGMAN_HOME/usage-limit-state.json"
}

# ============================================================================
# No state file at all (fresh install): fail open, spawn-crew allowed.
# ============================================================================
test_new_home

out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "no usage-state file: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# State clear: allowed.
# ============================================================================
set_usage_state clear
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "state clear: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# State acknowledged (pilot said "continue anyway"): allowed.
# ============================================================================
set_usage_state acknowledged
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "state acknowledged: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# State approaching: denied, with the reason naming the issue, the window,
# and the escape hatches.
# ============================================================================
set_usage_state approaching five_hour

out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_contains "state approaching: spawn-crew is denied" "$out" '"permissionDecision": "deny"'
assert_contains "denial cites issue #24" "$out" "issue #24"
assert_contains "denial names the window" "$out" "5-hour"
assert_contains "denial tells the caller already-running crew are untouched" "$out" "NOT affected by this pause"
assert_contains "denial notes in-flight work can still hit the hard limit" "$out" "hard limit"
assert_contains "denial names the --force-during-usage-limit escape hatch" "$out" "--force-during-usage-limit"

out="$(run_hook "bin/spawn-crew --type developer --scope global --objective y")"
assert_contains "state approaching: a --scope global spawn is denied too" "$out" '"permissionDecision": "deny"'

# The $WINGMAN_BIN/spawn-crew path form is recognized identically -
# resolve_command already reduces it to the basename "spawn-crew".
out="$(run_hook '$WINGMAN_BIN/spawn-crew --type developer --repo x --objective y')"
assert_contains "state approaching: \$WINGMAN_BIN/spawn-crew is denied too" "$out" '"permissionDecision": "deny"'

# A command chained with something else - the spawn-crew segment must still
# be caught.
out="$(run_hook "cd /tmp && bin/spawn-crew --type developer --repo x --objective y")"
assert_contains "state approaching: spawn-crew mid-chain is still denied" "$out" '"permissionDecision": "deny"'

# The seven_day window gets its own label in the message too.
set_usage_state approaching seven_day
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_contains "state approaching (seven_day): denial names the 7-day window" "$out" "7-day"

# ============================================================================
# State paused (pilot said "wait"): denied, same as approaching.
# ============================================================================
set_usage_state paused
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_contains "state paused: spawn-crew is denied" "$out" '"permissionDecision": "deny"'
assert_contains "denial names the --force-during-usage-limit escape hatch" "$out" "--force-during-usage-limit"

# ============================================================================
# State approaching/paused, --force-during-usage-limit on the call: always
# allowed.
# ============================================================================
set_usage_state approaching
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y --force-during-usage-limit")"
assert_eq "state approaching, --force-during-usage-limit: spawn-crew is allowed (no output)" "$out" ""

set_usage_state paused
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y --force-during-usage-limit")"
assert_eq "state paused, --force-during-usage-limit: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# State approaching: an unrelated command is untouched by this guard.
# ============================================================================
set_usage_state approaching
out="$(run_hook "gh pr list")"
assert_eq "state approaching: an unrelated command is allowed (no output)" "$out" ""

out="$(run_hook '$WINGMAN_STATE crew-set --id dev1 --status working --summary "on it"')"
assert_eq "state approaching: an ordinary crew-set is allowed (no output)" "$out" ""

# ============================================================================
# A malformed state file (unreadable JSON) fails open, matching
# cmd_usage_update's own default for a corrupt/missing file.
# ============================================================================
printf 'not json' > "$WINGMAN_HOME/usage-limit-state.json"
out="$(run_hook "bin/spawn-crew --type developer --repo x --objective y")"
assert_eq "a malformed state file fails open: spawn-crew is allowed (no output)" "$out" ""

# ============================================================================
# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56) -
# this hook must deny on that too, mirroring the outage guard's own posture,
# but only when the unresolvable command actually mentions spawn-crew (the
# substring pre-gate scopes this for every other command).
# ============================================================================
set_usage_state approaching
out="$(run_hook "spawn-crew 'oops")"
assert_contains "an unresolvable command mentioning spawn-crew is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "echo 'oops")"
assert_eq "an unresolvable command with no spawn-crew mention is allowed (pre-gate skips it)" "$out" ""

test_summary
