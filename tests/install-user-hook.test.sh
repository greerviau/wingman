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

WORK="$(wm_mktemp_dir)"

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

# --- --event: registers under the named event, idempotently -------------------
SETTINGS_EV="$WORK/settings-event.json"
TRACKER_PATH="$TEST_REPO/hooks/artifact-publish-tracker.sh"

if run_installer --settings "$SETTINGS_EV" --hook "$TRACKER_PATH" --event PostToolUse --check >/dev/null 2>&1; then
  fail "--event check reports not registered before install"
else
  ok "--event check reports not registered before install"
fi

run_installer --settings "$SETTINGS_EV" --hook "$TRACKER_PATH" --event PostToolUse --matcher "Artifact|Bash" >/dev/null
ev_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_EV'))
print(d['hooks']['PostToolUse'][0]['hooks'][0]['command'])
")"
assert_eq "the entry lands under the named event" "$ev_cmd" "$TRACKER_PATH"
ev_matcher="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_EV'))
print(d['hooks']['PostToolUse'][0]['matcher'])
")"
assert_eq "the entry carries the given matcher" "$ev_matcher" "Artifact|Bash"

if run_installer --settings "$SETTINGS_EV" --hook "$TRACKER_PATH" --event PostToolUse --check >/dev/null 2>&1; then
  ok "--event check reports registered after install"
else
  fail "--event check reports registered after install"
fi

# The idempotency check keys off --event too: re-registering the same hook
# under the same non-default event is a no-op...
run_installer --settings "$SETTINGS_EV" --hook "$TRACKER_PATH" --event PostToolUse >/dev/null
ev_count="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_EV'))
print(len(d['hooks']['PostToolUse']))
")"
assert_eq "re-registering under the same event is a no-op" "$ev_count" "1"

# ...while the same hook under a DIFFERENT event is a separate registration,
# independent of the existing one (the tracker genuinely needs two events).
if run_installer --settings "$SETTINGS_EV" --hook "$TRACKER_PATH" --event PostToolUseFailure --check >/dev/null 2>&1; then
  fail "the same hook under a different event reads as not yet registered"
else
  ok "the same hook under a different event reads as not yet registered"
fi
run_installer --settings "$SETTINGS_EV" --hook "$TRACKER_PATH" --event PostToolUseFailure --matcher "Artifact|Bash" >/dev/null
ev2_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_EV'))
print(d['hooks']['PostToolUseFailure'][0]['hooks'][0]['command'])
")"
assert_eq "the second event's entry lands under its own key" "$ev2_cmd" "$TRACKER_PATH"
ev_count="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_EV'))
print(len(d['hooks']['PostToolUse']))
")"
assert_eq "the first event's group is untouched by the second" "$ev_count" "1"

# Default event stays PreToolUse (the delegation guard's existing behavior).
run_installer --settings "$SETTINGS_EV" --hook "$HOOK_PATH" >/dev/null
def_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_EV'))
print(d['hooks']['PreToolUse'][0]['hooks'][0]['command'])
")"
assert_eq "no --event defaults to PreToolUse" "$def_cmd" "$HOOK_PATH"

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

# doctor also registers the Artifact-publish contract pair: the tracker under
# BOTH result events, the link guard under PreToolUse.
assert_contains "doctor reports the artifact hooks registered" "$out" "registered Artifact-publish contract hooks"
for ev in PostToolUse PostToolUseFailure; do
  ev_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS4'))
print(d['hooks']['$ev'][0]['hooks'][0]['command'])
" 2>/dev/null)"
  assert_eq "doctor registers the tracker under $ev" "$ev_cmd" "$TEST_REPO/hooks/artifact-publish-tracker.sh"
done
link_found="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS4'))
cmds = [h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']]
print('yes' if '$TEST_REPO/hooks/artifact-link-guard.sh' in cmds else 'no')
" 2>/dev/null)"
assert_eq "doctor registers the link guard under PreToolUse" "$link_found" "yes"

# doctor also registers the outage-detection guard (issue #23): PAUSE only
# actually takes effect in production if this registration step runs -
# proving the hook script itself works in isolation (its own
# api-outage-spawn-guard.test.sh) is not enough on its own.
assert_contains "doctor reports the outage-detection guard hook registered" "$out" "registered outage-detection guard hook"
outage_found="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS4'))
cmds = [h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']]
print('yes' if '$TEST_REPO/hooks/api-outage-spawn-guard.sh' in cmds else 'no')
" 2>/dev/null)"
assert_eq "doctor registers the outage-detection guard under PreToolUse" "$outage_found" "yes"

# Re-running doctor is a no-op for the already-registered set.
out2="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS4" "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "a second doctor run reports the artifact hooks already registered" "$out2" "Artifact-publish contract hooks registered"
assert_contains "a second doctor run reports the outage-detection guard hook already registered" "$out2" "outage-detection guard hook registered"

test_summary
