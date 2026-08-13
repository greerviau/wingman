#!/usr/bin/env bash
# E2E: hooks/no-foreground-poll-loop-guard.sh (issue #268). Denies a Bash
# command containing an unbounded while/until loop with a sleep invocation
# anywhere in it, unless `run_in_background: true`. Allows a for-loop (self-
# bounding), a bounded while/until with no sleep, and a command that only
# textually resembles the shape (inside a quoted string). Modeled on
# tests/no-foreground-watcher-guard.test.sh's run_hook shape.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/no-foreground-poll-loop-guard.sh"

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

# --- denied: both incidents' own literal command text, and the general shape,
#     with no run_in_background ------------------------------------------------
INSTANCE1='until ! pgrep -f "tests/run.sh" >/dev/null 2>&1; do sleep 5; done; echo "SUITE_DONE"; tail -200 /tmp/full-suite.out'
INSTANCE2='until [ -f .wf_done ]; do sleep 5; done'

for cmd in \
  "$INSTANCE1" \
  "$INSTANCE2" \
  'while true; do sleep 1; done' \
  'until false; do sleep 10; done' \
  'while true; do env sleep 5; done' \
  'while true; do /bin/sleep 5; done' \
  'while true; do echo hi; sleep 5; done'
do
  out="$(run_hook "$cmd" omit)"
  assert_contains "denied (no run_in_background): $cmd" "$out" '"permissionDecision": "deny"'
  assert_contains "denial names the missing timeout: $cmd" "$out" "no independent timeout"
done

# --- denied: run_in_background: false explicitly (not just absent) -----------
out="$(run_hook 'while true; do sleep 1; done' false)"
assert_contains "denied: run_in_background: false is still denied" "$out" '"permissionDecision": "deny"'

# --- allowed: the same set of commands, all WITH run_in_background: true -----
for cmd in \
  "$INSTANCE1" \
  "$INSTANCE2" \
  'while true; do sleep 1; done' \
  'until false; do sleep 10; done' \
  'while true; do env sleep 5; done' \
  'while true; do /bin/sleep 5; done' \
  'while true; do echo hi; sleep 5; done'
do
  out="$(run_hook "$cmd" true)"
  assert_eq "allowed with run_in_background: true: $cmd" "$out" ""
done

# --- allowed: no loop/sleep shape at all --------------------------------------
out="$(run_hook 'echo hello; ls -la; gh pr list' omit)"
assert_eq "allowed: an ordinary multi-command call with neither keyword" "$out" ""

# --- allowed: false-positive checks from the plan's own worked examples ------
out="$(run_hook 'echo "please sleep well, this is not a while loop"' omit)"
assert_eq "allowed: sleep/while text only inside a quoted string" "$out" ""

out="$(run_hook 'while read line; do echo "$line"; done < /tmp/x.txt' omit)"
assert_eq "allowed: a bounded while-read loop with no sleep invocation" "$out" ""

# --- allowed: a bounded while loop with no sleep at all -----------------------
out="$(run_hook 'while [ $i -lt 5 ]; do i=$((i+1)); done' omit)"
assert_eq "allowed: bounded while loop, no sleep segment" "$out" ""
out="$(run_hook 'while [ $i -lt 5 ]; do i=$((i+1)); done' true)"
assert_eq "allowed (rib true too): bounded while loop, no sleep segment" "$out" ""

# --- denied on unparseable input that also mentions the shape ----------------
out="$(run_hook 'until [ -f .wf_done ]; do sleep 5; done; echo "unterminated' omit)"
assert_contains "unterminated quote around a while/sleep mention is denied" "$out" '"permissionDecision": "deny"'
assert_contains "parse-fail denial names the fail-closed rule" "$out" "denied rather than partially checked"

# --- allowed: a for loop with sleep, confirming the deliberate exclusion -----
out="$(run_hook 'for i in 1 2 3; do sleep 1; done' omit)"
assert_eq "allowed: a for-loop is naturally self-bounding" "$out" ""
out="$(run_hook 'for i in 1 2 3; do sleep 1; done' true)"
assert_eq "allowed (rib true too): a for-loop with sleep" "$out" ""

# --- denied: a while/until+sleep loop NESTED inside a for/if block's own
#     do/then, where the enclosing block is not itself a while/until - the
#     loop-opener check must also look at the stripped body's first token,
#     not just the segment's original one, or this shape is invisible
#     (issue #268 PR #271 review round 1) --------------------------------------
for cmd in \
  'for item in a b c; do until grep -q done /tmp/x; do sleep 5; done; done' \
  'if [ -f flag ]; then while ! grep -q done /tmp/x; do sleep 5; done; fi'
do
  out="$(run_hook "$cmd" omit)"
  assert_contains "denied (nested while/until inside for/if): $cmd" "$out" '"permissionDecision": "deny"'
  assert_contains "denial names the missing timeout: $cmd" "$out" "no independent timeout"
  out="$(run_hook "$cmd" true)"
  assert_eq "allowed with run_in_background: true: $cmd" "$out" ""
done

# --- non-Bash payloads exit 0 silently, even when the text matches -----------
out="$(uv run --no-project --quiet python -c '
import json
print(json.dumps({"tool_name": "Write", "tool_input": {"file_path": "x.sh", "content": "while true; do sleep 1; done"}}))
' | bash "$HOOK")"
assert_eq "a non-Bash tool call mentioning the shape is allowed (no output)" "$out" ""

# --- an unrelated command is untouched (cheap pre-gate short-circuits) -------
out="$(run_hook 'gh pr list' omit)"
assert_eq "an unrelated command is allowed (no output)" "$out" ""

# --- failure posture: a non-string command whose coerced text is relevant ----
out="$(uv run --no-project --quiet python -c '
import json
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": ["while true", "sleep 1"], "run_in_background": True}}))
' | bash "$HOOK")"
assert_contains "non-string command mentioning the shape is denied, not allowed" "$out" '"permissionDecision": "deny"'
assert_contains "non-string-command denial names the fail-closed rule" "$out" "denied rather than partially checked"

# --- failure posture: the python decision body raises --------------------
BROKEN_DIR="$(wm_mktemp_dir)"
mkdir -p "$BROKEN_DIR/lib"
cp "$HOOK" "$BROKEN_DIR/no-foreground-poll-loop-guard.sh"
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
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": "while true; do sleep 1; done", "run_in_background": True}}))
' | bash "$BROKEN_DIR/no-foreground-poll-loop-guard.sh")"
assert_contains "an internal error in the decision body denies, not allows" "$out" '"permissionDecision": "deny"'
assert_contains "internal-error denial names the fail-closed rule" "$out" "denied rather than partially checked"

# --- failure posture: the python interpreter itself is unusable --------------
out="$(uv run --no-project --quiet python -c '
import json
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": "while true; do sleep 1; done", "run_in_background": True}}))
' | WM_UV=/bin/false bash "$HOOK")"
assert_contains "a dead interpreter denies a relevant payload (wrapper-level fail-closed)" "$out" '"permissionDecision": "deny"'

# --- the inverse: a broken interpreter must NOT deny an irrelevant command ---
out="$(WM_UV=/bin/false run_hook 'gh pr list' omit)"
assert_eq "an unrelated command is unaffected by a dead interpreter" "$out" ""

test_summary
