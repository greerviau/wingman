#!/usr/bin/env bash
# E2E: the codex-json guard transport (the orchestrator-guard-transports
# plan, step 7) - bin/lib/guard-transport.sh's codex branch, against a
# fixture $CODEX_HOME. Where a real codex binary happens to be installed,
# this file also confirms --dangerously-bypass-hook-trust and the
# [features].hooks default hands-on rather than from documentation alone.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"
. "$TEST_REPO/bin/lib/guard-transport.sh"

test_new_home
export WINGMAN_HOME

WORK="$(wm_mktemp_dir)"
NO_REQ="$WORK/no-requirements.toml"

# =============================================================================
# (1) install + self-test succeed against a fixture $CODEX_HOME, with no
# real codex binary needed for THIS half (the registered command is the
# dispatcher, not codex itself) - only for the --help/trust-flag check.
# =============================================================================
if wm_have codex; then
  unset WM_AGENT_BIN_OVERRIDE
  wm_agent_resolve codex
else
  # Descriptor resolution alone needs no real binary - only this branch's
  # own --help probe does (guarded separately below).
  . "$TEST_REPO/bin/lib/agent.sh"
  wm_agent_resolve codex
fi

CODEX_HOME_1="$(wm_mktemp_dir)"
if wm_have "${WM_AGENT_BIN:-codex}"; then
  out="$(CODEX_HOME="$CODEX_HOME_1" wm_guard_transport_sync codex-json "$TEST_REPO")"; rc=$?
  assert_true "codex-json: a healthy repo syncs and self-tests" "[ $rc -eq 0 ]"
  assert_eq "codex-json: success prints nothing" "$out" ""
  assert_true "codex-json: hooks.json was written under \$CODEX_HOME" \
    "[ -f '$CODEX_HOME_1/hooks.json' ]"
  assert_false "codex-json: nothing was written to a project scope path" \
    "[ -d '$TEST_REPO/.codex' ]"

  content="$(cat "$CODEX_HOME_1/hooks.json")"
  assert_contains "the registered command targets the real dispatcher" "$content" "guard_dispatch.py"
else
  echo "SKIP: no real codex binary on PATH - skipping the guard-transport.sh integration checks"
fi

# =============================================================================
# (2) a missing dispatcher script refuses
# =============================================================================
BAD_REPO="$(wm_mktemp_dir)/no-dispatcher"
mkdir -p "$BAD_REPO"
CODEX_HOME_2="$(wm_mktemp_dir)"
if wm_have "${WM_AGENT_BIN:-codex}"; then
  out="$(CODEX_HOME="$CODEX_HOME_2" wm_guard_transport_sync codex-json "$BAD_REPO")"; rc=$?
  assert_true "codex-json: a repo with no dispatcher refuses" "[ $rc -ne 0 ]"
  assert_contains "the refusal names the missing dispatcher" "$out" "guard_dispatch.py"
fi

# =============================================================================
# (3) real hands-on confirmation, where a real codex binary is installed
# (this environment has one via a user-prefix npm install)
# =============================================================================
if ! wm_have codex; then
  echo "SKIP: no real codex binary on PATH in this environment"
else
  help_out="$(timeout 20 codex --help 2>&1)"
  assert_contains "codex --help documents --dangerously-bypass-hook-trust (live, not just documentation)" \
    "$help_out" "--dangerously-bypass-hook-trust"

  features_out="$(timeout 20 codex features list 2>&1)"
  assert_contains "codex features list reports hooks as a real, known feature" "$features_out" "hooks"

  # Reproduces the exact live confirmation this stage's own descriptor
  # comment (bin/lib/agents/codex.sh) records: the trust-bypass flag prints
  # an observable warning when actually passed to a real invocation.
  bypass_out="$(CODEX_HOME="$(wm_mktemp_dir)" timeout 15 codex exec --dangerously-bypass-hook-trust "true" 2>&1 || true)"
  assert_contains "--dangerously-bypass-hook-trust prints its own warning on a real invocation" \
    "$bypass_out" "dangerously-bypass-hook-trust"
fi

# WM_AGENT_GUARD_LAUNCH_FLAGS composes the trust-bypass flag onto the
# descriptor regardless of whether codex itself is installed here.
assert_eq "codex.sh composes --dangerously-bypass-hook-trust as its guard launch flag" \
  "$WM_AGENT_GUARD_LAUNCH_FLAGS" "--dangerously-bypass-hook-trust"

test_summary
