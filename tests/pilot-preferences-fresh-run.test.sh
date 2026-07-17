#!/usr/bin/env bash
# E2E: a genuinely fresh wingman run walks out of the onboarding-preferences
# gate using ONLY the environment a real session is handed and the command the
# documentation tells it to type.
#
# This is the end-to-end fence around issue #49, where the guard denied every
# tool call while instructing an escape hatch ($WINGMAN_STATE pref-set ...)
# that the session could not actually form, because WINGMAN_STATE was never
# exported into wingman's own session. Two properties keep that class of bug
# out, and both are asserted here rather than assumed:
#
#   - The test never re-derives the escape command by hand. It sources the same
#     bin/lib/common.sh that bin/wingman sources, so $WINGMAN_STATE here is the
#     string a real session gets by construction, and it pins the
#     single-definition invariant that makes that legitimate.
#   - Every accepted command is then actually RUN. The guard accepting a shape
#     and the shape working are two different claims, and issue #49 lived in
#     exactly that gap.
#
# The final case removes WINGMAN_STATE from the environment entirely: a run
# whose export is missing for any reason must still be able to escape by doing
# precisely what the denial told it to do.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Drop any ambient WINGMAN_STATE first. The suite may itself be run from inside a
# wingman crew session, which exports one - and inheriting it would make every
# assertion below pass no matter what bin/lib/common.sh does, silently turning
# this whole test into a no-op against the very bug it fences. Sourcing common.sh
# must be the ONLY thing that puts WINGMAN_STATE in this environment.
unset WINGMAN_STATE

# The same file bin/wingman sources on its first line, so WINGMAN_STATE and
# WM_STATE_PY below are the real session-facing values, never a copy.
# shellcheck source=/dev/null
. "$TEST_REPO/bin/lib/common.sh"

GUARD="$TEST_REPO/hooks/pilot-preferences-guard.sh"
TRACKER="$TEST_REPO/hooks/pilot-preferences-ask-tracker.sh"

# --- the environment a real session is given -----------------------------------
assert_true "common.sh exports a non-empty WINGMAN_STATE" '[ -n "$WINGMAN_STATE" ]'
assert_contains "WINGMAN_STATE names the state engine" "$WINGMAN_STATE" "wm-state.py"

# The single-definition invariant that makes sourcing common.sh a legitimate
# stand-in for a real session: bin/wingman must not build a WINGMAN_STATE of its
# own. Reintroduce a second definition there and this test fails rather than
# silently exercising the wrong string.
assert_false "bin/wingman defines no WINGMAN_STATE of its own" \
  "grep -q 'WINGMAN_STATE=' \"$TEST_REPO/bin/wingman\""

SID="sess-fresh-run"

# run_tool <tool_name> <json tool_input body>; run_bash takes a JSON-escaped command.
run_tool() {
  printf '{"tool_name":"%s","session_id":"%s","tool_input":%s}' "$1" "$SID" "$2" | bash "$GUARD"
}
run_bash() { run_tool Bash "{\"command\":\"$1\"}"; }
# JSON-escape a raw shell command so it can be embedded in the payload above.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
# Drive the guard with a raw (unexpanded) shell command, exactly as typed.
run_bash_raw() { run_bash "$(json_escape "$1")"; }

# --- a genuinely fresh run: zero preferences cached -----------------------------
test_new_home
export CLAUDE_PROJECT_DIR="$TEST_REPO"
export WINGMAN_RUN_ID="run-fresh-$$"
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_contains "a fresh run denies Edit" "$out" '"permissionDecision": "deny"'
# The denial must carry a command that works, matched against the REAL values -
# never a literal retyped into this test.
assert_contains "the denial quotes the concrete absolute pref-set command" \
  "$out" "$WM_STATE_PY pref-set"
assert_contains "the denial fills in this run's actual run id" "$out" "$WINGMAN_RUN_ID"
assert_contains "the denial names the \$WINGMAN_STATE form too (it is exported)" \
  "$out" '$WINGMAN_STATE pref-set'

# --- the pilot is asked, and the answers are cached with the documented command --
printf '{"tool_name":"AskUserQuestion","session_id":"%s","tool_input":{"questions":[{"question":"Are you watching this session locally, or over Remote Control right now?","header":"Location","options":[{"label":"Local at this machine"},{"label":"Remote Control"}]}]},"tool_response":{"questions":[{"header":"Location","question":"Are you watching this session locally, or over Remote Control right now?","options":[{"label":"Remote Control","description":"x"},{"label":"Local at this machine","description":"y"}]}],"answers":{"Are you watching this session locally, or over Remote Control right now?":"Local at this machine"}}}' \
  "$SID" | bash "$TRACKER"
assert_true "the ask marker exists once a real AskUserQuestion completed" \
  "[ -f '$WINGMAN_HOME/prefs-asked-$SID' ]"

# For each key: the guard accepts the literal documented shape, AND that same
# literal string actually runs. Single-quoted here so this test's own shell does
# not expand it - the hook, like the real one, receives it unexpanded.
for pair in "remote:false" "artifact_linking:local" "verbosity:concise" "direct_spawn_visibility:each-round" "pr_comments:off"; do
  key="${pair%%:*}"; val="${pair##*:}"
  cmd='$WINGMAN_STATE pref-set --run-id "$WINGMAN_RUN_ID" --key '"$key"' --value '"$val"

  out="$(run_bash_raw "$cmd")"
  assert_eq "the guard accepts the literal documented pref-set for $key" "$out" ""

  # The assertion that would have caught issue #49: accepted is not the same as
  # runnable. Same environment, same string, actually executed.
  bash -c "$cmd" >/dev/null 2>&1
  assert_eq "the same literal string actually runs for $key" "$?" "0"
done

out="$(wm_state prefs-list --run-id "$WINGMAN_RUN_ID")"
assert_contains "remote is now cached" "$out" "remote"
assert_contains "artifact_linking is now cached" "$out" "artifact_linking"
assert_contains "verbosity is now cached" "$out" "verbosity"
assert_contains "direct_spawn_visibility is now cached" "$out" "direct_spawn_visibility"
assert_contains "pr_comments is now cached" "$out" "pr_comments"

out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_eq "the gate is cleared: Edit is allowed" "$out" ""

# --- the denial is actionable even with WINGMAN_STATE missing --------------------
# Part B's load-bearing property: the way out never depends on the variable the
# original bug was about. Here the export is gone, so the literal $WINGMAN_STATE
# shape no longer resolves (a false negative, per cmd_match's stated contract) -
# and the guard must therefore not name it, while still naming a command that works.
test_new_home
export CLAUDE_PROJECT_DIR="$TEST_REPO"
export WINGMAN_RUN_ID="run-fresh-noexport-$$"
SID="sess-fresh-run-noexport"
unset WINGMAN_STATE

out="$(run_bash_raw '$WINGMAN_STATE pref-set --run-id "$WINGMAN_RUN_ID" --key remote --value false')"
assert_contains "with WINGMAN_STATE unset the literal shape is denied (unresolvable)" \
  "$out" '"permissionDecision": "deny"'

out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_contains "Edit is denied" "$out" '"permissionDecision": "deny"'
assert_not_contains "the denial does NOT name a \$WINGMAN_STATE it cannot resolve" \
  "$out" '$WINGMAN_STATE pref-set'
assert_contains "the denial still quotes the concrete absolute command" \
  "$out" "$WM_STATE_PY pref-set"
assert_contains "the denial still fills in the run id" "$out" "$WINGMAN_RUN_ID"

# Do exactly what the denial said: extract its command (never retype it), fill in
# one key/value, and both submit it to the guard and run it.
escape_cmd="$(printf '%s' "$out" | wm_py -c '
import json, sys
d = json.load(sys.stdin)
reason = d["hookSpecificOutput"]["permissionDecisionReason"]
for line in reason.splitlines():
    line = line.strip()
    if "pref-set" in line and line.endswith("--value <value>"):
        print(line.replace("<key>", "remote").replace("<value>", "false"))
        break
')"
assert_contains "the extracted command is the absolute state-engine call" \
  "$escape_cmd" "$WM_STATE_PY pref-set"

printf '{"tool_name":"AskUserQuestion","session_id":"%s","tool_input":{},"tool_response":{}}' \
  "$SID" | bash "$TRACKER"

out="$(run_bash_raw "$escape_cmd")"
assert_eq "the guard accepts the very command its denial printed" "$out" ""

bash -c "$escape_cmd" >/dev/null 2>&1
assert_eq "the command its denial printed actually runs" "$?" "0"

out="$(wm_state pref-get --run-id "$WINGMAN_RUN_ID" --key remote)"
assert_eq "the answer it printed is genuinely cached" "$out" "false"

# The rest of the way out is the same command, so finish the gate with it and
# confirm a stranded-by-a-missing-export run really does get free.
for pair in "artifact_linking:local" "verbosity:concise" "direct_spawn_visibility:each-round" "pr_comments:off"; do
  key="${pair%%:*}"; val="${pair##*:}"
  bash -c "${escape_cmd/--key remote --value false/--key $key --value $val}" >/dev/null 2>&1
done
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_eq "a run with no WINGMAN_STATE export escapes the gate entirely" "$out" ""

unset CLAUDE_PROJECT_DIR WINGMAN_RUN_ID

test_summary
