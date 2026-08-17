#!/usr/bin/env bash
# E2E: bin/wingman's two fail-closed pre-exec gates (the orchestrator-guard-
# transports plan, §5.5) - the CONTINUITY gate (WM_AGENT_CONTINUITY_TRANSPORT)
# and the GUARD-TRANSPORT gate (WM_AGENT_GUARD_TRANSPORT), run in that
# order. Proves three paths:
#   (a) claude (WM_AGENT_GUARD_TRANSPORT=claude-json, WM_AGENT_CONTINUITY_
#       TRANSPORT=claude-async-rewake, so it clears the continuity gate and
#       reaches the guard gate): still fails closed on a broken hooks/
#       checkout, via sync-user-hooks.py reconciliation.
#   (b) a stubbed adapter with NO continuity transport built (the ordinary
#       shape of codex/grok/opencode/pi today): refuses at the CONTINUITY
#       gate, before the guard-transport gate ever runs - the stub binary is
#       never invoked, and (the §5.5 ordering property, asserted rather than
#       assumed) NOTHING is written to the fake $HOME, since the guard
#       install never got the chance to touch it.
#   (c) a stubbed adapter WITH a continuity transport but a corrupt guard
#       install: clears the continuity gate, then refuses at the guard-
#       transport gate, naming the GUARD side of the failure, not
#       continuity - proves the two gates are independently reachable and
#       distinguishably reported, not one gate wearing two names.
# Every refusal happens pre-exec: the target binary is never invoked.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# mk_mirror <target_dir> [<hook_script_relpath> missing]
# Mirrors $TEST_REPO's bin/ (whole-directory symlink, which also covers
# bin/lib/guard-transport.sh and friends), hooks/ (individual top-level
# symlinks), and hooks/lib/ (whole-directory symlink - guard_dispatch.py and
# its own dependencies, needed by every non-claude transport's self-test).
# With a second argument, that one top-level hook script is left out of the
# mirror, forcing sync-user-hooks.py's own reconciliation to fail - the same
# fault-injection shape as tests/session-guard-hook-sync.test.sh's own
# mk_mirror, reproduced locally since that file's version isn't shared.
mk_mirror() {
  _mm_dir="$1"; _mm_missing="${2:-}"
  mkdir -p "$_mm_dir"
  ln -s "$TEST_REPO/bin" "$_mm_dir/bin"
  mkdir -p "$_mm_dir/hooks"
  ln -s "$TEST_REPO/hooks/lib" "$_mm_dir/hooks/lib"
  for f in "$TEST_REPO"/hooks/*; do
    [ -f "$f" ] || continue
    _mm_base="$(basename "$f")"
    [ "hooks/$_mm_base" = "$_mm_missing" ] && continue
    ln -s "$f" "$_mm_dir/hooks/$_mm_base"
  done
}

# =============================================================================
# (a) claude-json: unchanged regression - still fails closed on a broken repo
# (now reached via the guard-transport gate, after clearing continuity)
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
# The failure sink's component label is now the consolidated "guard
# transport" for every transport (plan §5.5's own pseudocode) rather than
# claude-json's former standalone "guard-hook sync" - a deliberate part of
# this consolidation, not drift.
assert_contains "claude orchestrator: the failure sink records the guard-transport component" \
  "$(cat "$WINGMAN_HOME/last-launch-failure" 2>/dev/null)" "guard transport"

# =============================================================================
# (b) no continuity transport built: refuses at the CONTINUITY gate, before
# the guard-transport gate (and therefore any $HOME write) ever runs
# =============================================================================
STUB_DESC_B="$TEST_REPO/bin/lib/agents/__test-orch-continuity-stub.sh"
cat > "$STUB_DESC_B" <<'EOF'
WM_AGENT_BIN="__test-orch-continuity-stub-bin"
WM_AGENT_DISPLAY_NAME="Test Orchestrator Continuity Stub"
WM_AGENT_GUARD_TRANSPORT=pi-extension
WM_AGENT_REMOTE_CONTROL_FLAG=""
EOF

test_new_home
MIRROR_B="$(wm_mktemp_dir)/mirror-healthy"
mk_mirror "$MIRROR_B"
STUBDIR_B="$(wm_mktemp_dir)"
MARKER_B="$STUBDIR_B/invoked"
cat > "$STUBDIR_B/__test-orch-continuity-stub-bin" <<EOF
#!/usr/bin/env bash
printf 'STUB_INVOKED %s\n' "\$*" > "$MARKER_B"
exit 0
EOF
chmod +x "$STUBDIR_B/__test-orch-continuity-stub-bin"
FAKE_HOME_B="$(wm_mktemp_dir)"

unset WM_AGENT_BIN_OVERRIDE
out_b="$(HOME="$FAKE_HOME_B" PATH="$STUBDIR_B:$PATH" WM_ORCH_AGENT=__test-orch-continuity-stub "$MIRROR_B/bin/wingman" 2>&1)"; rc_b=$?
wm_stop_guardian
assert_true "no continuity transport: refuses to start, even on a healthy repo" "[ $rc_b -ne 0 ]"
assert_false "the stub binary was never execed (fail-closed, pre-exec)" "[ -f '$MARKER_B' ]"
assert_contains "the refusal names the resolved adapter" "$out_b" "Test Orchestrator Continuity Stub"
assert_contains "the refusal names its guard transport" "$out_b" "pi-extension"
assert_contains "the refusal states the capability has not been built, not that it is impossible" \
  "$out_b" "has not been built, not one that was shown to be impossible"
assert_contains "the failure sink records the continuity-transport component" \
  "$(cat "$WINGMAN_HOME/last-launch-failure" 2>/dev/null)" "continuity transport"
# The §5.5 ordering property: the continuity gate has no side effects, so a
# doomed launch must never have touched the operator's home directory at
# all - asserted directly, not assumed from the stub never having run.
assert_false "nothing was written to the fake \$HOME (the guard install never ran)" \
  "[ -d '$FAKE_HOME_B/.grok' ] || [ -d '$FAKE_HOME_B/.codex' ] || [ -d '$FAKE_HOME_B/.config/opencode' ]"

rm -f "$STUB_DESC_B"

# =============================================================================
# (c) a continuity transport IS present, but the guard install is corrupt:
# clears the continuity gate, then refuses at the guard-transport gate,
# naming the GUARD side specifically
# =============================================================================
STUB_DESC_C="$TEST_REPO/bin/lib/agents/__test-orch-corrupt-guard-stub.sh"
cat > "$STUB_DESC_C" <<'EOF'
WM_AGENT_BIN="__test-orch-corrupt-guard-stub-bin"
WM_AGENT_DISPLAY_NAME="Test Orchestrator Corrupt-Guard Stub"
WM_AGENT_GUARD_TRANSPORT=grok-json
WM_AGENT_CONTINUITY_TRANSPORT=test-stub-continuity
WM_AGENT_REMOTE_CONTROL_FLAG=""
EOF
# Deliberately corrupt: grok-json's own guard-transport branch refuses
# outright unless WM_AGENT_GUARD_ENV is exactly GROK_CLAUDE_HOOKS_ENABLED=0
# (bin/lib/guard-transport.sh's _wm_gt_sync_grok) - this stub carries none,
# simulating a descriptor that forgot to set it.

test_new_home
MIRROR_C="$(wm_mktemp_dir)/mirror-healthy-c"
mk_mirror "$MIRROR_C"
STUBDIR_C="$(wm_mktemp_dir)"
MARKER_C="$STUBDIR_C/invoked"
cat > "$STUBDIR_C/__test-orch-corrupt-guard-stub-bin" <<EOF
#!/usr/bin/env bash
printf 'STUB_INVOKED %s\n' "\$*" > "$MARKER_C"
exit 0
EOF
chmod +x "$STUBDIR_C/__test-orch-corrupt-guard-stub-bin"
FAKE_HOME_C="$(wm_mktemp_dir)"

unset WM_AGENT_BIN_OVERRIDE
out_c="$(HOME="$FAKE_HOME_C" PATH="$STUBDIR_C:$PATH" WM_ORCH_AGENT=__test-orch-corrupt-guard-stub "$MIRROR_C/bin/wingman" 2>&1)"; rc_c=$?
wm_stop_guardian
assert_true "corrupt guard install: refuses to start" "[ $rc_c -ne 0 ]"
assert_false "the stub binary was never execed" "[ -f '$MARKER_C' ]"
assert_contains "the refusal names the GUARD problem (GROK_CLAUDE_HOOKS_ENABLED), not continuity" \
  "$out_c" "GROK_CLAUDE_HOOKS_ENABLED=0"
assert_not_contains "the refusal does NOT claim the continuity capability is missing (it isn't - it cleared that gate)" \
  "$out_c" "has not been built"
assert_contains "the failure sink records the guard-transport component" \
  "$(cat "$WINGMAN_HOME/last-launch-failure" 2>/dev/null)" "guard transport"

rm -f "$STUB_DESC_C"

test_summary
