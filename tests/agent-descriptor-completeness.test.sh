#!/usr/bin/env bash
# E2E: agent descriptor completeness (issue #25, plan §7 item 1). Sources
# every file under bin/lib/agents/*.sh through wm_agent_resolve and asserts
# the two required fields are non-empty and the schema-level literal
# defaults (WM_AGENT_SYSPROMPT_MODE, WM_AGENT_VERIFIED) land in their
# documented value domains - catches a malformed descriptor with zero real
# binaries involved. No tmux, no fixture beyond an isolated $WINGMAN_HOME
# (wm_agent_resolve reads only bin/lib/agents/*.sh, never the roster or a
# config file).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"
. "$TEST_REPO/bin/lib/agent.sh"

test_new_home

FOUND=0
for f in "$TEST_REPO"/bin/lib/agents/*.sh; do
  [ -f "$f" ] || continue
  FOUND=$((FOUND+1))
  name="$(basename "$f" .sh)"

  wm_agent_resolve "$name"
  assert_true "$name: WM_AGENT_BIN is non-empty" "[ -n '$WM_AGENT_BIN' ]"
  assert_true "$name: WM_AGENT_DISPLAY_NAME is non-empty" "[ -n '$WM_AGENT_DISPLAY_NAME' ]"
  assert_true "$name: WM_AGENT_SYSPROMPT_MODE is a recognized mode" \
    "case '$WM_AGENT_SYSPROMPT_MODE' in flag|positional|prompt-flag|pointer-after-ready) true ;; *) false ;; esac"
  assert_true "$name: WM_AGENT_VERIFIED is 0 or 1" \
    "case '$WM_AGENT_VERIFIED' in 0|1) true ;; *) false ;; esac"
  # A mode requiring the flag template actually has one populated - a
  # descriptor claiming `flag`/`prompt-flag` with no WM_AGENT_SYSPROMPT_FLAG
  # would silently deliver nothing at launch (bin/lib/agent.sh's
  # wm_agent_emit_sysprompt no-ops on an empty template).
  case "$WM_AGENT_SYSPROMPT_MODE" in
    flag|prompt-flag)
      assert_true "$name: WM_AGENT_SYSPROMPT_FLAG is set (required for mode '$WM_AGENT_SYSPROMPT_MODE')" \
        "[ -n '$WM_AGENT_SYSPROMPT_FLAG' ]"
      ;;
  esac
done

assert_true "at least one descriptor was found (claude.sh, at minimum)" "[ '$FOUND' -ge 1 ]"

# wm_agent_list enumerates the identical set, sorted - the shared
# enumeration point --list-agents (plan step 10) will build on later.
listed="$(wm_agent_list)"
assert_contains "wm_agent_list finds the claude descriptor" "$listed" "claude"
assert_eq "wm_agent_list finds exactly as many descriptors as this scan did" \
  "$(printf '%s\n' "$listed" | grep -c .)" "$FOUND"

# An unknown agent name dies loudly rather than silently degrading. Run in a
# subshell: wm_die calls exit directly, which would otherwise tear down this
# whole test script rather than just the one check.
err="$(wm_agent_resolve "this-agent-does-not-exist-xyz" 2>&1)"; rc=$?
assert_true "resolving an unknown agent name fails" "[ $rc -ne 0 ]"
assert_contains "the failure names the unknown agent" "$err" "unknown agent"

test_summary
