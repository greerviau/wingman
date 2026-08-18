#!/usr/bin/env bash
# E2E: bin/lib/sync-grok-hooks.py - the grok-json guard transport's
# reconciler (the orchestrator-guard-transports plan, step 6). Mirrors
# tests/sync-user-hooks.test.sh's own coverage shape (fresh install,
# idempotent re-run, stale-entry update in place, fail-closed on an
# unparseable existing file, concurrent-writer safety), adapted for a
# wholesale-rendered, wingman-OWNED file rather than a merged shared
# settings.json.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SYNC="$TEST_REPO/bin/lib/sync-grok-hooks.py"
run_sync() { uv run --no-project --quiet "$SYNC" "$@"; }

WORK="$(wm_mktemp_dir)"
SETTINGS="$WORK/wingman.json"

# =============================================================================
# fresh install
# =============================================================================
out="$(run_sync --settings "$SETTINGS" --repo "$TEST_REPO" 2>&1)"; rc=$?
assert_true "fresh install exits 0" "[ $rc -eq 0 ]"
assert_true "the file was written" "[ -f '$SETTINGS' ]"

content="$(cat "$SETTINGS")"
assert_contains "the matcher covers Bash/apply_patch/Edit/Write" "$content" '"^(Bash|apply_patch|Edit|Write)$"'
assert_contains "the command targets the real dispatcher" "$content" "hooks/lib/guard_dispatch.py"
assert_contains "the dialect is grok" "$content" "--dialect grok"
assert_contains "the timeout is raised to 30 (not grok's own 5s default)" "$content" '"timeout": 30'
assert_contains "the guards list names direct-edit" "$content" "direct-edit"
assert_contains "the guards list names watcher-kill" "$content" "watcher-kill"
assert_contains "the guards list names spawn-pause" "$content" "spawn-pause"
assert_contains "the guards list names foreground-watcher" "$content" "foreground-watcher"
assert_contains "the guards list names foreground-poll-loop" "$content" "foreground-poll-loop"
assert_not_contains "crew-only merge is NOT in the guards list" "$content" ",merge,"
assert_not_contains "crew-only worker-spawn is NOT in the guards list" "$content" "worker-spawn"

# =============================================================================
# idempotent re-run: --check reports nothing to do, no write
# =============================================================================
mtime_before="$(stat -c %Y "$SETTINGS" 2>/dev/null || stat -f %m "$SETTINGS")"
sleep 1
out="$(run_sync --settings "$SETTINGS" --repo "$TEST_REPO" --check 2>&1)"; rc=$?
assert_true "--check reports already up to date (exit 0)" "[ $rc -eq 0 ]"
mtime_after="$(stat -c %Y "$SETTINGS" 2>/dev/null || stat -f %m "$SETTINGS")"
assert_eq "the file was not rewritten (mtime unchanged)" "$mtime_after" "$mtime_before"

# =============================================================================
# a genuinely stale file (different command) is rewritten in place
# =============================================================================
cat > "$SETTINGS" <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "stale-command", "timeout": 5}]}]}}
EOF
out="$(run_sync --settings "$SETTINGS" --repo "$TEST_REPO" 2>&1)"; rc=$?
assert_true "a stale file is rewritten (exit 0)" "[ $rc -eq 0 ]"
content="$(cat "$SETTINGS")"
assert_not_contains "the stale command is gone" "$content" "stale-command"
assert_contains "the correct command is now present" "$content" "guard_dispatch.py"
assert_contains "the timeout is corrected to 30" "$content" '"timeout": 30'

# =============================================================================
# fail-closed: a missing dispatcher script refuses and writes nothing
# =============================================================================
BAD_REPO="$(wm_mktemp_dir)/no-dispatcher-here"
mkdir -p "$BAD_REPO"
NEVER_WRITTEN="$WORK/never-written.json"
out="$(run_sync --settings "$NEVER_WRITTEN" --repo "$BAD_REPO" 2>&1)"; rc=$?
assert_true "a missing dispatcher script refuses" "[ $rc -ne 0 ]"
assert_contains "the failure names the missing dispatcher" "$out" "guard_dispatch.py"
assert_false "nothing was written" "[ -f '$NEVER_WRITTEN' ]"

# =============================================================================
# fail-closed: an unparseable existing file refuses (never overwritten
# silently, never treated as absent)
# =============================================================================
BROKEN="$WORK/broken.json"
printf 'not json at all' > "$BROKEN"
out="$(run_sync --settings "$BROKEN" --repo "$TEST_REPO" 2>&1)"; rc=$?
assert_true "an unparseable existing file refuses" "[ $rc -ne 0 ]"
assert_eq "the broken file is left untouched" "$(cat "$BROKEN")" "not json at all"

# =============================================================================
# fail-closed: an unparseable manifest refuses
# =============================================================================
BAD_MANIFEST="$(wm_mktemp_file)"
printf 'not json' > "$BAD_MANIFEST"
NEVER2="$WORK/never2.json"
out="$(run_sync --settings "$NEVER2" --repo "$TEST_REPO" --manifest "$BAD_MANIFEST" 2>&1)"; rc=$?
assert_true "an unparseable manifest refuses" "[ $rc -ne 0 ]"
assert_false "nothing was written" "[ -f '$NEVER2' ]"

# =============================================================================
# concurrent writers: every run converges on the identical desired document,
# no corruption, no torn write (matches sync-user-hooks.test.sh's own
# concurrent-run coverage)
# =============================================================================
CONCURRENT="$WORK/concurrent.json"
rm -f "$CONCURRENT"
pids=""
for i in 1 2 3 4 5; do
  run_sync --settings "$CONCURRENT" --repo "$TEST_REPO" >/dev/null 2>&1 &
  pids="$pids $!"
done
wait $pids
assert_true "the file is valid JSON after concurrent runs" \
  "uv run --no-project --quiet python -c \"import json; json.load(open('$CONCURRENT'))\""
final_content="$(cat "$CONCURRENT")"
assert_contains "the converged content is the correct desired document" "$final_content" "guard_dispatch.py"

test_summary
