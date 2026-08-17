#!/usr/bin/env bash
# E2E: bin/lib/guard-transport.sh - the §5.4.0 self-test standard (the
# orchestrator-guard-transports plan, step 4) and the relocated claude-json
# branch of wm_guard_transport_sync. No real non-Claude CLI is installed
# here; this file proves the SELF-TEST MECHANISM itself against real,
# already-built command lines (hooks/no-foreground-watcher-guard.sh for
# claude, hooks/lib/guard_dispatch.py for the four non-Claude dialects) and
# against deliberately-broken stub commands, per dialect.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"
. "$TEST_REPO/bin/lib/guard-transport.sh"

test_new_home
export WINGMAN_HOME
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# =============================================================================
# (1) the self-test passes against a correct, real registration - one per
# dialect, including claude's own real hook entry point
# =============================================================================
assert_true "claude: self-test passes against the real hook" \
  "wm_guard_transport_selftest claude $TEST_REPO/hooks/no-foreground-watcher-guard.sh"

for D in codex grok opencode pi; do
  assert_true "$D: self-test passes against the real dispatcher" \
    "wm_guard_transport_selftest $D uv run --no-project --quiet $TEST_REPO/hooks/lib/guard_dispatch.py --dialect $D --guards foreground-watcher"
done

# =============================================================================
# (2) MF-1 guard: the deny fixture's verdict is unchanged with
# WINGMAN_CREW_ID unset - proves nobody can later swap in a crew-only-guard
# fixture (e.g. gh pr merge) that would pass vacuously in the orchestrator's
# own preflight scope (§5.4.0's own documented rejected-candidate table)
# =============================================================================
assert_true "the self-test itself never sets WINGMAN_CREW_ID (still unset after two full passes)" \
  "[ -z \"\${WINGMAN_CREW_ID:-}\" ]"

# =============================================================================
# (3) refuses when the registered command is unrunnable
# =============================================================================
out="$(wm_guard_transport_selftest codex /no/such/binary --dialect codex --guards foreground-watcher 2>&1)"; rc=$?
assert_true "an unrunnable registered command refuses" "[ $rc -ne 0 ]"
assert_contains "the refusal names the exact command" "$out" "/no/such/binary"
assert_contains "the refusal names the remedy" "$out" "Remedy:"

# =============================================================================
# (4) refuses when mis-flagged (a --dialect typo means an unknown dialect,
# which guard_dispatch.py itself rejects with a nonzero exit and no valid
# deny/allow shape)
# =============================================================================
out="$(wm_guard_transport_selftest codex uv run --no-project --quiet "$TEST_REPO/hooks/lib/guard_dispatch.py" --dialect nonexistent-dialect --guards foreground-watcher 2>&1)"; rc=$?
assert_true "a mis-flagged (bad --dialect) registration refuses" "[ $rc -ne 0 ]"

# =============================================================================
# (5) refuses when the registered command imports a broken module
# =============================================================================
BROKEN_DISPATCH="$(wm_mktemp_file)"
cat > "$BROKEN_DISPATCH" <<'EOF'
import sys
import this_module_does_not_exist  # noqa
EOF
out="$(wm_guard_transport_selftest codex uv run --no-project --quiet python "$BROKEN_DISPATCH" 2>&1)"; rc=$?
assert_true "a command importing a broken module refuses" "[ $rc -ne 0 ]"

# =============================================================================
# (6) refuses on a deny-everything dispatcher (the ALLOW half's whole
# purpose: catch an inverted condition before it reaches a live session)
# =============================================================================
DENY_EVERYTHING="$(wm_mktemp_file)"
cat > "$DENY_EVERYTHING" <<'EOF'
import sys
print('{"decision": "deny", "reason": "stub always denies"}')
sys.exit(2)
EOF
out="$(wm_guard_transport_selftest pi uv run --no-project --quiet python "$DENY_EVERYTHING" 2>&1)"; rc=$?
assert_true "a deny-everything stub refuses (caught by the allow-fixture half)" "[ $rc -ne 0 ]"
assert_contains "the refusal names the allow-fixture failure specifically" "$out" "denied the known-allow fixture"

# =============================================================================
# (7) wm_guard_transport_sync's claude-json branch: relocated, behaviour-
# preserving (still registers via sync-user-hooks.py) and now also runs the
# self-test.
# =============================================================================
MIRROR="$(wm_mktemp_dir)/mirror-healthy"
mkdir -p "$MIRROR"
ln -s "$TEST_REPO/bin" "$MIRROR/bin"
mkdir -p "$MIRROR/hooks"
for f in "$TEST_REPO"/hooks/*; do
  [ -f "$f" ] || continue
  ln -s "$f" "$MIRROR/hooks/$(basename "$f")"
done

out="$(wm_guard_transport_sync claude-json "$MIRROR" 2>&1)"; rc=$?
assert_true "claude-json: a healthy repo syncs and self-tests successfully" "[ $rc -eq 0 ]"
assert_eq "claude-json: success prints nothing" "$out" ""
assert_true "claude-json: the hooks were actually registered" \
  "grep -q no-foreground-watcher-guard '$WM_CLAUDE_USER_SETTINGS'"

# A broken repo (missing hook script) still refuses, naming the sync
# failure - unchanged regression behaviour (tests/orchestrator-guard-sync-
# gate.test.sh part (a) exercises the equivalent path through bin/wingman
# itself; this asserts the same property at the library-function level).
MIRROR_BAD="$(wm_mktemp_dir)/mirror-bad"
mkdir -p "$MIRROR_BAD/hooks"
ln -s "$TEST_REPO/bin" "$MIRROR_BAD/bin"
for f in "$TEST_REPO"/hooks/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ "$b" = "no-direct-edit-guard.sh" ] && continue
  ln -s "$f" "$MIRROR_BAD/hooks/$b"
done
out="$(wm_guard_transport_sync claude-json "$MIRROR_BAD" 2>&1)"; rc=$?
assert_true "claude-json: a broken repo (missing script) still refuses" "[ $rc -ne 0 ]"
assert_contains "the refusal names the missing script" "$out" "no-direct-edit-guard.sh"

# =============================================================================
# (8) an unimplemented transport refuses without touching anything
# =============================================================================
out="$(wm_guard_transport_sync codex-json "$MIRROR" 2>&1)"; rc=$?
assert_true "codex-json (not yet built) refuses" "[ $rc -ne 0 ]"
assert_contains "the refusal names the transport" "$out" "codex-json"
assert_contains "the refusal states no orchestrator-side implementation exists yet" \
  "$out" "no orchestrator-side guard install/verify implementation"

test_summary
