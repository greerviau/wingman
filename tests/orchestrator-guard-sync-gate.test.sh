#!/usr/bin/env bash
# E2E: bin/wingman's fail-closed guard-hook-sync gate dispatches on the
# resolved ORCHESTRATOR adapter's own WM_AGENT_GUARD_TRANSPORT. Proves two
# paths:
#   (a) claude (WM_AGENT_GUARD_TRANSPORT=claude-json): still fails closed on
#       a broken hooks/ checkout, via sync-user-hooks.py reconciliation.
#   (b) a stubbed non-claude orchestrator adapter with an unimplemented guard
#       transport: bin/wingman refuses to start even against a perfectly
#       healthy repo, because there is currently no orchestrator-side
#       install/verify path for any transport but claude-json - the intended
#       safety property for an unbuilt transport, not a bug.
# Both refusals happen pre-exec: the target binary is never invoked either
# way, distinguishing this from a crew-side, spawn-time-only check.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# mk_mirror <target_dir> [<hook_script_relpath> missing]
# Mirrors $TEST_REPO's bin/ (whole-directory symlink) and hooks/ (individual
# symlinks); with a second argument, that one hook script is left out of the
# mirror, forcing sync-user-hooks.py's own reconciliation to fail - the same
# fault-injection shape as tests/session-guard-hook-sync.test.sh's own
# mk_mirror, reproduced locally since that file's version isn't shared.
mk_mirror() {
  _mm_dir="$1"; _mm_missing="${2:-}"
  mkdir -p "$_mm_dir"
  ln -s "$TEST_REPO/bin" "$_mm_dir/bin"
  mkdir -p "$_mm_dir/hooks"
  for f in "$TEST_REPO"/hooks/*; do
    [ -f "$f" ] || continue
    _mm_base="$(basename "$f")"
    [ "hooks/$_mm_base" = "$_mm_missing" ] && continue
    ln -s "$f" "$_mm_dir/hooks/$_mm_base"
  done
}

# =============================================================================
# (a) claude-json: unchanged regression - still fails closed on a broken repo
# =============================================================================
test_new_home
MIRROR_A="$(wm_mktemp_dir)/mirror-bad-claude"
mk_mirror "$MIRROR_A" "hooks/no-direct-edit-guard.sh"
STUBDIR_A="$(wm_mktemp_dir)"
MARKER_A="$STUBDIR_A/invoked"
cat > "$STUBDIR_A/claude" <<EOF
#!/usr/bin/env bash
printf 'STUB_CLAUDE_INVOKED %s\n' "\$*" > "$MARKER_A"
exit 0
EOF
chmod +x "$STUBDIR_A/claude"
# tests/lib.sh's default WM_AGENT_BIN_OVERRIDE would win over this file's
# PATH-based stub - unset it here (see tests/agent-descriptor-completeness.test.sh).
unset WM_AGENT_BIN_OVERRIDE
unset WM_ORCH_AGENT
out_a="$(PATH="$STUBDIR_A:$PATH" "$MIRROR_A/bin/wingman" 2>&1)"; rc_a=$?
wm_stop_guardian
assert_true "claude orchestrator: a broken repo still exits non-zero (regression)" "[ $rc_a -ne 0 ]"
assert_false "claude orchestrator: claude was never execed" "[ -f '$MARKER_A' ]"
assert_contains "claude orchestrator: the refusal still names the remedy" "$out_a" "bin/doctor -y"
assert_contains "claude orchestrator: the failure sink still records a guard-hook-sync failure" \
  "$(cat "$WINGMAN_HOME/last-launch-failure" 2>/dev/null)" "guard-hook sync"

# =============================================================================
# (b) an unimplemented guard transport fails closed even on a healthy repo
# =============================================================================
STUB_DESC="$TEST_REPO/bin/lib/agents/__test-orch-guard-transport-stub.sh"
cat > "$STUB_DESC" <<'EOF'
WM_AGENT_BIN="__test-orch-guard-transport-stub-bin"
WM_AGENT_DISPLAY_NAME="Test Orchestrator Guard-Transport Stub"
WM_AGENT_GUARD_TRANSPORT=pi-extension
WM_AGENT_REMOTE_CONTROL_FLAG=""
EOF

test_new_home
MIRROR_B="$(wm_mktemp_dir)/mirror-healthy"
mk_mirror "$MIRROR_B"
STUBDIR_B="$(wm_mktemp_dir)"
MARKER_B="$STUBDIR_B/invoked"
cat > "$STUBDIR_B/__test-orch-guard-transport-stub-bin" <<EOF
#!/usr/bin/env bash
printf 'STUB_INVOKED %s\n' "\$*" > "$MARKER_B"
exit 0
EOF
chmod +x "$STUBDIR_B/__test-orch-guard-transport-stub-bin"

unset WM_AGENT_BIN_OVERRIDE
out_b="$(PATH="$STUBDIR_B:$PATH" WM_ORCH_AGENT=__test-orch-guard-transport-stub "$MIRROR_B/bin/wingman" 2>&1)"; rc_b=$?
wm_stop_guardian
assert_true "an unimplemented guard transport refuses to start, even on a healthy repo" "[ $rc_b -ne 0 ]"
assert_false "the stub binary was never execed (fail-closed, pre-exec)" "[ -f '$MARKER_B' ]"
assert_contains "the refusal names the resolved adapter" "$out_b" "Test Orchestrator Guard-Transport Stub"
assert_contains "the refusal names its guard transport" "$out_b" "pi-extension"
assert_contains "the refusal states no orchestrator-side implementation exists yet" \
  "$out_b" "no orchestrator-side guard install/verify implementation"
assert_contains "the failure sink records the guard-transport component, not a sync attempt" \
  "$(cat "$WINGMAN_HOME/last-launch-failure" 2>/dev/null)" "guard transport"

rm -f "$STUB_DESC"

test_summary
