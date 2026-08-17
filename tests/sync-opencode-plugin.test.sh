#!/usr/bin/env bash
# E2E: bin/lib/sync-opencode-plugin.py - the opencode-plugin guard
# transport's reconciler (the orchestrator-guard-transports plan, step 8).
# Renders bin/lib/agents/opencode/wingman-guard.js.tmpl into a plain file
# (never merged/reconciled group-by-group, since it is wingman's own -
# mirrors tests/sync-grok-hooks.test.sh/tests/sync-codex-hooks.test.sh's own
# coverage shape).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SYNC="$TEST_REPO/bin/lib/sync-opencode-plugin.py"
WORK="$(wm_mktemp_dir)"

run_sync() {
  # run_sync <plugin-path> [extra args...]
  _rs_path="$1"; shift
  uv run --no-project --quiet "$SYNC" --plugin-path "$_rs_path" --repo "$TEST_REPO" "$@"
}

# =============================================================================
# fresh install
# =============================================================================
P1="$WORK/wingman-guard-1.js"
out="$(run_sync "$P1" 2>&1)"; rc=$?
assert_true "fresh install exits 0" "[ $rc -eq 0 ]"
assert_true "the file was written" "[ -f '$P1' ]"

content="$(cat "$P1")"
assert_contains "the dispatcher path is baked in" "$content" "hooks/lib/guard_dispatch.py"
assert_contains "the guards list names direct-edit" "$content" "direct-edit"
assert_contains "the guards list names watcher-kill" "$content" "watcher-kill"
assert_not_contains "crew-only merge is not baked in" "$content" ",merge,"
assert_true "node --check accepts the rendered file as plain JS" "node --check '$P1'"

# =============================================================================
# idempotent re-run
# =============================================================================
mtime_before="$(stat -c %Y "$P1" 2>/dev/null || stat -f %m "$P1")"
sleep 1
out="$(run_sync "$P1" --check 2>&1)"; rc=$?
assert_true "--check reports already up to date" "[ $rc -eq 0 ]"
mtime_after="$(stat -c %Y "$P1" 2>/dev/null || stat -f %m "$P1")"
assert_eq "the file was not rewritten" "$mtime_after" "$mtime_before"

# =============================================================================
# a hand-edited file is overwritten with the correct render
# =============================================================================
printf '// hand-edited garbage\n' > "$P1"
out="$(run_sync "$P1" 2>&1)"; rc=$?
assert_true "a hand-edited file is rewritten" "[ $rc -eq 0 ]"
assert_not_contains "the hand-edit is gone" "$(cat "$P1")" "hand-edited garbage"
assert_contains "the correct render is back" "$(cat "$P1")" "guard_dispatch.py"

# =============================================================================
# fail-closed: missing dispatcher
# =============================================================================
BAD_REPO="$(wm_mktemp_dir)/no-dispatcher"
mkdir -p "$BAD_REPO"
P2="$WORK/wingman-guard-2.js"
out="$(uv run --no-project --quiet "$SYNC" --plugin-path "$P2" --repo "$BAD_REPO" 2>&1)"; rc=$?
assert_true "a missing dispatcher refuses" "[ $rc -ne 0 ]"
assert_contains "the failure names the missing dispatcher" "$out" "guard_dispatch.py"
assert_false "nothing was written" "[ -f '$P2' ]"

# =============================================================================
# fail-closed: missing/broken template
# =============================================================================
NO_TMPL_REPO="$(wm_mktemp_dir)/no-template"
mkdir -p "$NO_TMPL_REPO/hooks/lib" "$NO_TMPL_REPO/bin/lib/agents/opencode"
cp "$TEST_REPO/hooks/lib/guard_dispatch.py" "$NO_TMPL_REPO/hooks/lib/guard_dispatch.py"
P3="$WORK/wingman-guard-3.js"
out="$(uv run --no-project --quiet "$SYNC" --plugin-path "$P3" --repo "$NO_TMPL_REPO" 2>&1)"; rc=$?
assert_true "a missing template refuses" "[ $rc -ne 0 ]"
assert_contains "the failure names the missing template" "$out" "wingman-guard.js.tmpl"

mkdir -p "$NO_TMPL_REPO/bin/lib/agents/opencode"
printf 'export const WingmanGuard = () => ({});\n' > "$NO_TMPL_REPO/bin/lib/agents/opencode/wingman-guard.js.tmpl"
out="$(uv run --no-project --quiet "$SYNC" --plugin-path "$P3" --repo "$NO_TMPL_REPO" 2>&1)"; rc=$?
assert_true "a template missing the placeholder tokens refuses" "[ $rc -ne 0 ]"
assert_contains "the failure names the missing placeholders" "$out" "placeholder"

# =============================================================================
# concurrent writers converge, no corruption
# =============================================================================
P4="$WORK/wingman-guard-4.js"
rm -f "$P4"
pids=""
for i in 1 2 3 4 5; do
  run_sync "$P4" >/dev/null 2>&1 &
  pids="$pids $!"
done
wait $pids
assert_true "node --check still accepts the file after concurrent writers" "node --check '$P4'"
assert_contains "the converged content is correct" "$(cat "$P4")" "guard_dispatch.py"

test_summary
