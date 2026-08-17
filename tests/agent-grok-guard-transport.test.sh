#!/usr/bin/env bash
# E2E: the grok-json guard transport (the orchestrator-guard-transports
# plan, step 6) - bin/lib/guard-transport.sh's grok branch, against a fixture
# $HOME (no real grok CLI needed for the sync/self-test path itself, since
# the registered command is the dispatcher, not grok). Where a real grok
# binary happens to be installed, this file ALSO confirms
# GROK_CLAUDE_HOOKS_ENABLED=0's real effect and personal-scope hook
# discovery hands-on, via `grok inspect --json` - the plan's own §7
# requirement for this specific field, done here rather than left purely
# attributed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"
. "$TEST_REPO/bin/lib/guard-transport.sh"

test_new_home
export WINGMAN_HOME

# =============================================================================
# (1) missing WM_AGENT_GUARD_ENV refuses BEFORE touching the filesystem at
# all - the compatibility-path hazard is checked first
# =============================================================================
GROK_HOME_1="$(wm_mktemp_dir)"
unset WM_AGENT_GUARD_ENV
out="$(HOME="$GROK_HOME_1" wm_guard_transport_sync grok-json "$TEST_REPO")"; rc=$?
assert_true "grok-json: missing WM_AGENT_GUARD_ENV refuses" "[ $rc -ne 0 ]"
assert_contains "the refusal names GROK_CLAUDE_HOOKS_ENABLED=0" "$out" "GROK_CLAUDE_HOOKS_ENABLED=0"
assert_false "nothing was written to the fake HOME" "[ -f '$GROK_HOME_1/.grok/hooks/wingman.json' ]"

# The WRONG value also refuses (not merely "unset").
export WM_AGENT_GUARD_ENV="something-else=1"
out="$(HOME="$GROK_HOME_1" wm_guard_transport_sync grok-json "$TEST_REPO")"; rc=$?
assert_true "grok-json: a wrong WM_AGENT_GUARD_ENV value also refuses" "[ $rc -ne 0 ]"

# =============================================================================
# (2) the correct value: install + self-test succeed against a fixture $HOME
# =============================================================================
export WM_AGENT_GUARD_ENV="GROK_CLAUDE_HOOKS_ENABLED=0"
GROK_HOME_2="$(wm_mktemp_dir)"
out="$(HOME="$GROK_HOME_2" wm_guard_transport_sync grok-json "$TEST_REPO")"; rc=$?
assert_true "grok-json: a healthy repo with the correct env syncs and self-tests" "[ $rc -eq 0 ]"
assert_eq "grok-json: success prints nothing" "$out" ""
assert_true "grok-json: wingman.json was written to the personal scope path" \
  "[ -f '$GROK_HOME_2/.grok/hooks/wingman.json' ]"
assert_false "grok-json: NOTHING was written to a project scope path" \
  "[ -d '$TEST_REPO/.grok' ]"

content="$(cat "$GROK_HOME_2/.grok/hooks/wingman.json")"
assert_contains "the registered command targets the real dispatcher" "$content" "guard_dispatch.py"

# =============================================================================
# (3) a missing dispatcher script refuses
# =============================================================================
BAD_REPO="$(wm_mktemp_dir)/no-dispatcher"
mkdir -p "$BAD_REPO"
GROK_HOME_3="$(wm_mktemp_dir)"
out="$(HOME="$GROK_HOME_3" wm_guard_transport_sync grok-json "$BAD_REPO")"; rc=$?
assert_true "grok-json: a repo with no dispatcher refuses" "[ $rc -ne 0 ]"
assert_contains "the refusal names the missing dispatcher" "$out" "guard_dispatch.py"

unset WM_AGENT_GUARD_ENV

# =============================================================================
# (4) real hands-on confirmation, where a real grok binary happens to be
# installed (this environment has one via a user-prefix npm install) -
# GROK_CLAUDE_HOOKS_ENABLED=0's actual effect, and personal-scope discovery,
# both via a live `grok inspect --json` diff rather than documentation alone
# =============================================================================
if ! wm_have grok; then
  echo "SKIP: no real grok binary on PATH in this environment - skipping the hands-on grok inspect --json checks"
else
  REAL_CHECK_HOME="$(wm_mktemp_dir)"
  uv run --no-project --quiet "$TEST_REPO/bin/lib/sync-grok-hooks.py" \
    --settings "$REAL_CHECK_HOME/.grok/hooks/wingman.json" --repo "$TEST_REPO" >/dev/null 2>&1

  inspect_default="$(HOME="$REAL_CHECK_HOME" grok inspect --json 2>/dev/null)"
  inspect_disabled="$(HOME="$REAL_CHECK_HOME" GROK_CLAUDE_HOOKS_ENABLED=0 grok inspect --json 2>/dev/null)"

  own_hook_count="$(printf '%s' "$inspect_default" | uv run --no-project --quiet python -c '
import json, sys
d = json.load(sys.stdin)
print(sum(1 for h in d.get("hooks", []) if "guard_dispatch.py" in (h.get("target") or "")))
')"
  assert_eq "grok inspect --json discovers the rendered personal-scope hook" "$own_hook_count" "1"

  own_hook_no_vendor="$(printf '%s' "$inspect_default" | uv run --no-project --quiet python -c '
import json, sys
d = json.load(sys.stdin)
hooks = [h for h in d.get("hooks", []) if "guard_dispatch.py" in (h.get("target") or "")]
print(hooks[0].get("vendor") if hooks else "MISSING")
')"
  assert_eq "the discovered hook carries no vendor tag (native, not a compat cell - no trust gate)" "$own_hook_no_vendor" "None"

  # GROK_CLAUDE_HOOKS_ENABLED=0 must NOT disable wingman's own native grok
  # hook (only the Claude-compat cells) - it has no vendor tag to disable.
  own_hook_still_present="$(printf '%s' "$inspect_disabled" | uv run --no-project --quiet python -c '
import json, sys
d = json.load(sys.stdin)
print(sum(1 for h in d.get("hooks", []) if "guard_dispatch.py" in (h.get("target") or "")))
')"
  assert_eq "the native grok hook is UNAFFECTED by GROK_CLAUDE_HOOKS_ENABLED=0" "$own_hook_still_present" "1"
fi

test_summary
