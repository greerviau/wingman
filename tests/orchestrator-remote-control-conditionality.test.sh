#!/usr/bin/env bash
# E2E: bin/lib/orchestrator-bootstrap.sh's Remote-Control self-pane
# registration is gated on the resolved ORCHESTRATOR adapter's own
# WM_AGENT_REMOTE_CONTROL_FLAG being populated - only claude.sh sets it
# today, so every other orchestrator adapter must skip registration cleanly
# (not as an error) rather than writing a pane no watcher can ever act on.
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
  ln -s "$TEST_REPO/hooks/lib" "$1/hooks/lib"
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
out_a="$(TMUX_PANE="%wm-test-pane-a" PATH="$STUBDIR_A:$PATH" WINGMAN_RUN_ID="orch-rc-a" "$MIRROR_A/bin/lib/orchestrator-bootstrap.sh" --agent claude --repo "$MIRROR_A" 2>&1)"; rc_a=$?
wm_stop_guardian
assert_eq "claude orchestrator: a healthy bootstrap exits 0" "$rc_a" "0"
assert_true "claude orchestrator: the self-pane file was written" "[ -f '$WINGMAN_HOME/self-pane' ]"
assert_eq "claude orchestrator: it carries the tmux pane" \
  "$(cat "$WINGMAN_HOME/self-pane" 2>/dev/null)" "%wm-test-pane-a"
assert_not_contains "claude orchestrator: no guard-transport refusal leaked into a healthy run" \
  "$out_a" "has no orchestrator-side guard install/verify implementation"

# --- a stubbed adapter with no Remote-Control-equivalent flag: skipped ------
STUB_DESC="$TEST_REPO/bin/lib/agents/__test-orch-no-rc-stub.sh"
cat > "$STUB_DESC" <<'EOF'
WM_AGENT_BIN="__test-orch-no-rc-stub-bin"
WM_AGENT_DISPLAY_NAME="Test Orchestrator No-Remote-Control Stub"
WM_AGENT_GUARD_TRANSPORT=claude-json
WM_AGENT_CONTINUITY_TRANSPORT=claude-async-rewake
WM_AGENT_REMOTE_CONTROL_FLAG=""
EOF

test_new_home
MIRROR_B="$(wm_mktemp_dir)/mirror-b"
mk_mirror "$MIRROR_B"
STUBDIR_B="$(wm_mktemp_dir)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR_B/__test-orch-no-rc-stub-bin"
chmod +x "$STUBDIR_B/__test-orch-no-rc-stub-bin"
unset WM_AGENT_BIN_OVERRIDE
out_b="$(TMUX_PANE="%wm-test-pane-b" PATH="$STUBDIR_B:$PATH" WINGMAN_RUN_ID="orch-rc-b" "$MIRROR_B/bin/lib/orchestrator-bootstrap.sh" --agent __test-orch-no-rc-stub --repo "$MIRROR_B" 2>&1)"; rc_b=$?
wm_stop_guardian
assert_eq "no-remote-control orchestrator: a healthy bootstrap still exits 0" "$rc_b" "0"
assert_false "no-remote-control orchestrator: no self-pane file was written" "[ -f '$WINGMAN_HOME/self-pane' ]"
assert_not_contains "no-remote-control orchestrator: no guard-transport refusal leaked into a healthy run" \
  "$out_b" "has no orchestrator-side guard install/verify implementation"

# --- switching from claude to a no-RC adapter clears a PRIOR run's stale
# self-pane/.hash/.fired, rather than leaving self_pane_check to read a dead
# pointer as live -----------------------------------------------------------
test_new_home
MIRROR_C="$(wm_mktemp_dir)/mirror-c"
mk_mirror "$MIRROR_C"
STUBDIR_C1="$(wm_mktemp_dir)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR_C1/claude"; chmod +x "$STUBDIR_C1/claude"
unset WM_AGENT_BIN_OVERRIDE
TMUX_PANE="%wm-test-pane-c1" PATH="$STUBDIR_C1:$PATH" WINGMAN_RUN_ID="orch-rc-c1" "$MIRROR_C/bin/lib/orchestrator-bootstrap.sh" --agent claude --repo "$MIRROR_C" >/dev/null 2>&1
wm_stop_guardian
assert_true "staleness setup: the first (claude) bootstrap wrote a self-pane" "[ -f '$WINGMAN_HOME/self-pane' ]"
# Simulates watch-fleet's own self_pane_check having already touched these on
# a prior cycle (bin/watch-fleet:489,494) - both must be cleared too, not
# just self-pane itself.
printf 'stale-hash' > "$WINGMAN_HOME/self-pane.hash"
printf 'stale-fired' > "$WINGMAN_HOME/self-pane.fired"

STUBDIR_C2="$(wm_mktemp_dir)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR_C2/__test-orch-no-rc-stub-bin"
chmod +x "$STUBDIR_C2/__test-orch-no-rc-stub-bin"
unset WM_AGENT_BIN_OVERRIDE
# A DIFFERENT identity than the first (claude) bootstrap above - the cache is
# keyed per process identity (docs/analysis/2026-08-18-remove-bin-wingman-
# launcher-spec.md §4.5), so reusing the same one would read the first run's
# cached "pass" and skip the second bootstrap's own self-pane step entirely,
# never reaching the clear-stale-files branch this asserts.
out_c="$(TMUX_PANE="%wm-test-pane-c2" PATH="$STUBDIR_C2:$PATH" WINGMAN_RUN_ID="orch-rc-c2" "$MIRROR_C/bin/lib/orchestrator-bootstrap.sh" --agent __test-orch-no-rc-stub --repo "$MIRROR_C" 2>&1)"; rc_c=$?
wm_stop_guardian
assert_eq "staleness: the second (no-RC) bootstrap still exits 0" "$rc_c" "0"
assert_false "staleness: the stale self-pane is cleared" "[ -f '$WINGMAN_HOME/self-pane' ]"
assert_false "staleness: the stale self-pane.hash is cleared" "[ -f '$WINGMAN_HOME/self-pane.hash' ]"
assert_false "staleness: the stale self-pane.fired is cleared" "[ -f '$WINGMAN_HOME/self-pane.fired' ]"
assert_not_contains "staleness: no guard-transport refusal leaked into a healthy run" \
  "$out_c" "has no orchestrator-side guard install/verify implementation"

rm -f "$STUB_DESC"

test_summary
