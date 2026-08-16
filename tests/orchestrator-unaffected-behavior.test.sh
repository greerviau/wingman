#!/usr/bin/env bash
# E2E regression: three of bin/wingman's startup steps must stay
# UNCONDITIONAL regardless of which orchestrator agent resolves - the
# tmux-server guardian arm, the WINGMAN_RUN_ID mint, and the
# WINGMAN_BIN/WINGMAN_REPO export. None of these three were ever
# hooks/flags-shaped, and this file exists so a future change accidentally
# making one of them adapter-conditional fails a test instead of drifting
# silently.
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

wait_for_file() {
  _wf_tries=30
  while [ "$_wf_tries" -gt 0 ]; do
    [ -f "$1" ] && return 0
    sleep 0.1
    _wf_tries=$((_wf_tries - 1))
  done
  return 1
}

# run_one <label> <orch-agent-or-empty> <mirror-dir> <stub-dir> <stub-bin-name>
#
# The stub binary echoes its own inherited WINGMAN_RUN_ID/WINGMAN_BIN/
# WINGMAN_REPO to a marker file, so this proves the three checks reach
# whatever bin/wingman actually execs, not merely that bin/wingman itself
# computed them internally.
run_one() {
  _ro_label="$1" _ro_agent="$2" _ro_mirror="$3" _ro_stubdir="$4" _ro_stubname="$5"
  test_new_home
  mk_mirror "$_ro_mirror"
  _ro_marker="$_ro_stubdir/env"
  cat > "$_ro_stubdir/$_ro_stubname" <<EOF
#!/usr/bin/env bash
printf 'RUN_ID=%s\nBIN=%s\nREPO=%s\n' "\$WINGMAN_RUN_ID" "\$WINGMAN_BIN" "\$WINGMAN_REPO" > "$_ro_marker"
exit 0
EOF
  chmod +x "$_ro_stubdir/$_ro_stubname"

  # tests/lib.sh's default WM_AGENT_BIN_OVERRIDE would win over this file's
  # PATH-based stub - unset it here (see tests/agent-descriptor-completeness.test.sh).
  unset WM_AGENT_BIN_OVERRIDE
  if [ -n "$_ro_agent" ]; then
    _ro_out="$(TMUX_PANE="%wm-test-unaffected" PATH="$_ro_stubdir:$PATH" WM_ORCH_AGENT="$_ro_agent" "$_ro_mirror/bin/wingman" 2>&1)"
  else
    _ro_out="$(TMUX_PANE="%wm-test-unaffected" PATH="$_ro_stubdir:$PATH" "$_ro_mirror/bin/wingman" 2>&1)"
  fi
  _ro_rc=$?

  assert_true "$_ro_label: bin/wingman reaches exec (exits 0)" "[ $_ro_rc -eq 0 ]"
  assert_true "$_ro_label: the guardian's pidfile appears (the arm ran)" "wait_for_file '$WINGMAN_HOME/tmux-guardian.pid'"
  wm_stop_guardian

  assert_true "$_ro_label: the env marker was written (exec reached)" "[ -f '$_ro_marker' ]"
  _ro_env="$(cat "$_ro_marker" 2>/dev/null)"
  _ro_runid="$(printf '%s\n' "$_ro_env" | sed -n 's/^RUN_ID=//p')"
  _ro_bin="$(printf '%s\n' "$_ro_env" | sed -n 's/^BIN=//p')"
  _ro_repo="$(printf '%s\n' "$_ro_env" | sed -n 's/^REPO=//p')"
  assert_true "$_ro_label: WINGMAN_RUN_ID was minted (non-empty)" "[ -n '$_ro_runid' ]"
  assert_eq "$_ro_label: WINGMAN_BIN points at this mirror's bin/" "$_ro_bin" "$_ro_mirror/bin"
  assert_eq "$_ro_label: WINGMAN_REPO points at this mirror's root" "$_ro_repo" "$_ro_mirror"
}

# --- default (claude) --------------------------------------------------------
unset WM_ORCH_AGENT
run_one "claude orchestrator (default)" "" "$(wm_mktemp_dir)/mirror-a" "$(wm_mktemp_dir)" claude

# --- a stubbed non-claude orchestrator adapter (implemented guard transport,
# so this run legitimately reaches exec too - isolating these three checks
# from the separate guard-transport gate tests/orchestrator-guard-sync-
# gate.test.sh already covers) ------------------------------------------------
STUB_DESC="$TEST_REPO/bin/lib/agents/__test-orch-unaffected-stub.sh"
cat > "$STUB_DESC" <<'EOF'
WM_AGENT_BIN="__test-orch-unaffected-stub-bin"
WM_AGENT_DISPLAY_NAME="Test Orchestrator Unaffected-Behavior Stub"
WM_AGENT_GUARD_TRANSPORT=claude-json
WM_AGENT_REMOTE_CONTROL_FLAG=""
EOF
run_one "non-claude orchestrator (stub)" "__test-orch-unaffected-stub" \
  "$(wm_mktemp_dir)/mirror-b" "$(wm_mktemp_dir)" __test-orch-unaffected-stub-bin
rm -f "$STUB_DESC"

test_summary
