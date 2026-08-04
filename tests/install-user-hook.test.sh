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

# --- --event Stop: no matcher key, plus --async-rewake/--timeout/--rewake-summary (issue #199) ---
SETTINGS_STOP="$WORK/settings-stop.json"
STOP_CREW_HOOK="$TEST_REPO/hooks/stop-continuity-crew.sh"

run_installer --settings "$SETTINGS_STOP" --hook "$STOP_CREW_HOOK" --event Stop \
  --async-rewake --timeout 600 --rewake-summary "Wingman fleet continuity (crew)" >/dev/null

stop_entry="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_STOP'))
g = d['hooks']['Stop'][0]
h = g['hooks'][0]
print('matcher' in g)
print(h['command'])
print(h.get('asyncRewake'))
print(h.get('timeout'))
print(h.get('rewakeSummary'))
")"
assert_eq "a Stop registration carries no matcher key" "$(printf '%s\n' "$stop_entry" | sed -n 1p)" "False"
assert_eq "the Stop entry's command is the given hook path" "$(printf '%s\n' "$stop_entry" | sed -n 2p)" "$STOP_CREW_HOOK"
assert_eq "--async-rewake sets asyncRewake: true" "$(printf '%s\n' "$stop_entry" | sed -n 3p)" "True"
assert_eq "--timeout sets the given timeout" "$(printf '%s\n' "$stop_entry" | sed -n 4p)" "600"
assert_eq "--rewake-summary sets the given rewakeSummary" "$(printf '%s\n' "$stop_entry" | sed -n 5p)" "Wingman fleet continuity (crew)"

if run_installer --settings "$SETTINGS_STOP" --hook "$STOP_CREW_HOOK" --event Stop --check >/dev/null 2>&1; then
  ok "a Stop registration is detected as registered by --check"
else
  fail "a Stop registration is detected as registered by --check"
fi

# --- attribute-aware --check and in-place update (issue #231) ----------------
# SETTINGS_STOP already carries STOP_CREW_HOOK registered with timeout 600
# (set above). --check with no attribute flags still matches on command alone
# (unchanged behavior, re-proven here against a fixture that actually HAS
# entry_options this time, not just the plain fixtures elsewhere in this file).
if run_installer --settings "$SETTINGS_STOP" --hook "$STOP_CREW_HOOK" --event Stop --check >/dev/null 2>&1; then
  ok "--check with no attribute flags still matches on command alone"
else
  fail "--check with no attribute flags still matches on command alone"
fi

# --check with --timeout matching the registered value passes.
if run_installer --settings "$SETTINGS_STOP" --hook "$STOP_CREW_HOOK" --event Stop --timeout 600 --check >/dev/null 2>&1; then
  ok "--check with a matching --timeout passes"
else
  fail "--check with a matching --timeout passes"
fi

# --check with a DIFFERENT --timeout fails - the direct regression for the
# migration hazard: a command-only match would read this as "already
# registered" and never correct the stale timeout.
if run_installer --settings "$SETTINGS_STOP" --hook "$STOP_CREW_HOOK" --event Stop --timeout 3600 --check >/dev/null 2>&1; then
  fail "--check with a mismatched --timeout fails"
else
  ok "--check with a mismatched --timeout fails"
fi

# A non-check run against a differing entry rewrites it in place, rather than
# leaving it stale or appending a duplicate group for the same command.
run_installer --settings "$SETTINGS_STOP" --hook "$STOP_CREW_HOOK" --event Stop \
  --async-rewake --timeout 3600 --rewake-summary "Wingman fleet continuity (crew)" >/dev/null
updated_stop="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_STOP'))
cmds = [h for g in d['hooks']['Stop'] for h in g['hooks'] if h['command'] == '$STOP_CREW_HOOK']
print(len(cmds))
print(cmds[0].get('timeout') if cmds else None)
")"
assert_eq "the resulting file has no duplicate entry for that command" "$(printf '%s\n' "$updated_stop" | sed -n 1p)" "1"
assert_eq "the differing entry was rewritten in place to the new timeout" "$(printf '%s\n' "$updated_stop" | sed -n 2p)" "3600"
if run_installer --settings "$SETTINGS_STOP" --hook "$STOP_CREW_HOOK" --event Stop --timeout 3600 --check >/dev/null 2>&1; then
  ok "--check with the new --timeout passes after the in-place update"
else
  fail "--check with the new --timeout passes after the in-place update"
fi

# --- both reconcilers still run standalone after the shared-helper extraction
# (issue #231) - a broken sibling import to bin/lib/user_hook_entry.py must
# fail the build, not ship silently.
if uv run --no-project --quiet "$INSTALLER" -h >/dev/null 2>&1; then
  ok "install-user-hook.py still runs standalone under uv run"
else
  fail "install-user-hook.py still runs standalone under uv run"
fi
if uv run --no-project --quiet "$TEST_REPO/bin/lib/sync-user-hooks.py" -h >/dev/null 2>&1; then
  ok "sync-user-hooks.py still runs standalone under uv run"
else
  fail "sync-user-hooks.py still runs standalone under uv run"
fi

# A Stop registration with none of the three new flags omits all three keys
# (they are optional, not defaulted-on) and still carries no matcher.
SETTINGS_STOP2="$WORK/settings-stop2.json"
STOP_GUARD_CREW_HOOK="$TEST_REPO/hooks/stop-guard-crew.sh"
run_installer --settings "$SETTINGS_STOP2" --hook "$STOP_GUARD_CREW_HOOK" --event Stop >/dev/null
plain_stop="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_STOP2'))
g = d['hooks']['Stop'][0]
h = g['hooks'][0]
print('matcher' in g)
print('asyncRewake' in h)
print('timeout' in h)
print('rewakeSummary' in h)
")"
assert_eq "a plain Stop registration has no matcher key" "$(printf '%s\n' "$plain_stop" | sed -n 1p)" "False"
assert_eq "a plain Stop registration has no asyncRewake key" "$(printf '%s\n' "$plain_stop" | sed -n 2p)" "False"
assert_eq "a plain Stop registration has no timeout key" "$(printf '%s\n' "$plain_stop" | sed -n 3p)" "False"
assert_eq "a plain Stop registration has no rewakeSummary key" "$(printf '%s\n' "$plain_stop" | sed -n 4p)" "False"

# A non-Stop event registration is unaffected: it still carries a matcher, and
# none of the three new (Stop-oriented) keys leak in when unset.
SETTINGS_NONSTOP="$WORK/settings-nonstop.json"
run_installer --settings "$SETTINGS_NONSTOP" --hook "$HOOK_PATH" --event PreToolUse >/dev/null
nonstop_matcher="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS_NONSTOP'))
print('matcher' in d['hooks']['PreToolUse'][0])
")"
assert_eq "a non-Stop registration still carries a matcher key" "$nonstop_matcher" "True"

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

# doctor also registers the watcher-protection guard (issue #64), unconditionally
# and under PreToolUse, alongside the other user-scope hooks above.
assert_contains "doctor reports the watcher-protection guard registered" "$out" "registered watcher-protection guard hook"
watcher_found="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS4'))
cmds = [h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']]
print('yes' if '$TEST_REPO/hooks/no-watcher-kill-guard.sh' in cmds else 'no')
" 2>/dev/null)"
assert_eq "doctor registers the watcher-protection guard under PreToolUse" "$watcher_found" "yes"

# Scoped to Bash alone (not the broader Edit|Write|NotebookEdit|Bash default) -
# this hook only ever inspects Bash tool calls, and a broader matcher would
# needlessly run its cheap "kill" substring pre-gate against every Edit/Write/
# NotebookEdit payload too.
watcher_matcher="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS4'))
for g in d['hooks']['PreToolUse']:
    if any(h['command'] == '$TEST_REPO/hooks/no-watcher-kill-guard.sh' for h in g['hooks']):
        print(g.get('matcher'))
        break
" 2>/dev/null)"
assert_eq "doctor scopes the watcher-protection guard to the Bash matcher" "$watcher_matcher" "Bash"

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

# doctor also registers the usage-limit-quota detection pair (issue #24): the
# statusLine capture command AND the spawn guard hook, mirroring the outage
# block's own proof that this is actually wired in, not just unit-tested in
# isolation.
assert_contains "doctor reports usage-limit detection registered" "$out" "registered usage-limit detection (statusline + spawn guard)"
usage_statusline_cmd="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS4'))
print(d.get('statusLine', {}).get('command', ''))
" 2>/dev/null)"
assert_contains "doctor registers our script as the statusLine command" "$usage_statusline_cmd" "$TEST_REPO/bin/lib/usage-statusline.py"
usage_guard_found="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS4'))
cmds = [h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']]
print('yes' if '$TEST_REPO/hooks/usage-limit-spawn-guard.sh' in cmds else 'no')
" 2>/dev/null)"
assert_eq "doctor registers the usage-limit spawn guard under PreToolUse" "$usage_guard_found" "yes"

# Re-running doctor is a no-op for the already-registered set.
out2="$(WM_CLAUDE_USER_SETTINGS="$SETTINGS4" "$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "a second doctor run reports the artifact hooks already registered" "$out2" "Artifact-publish contract hooks registered"
assert_contains "a second doctor run reports the watcher-protection guard already registered" "$out2" "watcher-protection guard hook registered"
assert_contains "a second doctor run reports the outage-detection guard hook already registered" "$out2" "outage-detection guard hook registered"
assert_contains "a second doctor run reports usage-limit detection already registered" "$out2" "usage-limit detection (statusline + spawn guard) registered"

test_summary
