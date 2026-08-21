#!/usr/bin/env bash
# E2E regression: the tmux-server guardian arm inside bin/lib/orchestrator-
# bootstrap.sh must stay UNCONDITIONAL regardless of which orchestrator
# agent resolves - it is plain tmux/process work with no dependency on the
# resolved descriptor's own fields, and this file exists so a future change
# accidentally making it adapter-conditional fails a test instead of
# drifting silently.
#
# The other two properties this file used to check under bin/wingman -
# WINGMAN_RUN_ID being minted and exported, and WINGMAN_BIN/WINGMAN_REPO
# being exported, into the exec'd process's own environment - no longer
# apply at all: there is no launcher and no exec step any more (docs/
# analysis/2026-08-18-remove-bin-wingman-launcher-spec.md, §4.3/§4.4). The
# run-id substitute is now computed on demand (bin/lib/harness-identity.sh),
# never minted or exported; WINGMAN_BIN/WINGMAN_REPO are self-bootstrapped by
# the session itself (docs/configuration.md's "The orchestrator's own
# self-bootstrap"), never exported into a process nothing execs. Self-pane
# registration's own adapter-conditionality is tests/orchestrator-remote-
# control-conditionality.test.sh's own concern, not duplicated here.
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

wait_for_file() {
  _wf_tries=30
  while [ "$_wf_tries" -gt 0 ]; do
    [ -f "$1" ] && return 0
    sleep 0.1
    _wf_tries=$((_wf_tries - 1))
  done
  return 1
}

# run_one <label> <agent> <mirror-dir> <stub-dir> <stub-bin-name> <identity>
run_one() {
  _ro_label="$1" _ro_agent="$2" _ro_mirror="$3" _ro_stubdir="$4" _ro_stubname="$5" _ro_identity="$6"
  test_new_home
  mk_mirror "$_ro_mirror"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$_ro_stubdir/$_ro_stubname"
  chmod +x "$_ro_stubdir/$_ro_stubname"

  # tests/lib.sh's default WM_AGENT_BIN_OVERRIDE would win over this file's
  # PATH-based stub - unset it here (see tests/agent-descriptor-completeness.test.sh).
  unset WM_AGENT_BIN_OVERRIDE
  _ro_rc="$(TMUX_PANE="%wm-test-unaffected" PATH="$_ro_stubdir:$PATH" WINGMAN_RUN_ID="$_ro_identity" \
    "$_ro_mirror/bin/lib/orchestrator-bootstrap.sh" --agent "$_ro_agent" --repo "$_ro_mirror" >/dev/null 2>&1; echo $?)"

  assert_true "$_ro_label: the bootstrap exits 0" "[ $_ro_rc -eq 0 ]"
  assert_true "$_ro_label: the guardian's pidfile appears (the arm ran)" "wait_for_file '$WINGMAN_HOME/tmux-guardian.pid'"
  wm_stop_guardian
}

# --- claude ------------------------------------------------------------------
run_one "claude orchestrator" claude "$(wm_mktemp_dir)/mirror-a" "$(wm_mktemp_dir)" claude "orch-unaffected-a"

# --- a stubbed non-claude orchestrator adapter (implemented guard transport,
# so this run legitimately reaches a clean exit too - isolating this check
# from the separate guard-transport gate tests/orchestrator-guard-sync-
# gate.test.sh already covers) ------------------------------------------------
STUB_DESC="$TEST_REPO/bin/lib/agents/__test-orch-unaffected-stub.sh"
cat > "$STUB_DESC" <<'EOF'
WM_AGENT_BIN="__test-orch-unaffected-stub-bin"
WM_AGENT_DISPLAY_NAME="Test Orchestrator Unaffected-Behavior Stub"
WM_AGENT_GUARD_TRANSPORT=claude-json
WM_AGENT_CONTINUITY_TRANSPORT=claude-async-rewake
WM_AGENT_REMOTE_CONTROL_FLAG=""
EOF
run_one "non-claude orchestrator (stub)" __test-orch-unaffected-stub \
  "$(wm_mktemp_dir)/mirror-b" "$(wm_mktemp_dir)" __test-orch-unaffected-stub-bin "orch-unaffected-b"
rm -f "$STUB_DESC"

test_summary
