#!/usr/bin/env bash
# E2E: bin/lib/claude-gate-check.py's bypass-status/bypass-set subcommands
# (issue #16), and bin/doctor's wiring of the new Bypass-Permissions
# acceptance check. Every settings.json path here is a throwaway tmp file -
# never the real developer machine's ~/.claude/settings.json. The
# trust-status subcommand and bin/spawn-crew's own preflight wiring are
# covered separately in tests/spawn-crew-trust-preflight.test.sh.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

CHECK="$TEST_REPO/bin/lib/claude-gate-check.py"
run_check() { uv run --no-project --quiet "$CHECK" "$@"; }

WORK="$(wm_mktemp_dir)"

# --- bypass-status: missing file reads as not accepted ------------------------
SETTINGS="$WORK/settings.json"
if run_check bypass-status --settings "$SETTINGS" >/dev/null 2>&1; then
  fail "missing settings file: bypass-status reports accepted"
else
  ok "missing settings file: bypass-status reports not accepted"
fi

# --- bypass-status: key absent, false, true ------------------------------------
printf '{"theme": "dark"}\n' > "$SETTINGS"
if run_check bypass-status --settings "$SETTINGS" >/dev/null 2>&1; then
  fail "key absent: bypass-status reports accepted"
else
  ok "key absent: bypass-status reports not accepted"
fi

printf '{"skipDangerousModePermissionPrompt": false}\n' > "$SETTINGS"
if run_check bypass-status --settings "$SETTINGS" >/dev/null 2>&1; then
  fail "key false: bypass-status reports accepted"
else
  ok "key false: bypass-status reports not accepted"
fi

printf '{"skipDangerousModePermissionPrompt": true}\n' > "$SETTINGS"
if run_check bypass-status --settings "$SETTINGS" >/dev/null 2>&1; then
  ok "key true: bypass-status reports accepted"
else
  fail "key true: bypass-status reports accepted"
fi

# --- bypass-set: idempotently merges the key, preserving other keys -----------
SETTINGS2="$WORK/settings-existing.json"
cat > "$SETTINGS2" <<'JSON'
{
  "theme": "dark",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/some/other/pretooluse.sh"}]}
    ]
  }
}
JSON
run_check bypass-set --settings "$SETTINGS2" >/dev/null
val="$(uv run --no-project --quiet python -c "
import json
print(json.load(open('$SETTINGS2'))['skipDangerousModePermissionPrompt'])
")"
assert_eq "bypass-set writes skipDangerousModePermissionPrompt: true" "$val" "True"
theme="$(uv run --no-project --quiet python -c "
import json
print(json.load(open('$SETTINGS2'))['theme'])
")"
assert_eq "bypass-set preserves an unrelated top-level key" "$theme" "dark"
hook_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS2'))
print(d['hooks']['PreToolUse'][0]['hooks'][0]['command'])
")"
assert_eq "bypass-set preserves existing hook registrations" "$hook_cmd" "/some/other/pretooluse.sh"

if run_check bypass-status --settings "$SETTINGS2" >/dev/null 2>&1; then
  ok "after bypass-set: bypass-status reports accepted"
else
  fail "after bypass-set: bypass-status reports accepted"
fi

# Re-running is a no-op (idempotent) - same content, no duplicate keys.
run_check bypass-set --settings "$SETTINGS2" >/dev/null
key_count="$(uv run --no-project --quiet python -c "
import json
print(len(json.load(open('$SETTINGS2'))))
")"
assert_eq "re-running bypass-set does not add duplicate top-level keys" "$key_count" "3"

# --- bypass-set refuses to clobber invalid JSON --------------------------------
SETTINGS3="$WORK/settings-broken.json"
printf 'not valid json{' > "$SETTINGS3"
if run_check bypass-set --settings "$SETTINGS3" >/dev/null 2>&1; then
  fail "invalid existing JSON is rejected, not silently overwritten"
else
  ok "invalid existing JSON is rejected, not silently overwritten"
fi
assert_eq "the broken file is left untouched" "$(cat "$SETTINGS3")" "not valid json{"

# bypass-status on invalid JSON fails closed (not accepted), never crashes.
if run_check bypass-status --settings "$SETTINGS3" >/dev/null 2>&1; then
  fail "invalid JSON: bypass-status reports accepted"
else
  ok "invalid JSON: bypass-status fails closed (reports not accepted)"
fi

# --- bin/doctor wires this in, via an overridable settings path --------------
# doctor's own overall exit code depends on unrelated required deps (e.g.
# `claude` itself, which a CI runner need not have installed) - this only
# proves the new check block runs and succeeds regardless of that.
test_new_home
SETTINGS4="$WORK/doctor-settings.json"
printf '{"theme": "dark"}\n' > "$SETTINGS4"
out="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS4" "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "doctor reports Bypass-Permissions mode accepted" "$out" "accepted Bypass-Permissions mode"
doctor_val="$(uv run --no-project --quiet python -c "
import json
print(json.load(open('$SETTINGS4'))['skipDangerousModePermissionPrompt'])
")"
assert_eq "doctor sets skipDangerousModePermissionPrompt at the overridden path" "$doctor_val" "True"
doctor_theme="$(uv run --no-project --quiet python -c "
import json
print(json.load(open('$SETTINGS4'))['theme'])
")"
assert_eq "doctor's bypass check preserves unrelated pre-existing settings" "$doctor_theme" "dark"

# Re-running doctor is a no-op for the already-accepted state.
out2="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS4" "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "a second doctor run reports Bypass-Permissions mode already accepted" "$out2" "Bypass-Permissions mode already accepted"

# --- fleet-continuity Stop hooks (issue #185), project scope -----------------
# Report-only (no install/write attempted, since .claude/settings.json is
# version-controlled) - all three fixtures are pointed at throwaway paths via
# WM_PROJECT_SETTINGS/WM_STOP_GUARD_SCRIPT/WM_STOP_CONTINUITY_SCRIPT, never the
# real checkout.
PROJ_SETTINGS_OK="$WORK/proj-settings-ok.json"
PROJ_GUARD_SH="$WORK/proj-stop-guard.sh"
PROJ_CONTINUITY_SH="$WORK/proj-stop-continuity.sh"
cat > "$PROJ_SETTINGS_OK" <<'JSON'
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "\"$CLAUDE_PROJECT_DIR/hooks/stop-guard.sh\""}]},
      {"hooks": [{"type": "command", "command": "\"$CLAUDE_PROJECT_DIR/hooks/stop-continuity.sh\"", "asyncRewake": true}]}
    ]
  }
}
JSON
printf '#!/usr/bin/env bash\n' > "$PROJ_GUARD_SH"; chmod +x "$PROJ_GUARD_SH"
printf '#!/usr/bin/env bash\n' > "$PROJ_CONTINUITY_SH"; chmod +x "$PROJ_CONTINUITY_SH"

out3="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS4" WM_PROJECT_SETTINGS="$PROJ_SETTINGS_OK" \
        WM_STOP_GUARD_SCRIPT="$PROJ_GUARD_SH" WM_STOP_CONTINUITY_SCRIPT="$PROJ_CONTINUITY_SH" \
        "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "both entries present and executable: doctor reports registered" "$out3" "fleet-continuity Stop hooks registered"

# One entry missing (stop-continuity.sh's own Stop entry absent) - warns, and
# never attempts to write/install anything into the version-controlled file.
PROJ_SETTINGS_MISSING="$WORK/proj-settings-missing.json"
cat > "$PROJ_SETTINGS_MISSING" <<'JSON'
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "\"$CLAUDE_PROJECT_DIR/hooks/stop-guard.sh\""}]}
    ]
  }
}
JSON
before_missing="$(cat "$PROJ_SETTINGS_MISSING")"
out4="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS4" WM_PROJECT_SETTINGS="$PROJ_SETTINGS_MISSING" \
        WM_STOP_GUARD_SCRIPT="$PROJ_GUARD_SH" WM_STOP_CONTINUITY_SCRIPT="$PROJ_CONTINUITY_SH" \
        "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "a missing Stop entry: doctor warns" "$out4" "fleet-continuity Stop hooks (issue #185) not registered"
assert_eq "a missing entry never rewrites the settings file" "$(cat "$PROJ_SETTINGS_MISSING")" "$before_missing"

# A script present in settings.json but not executable on disk - warns.
PROJ_CONTINUITY_SH_NOEXEC="$WORK/proj-stop-continuity-noexec.sh"
printf '#!/usr/bin/env bash\n' > "$PROJ_CONTINUITY_SH_NOEXEC"
chmod -x "$PROJ_CONTINUITY_SH_NOEXEC"
out5="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS4" WM_PROJECT_SETTINGS="$PROJ_SETTINGS_OK" \
        WM_STOP_GUARD_SCRIPT="$PROJ_GUARD_SH" WM_STOP_CONTINUITY_SCRIPT="$PROJ_CONTINUITY_SH_NOEXEC" \
        "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "a non-executable script: doctor warns" "$out5" "fleet-continuity Stop hooks (issue #185) not registered"

# --- fleet-continuity Stop hooks (issue #199), crew sessions, user scope ----
# Unlike the project-scope pair above, this pair IS installable (GUARD_SETTINGS
# is a real, pilot-owned file, not version-controlled) - mirrors the
# project-scope case's registered/missing/non-executable shape, adapted for
# that. Throwaway executable fixtures via WM_STOP_GUARD_CREW_SCRIPT/
# WM_STOP_CONTINUITY_CREW_SCRIPT, never the real checked-in wrapper files.
CREW_GUARD_SH="$WORK/crew-stop-guard.sh"
CREW_CONTINUITY_SH="$WORK/crew-stop-continuity.sh"
printf '#!/usr/bin/env bash\n' > "$CREW_GUARD_SH"; chmod +x "$CREW_GUARD_SH"
printf '#!/usr/bin/env bash\n' > "$CREW_CONTINUITY_SH"; chmod +x "$CREW_CONTINUITY_SH"

SETTINGS5="$WORK/crew-continuity-settings.json"
out6="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS5" \
        WM_STOP_GUARD_CREW_SCRIPT="$CREW_GUARD_SH" WM_STOP_CONTINUITY_CREW_SCRIPT="$CREW_CONTINUITY_SH" \
        "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "fresh: doctor warns the crew Stop hooks are not registered" "$out6" "fleet-continuity Stop hooks (crew, issue #199) not registered"
assert_contains "fresh: doctor registers the crew Stop hooks" "$out6" "registered fleet-continuity Stop hooks (crew)"
crew_guard_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS5'))
cmds = [h['command'] for g in d['hooks']['Stop'] for h in g['hooks']]
print('yes' if '$CREW_GUARD_SH' in cmds else 'no')
")"
assert_eq "the registered entry references the crew guard script" "$crew_guard_cmd" "yes"
crew_continuity_entry="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS5'))
for g in d['hooks']['Stop']:
    for h in g['hooks']:
        if h['command'] == '$CREW_CONTINUITY_SH':
            print(h.get('asyncRewake'))
            print(h.get('timeout'))
            print(h.get('rewakeSummary'))
")"
assert_eq "the registered continuity entry sets asyncRewake" "$(printf '%s\n' "$crew_continuity_entry" | sed -n 1p)" "True"
assert_eq "the registered continuity entry sets timeout 600" "$(printf '%s\n' "$crew_continuity_entry" | sed -n 2p)" "600"
assert_eq "the registered continuity entry sets the crew rewakeSummary" "$(printf '%s\n' "$crew_continuity_entry" | sed -n 3p)" "Wingman fleet continuity (crew)"

# Idempotent: re-running reports already registered, does not duplicate.
out7="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS5" \
        WM_STOP_GUARD_CREW_SCRIPT="$CREW_GUARD_SH" WM_STOP_CONTINUITY_CREW_SCRIPT="$CREW_CONTINUITY_SH" \
        "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "a second run reports the crew Stop hooks already registered" "$out7" "fleet-continuity Stop hooks (crew) registered"
stop_group_count="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS5'))
print(len(d['hooks']['Stop']))
")"
assert_eq "re-running does not duplicate the Stop entries" "$stop_group_count" "2"

# A script registered in settings.json but not executable on disk - warns,
# same as the project-scope case.
CREW_CONTINUITY_SH_NOEXEC="$WORK/crew-stop-continuity-noexec.sh"
printf '#!/usr/bin/env bash\n' > "$CREW_CONTINUITY_SH_NOEXEC"
chmod -x "$CREW_CONTINUITY_SH_NOEXEC"
SETTINGS6="$WORK/crew-continuity-settings-noexec.json"
out8="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS6" \
        WM_STOP_GUARD_CREW_SCRIPT="$CREW_GUARD_SH" WM_STOP_CONTINUITY_CREW_SCRIPT="$CREW_CONTINUITY_SH_NOEXEC" \
        "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "a non-executable crew script: doctor warns" "$out8" "fleet-continuity Stop hooks (crew, issue #199) not registered"

# --- Worker-spawn depth-cap guard hook (issue #212), user scope -------------
# hooks/no-worker-spawn-guard.sh is registered by its own real, checked-in
# path (unlike the Stop-hooks pair above, there is no fixture-script env var
# to swap in) - a throwaway settings.json is enough to isolate this from the
# real developer machine.
SETTINGS9="$WORK/worker-spawn-guard-settings.json"
out9="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS9" "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "fresh: doctor warns the worker-spawn guard hook is not registered" "$out9" "worker-spawn depth-cap guard hook (issue #212) not registered"
assert_contains "fresh: doctor registers the worker-spawn guard hook" "$out9" "registered worker-spawn depth-cap guard hook"
worker_spawn_guard_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS9'))
cmds = [h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']]
print('yes' if '$TEST_REPO/hooks/no-worker-spawn-guard.sh' in cmds else 'no')
")"
assert_eq "the registered entry references the real hook path" "$worker_spawn_guard_cmd" "yes"

# Idempotent: re-running reports already registered, does not duplicate the
# entry for this hook specifically (other hooks share the same PreToolUse
# array, so this counts occurrences of THIS hook's own command string, not
# the group's total size).
out10="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS9" "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "a second run reports the worker-spawn guard hook already registered" "$out10" "worker-spawn depth-cap guard hook registered"
worker_spawn_guard_count="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS9'))
cmds = [h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']]
print(cmds.count('$TEST_REPO/hooks/no-worker-spawn-guard.sh'))
")"
assert_eq "re-running does not duplicate the hook entry" "$worker_spawn_guard_count" "1"

test_summary
