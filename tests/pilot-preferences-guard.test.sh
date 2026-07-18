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

# run_bash_json <command> - like run_bash, but the command is JSON-encoded
# via python (not hand-interpolated), so embedded quotes/backslashes/newlines
# (a multi-line command) survive intact instead of corrupting the hand-built
# JSON literal run_bash/run_tool build above.
run_bash_json() {
  uv run --no-project --quiet python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "session_id": sys.argv[2],
                   "tool_input": {"command": sys.argv[1]}}))
' "$1" "$SID" | bash "$GUARD"
}

OUTSIDE_DIR="$(wm_mktemp_dir)"

test_new_home
export CLAUDE_PROJECT_DIR="$TEST_REPO"
export WINGMAN_RUN_ID="run-guard"
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# --- zero of five answered: only the narrow exemptions pass -------------------
out="$(run_tool AskUserQuestion '{}')"
assert_eq "AskUserQuestion is always allowed (no output)" "$out" ""

# The /prefs skill is the one narrow Skill-tool exemption: it exists only to
# run this exact gate, so it must be runnable while the gate is unsatisfied -
# but no other skill gets the same pass.
out="$(run_tool Skill '{"skill":"prefs"}')"
assert_eq "the prefs skill is allowed" "$out" ""

out="$(run_tool Skill '{"skill":"watch"}')"
assert_contains "every other skill still falls through to deny" "$out" '"permissionDecision": "deny"'

out="$(run_tool Skill '{"skill":"status"}')"
assert_contains "an unrelated skill is denied too" "$out" '"permissionDecision": "deny"'

out="$(run_bash "bin/lib/wm-state.py prefs-list --run-id run-guard")"
assert_eq "prefs-list (relative path) is allowed" "$out" ""

# --- issue #56's own regression: a segment that fails to lex must never be
# silently dropped, letting the REST of the command's segments (which happen
# to be allowed on their own) make the guard conclude the whole command is
# allowed. Pre-fix, command_segments() returned only [['bin/crew-list']] -
# the trailing-backslash `touch` line vanished without a trace - so this
# call produced empty stdout (allowed) even though the real Bash tool call
# still executes the touch. Confirmed directly against unfixed main.
ISSUE56_REPRO="$(printf 'bin/crew-list\ntouch /tmp/x_from_issue56 \\\n')"
out="$(run_bash_json "$ISSUE56_REPRO")"
assert_contains "issue #56 repro: the touch segment is now seen and denies the whole call" \
  "$out" '"permissionDecision": "deny"'

# --- command/process-substitution bypasses (r2/r3): an otherwise-allowed
# segment must not smuggle a hidden invocation through a substitution span.
out="$(run_bash 'bin/crew-list $(touch /tmp/x)')"
assert_contains 'bin/crew-list $(touch /tmp/x) is denied (substitution bypass)' \
  "$out" '"permissionDecision": "deny"'

out="$(run_bash 'bin/crew-list `touch /tmp/x`')"
assert_contains 'bin/crew-list `touch /tmp/x` is denied (backtick substitution bypass)' \
  "$out" '"permissionDecision": "deny"'

out="$(run_bash 'bin/crew-list <(touch /tmp/x)')"
assert_contains 'bin/crew-list <(touch /tmp/x) is denied (process-substitution bypass)' \
  "$out" '"permissionDecision": "deny"'

out="$(run_bash 'bin/crew-list >(touch /tmp/x)')"
assert_contains 'bin/crew-list >(touch /tmp/x) is denied (process-substitution bypass)' \
  "$out" '"permissionDecision": "deny"'

# --- fail closed: a genuinely unresolvable command is denied, not treated as
# "no segments, nothing to check".
out="$(run_bash "echo 'oops")"
assert_contains "a genuinely unterminated quote is denied" "$out" '"permissionDecision": "deny"'
assert_contains "the parse-failure denial names the heredoc-quoting remedy verbatim" \
  "$out" "<<'EOF'"

out="$(run_bash "$TEST_REPO/bin/lib/wm-state.py pref-get --run-id run-guard --key remote")"
assert_eq "pref-get (absolute path) is allowed" "$out" ""

# The expanded $WINGMAN_STATE value - uv run with its own leading flags in
# front of the script path - must be recognized (regression test for the
# cmd_match uv flag-skipping fix).
out="$(run_bash "uv run --no-project --quiet $TEST_REPO/bin/lib/wm-state.py prefs-list --run-id run-guard")"
assert_eq "the expanded uv form of prefs-list is allowed" "$out" ""

# The truly literal, UNexpanded `$WINGMAN_STATE ...` string - what the hook
# actually receives, since hooks see the command before shell expansion. With
# the variable exported (bin/wingman exports it for wingman's own session),
# cmd_match expands it from the hook environment and the call is allowed;
# without it, the segment stays unresolved and the deny stands (never a wrong
# allow).
export WINGMAN_STATE="uv run --no-project --quiet $TEST_REPO/bin/lib/wm-state.py"
out="$(run_bash "\$WINGMAN_STATE prefs-list --run-id \\\"\$WINGMAN_RUN_ID\\\"")"
assert_eq "the literal unexpanded \$WINGMAN_STATE prefs-list is allowed" "$out" ""
out="$(WINGMAN_STATE= run_bash "\$WINGMAN_STATE prefs-list --run-id run-guard")"
assert_contains "the literal shape with WINGMAN_STATE unset stays denied" "$out" '"permissionDecision": "deny"'

out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_contains "Edit is denied" "$out" '"permissionDecision": "deny"'
assert_contains "the denial names the remote prompt" "$out" "Remote Control right now"
assert_contains "the denial names the artifact_linking prompt" "$out" "hosted Artifact link"
assert_contains "the denial names the verbosity prompt" "$out" "narrate my own reasoning"
assert_contains "the denial names the direct_spawn_visibility prompt" "$out" "each round of a revise loop"
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
assert_eq "the expanded uv form of pref-set is allowed after the marker" "$out" ""

out="$(run_bash "\$WINGMAN_STATE pref-set --run-id run-guard --key remote --value true")"
assert_eq "the literal unexpanded \$WINGMAN_STATE pref-set is allowed after the marker" "$out" ""

# --- interpreter-wrapper shapes -------------------------------------------------
# A Python interpreter in front of the script resolves to the script, so the
# shape a session improvising the escape hatch from stale memory produces is
# recognized rather than denied as a bare `python`.
out="$(run_bash "uv run --no-project --quiet python $TEST_REPO/bin/lib/wm-state.py pref-set --run-id run-guard --key remote --value true")"
assert_eq "the uv-wrapped interpreter form of pref-set is allowed" "$out" ""

out="$(run_bash "python3 $TEST_REPO/bin/lib/wm-state.py prefs-list --run-id run-guard")"
assert_eq "the bare python3 interpreter form of prefs-list is allowed" "$out" ""

# ...but `-m` and `-c` are never unwrapped: a module and inline code are not
# script invocations, so they resolve to the interpreter and match no allowlist.
out="$(run_bash "uv run --no-project --quiet python -m http.server")"
assert_contains "python -m <module> is not unwrapped (still denied)" "$out" '"permissionDecision": "deny"'

out="$(run_bash "python3 -c 'import os; os.system(\\\"rm -rf /tmp/x\\\")'")"
assert_contains "python -c <code> is not unwrapped (still denied)" "$out" '"permissionDecision": "deny"'

# --- the deny reason quotes a command the guard has verified it accepts ----------
# The core of issue #49: the guard must never instruct a shape its own allowlist
# would reject. The concrete absolute command is always named; the $WINGMAN_STATE
# short form only when it, too, resolves.
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_contains "the denial quotes the concrete absolute pref-set command" \
  "$out" "$TEST_REPO/bin/lib/wm-state.py pref-set"
assert_contains "the denial fills in the actual run id" "$out" "run-guard"
assert_contains "with WINGMAN_STATE exported the denial also names the short form" \
  "$out" '$WINGMAN_STATE pref-set'

out="$(WINGMAN_STATE= run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_contains "with WINGMAN_STATE unset the denial still quotes the absolute command" \
  "$out" "$TEST_REPO/bin/lib/wm-state.py pref-set"
assert_not_contains "with WINGMAN_STATE unset the denial does not name the short form" \
  "$out" '$WINGMAN_STATE pref-set'

# --- fail-open does NOT trigger on the healthy path ------------------------------
# The regression fence around the valve: a normal unanswered run denies, and
# leaves no fail-open marker behind.
assert_contains "a healthy unanswered run still denies" "$out" '"permissionDecision": "deny"'
assert_not_contains "a healthy unanswered run does not fail open" "$out" "FAILED OPEN"
assert_false "no fail-open marker is written on the healthy path" \
  "[ -f '$WINGMAN_HOME/prefs-guard-failopen-$SID' ]"

# --- two of five answered: the denial narrows to what is left ------------------
wm_state pref-set --run-id run-guard --key remote --value true >/dev/null
wm_state pref-set --run-id run-guard --key artifact_linking --value artifact >/dev/null
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_contains "Edit is still denied with two preferences missing" "$out" '"permissionDecision": "deny"'
assert_contains "the denial names one missing prompt (verbosity)" "$out" "narrate my own reasoning"
assert_contains "the denial names the other missing prompt (direct_spawn_visibility)" "$out" "each round of a revise loop"
assert_not_contains "the denial no longer names the answered remote prompt" "$out" "Remote Control right now"
assert_not_contains "the denial no longer names the answered linking prompt" "$out" "hosted Artifact link"

out="$(run_bash "bin/crew-list")"
assert_eq "the Bash exemptions still apply with two missing" "$out" ""

# --- four of five answered: the denial narrows to what is left -----------------
wm_state pref-set --run-id run-guard --key verbosity --value concise >/dev/null
wm_state pref-set --run-id run-guard --key direct_spawn_visibility --value each-round >/dev/null
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_contains "Edit is still denied with one preference missing" "$out" '"permissionDecision": "deny"'
assert_contains "the denial names the one missing prompt (pr_comments)" "$out" "write to GitHub PRs"
assert_not_contains "the denial no longer names the answered verbosity prompt" "$out" "narrate my own reasoning"

# --- all five answered: the guard is a full no-op ------------------------------
wm_state pref-set --run-id run-guard --key pr_comments --value off >/dev/null
out="$(run_tool Edit "{\"file_path\":\"$TEST_REPO/x.py\"}")"
assert_eq "Edit is allowed once all preferences are answered" "$out" ""
out="$(run_bash "git status")"
assert_eq "generic Bash is allowed once all preferences are answered" "$out" ""

# --- fail-open: the state engine is unreadable -----------------------------------
# A guard that denies every tool call while unable to name a way out strands the
# only actor that can satisfy it. With no wm-state.py to run, no preference can
# ever be cached, so the guard must get out of the way - loudly - rather than
# deny forever (issue #49's worst case).
FIXTURE="$(wm_mktemp_dir)/broken-repo"
mkdir -p "$FIXTURE/hooks/lib" "$FIXTURE/bin/lib"   # bin/lib deliberately left empty
cp "$TEST_REPO/hooks/pilot-preferences-guard.sh" "$FIXTURE/hooks/"
cp "$TEST_REPO/hooks/lib/pilot-prefs.sh" "$TEST_REPO/hooks/lib/cmd_match.py" "$FIXTURE/hooks/lib/"

test_new_home
export CLAUDE_PROJECT_DIR="$FIXTURE"
export WINGMAN_RUN_ID="run-broken"
BSID="sess-broken"

broken_edit() {
  printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"/x.py"}}' "$BSID" \
    | bash "$FIXTURE/hooks/pilot-preferences-guard.sh"
}

out="$(broken_edit)"
assert_not_contains "engine unreadable: the call is NOT denied" "$out" '"permissionDecision"'
assert_contains "engine unreadable: a systemMessage is emitted" "$out" "systemMessage"
assert_contains "engine unreadable: it says the guard failed open" "$out" "FAILED OPEN"
assert_true "engine unreadable: the fail-open marker is written" \
  "[ -f '$WINGMAN_HOME/prefs-guard-failopen-$BSID' ]"

out="$(broken_edit)"
assert_eq "engine unreadable: the second call is allowed with no repeat message" "$out" ""

# --- fail-open: the escape hatch does not resolve --------------------------------
# The third condition, isolated: the engine is fine and Python still runs, but
# $WM_UV is a wrapper cmd_match cannot see through, so the guard's own canonical
# pref-set command would not pass its own allowlist. Verified as a genuine probe
# failure (it resolves to the wrapper's basename, not wm-state.py) before the
# guard is asked how it reacts.
RUNNER="$(wm_mktemp_dir)/wm-run.sh"
printf '#!/usr/bin/env bash\nexec uv run --no-project --quiet "$@"\n' > "$RUNNER"
chmod +x "$RUNNER"

probe="$(PYTHONPATH="$TEST_REPO/hooks/lib" uv run --no-project --quiet python -c "
from cmd_match import command_segments, resolve_command
b, _ = resolve_command(command_segments('$RUNNER $TEST_REPO/bin/lib/wm-state.py pref-set')[0])
print(b)")"
assert_eq "the chosen WM_UV override provably fails the probe" "$probe" "wm-run.sh"

test_new_home
export CLAUDE_PROJECT_DIR="$TEST_REPO"
export WINGMAN_RUN_ID="run-probefail"
PSID="sess-probefail"

out="$(printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"/x.py"}}' "$PSID" \
  | WM_UV="$RUNNER" bash "$GUARD")"
assert_not_contains "unresolvable escape hatch: the call is NOT denied" "$out" '"permissionDecision"'
assert_contains "unresolvable escape hatch: it says the guard failed open" "$out" "FAILED OPEN"
assert_contains "unresolvable escape hatch: the reason names the probe failure" \
  "$out" "does not resolve to an allowed shape"
assert_true "unresolvable escape hatch: the fail-open marker is written" \
  "[ -f '$WINGMAN_HOME/prefs-guard-failopen-$PSID' ]"

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
