#!/usr/bin/env bash
# E2E: bin/wingman's Remote-Control self-pane registration is gated on the
# resolved ORCHESTRATOR adapter's own WM_AGENT_REMOTE_CONTROL_FLAG being
# populated - only claude.sh sets it today, so every other orchestrator
# adapter must skip registration cleanly (not as an error) rather than
# writing a pane no watcher can ever act on.
#
# The stubbed adapter below keeps WM_AGENT_GUARD_TRANSPORT=claude-json so the
# run reaches a clean exit either way - the guard-transport gate itself is
# tests/orchestrator-guard-sync-gate.test.sh's own concern, and conflating
# the two here would leave an ambiguous failure with two possible causes.
#
# TMUX_PANE is set explicitly to a synthetic value for both cases below,
# rather than relying on whatever this test-runner process happens to
# inherit, so the only variable under test is the adapter's own flag.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mk_mirror() {
  mkdir -p "$1"
  ln -s "$TEST_REPO/bin" "$1/bin"
  mkdir -p "$1/hooks"
  for f in "$TEST_REPO"/hooks/*; do
    [ -f "$f" ] || continue
    ln -s "$f" "$1/hooks/$(basename "$f")"
  done
}

# --- claude (has WM_AGENT_REMOTE_CONTROL_FLAG): the pane IS registered ------
test_new_home
MIRROR_A="$(wm_mktemp_dir)/mirror-a"
mk_mirror "$MIRROR_A"
STUBDIR_A="$(wm_mktemp_dir)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR_A/claude"; chmod +x "$STUBDIR_A/claude"
# tests/lib.sh's default WM_AGENT_BIN_OVERRIDE would win over this file's
# PATH-based stub - unset it here (see tests/agent-descriptor-completeness.test.sh).
unset WM_AGENT_BIN_OVERRIDE
unset WM_ORCH_AGENT
out_a="$(TMUX_PANE="%wm-test-pane-a" PATH="$STUBDIR_A:$PATH" "$MIRROR_A/bin/wingman" 2>&1)"; rc_a=$?
wm_stop_guardian
assert_eq "claude orchestrator: a healthy launch exits 0" "$rc_a" "0"
assert_true "claude orchestrator: the self-pane file was written" "[ -f '$WINGMAN_HOME/self-pane' ]"
assert_eq "claude orchestrator: it carries the tmux pane" \
  "$(cat "$WINGMAN_HOME/self-pane" 2>/dev/null)" "%wm-test-pane-a"

# --- a stubbed adapter with no Remote-Control-equivalent flag: skipped ------
STUB_DESC="$TEST_REPO/bin/lib/agents/__test-orch-no-rc-stub.sh"
cat > "$STUB_DESC" <<'EOF'
WM_AGENT_BIN="__test-orch-no-rc-stub-bin"
WM_AGENT_DISPLAY_NAME="Test Orchestrator No-Remote-Control Stub"
WM_AGENT_GUARD_TRANSPORT=claude-json
WM_AGENT_REMOTE_CONTROL_FLAG=""
EOF

test_new_home
MIRROR_B="$(wm_mktemp_dir)/mirror-b"
mk_mirror "$MIRROR_B"
STUBDIR_B="$(wm_mktemp_dir)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR_B/__test-orch-no-rc-stub-bin"
chmod +x "$STUBDIR_B/__test-orch-no-rc-stub-bin"
unset WM_AGENT_BIN_OVERRIDE
out_b="$(TMUX_PANE="%wm-test-pane-b" PATH="$STUBDIR_B:$PATH" WM_ORCH_AGENT=__test-orch-no-rc-stub "$MIRROR_B/bin/wingman" 2>&1)"; rc_b=$?
wm_stop_guardian
assert_eq "no-remote-control orchestrator: a healthy launch still exits 0" "$rc_b" "0"
assert_false "no-remote-control orchestrator: no self-pane file was written" "[ -f '$WINGMAN_HOME/self-pane' ]"

rm -f "$STUB_DESC"

test_summary
