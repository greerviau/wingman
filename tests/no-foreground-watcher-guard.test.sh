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
  assert_contains "denial cites issue #202: $cmd" "$out" "issue #202"
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
assert_contains "parse-fail denial cites issue #56" "$out" "issue #56"

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
assert_contains "non-string-command denial cites issue #202" "$out" "issue #202"

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
assert_contains "internal-error denial cites issue #202" "$out" "issue #202"

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
assert_contains "denial cites issue #202" "$out" "issue #202"

out="$(run_hook 'bash /abs/path/to/bin/pr-watch --pr https://github.com/owner/repo/pull/240' true)"
assert_eq "allowed (interpreter-prefix form, run_in_background: true): bash .../pr-watch --pr <url>" "$out" ""

test_summary
