#!/usr/bin/env bash
# Unit: bin/lib/agent.sh's wm_agent_apply_guard_env - the `eval "export
# $WM_AGENT_GUARD_ENV"` step that applies a descriptor's guard-transport
# environment (grok's own GROK_CLAUDE_HOOKS_ENABLED=0 today) into the
# calling shell. No production caller invokes this any more (bin/wingman,
# its only caller, is retired - docs/analysis/2026-08-18-remove-bin-wingman-
# launcher-spec.md; there is no exec step left for the orchestrator to apply
# a guard-transport environment before, and crew never called it either),
# but the function itself stays (bin/lib/agent.sh is left intact by that
# migration - a future caller, orchestrator- or crew-side, may still need
# it), so its one genuinely tricky property - surviving a value shaped like
# opencode's real WM_AGENT_ENV_PREFIX (quotes and braces) through an eval -
# stays covered on its own merits, independent of any caller.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"

# the eval-mechanism regression case: opencode's REAL quote-and-brace-heavy
# WM_AGENT_ENV_PREFIX string, fed through wm_agent_apply_guard_env directly
# (as WM_AGENT_GUARD_ENV, standing in for it) - proves the eval survives it.
WM_AGENT_ENV_UNSET=""
WM_AGENT_GUARD_ENV='OPENCODE_CONFIG_CONTENT='"'"'{"permission":{"*":"allow"}}'"'"''
wm_agent_apply_guard_env
assert_eq "the opencode-shaped quote-and-brace value round-trips through eval intact" \
  "$OPENCODE_CONFIG_CONTENT" '{"permission":{"*":"allow"}}'
unset OPENCODE_CONFIG_CONTENT WM_AGENT_GUARD_ENV

# WM_AGENT_ENV_UNSET removes the named variable from the calling shell.
WM_TEST_UNSET_ME=leaked-value
WM_AGENT_ENV_UNSET="WM_TEST_UNSET_ME"
WM_AGENT_GUARD_ENV=""
wm_agent_apply_guard_env
assert_eq "WM_AGENT_ENV_UNSET removes the named variable" "${WM_TEST_UNSET_ME:-<unset>}" "<unset>"
unset WM_AGENT_ENV_UNSET WM_AGENT_GUARD_ENV

# A descriptor that sets neither field is a clean no-op - no bogus `export`
# of an empty string, no error under `set -u`.
WM_AGENT_ENV_UNSET=""
WM_AGENT_GUARD_ENV=""
assert_true "a descriptor with no guard env/unset fields is a clean no-op" "wm_agent_apply_guard_env"
unset WM_AGENT_ENV_UNSET WM_AGENT_GUARD_ENV

test_summary
