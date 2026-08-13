#!/usr/bin/env bash
# E2E: hooks/no-foreground-watcher-guard.sh (issue #202). Denies an arming
# bin/watch-fleet/bin/pr-watch Bash call unless `run_in_background: true`,
# and denies every detached form (nohup, setsid, a trailing bare `&`) even
# with it. Allows every read-only/one-shot form regardless, including under
# a timeout/nice wrapper. Modeled on tests/no-worker-spawn-guard.test.sh's
# run_hook shape.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/no-foreground-watcher-guard.sh"

run_hook() {
  # run_hook <command> [rib: true|false|omit (default)]
  uv run --no-project --quiet python -c '
import json, sys
cmd, rib = sys.argv[1], sys.argv[2]
payload = {"tool_name": "Bash", "tool_input": {"command": cmd}}
if rib == "true":
    payload["tool_input"]["run_in_background"] = True
elif rib == "false":
    payload["tool_input"]["run_in_background"] = False
print(json.dumps(payload))
' "$1" "${2:-omit}" | bash "$HOOK"
}

# --- denied: an arming call with no run_in_background ------------------------
for cmd in \
  'bin/watch-fleet' \
  '$WINGMAN_BIN/watch-fleet' \
  'watch-fleet' \
  'bin/watch-fleet --owner ""' \
  'bin/watch-fleet --start' \
  'bin/watch-fleet arm' \
  'bin/pr-watch --pr 5'
do
  export WINGMAN_BIN="$TEST_REPO/bin"
  out="$(run_hook "$cmd" omit)"
  assert_contains "denied (no run_in_background): $cmd" "$out" '"permissionDecision": "deny"'
  assert_contains "denial names the wedge: $cmd" "$out" "wedges this session indefinitely"
done

out="$(run_hook 'bin/watch-fleet' false)"
assert_contains "denied: run_in_background: false is still denied" "$out" '"permissionDecision": "deny"'

# --- denied even WITH run_in_background: true: every detached form -----------
for cmd in \
  'nohup bin/watch-fleet' \
  'setsid bin/watch-fleet' \
  'bin/watch-fleet &' \
  'bin/watch-fleet > /tmp/x 2>&1 &'
do
  out="$(run_hook "$cmd" true)"
  assert_contains "denied even backgrounded (detached): $cmd" "$out" '"permissionDecision": "deny"'
done

# --- allowed: every arming form WITH run_in_background: true (non-detached) --
for cmd in \
  'bin/watch-fleet' \
  '$WINGMAN_BIN/watch-fleet' \
  'watch-fleet' \
  'bin/watch-fleet --owner ""' \
  'bin/watch-fleet --start' \
  'bin/watch-fleet arm' \
  'bin/pr-watch --pr 5'
do
  out="$(run_hook "$cmd" true)"
  assert_eq "allowed with run_in_background: true: $cmd" "$out" ""
done

# --- allowed: read-only/one-shot forms, no run_in_background needed ----------
for cmd in \
  'bin/watch-fleet --status' \
  'bin/watch-fleet --stop' \
  'bin/watch-fleet --classify' \
  'bin/watch-fleet --help' \
  'bin/watch-fleet -h' \
  'bin/pr-watch --pr 5 --once' \
  'bin/pr-watch --help'
do
  out="$(run_hook "$cmd" omit)"
  assert_eq "allowed (read-only, no rib needed): $cmd" "$out" ""
done

# --- allowed: read-only forms under a launcher wrapper (step-1 item-5) -------
out="$(run_hook 'timeout 5 bin/watch-fleet --status' omit)"
assert_eq "allowed: timeout-wrapped --status needs no run_in_background" "$out" ""

out="$(run_hook 'nice bin/watch-fleet --stop' omit)"
assert_eq "allowed: nice-wrapped --stop needs no run_in_background" "$out" ""

# --- an arming call under a non-detached wrapper still needs run_in_background
out="$(run_hook 'timeout 60 bin/watch-fleet' omit)"
assert_contains "denied: timeout-wrapped arming call still needs run_in_background" "$out" '"permissionDecision": "deny"'
out="$(run_hook 'timeout 60 bin/watch-fleet' true)"
assert_eq "allowed: timeout-wrapped arming call with run_in_background: true" "$out" ""

# --- not denied by the & rule for 2>&1 alone ----------------------------------
out="$(run_hook 'bin/watch-fleet 2>&1' true)"
assert_eq "2>&1 alone (no trailing &) is not treated as detached" "$out" ""
out="$(run_hook 'bin/watch-fleet --status 2>&1' omit)"
assert_eq "2>&1 on a read-only form, no rib, is still allowed" "$out" ""

# --- && is not mistaken for a bare backgrounding & ----------------------------
out="$(run_hook 'true && bin/watch-fleet' true)"
assert_eq "&& is not treated as a bare &" "$out" ""

# --- parse-fail-closed on an unresolvable command mentioning watch-fleet -----
out="$(run_hook 'bin/watch-fleet --owner "unterminated' omit)"
assert_contains "unterminated quote around a watch-fleet mention is denied" "$out" '"permissionDecision": "deny"'
assert_contains "parse-fail denial names the fail-closed rule" "$out" "denied rather than partially checked"

# --- non-Bash payloads exit 0 silently ----------------------------------------
out="$(uv run --no-project --quiet python -c '
import json
print(json.dumps({"tool_name": "Read", "tool_input": {"file_path": "bin/watch-fleet"}}))
' | bash "$HOOK")"
assert_eq "a non-Bash tool call is allowed (no output)" "$out" ""

# --- a Bash command that merely MENTIONS watch-fleet/pr-watch is allowed -----
out="$(run_hook 'grep -n watch-fleet bin/watch-fleet' omit)"
assert_eq "a grep mentioning watch-fleet is allowed" "$out" ""
out="$(run_hook 'cat docs/architecture.md | grep pr-watch' omit)"
assert_eq "a pipeline merely mentioning pr-watch is allowed" "$out" ""

# --- an unrelated command is untouched (cheap pre-gate short-circuits) -------
out="$(run_hook 'gh pr list' omit)"
assert_eq "an unrelated command is allowed (no output)" "$out" ""

# --- failure posture (MF1 regressions): each of these currently ALLOWS in the
# naive model hook, and each must be a real DENY here ------------------------

# (1) command is not a string, but its coerced text mentions watch-fleet.
out="$(uv run --no-project --quiet python -c '
import json
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": ["bin/watch-fleet"], "run_in_background": True}}))
' | bash "$HOOK")"
assert_contains "non-string command mentioning watch-fleet is denied, not allowed" "$out" '"permissionDecision": "deny"'
assert_contains "non-string-command denial names the fail-closed rule" "$out" "denied rather than partially checked"

# (2) the python decision body raises (a stubbed, broken cmd_match.py ahead of
# the real one on PYTHONPATH - the hook resolves PYTHONPATH from its OWN
# dirname, so this is driven through a temp copy of the hook alongside a
# broken lib/ sibling, never mutating the real hooks/lib/cmd_match.py).
BROKEN_DIR="$(wm_mktemp_dir)"
mkdir -p "$BROKEN_DIR/lib"
cp "$HOOK" "$BROKEN_DIR/no-foreground-watcher-guard.sh"
cat > "$BROKEN_DIR/lib/cmd_match.py" <<'PYEOF'
def basename(tok):
    raise RuntimeError("boom - broken cmd_match fixture")
def command_segments(cmd_str):
    raise RuntimeError("boom - broken cmd_match fixture")
def resolve_command(tokens):
    raise RuntimeError("boom - broken cmd_match fixture")
PYEOF
out="$(uv run --no-project --quiet python -c '
import json
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": "bin/watch-fleet", "run_in_background": True}}))
' | bash "$BROKEN_DIR/no-foreground-watcher-guard.sh")"
assert_contains "an internal error in the decision body denies, not allows" "$out" '"permissionDecision": "deny"'
assert_contains "internal-error denial names the fail-closed rule" "$out" "denied rather than partially checked"

# (3) the python interpreter itself is unusable (dead/broken $WM_UV): a
# relevant payload denies via the WRAPPER's own exit-status check.
out="$(uv run --no-project --quiet python -c '
import json
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": "bin/watch-fleet", "run_in_background": True}}))
' | WM_UV=/bin/false bash "$HOOK")"
assert_contains "a dead interpreter denies a relevant payload (wrapper-level fail-closed)" "$out" '"permissionDecision": "deny"'

# --- the inverse of (3): a broken interpreter must NOT deny an irrelevant
# command - the cheap textual pre-gate short-circuits before python ever runs,
# so a dead $WM_UV cannot affect a command with no watch-fleet/pr-watch
# mention at all. --------------------------------------------------------------
out="$(WM_UV=/bin/false run_hook 'gh pr list' omit)"
assert_eq "an unrelated command is unaffected by a dead interpreter" "$out" ""

# --- checked-in fixtures: full-envelope PreToolUse payload shapes -----------
# Hand-built (not literally captured from a live transcript), but with the
# full real envelope - session_id/transcript_path/cwd/permission_mode
# alongside hook_event_name/tool_name/tool_input/tool_use_id - so this
# regression-pins the hook's own parsing against the real payload SHAPE, not
# just the two fields the hook itself reads. Does NOT pin the contract
# against a future harness version that stops sending run_in_background at
# all - failing closed covers that, see the hook's own header comment and
# docs/architecture.md.
out="$(bash "$HOOK" < "$TEST_REPO/tests/fixtures/pretooluse-watch-fleet-foreground.json")"
assert_contains "full-envelope foreground fixture is denied" "$out" '"permissionDecision": "deny"'

out="$(bash "$HOOK" < "$TEST_REPO/tests/fixtures/pretooluse-watch-fleet-background.json")"
assert_eq "full-envelope background fixture is allowed (no output)" "$out" ""

# --- issue #241: the incident's literal command shape, pinned ----------------
# The wedge investigated in #241 was NOT a matcher gap (this file already
# covers `bin/pr-watch --pr 5` above, denied/allowed correctly) - it was that
# the guard was never registered on the live machine at all. Still, the
# incident's exact `ps`-rendered shape (a `#!/usr/bin/env bash` script always
# shows as `bash <script> <args>` regardless of how it was actually invoked)
# is worth pinning explicitly rather than left to incidental coverage, so a
# future change to the interpreter-prefix unwrapping in
# hooks/lib/cmd_match.py's resolve_command() cannot silently regress it.
out="$(run_hook 'bash /abs/path/to/bin/pr-watch --pr https://github.com/owner/repo/pull/240' omit)"
assert_contains "denied (interpreter-prefix form, no run_in_background): bash .../pr-watch --pr <url>" "$out" '"permissionDecision": "deny"'
assert_contains "denial names the wedge" "$out" "wedges this session indefinitely"

out="$(run_hook 'bash /abs/path/to/bin/pr-watch --pr https://github.com/owner/repo/pull/240' true)"
assert_eq "allowed (interpreter-prefix form, run_in_background: true): bash .../pr-watch --pr <url>" "$out" ""

# =============================================================================
# issue #198: an arming watch-fleet call is denied outright while a
# spurious-repeated standdown holds for this session's owner - never
# pr-watch, which has no standdown concept - and --clear-standdown is
# allowlisted as the one explicit way out.
# =============================================================================
test_new_home
export WINGMAN_RUN_ID=standdown-test-run
printf '%s\n%s\n' "$WINGMAN_RUN_ID" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch.suppressed"

out="$(run_hook 'bin/watch-fleet' true)"
assert_contains "denied while a run-scoped standdown holds" "$out" '"permissionDecision": "deny"'
assert_contains "denial names the standdown in force" "$out" "A spurious-repeated failure-budget standdown is in force"
assert_contains "denial names --clear-standdown as the way out" "$out" "--clear-standdown"

# Absence is a definite answer: no marker at all allows normally.
rm -f "$WINGMAN_HOME/watch.suppressed"
out="$(run_hook 'bin/watch-fleet' true)"
assert_eq "allowed with no standdown marker present" "$out" ""

# A marker stamped by a DIFFERENT, presumably-ended run reads as inactive -
# the shared wm_run_scoped_marker_active predicate, reimplemented here.
printf '%s\n%s\n' "some-other-run" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch.suppressed"
out="$(run_hook 'bin/watch-fleet' true)"
assert_eq "allowed: a foreign-run standdown marker is treated as inactive" "$out" ""

# Re-arm the CURRENT-run marker for the remaining checks in this section.
printf '%s\n%s\n' "$WINGMAN_RUN_ID" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch.suppressed"

# The read-only/one-shot forms, including --clear-standdown itself, stay
# allowed while the standdown holds - it is the explicit, pilot-directed way
# out, never itself classified as arming.
for cmd in \
  'bin/watch-fleet --status' \
  'bin/watch-fleet --stop' \
  'bin/watch-fleet --classify' \
  'bin/watch-fleet --clear-standdown'
do
  out="$(run_hook "$cmd" omit)"
  assert_eq "allowed while suppressed (read-only/one-shot): $cmd" "$out" ""
done

# bin/pr-watch has no standdown concept - unaffected by a watch-fleet marker.
out="$(run_hook 'bin/pr-watch --pr 5' true)"
assert_eq "pr-watch arming is unaffected by a watch-fleet standdown marker" "$out" ""

unset WINGMAN_RUN_ID
rm -f "$WINGMAN_HOME/watch.suppressed"

# --- owner scoping: a crew session is gated by its own owner-keyed marker,
# never by the unscoped one, and vice versa ----------------------------------
test_new_home
printf '%s\n%s\n' "" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch-leadx.suppressed"
out="$(WINGMAN_CREW_ID=leadx run_hook 'bin/watch-fleet' true)"
assert_contains "a crew session (WINGMAN_CREW_ID=leadx) is gated by its own owner-scoped marker" "$out" '"permissionDecision": "deny"'
rm -f "$WINGMAN_HOME/watch-leadx.suppressed"

printf '%s\n%s\n' "" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch.suppressed"
out="$(WINGMAN_CREW_ID=leadx run_hook 'bin/watch-fleet' true)"
assert_eq "an owner-scoped (leadx) session is unaffected by the unscoped marker" "$out" ""
rm -f "$WINGMAN_HOME/watch.suppressed"

# --- MUST-FIX 3 (plan review): the command's own --owner must win over
# $WINGMAN_CREW_ID, matching bin/watch-fleet's own precedence - otherwise the
# marker the guard checks and the cycle the command actually arms can be
# different owners ------------------------------------------------------------
test_new_home

# Bypass direction: WINGMAN_CREW_ID=leadx is under no standdown of its own,
# but the command explicitly targets the unscoped owner ("") while THAT
# owner's standdown holds. Checking only $WINGMAN_CREW_ID would find nothing
# and wrongly allow - reopening R1's loop through the arm this session is
# actually about to perform.
printf '%s\n%s\n' "" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch.suppressed"
out="$(WINGMAN_CREW_ID=leadx run_hook 'bin/watch-fleet --owner ""' true)"
assert_contains "an explicit --owner \"\" is gated by the unscoped marker even though WINGMAN_CREW_ID=leadx" "$out" '"permissionDecision": "deny"'
rm -f "$WINGMAN_HOME/watch.suppressed"

# False-deny direction: WINGMAN_CREW_ID=leadx is itself under a standdown,
# but the command explicitly targets a different, healthy owner. Checking
# only $WINGMAN_CREW_ID would find leadx's own marker and wrongly deny an arm
# of an unrelated, un-suppressed cycle.
printf '%s\n%s\n' "" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch-leadx.suppressed"
out="$(WINGMAN_CREW_ID=leadx run_hook 'bin/watch-fleet --owner otherowner' true)"
assert_eq "an explicit --owner otherowner is unaffected by leadx's own standdown" "$out" ""
rm -f "$WINGMAN_HOME/watch-leadx.suppressed"

# --- fail-closed posture: an unreadable $WINGMAN_HOME denies; a merely
# absent marker is a different, definite answer and still allows ------------
test_new_home
chmod 000 "$WINGMAN_HOME"
out="$(run_hook 'bin/watch-fleet' true)"
assert_contains "an unreadable WINGMAN_HOME denies (fail-closed)" "$out" '"permissionDecision": "deny"'
chmod 755 "$WINGMAN_HOME"

# --- issue #331, cross-file-agreement nice-to-have: this guard is entirely
# unaffected by #331 (it derives the marker path and denies independently of
# crew-set/roster state, exercised throughout this file already) - but at the
# moment it denies an arm attempt, crew-get for the same owner should ALSO
# show blocked, i.e. the two independent signals (tool-level denial,
# status-level visibility) agree during the same standdown without either
# depending on the other. Calls wm_assert_standdown_blocked directly (the
# same helper hooks/stop-continuity.sh and hooks/stop-guard.sh call) rather
# than going through a full Stop-hook invocation, matching this file's own
# narrow focus on the guard alone.
test_new_home
wm_state crew-add --id leadg --type lead --objective x --repo /tmp --window wm-leadg --session-id s-leadg >/dev/null
wm_state crew-set --id leadg --status working --summary busy >/dev/null
printf '%s\n%s\n' "" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch-leadg.suppressed"
(
  WM_HOME="$WINGMAN_HOME"
  WM_UV="uv run --no-project --quiet"
  STATE_PY="$TEST_REPO/bin/lib/wm-state.py"
  . "$TEST_REPO/hooks/lib/watcher-liveness.sh"
  wm_assert_standdown_blocked leadg "$WINGMAN_HOME/watch-leadg.suppressed"
)
out="$(WINGMAN_CREW_ID=leadg run_hook 'bin/watch-fleet' true)"
assert_contains "the guard denies leadg's own arm attempt while the marker holds" "$out" '"permissionDecision": "deny"'
assert_contains "crew-get for leadg agrees: status is blocked at the same moment" "$(wm_state crew-get --id leadg)" "\"status\": \"blocked\""
rm -f "$WINGMAN_HOME/watch-leadg.suppressed"

test_summary
