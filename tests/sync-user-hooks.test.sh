#!/usr/bin/env bash
# E2E: bin/lib/sync-user-hooks.py, the reconciler that registers every
# user-scope guard hook named in bin/lib/user-hooks.json into a Claude Code
# user-level settings.json (issue #241). Never touches the real
# ~/.claude/settings.json - every settings path here is a throwaway tmp file.
# The manifest/bin-doctor equality test (the drift proof) lives in
# tests/doctor.test.sh instead, alongside doctor's own hook-registration
# assertions; the session-creation wiring (bin/wingman, bin/spawn-crew,
# bin/crew-resume all reconcile before they start a session, and refuse if
# they can't) lives in tests/session-guard-hook-sync.test.sh.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SYNC="$TEST_REPO/bin/lib/sync-user-hooks.py"
MANIFEST="$TEST_REPO/bin/lib/user-hooks.json"
run_sync() { uv run --no-project --quiet "$SYNC" --manifest "$MANIFEST" "$@"; }

WORK="$(wm_mktemp_dir)"

# Total registered hook commands across every event, as "<event>\t<command>"
# lines - the canonical shape used by several assertions below.
all_registered() {
  uv run --no-project --quiet python -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for event, groups in (d.get('hooks') or {}).items():
    for g in groups:
        for h in g.get('hooks', []):
            print(f\"{event}\t{h.get('command')}\")
" "$1"
}

manifest_command_count() {
  uv run --no-project --quiet python -c "
import json
d = json.load(open('$MANIFEST'))
print(sum(len(g['hooks']) for g in d['groups']))
"
}
EXPECTED_COUNT="$(manifest_command_count)"

# --- test 1: fresh settings file registers every manifest entry once each ----
SETTINGS1="$WORK/fresh.json"
run_sync --settings "$SETTINGS1" --repo "$TEST_REPO"
rc1=$?
assert_eq "fresh settings: sync exits 0" "$rc1" "0"
count1="$(all_registered "$SETTINGS1" | sort -u | wc -l | tr -d ' ')"
assert_eq "fresh settings: every manifest entry registered exactly once" "$count1" "$EXPECTED_COUNT"
assert_contains "the foreground-watcher hook lands under PreToolUse" \
  "$(all_registered "$SETTINGS1")" "PreToolUse	$TEST_REPO/hooks/no-foreground-watcher-guard.sh"
assert_contains "the artifact-publish tracker lands under PostToolUseFailure too" \
  "$(all_registered "$SETTINGS1")" "PostToolUseFailure	$TEST_REPO/hooks/artifact-publish-tracker.sh"
# No "matcher" key on a Stop entry - mirrors install-user-hook.py's own rule.
stop_matcher_count="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS1'))
print(sum(1 for g in d['hooks']['Stop'] if 'matcher' in g))
")"
assert_eq "no Stop entry carries a matcher key" "$stop_matcher_count" "0"
# A PreToolUse entry does carry a matcher.
pretooluse_matcher="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS1'))
for g in d['hooks']['PreToolUse']:
    for h in g['hooks']:
        if h['command'].endswith('no-foreground-watcher-guard.sh'):
            print(g.get('matcher'))
")"
assert_eq "a PreToolUse entry carries its matcher" "$pretooluse_matcher" "Bash"

# --- test 2: idempotence - a second run writes nothing -----------------------
before_mtime="$(stat -c %Y "$SETTINGS1" 2>/dev/null || stat -f %m "$SETTINGS1")"
before_bytes="$(cat "$SETTINGS1")"
sleep 1.1   # coarse mtime resolution on some filesystems
run_sync --settings "$SETTINGS1" --repo "$TEST_REPO"
rc2=$?
assert_eq "idempotent re-run: sync exits 0" "$rc2" "0"
after_mtime="$(stat -c %Y "$SETTINGS1" 2>/dev/null || stat -f %m "$SETTINGS1")"
after_bytes="$(cat "$SETTINGS1")"
assert_eq "idempotent re-run: mtime is unchanged" "$after_mtime" "$before_mtime"
assert_eq "idempotent re-run: byte content is unchanged" "$after_bytes" "$before_bytes"

# --- test 3: partial state - existing entries preserved, third-party group survives
SETTINGS3="$WORK/partial.json"
cat > "$SETTINGS3" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "$TEST_REPO/hooks/no-direct-edit-guard.sh"}]},
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "/some/third-party/hook.sh"}]}
    ]
  }
}
EOF
run_sync --settings "$SETTINGS3" --repo "$TEST_REPO"
rc3=$?
assert_eq "partial state: sync exits 0" "$rc3" "0"
count3="$(all_registered "$SETTINGS3" | sort -u | wc -l | tr -d ' ')"
# EXPECTED_COUNT manifest entries plus the one pre-seeded third-party hook.
assert_eq "partial state: every manifest entry present exactly once, plus the untouched third-party one" "$count3" "$((EXPECTED_COUNT + 1))"
delegation_count3="$(all_registered "$SETTINGS3" | grep -c "no-direct-edit-guard.sh$")"
assert_eq "the pre-existing delegation entry was not duplicated" "$delegation_count3" "1"
third_party_survives="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS3'))
cmds = [h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']]
print('yes' if '/some/third-party/hook.sh' in cmds else 'no')
")"
assert_eq "an unrelated third-party hook group survives untouched" "$third_party_survives" "yes"

# --- test 4: --check is read-only ---------------------------------------------
SETTINGS4="$WORK/check-only.json"
if run_sync --settings "$SETTINGS4" --repo "$TEST_REPO" --check >/dev/null 2>&1; then
  fail "--check against a fresh (absent) settings file exits 0"
else
  ok "--check against a fresh (absent) settings file exits non-zero"
fi
assert_false "--check never creates the settings file" "[ -f '$SETTINGS4' ]"
report_out="$(run_sync --settings "$SETTINGS4" --repo "$TEST_REPO" --check --report 2>/dev/null)"
assert_contains "--report names a missing hook" "$report_out" "no-direct-edit-guard.sh"
report_lines="$(printf '%s\n' "$report_out" | grep -c .)"
assert_eq "--report lists every missing manifest entry" "$report_lines" "$EXPECTED_COUNT"

# --- helper: a repo mirror with one hook script broken, for the fail-closed
# tests below. Only hooks/ is materialized (sync-user-hooks.py's --repo is
# resolved directly, so nothing else from the real tree is needed); every
# other script is symlinked to the real one so the manifest's other 15
# entries still resolve normally. -----------------------------------------
mk_broken_repo() {
  # $1 = target dir, $2 = repo-relative script to break, $3 = missing|noexec
  _br_dir="$1"; _br_script="$2"; _br_mode="$3"
  mkdir -p "$_br_dir/hooks"
  for f in "$TEST_REPO"/hooks/*; do
    [ -f "$f" ] || continue
    _br_base="$(basename "$f")"
    [ "hooks/$_br_base" = "$_br_script" ] && continue
    ln -s "$f" "$_br_dir/hooks/$_br_base"
  done
  case "$_br_mode" in
    missing) : ;;  # simply never symlinked above
    noexec)
      cp "$TEST_REPO/$_br_script" "$_br_dir/$_br_script"
      chmod -x "$_br_dir/$_br_script"
      ;;
  esac
}

# --- test 5: fail closed on a missing script ----------------------------------
BROKEN5="$WORK/broken-missing"
mk_broken_repo "$BROKEN5" "hooks/no-direct-edit-guard.sh" missing
SETTINGS5="$WORK/fail-missing.json"
out5="$(run_sync --settings "$SETTINGS5" --repo "$BROKEN5" 2>&1)"; rc5=$?
assert_eq "missing script: sync exits 2" "$rc5" "2"
assert_contains "missing script: the script's path is in the output" "$out5" "$BROKEN5/hooks/no-direct-edit-guard.sh"
assert_false "missing script: no settings file is written at all" "[ -f '$SETTINGS5' ]"

# --- test 6: fail closed on a non-executable script ---------------------------
BROKEN6="$WORK/broken-noexec"
mk_broken_repo "$BROKEN6" "hooks/no-merge-guard.sh" noexec
SETTINGS6="$WORK/fail-noexec.json"
out6="$(run_sync --settings "$SETTINGS6" --repo "$BROKEN6" 2>&1)"; rc6=$?
assert_eq "non-executable script: sync exits 2" "$rc6" "2"
assert_contains "non-executable script: the script's path is in the output" "$out6" "$BROKEN6/hooks/no-merge-guard.sh"
assert_false "non-executable script: no settings file is written at all" "[ -f '$SETTINGS6' ]"

# --- test 7: fail closed on invalid JSON settings -----------------------------
SETTINGS7="$WORK/broken.json"
printf '{nope' > "$SETTINGS7"
out7="$(run_sync --settings "$SETTINGS7" --repo "$TEST_REPO" 2>&1)"; rc7=$?
assert_eq "invalid JSON settings: sync exits 2" "$rc7" "2"
assert_contains "invalid JSON settings: the message names the file" "$out7" "$SETTINGS7"
assert_eq "invalid JSON settings: the file is left byte-identical" "$(cat "$SETTINGS7")" "{nope"

# --- test 8: the asyncRewake entry shape --------------------------------------
SETTINGS8="$WORK/async-rewake.json"
run_sync --settings "$SETTINGS8" --repo "$TEST_REPO" >/dev/null
continuity_entry="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS8'))
for g in d['hooks']['Stop']:
    for h in g['hooks']:
        if h['command'].endswith('stop-continuity-crew.sh'):
            print(h.get('asyncRewake'))
            print(h.get('timeout'))
            print(h.get('rewakeSummary'))
")"
assert_eq "stop-continuity-crew.sh sets asyncRewake" "$(printf '%s\n' "$continuity_entry" | sed -n 1p)" "True"
assert_eq "stop-continuity-crew.sh sets timeout 600" "$(printf '%s\n' "$continuity_entry" | sed -n 2p)" "600"
assert_eq "stop-continuity-crew.sh sets the crew rewakeSummary" "$(printf '%s\n' "$continuity_entry" | sed -n 3p)" "Wingman fleet continuity (crew)"
guard_entry_options="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$SETTINGS8'))
for g in d['hooks']['Stop']:
    for h in g['hooks']:
        if h['command'].endswith('stop-guard-crew.sh'):
            print('asyncRewake' in h, 'timeout' in h, 'rewakeSummary' in h)
")"
assert_eq "stop-guard-crew.sh (no entry_options in the manifest) carries none of those keys" "$guard_entry_options" "False False False"

# --- test 9: concurrency - N reconcilers racing one fresh settings file -------
SETTINGS9="$WORK/concurrent.json"
_pids=""
for _i in $(seq 1 8); do
  run_sync --settings "$SETTINGS9" --repo "$TEST_REPO" >/dev/null 2>&1 &
  _pids="$_pids $!"
  wm_track "$!"
done
for _p in $_pids; do wait "$_p"; done
count9="$(all_registered "$SETTINGS9" | sort -u | wc -l | tr -d ' ')"
raw_count9="$(all_registered "$SETTINGS9" | wc -l | tr -d ' ')"
assert_eq "concurrent runs: every manifest entry appears exactly once (unique count)" "$count9" "$EXPECTED_COUNT"
assert_eq "concurrent runs: no entry was registered more than once (raw count matches unique count)" "$raw_count9" "$count9"
if uv run --no-project --quiet python -c "import json; json.load(open('$SETTINGS9'))" >/dev/null 2>&1; then
  ok "concurrent runs: the settings file is valid JSON"
else
  fail "concurrent runs: the settings file is valid JSON"
fi

test_summary
