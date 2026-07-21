#!/usr/bin/env bash
# no-interactive-prompt-guard.sh - a Claude Code PreToolUse hook (matcher
# "AskUserQuestion|EnterPlanMode|ExitPlanMode"). Mechanically enforces that no
# crew session - a worker or a lead, anything with WINGMAN_CREW_ID set - ever
# sits on an interactive, human-facing prompt. Only the top-level wingman
# session is ever actually watched by a human in real time (CLAUDE.md's own
# prime directive is built on this); a crew session that called one of these
# tools would hang waiting for a choice nobody is present to make, and if
# that session happened to ALSO be frozen on some other pending dialog, a
# later-arriving keystroke meant for this new prompt (or a stall-recovery
# nudge - see bin/watch-fleet) risks being read as input to the WRONG one
# (e.g. selecting whatever a y/n or numbered-choice dialog already has
# highlighted). Issue #155's original investigation treated the silent-stall
# nudge's visibility as the fix; widening it turned up this as the sharper,
# preventable root cause the nudge was only ever working around.
#
# What is denied, for every crew session (WINGMAN_CREW_ID set):
#   - AskUserQuestion - waits for a human to pick an option; nobody is
#     watching a crew pane in real time to answer it.
#   - EnterPlanMode - "This tool REQUIRES user approval" per its own
#     description; a crew session would hang transitioning into a mode
#     nobody can approve it into.
#   - ExitPlanMode - the same approval wait, at the other end of plan mode.
#
# The escalation path every denial names is playbooks/_status-contract.md's
# existing `blocked` state, unchanged: set --status blocked with the specific
# question (and its options, if any) as --blocker, which wakes the owning
# lead/wingman through the existing watcher; relay the human's answer back
# with bin/crew-say once it arrives, then resume `working`. See that
# playbook's "blocked for a human dependency" section - "I need a human
# choice" is the same family of case as "I need a human to perform a
# privileged action."
#
# This does not touch Claude Code's own built-in permission/trust dialogs -
# those are already handled by --permission-mode bypassPermissions plus
# bin/spawn-crew's preflight checks (see CLAUDE.md, "Spawning crew"), and by
# bin/watch-fleet's prompt_freeze_check backstop for whatever that preflight
# cannot cover. This hook is about tools a crew session's OWN turn can call
# that would otherwise open a second, independent human-wait state.
#
# Registered user-level by bin/doctor (crew sessions have their project root
# in other repos, where this repo's project-level .claude/settings.json never
# loads) - same reasoning as the delegation guard, the Artifact-publish
# contract hooks, and the merge-authorization contract hooks.
# bash-3.2-safe.
set -u

INPUT="$(cat)"

# Active for every crew session - worker or lead - never for wingman's own
# top-level session (no WINGMAN_CREW_ID at all), which IS the thing a human
# actually watches in real time and so is exactly where these tools belong.
if [ -z "${WINGMAN_CREW_ID:-}" ]; then
  exit 0
fi

# Cheap no-op pre-gate: only a payload naming one of the three guarded tools
# can possibly match below.
case "$INPUT" in
  *AskUserQuestion*|*EnterPlanMode*|*ExitPlanMode*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | uv run --no-project --quiet python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

tool = data.get("tool_name", "")

if tool not in ("AskUserQuestion", "EnterPlanMode", "ExitPlanMode"):
    sys.exit(0)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "%s is not yours to call from a crew session (issue #155): it "
            "waits for a human to respond interactively, and nobody watches "
            "a crew session'"'"'s pane in real time to answer it - only the "
            "top-level wingman session is actually watched. Escalate "
            "instead: set --status blocked with the specific question (and "
            "its options, if any) as --blocker, e.g. $WINGMAN_STATE crew-set "
            "--id \"$WINGMAN_CREW_ID\" --status blocked --blocker \"<the "
            "question you needed to ask>\" - this wakes your owner through "
            "the existing watcher. Once the human answers (relayed back via "
            "bin/crew-say), report --status working and continue. See "
            "playbooks/_status-contract.md, \"blocked for a human "
            "dependency.\"" % tool
        ),
    }
}))
sys.exit(0)
' 2>/dev/null

exit 0
