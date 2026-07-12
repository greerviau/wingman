#!/usr/bin/env bash
# E2E: bin/lib/install-user-hook.py, the idempotent installer bin/doctor uses to
# register the delegation guard hook (#17) in user-level Claude Code settings.
# Every settings.json path here is a throwaway tmp file - never the real
# developer machine's ~/.claude/settings.json.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

INSTALLER="$TEST_REPO/bin/lib/install-user-hook.py"
HOOK_PATH="$TEST_REPO/hooks/no-direct-edit-guard.sh"

run_installer() { uv run --no-project --quiet "$INSTALLER" "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- fresh install ------------------------------------------------------------
SETTINGS="$WORK/settings.json"

if run_installer --settings "$SETTINGS" --hook "$HOOK_PATH" --check >/dev/null 2>&1; then
  fail "fresh settings file: --check reports registered before install"
else
  ok "fresh settings file: --check reports not registered before install"
fi

out="$(run_installer --settings "$SETTINGS" --hook "$HOOK_PATH")"
assert_contains "install reports registered" "$out" "registered"
assert_true "settings file now exists" "[ -f '$SETTINGS' ]"

cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS'))
print(d['hooks']['PreToolUse'][0]['hooks'][0]['command'])
")"
assert_eq "installed entry references the absolute hook path" "$cmd" "$HOOK_PATH"

matcher="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS'))
print(d['hooks']['PreToolUse'][0]['matcher'])
")"
assert_eq "installed entry matches Edit/Write/NotebookEdit/Bash" "$matcher" "Edit|Write|NotebookEdit|Bash"

if run_installer --settings "$SETTINGS" --hook "$HOOK_PATH" --check >/dev/null 2>&1; then
  ok "after install: --check reports registered"
else
  fail "after install: --check reports registered"
fi

# --- idempotent: re-running does not duplicate the entry ---------------------
run_installer --settings "$SETTINGS" --hook "$HOOK_PATH" >/dev/null
count="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS'))
print(len(d['hooks']['PreToolUse']))
")"
assert_eq "re-running does not add a second PreToolUse group" "$count" "1"

# --- merges additively: pre-existing unrelated settings are preserved --------
SETTINGS2="$WORK/settings-existing.json"
cat > "$SETTINGS2" <<'JSON'
{
  "theme": "dark",
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "/some/other/stop-hook.sh"}]}
    ],
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/some/other/pretooluse.sh"}]}
    ]
  }
}
JSON

run_installer --settings "$SETTINGS2" --hook "$HOOK_PATH" >/dev/null

theme="$(uv run --no-project --quiet python -c "
import json
print(json.load(open('$SETTINGS2'))['theme'])
")"
assert_eq "unrelated top-level key is preserved" "$theme" "dark"

stop_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS2'))
print(d['hooks']['Stop'][0]['hooks'][0]['command'])
")"
assert_eq "existing Stop hook is preserved" "$stop_cmd" "/some/other/stop-hook.sh"

other_pretool="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS2'))
print(d['hooks']['PreToolUse'][0]['hooks'][0]['command'])
")"
assert_eq "existing unrelated PreToolUse entry is preserved" "$other_pretool" "/some/other/pretooluse.sh"

pretool_count="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS2'))
print(len(d['hooks']['PreToolUse']))
")"
assert_eq "our entry is appended alongside the existing one" "$pretool_count" "2"

# --- refuses to clobber invalid JSON ------------------------------------------
SETTINGS3="$WORK/settings-broken.json"
printf 'not valid json{' > "$SETTINGS3"
if run_installer --settings "$SETTINGS3" --hook "$HOOK_PATH" >/dev/null 2>&1; then
  fail "invalid existing JSON is rejected, not silently overwritten"
else
  ok "invalid existing JSON is rejected, not silently overwritten"
fi
assert_eq "the broken file is left untouched" "$(cat "$SETTINGS3")" "not valid json{"

# --- bin/doctor wires this in, via an overridable settings path --------------
# doctor's own overall exit code depends on unrelated required deps (e.g.
# `claude` itself, which a CI runner need not have installed) - this only
# proves the hook registration step runs and succeeds regardless of that.
test_new_home
SETTINGS4="$WORK/doctor-settings.json"
out="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS4" "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "doctor reports the hook registered" "$out" "registered delegation guard hook"
assert_true "doctor registers the hook at the overridden path" "[ -f '$SETTINGS4' ]"
doctor_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS4'))
print(d['hooks']['PreToolUse'][0]['hooks'][0]['command'])
" 2>/dev/null)"
assert_eq "doctor's registered entry references the absolute hook path" "$doctor_cmd" "$HOOK_PATH"

test_summary
