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

test_summary
