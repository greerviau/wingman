#!/usr/bin/env bash
# E2E: hooks/pilot-preferences-guard.sh, the PreToolUse gate enforcing
# CLAUDE.md's "Confirm onboarding preferences (once per run)" step. While any
# required preference is unanswered for the run, every tool call is denied
# except: AskUserQuestion, read-only preference checks (prefs-list/pref-get),
# pref-set (only after a real AskUserQuestion completed this session), and the
# fleet-supervision commands stop-guard.sh itself directs the session to run
# (crew-list, arming watch-fleet, arming crew-ask await, reading
# $WINGMAN_HOME/wake).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

GUARD="$TEST_REPO/hooks/pilot-preferences-guard.sh"
TRACKER="$TEST_REPO/hooks/pilot-preferences-ask-tracker.sh"
SID="sess-guard-test"

# run_tool <tool_name> <json-escaped tool_input body>
run_tool() {
  printf '{"tool_name":"%s","session_id":"%s","tool_input":%s}' "$1" "$SID" "$2" | bash "$GUARD"
}
run_bash() { run_tool Bash "{\"command\":\"$1\"}"; }

OUTSIDE_DIR="$(mktemp -d)"
trap 'rm -rf "$OUTSIDE_DIR"' EXIT

test_new_home
export CLAUDE_PROJECT_DIR="$TEST_REPO"
export WINGMAN_RUN_ID="run-guard"
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# --- zero of three answered: only the narrow exemptions pass -------------------
out="$(run_tool AskUserQuestion '{}')"
assert_eq "AskUserQuestion is always allowed (no output)" "$out" ""

out="$(run_bash "bin/lib/wm-state.py prefs-list --run-id run-guard")"
assert_eq "prefs-list (relative path) is allowed" "$out" ""

out="$(run_bash "$TEST_REPO/bin/lib/wm-state.py pref-get --run-id run-guard --key remote")"
assert_eq "pref-get (absolute path) is allowed" "$out" ""

# The literal exported $WINGMAN_STATE form - uv run with its own leading flags
# in front of the script path - must be recognized too (the shape CLAUDE.md
# itself tells the session to run; regression test for the cmd_match uv fix).
out="$(run_bash "uv run --no-project --quiet $TEST_REPO/bin/lib/wm-state.py prefs-list --run-id run-guard")"
assert_eq "the literal \$WINGMAN_STATE form of prefs-list is allowed" "$out" ""

out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_contains "Edit is denied" "$out" '"permissionDecision": "deny"'
assert_contains "the denial names the remote prompt" "$out" "Remote Control right now"
assert_contains "the denial names the artifact_linking prompt" "$out" "hosted Artifact link"
assert_contains "the denial names the verbosity prompt" "$out" "narrate my own reasoning"
assert_contains "the denial points at the batched ask" "$out" "AskUserQuestion"

out="$(run_tool Write "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_contains "Write is denied" "$out" '"permissionDecision": "deny"'

out="$(run_tool Read "{\"file_path\":\"$TEST_REPO/README.md\"}")"
assert_contains "Read of an unrelated path is denied" "$out" '"permissionDecision": "deny"'

out="$(run_tool Task '{"prompt":"x"}')"
assert_contains "Task is denied" "$out" '"permissionDecision": "deny"'

out="$(run_bash "git status")"
assert_contains "an unrelated Bash command is denied" "$out" '"permissionDecision": "deny"'

out="$(run_bash "bin/lib/wm-state.py pref-set --run-id run-guard --key remote --value true && rm -rf /tmp/x")"
assert_contains "a chained pref-set does not qualify (mixed segments denied)" "$out" '"permissionDecision": "deny"'

# --- fleet supervision stays possible while the gate is unsatisfied ------------
out="$(run_bash "bin/crew-list")"
assert_eq "bin/crew-list is allowed" "$out" ""

out="$(run_bash "$TEST_REPO/bin/watch-fleet")"
assert_eq "arming bin/watch-fleet is allowed" "$out" ""

out="$(run_bash "bin/crew-ask await --id req-1")"
assert_eq "arming bin/crew-ask await is allowed" "$out" ""

out="$(run_bash "bin/crew-say w1 relaying-the-answer")"
assert_contains "bin/crew-say is still denied (deliberate exclusion)" "$out" '"permissionDecision": "deny"'

out="$(run_tool Read "{\"file_path\":\"$WINGMAN_HOME/wake\"}")"
assert_eq "Read of \$WINGMAN_HOME/wake is allowed" "$out" ""

# --- pref-set requires a completed AskUserQuestion first (self-answer gap) -----
out="$(run_bash "bin/lib/wm-state.py pref-set --run-id run-guard --key remote --value true")"
assert_contains "pref-set before any AskUserQuestion is denied" "$out" '"permissionDecision": "deny"'
assert_contains "the pref-set denial demands a real question first" "$out" "never invented"

printf '{"tool_name":"AskUserQuestion","session_id":"%s","tool_input":{},"tool_response":{}}' "$SID" | bash "$TRACKER"
assert_true "the ask-tracker marker exists after an AskUserQuestion completes" \
  "[ -f '$WINGMAN_HOME/prefs-asked-$SID' ]"

out="$(run_bash "bin/lib/wm-state.py pref-set --run-id run-guard --key remote --value true")"
assert_eq "pref-set after the ask marker is allowed" "$out" ""

out="$(run_bash "uv run --no-project --quiet $TEST_REPO/bin/lib/wm-state.py pref-set --run-id run-guard --key remote --value true")"
assert_eq "the literal \$WINGMAN_STATE form of pref-set is allowed after the marker" "$out" ""

# --- two of three answered: the denial narrows to what is left -----------------
wm_state pref-set --run-id run-guard --key remote --value true >/dev/null
wm_state pref-set --run-id run-guard --key artifact_linking --value artifact >/dev/null
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_contains "Edit is still denied with one preference missing" "$out" '"permissionDecision": "deny"'
assert_contains "the denial names the one missing prompt" "$out" "narrate my own reasoning"
assert_not_contains "the denial no longer names the answered remote prompt" "$out" "Remote Control right now"
assert_not_contains "the denial no longer names the answered linking prompt" "$out" "hosted Artifact link"

out="$(run_bash "bin/crew-list")"
assert_eq "the Bash exemptions still apply with one missing" "$out" ""

# --- all three answered: the guard is a full no-op ------------------------------
wm_state pref-set --run-id run-guard --key verbosity --value concise >/dev/null
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_eq "Edit is allowed once all preferences are answered" "$out" ""
out="$(run_bash "git status")"
assert_eq "generic Bash is allowed once all preferences are answered" "$out" ""

# --- inactive shapes -------------------------------------------------------------
test_new_home
export CLAUDE_PROJECT_DIR="$TEST_REPO"

unset WINGMAN_RUN_ID
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_eq "no WINGMAN_RUN_ID (not launched via bin/wingman): no-op" "$out" ""

export WINGMAN_RUN_ID="run-guard2"
export WINGMAN_CREW_ID=w1 WINGMAN_CREW_TYPE=developer
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_eq "a worker crew session: no-op" "$out" ""

export WINGMAN_CREW_ID=lead1 WINGMAN_CREW_TYPE=lead
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_eq "a lead crew session: no-op (leads never do the eager ask)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE
export CLAUDE_PROJECT_DIR="$OUTSIDE_DIR"
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_eq "a non-wingman project root: no-op" "$out" ""

unset CLAUDE_PROJECT_DIR WINGMAN_RUN_ID

test_summary
