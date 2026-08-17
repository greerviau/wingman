#!/usr/bin/env bash
# E2E: bin/wingman's launch-line composition mechanism (the orchestrator-
# guard-transports plan, §5.6) - WM_AGENT_GUARD_LAUNCH_FLAGS reaching the
# exec line, WM_AGENT_GUARD_ENV and WM_AGENT_ENV_UNSET reaching the exec'd
# process's own environment (via wm_agent_apply_guard_env), WM_AGENT_ENV_
# PREFIX deliberately NOT reaching it, and WINGMAN_PROJECT_DIR being
# exported. tests/agent-pi.test.sh cannot cover any of this - it exercises
# bin/spawn-crew's own composed launch SCRIPT, a path bin/wingman does not
# use at all (bin/wingman execs directly, with no script-composition step -
# see bin/lib/agent.sh's own wm_agent_apply_guard_env docstring).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"

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

run_stub_launch() {
  # run_stub_launch <label-suffix> <descriptor-body-heredoc-var-name>
  _rsl_suffix="$1"
  test_new_home
  export WINGMAN_HOME
  _rsl_mirror="$(wm_mktemp_dir)/mirror-$_rsl_suffix"
  mk_mirror "$_rsl_mirror"
  _rsl_stubdir="$(wm_mktemp_dir)"
  _rsl_marker="$_rsl_stubdir/env-$_rsl_suffix"
  cat > "$_rsl_stubdir/__test-launch-comp-$_rsl_suffix-bin" <<EOF
#!/usr/bin/env bash
{
  printf 'ARGV:%s\n' "\$*"
  printf 'GUARD_ENV_VAR:%s\n' "\${WM_TEST_GUARD_VAR:-<unset>}"
  printf 'UNSET_VAR:%s\n' "\${WM_TEST_UNSET_ME:-<unset>}"
  printf 'ENV_PREFIX_VAR:%s\n' "\${WM_TEST_PREFIX_VAR:-<unset>}"
  printf 'PROJECT_DIR:%s\n' "\${WINGMAN_PROJECT_DIR:-<unset>}"
} > "$_rsl_marker"
exit 0
EOF
  chmod +x "$_rsl_stubdir/__test-launch-comp-$_rsl_suffix-bin"
  unset WM_AGENT_BIN_OVERRIDE
  WM_TEST_UNSET_ME=leaked-value \
    PATH="$_rsl_stubdir:$PATH" WM_ORCH_AGENT="__test-launch-comp-$_rsl_suffix" \
    "$_rsl_mirror/bin/wingman" >/dev/null 2>&1
  wm_stop_guardian
  cat "$_rsl_marker" 2>/dev/null
}

# =============================================================================
# WM_AGENT_GUARD_LAUNCH_FLAGS reaches the exec line; WM_AGENT_GUARD_ENV and
# WM_AGENT_ENV_UNSET reach the exec'd process's own environment
# =============================================================================
STUB1="$TEST_REPO/bin/lib/agents/__test-launch-comp-basic.sh"
cat > "$STUB1" <<'EOF'
WM_AGENT_BIN="__test-launch-comp-basic-bin"
WM_AGENT_DISPLAY_NAME="Test Launch Composition Basic Stub"
WM_AGENT_GUARD_TRANSPORT=claude-json
WM_AGENT_CONTINUITY_TRANSPORT=claude-async-rewake
WM_AGENT_GUARD_LAUNCH_FLAGS="--my-guard-flag --with an-argument"
WM_AGENT_GUARD_ENV="WM_TEST_GUARD_VAR=guard-env-applied"
WM_AGENT_ENV_UNSET="WM_TEST_UNSET_ME"
WM_AGENT_ENV_PREFIX="WM_TEST_PREFIX_VAR=should-never-appear"
WM_AGENT_REMOTE_CONTROL_FLAG=""
EOF
out1="$(run_stub_launch basic)"
rm -f "$STUB1"

assert_contains "WM_AGENT_GUARD_LAUNCH_FLAGS reaches the exec line's argv" "$out1" "--my-guard-flag --with an-argument"
assert_contains "WM_AGENT_GUARD_ENV is exported into the exec'd process" "$out1" "GUARD_ENV_VAR:guard-env-applied"
assert_contains "WM_AGENT_ENV_UNSET removes the named variable" "$out1" "UNSET_VAR:<unset>"
# The negative is the most valuable assertion here (plan §8's own emphasis):
# NOT applying the crew env prefix in bin/wingman is a consciously chosen
# behaviour, exactly what a later well-meaning "the orchestrator should
# honour the descriptor's env prefix too" change would quietly undo.
assert_contains "WM_AGENT_ENV_PREFIX does NOT reach the exec'd process" "$out1" "ENV_PREFIX_VAR:<unset>"
assert_contains "WINGMAN_PROJECT_DIR is exported" "$out1" "PROJECT_DIR:"
assert_not_contains "...and it is not the degrade sentinel" "$out1" "PROJECT_DIR:<unset>"

# =============================================================================
# A descriptor that sets NEITHER WM_AGENT_GUARD_LAUNCH_FLAGS nor
# WM_AGENT_GUARD_ENV composes cleanly (no stray empty tokens, no bogus
# `export` of an empty string) - claude's own real shape today.
# =============================================================================
STUB2="$TEST_REPO/bin/lib/agents/__test-launch-comp-empty.sh"
cat > "$STUB2" <<'EOF'
WM_AGENT_BIN="__test-launch-comp-empty-bin"
WM_AGENT_DISPLAY_NAME="Test Launch Composition Empty Stub"
WM_AGENT_GUARD_TRANSPORT=claude-json
WM_AGENT_CONTINUITY_TRANSPORT=claude-async-rewake
WM_AGENT_REMOTE_CONTROL_FLAG=""
EOF
out2="$(run_stub_launch empty)"
rm -f "$STUB2"
argv2="$(printf '%s\n' "$out2" | sed -n 's/^ARGV://p')"
assert_not_contains "no guard launch flags: nothing guard-shaped leaks into argv" "$argv2" "--my-guard-flag"
assert_not_contains "...and no stray empty token either" "$argv2" "  "
assert_contains "no guard env: the marker var stays unset" "$out2" "GUARD_ENV_VAR:<unset>"

# =============================================================================
# the eval-mechanism regression case: opencode's REAL quote-and-brace-heavy
# WM_AGENT_ENV_PREFIX string, fed through wm_agent_apply_guard_env directly
# (as WM_AGENT_GUARD_ENV, standing in for it) - proves the eval survives it,
# even though that exact string is never applied on the bin/wingman path in
# real use (opencode.sh's own WM_AGENT_GUARD_ENV is empty).
# =============================================================================
test_new_home
export WINGMAN_HOME
WM_AGENT_ENV_UNSET=""
WM_AGENT_GUARD_ENV='OPENCODE_CONFIG_CONTENT='"'"'{"permission":{"*":"allow"}}'"'"''
wm_agent_apply_guard_env
assert_eq "the opencode-shaped quote-and-brace value round-trips through eval intact" \
  "$OPENCODE_CONFIG_CONTENT" '{"permission":{"*":"allow"}}'
unset OPENCODE_CONFIG_CONTENT WM_AGENT_GUARD_ENV WM_AGENT_ENV_UNSET

test_summary
