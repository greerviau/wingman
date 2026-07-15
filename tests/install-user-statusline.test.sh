#!/usr/bin/env bash
# E2E: bin/lib/install-user-statusline.py, the idempotent installer bin/doctor
# uses to register wingman's usage-quota capture script as the user-level
# `statusLine` command (issue #24). Every settings.json path here is a
# throwaway tmp file - never the real developer machine's
# ~/.claude/settings.json. Mirrors tests/install-user-hook.test.sh's own
# coverage shape.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

INSTALLER="$TEST_REPO/bin/lib/install-user-statusline.py"
SCRIPT_PATH="$TEST_REPO/bin/lib/usage-statusline.py"

run_installer() { uv run --no-project --quiet "$INSTALLER" "$@"; }

WORK="$(wm_mktemp_dir)"

# --- fresh install (no prior statusLine at all) -------------------------------
SETTINGS="$WORK/settings.json"

if run_installer --settings "$SETTINGS" --script "$SCRIPT_PATH" --check >/dev/null 2>&1; then
  fail "fresh settings file: --check reports registered before install"
else
  ok "fresh settings file: --check reports not registered before install"
fi

out="$(run_installer --settings "$SETTINGS" --script "$SCRIPT_PATH")"
assert_contains "install reports registered" "$out" "registered"
assert_true "settings file now exists" "[ -f '$SETTINGS' ]"

cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS'))
print(d['statusLine']['command'])
")"
assert_eq "installed command invokes our script directly (no prior command to chain)" \
  "$cmd" "uv run --no-project --quiet $SCRIPT_PATH"

typ="$(uv run --no-project --quiet python -c "
import json
print(json.load(open('$SETTINGS'))['statusLine']['type'])
")"
assert_eq "statusLine.type is command" "$typ" "command"

if run_installer --settings "$SETTINGS" --script "$SCRIPT_PATH" --check >/dev/null 2>&1; then
  ok "after install: --check reports registered"
else
  fail "after install: --check reports registered"
fi

# --- idempotent: re-running is a no-op, does not double-wrap ------------------
out2="$(run_installer --settings "$SETTINGS" --script "$SCRIPT_PATH")"
assert_contains "re-running reports already registered" "$out2" "already registered"
cmd2="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS'))
print(d['statusLine']['command'])
")"
assert_eq "re-running leaves the command unchanged" "$cmd2" "$cmd"

# --- a pilot's pre-existing custom statusline is CHAINED, not clobbered ------
SETTINGS_CHAIN="$WORK/settings-chain.json"
cat > "$SETTINGS_CHAIN" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/my-custom-statusline.sh",
    "refreshInterval": 5
  }
}
JSON

out3="$(run_installer --settings "$SETTINGS_CHAIN" --script "$SCRIPT_PATH")"
assert_contains "install reports it chained to the prior command" "$out3" "chained"

chained_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_CHAIN'))
print(d['statusLine']['command'])
")"
assert_contains "the new command invokes our script" "$chained_cmd" "$SCRIPT_PATH"
assert_contains "the new command carries --chain" "$chained_cmd" "--chain"
assert_contains "the new command preserves the pilot's original command, shell-quoted" \
  "$chained_cmd" "~/.claude/my-custom-statusline.sh"

refresh="$(uv run --no-project --quiet python -c "
import json
print(json.load(open('$SETTINGS_CHAIN'))['statusLine'].get('refreshInterval'))
")"
assert_eq "refreshInterval is left untouched" "$refresh" "5"

if run_installer --settings "$SETTINGS_CHAIN" --script "$SCRIPT_PATH" --check >/dev/null 2>&1; then
  ok "after chaining install: --check reports registered"
else
  fail "after chaining install: --check reports registered"
fi

# Re-running against the now-chained settings is a no-op (does not re-chain
# our own already-chained command into itself).
out4="$(run_installer --settings "$SETTINGS_CHAIN" --script "$SCRIPT_PATH")"
assert_contains "re-running against an already-chained entry is a no-op" "$out4" "already registered"
chained_cmd2="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_CHAIN'))
print(d['statusLine']['command'])
")"
assert_eq "the command is unchanged by the no-op re-run" "$chained_cmd2" "$chained_cmd"

# --- merges additively: unrelated top-level settings are preserved -----------
SETTINGS_MERGE="$WORK/settings-merge.json"
cat > "$SETTINGS_MERGE" <<'JSON'
{"theme": "dark", "otherSetting": 42}
JSON
run_installer --settings "$SETTINGS_MERGE" --script "$SCRIPT_PATH" >/dev/null
theme="$(uv run --no-project --quiet python -c "
import json
print(json.load(open('$SETTINGS_MERGE'))['theme'])
")"
assert_eq "unrelated top-level key is preserved" "$theme" "dark"

# --- refuses to clobber invalid JSON ------------------------------------------
SETTINGS_BROKEN="$WORK/settings-broken.json"
printf 'not valid json{' > "$SETTINGS_BROKEN"
if run_installer --settings "$SETTINGS_BROKEN" --script "$SCRIPT_PATH" >/dev/null 2>&1; then
  fail "invalid existing JSON is rejected, not silently overwritten"
else
  ok "invalid existing JSON is rejected, not silently overwritten"
fi
assert_eq "the broken file is left untouched" "$(cat "$SETTINGS_BROKEN")" "not valid json{"

test_summary
