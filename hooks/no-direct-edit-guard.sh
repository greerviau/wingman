#!/usr/bin/env bash
# no-direct-edit-guard.sh - a Claude Code PreToolUse hook, wired only for the
# wingman repo. Mechanically enforces CLAUDE.md's prime directive ("never do
# heavy work yourself") by blocking direct Edit/Write/NotebookEdit calls and
# direct test-runner Bash invocations at the orchestrator layer, redirecting to
# bin/spawn-crew instead of letting the call through. See issue #17: the
# prompt-level instruction alone did not stop wingman from editing code
# directly once "it's a small change" felt like an implicit exception.
#
# Scoped like stop-guard.sh: active when this session is an orchestrator -
# wingman's own top-level layer (WINGMAN_CREW_ID unset) or a lead
# (WINGMAN_CREW_TYPE=lead, a conductor over its own crew, the same role wingman
# plays one layer up). Every other crew type (developer, architect, reviewer,
# software-analyst, research, ...) is a worker for whom editing files and
# running tests is literally the job, so the guard stays inactive there.
#
# Wired in .claude/settings.json of this repo, so it applies only here.
# bash-3.2-safe.
set -u

WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Inactive for any worker crew type: WINGMAN_CREW_ID is set (this is a spawned
# crew member) AND its type is not "lead". wingman's own top-level layer has no
# WINGMAN_CREW_ID at all, and a lead is an orchestrator like wingman one layer
# down, so both stay guarded.
if [ -n "${WINGMAN_CREW_ID:-}" ] && [ "${WINGMAN_CREW_TYPE:-}" != "lead" ]; then
  exit 0
fi

printf '%s' "$INPUT" | $WM_UV python -c '
import json, re, sys

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

tool = data.get("tool_name", "")
tool_input = data.get("tool_input", {}) or {}


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


if tool in ("Edit", "Write", "NotebookEdit"):
    deny(
        "Direct %s calls are not yours to make here - you are acting as an "
        "orchestrator (wingman'"'"'s top-level layer, or a lead), and CLAUDE.md'"'"'s "
        "prime directive is \"never do heavy work yourself,\" no size exception. "
        "Spawn a developer crew member to make this change instead: "
        "bin/spawn-crew --type developer --repo <name> --objective \"<the "
        "change>\" (or --input <plan-path> if an analyst already produced a "
        "plan). See issue #17." % tool
    )

if tool == "Bash":
    command = tool_input.get("command", "") or ""
    # Direct test-runner invocations only - generic Bash (gh, git, ls, grep,
    # cat, ...) is exactly how wingman/leads do legitimate orchestration and
    # must stay unblocked (this hook'"'"'s own author depends on it constantly).
    test_patterns = [
        r"(^|[\s;&|/])pytest\b",
        r"\b(npm|yarn|pnpm)\s+(run\s+)?test\b",
        r"\bgo\s+test\b",
        r"\bcargo\s+test\b",
        r"\brspec\b",
        r"\bjest\b",
        r"\bmocha\b",
        r"\bpython3?\s+-m\s+(pytest|unittest)\b",
        r"\bmake\s+test\b",
        r"tests?/[^\s]*\.test\.sh\b",
        r"tests?/run\.sh\b",
    ]
    if any(re.search(p, command) for p in test_patterns):
        deny(
            "Running the test suite directly is not yours to do here - you are "
            "acting as an orchestrator. Hand the change and its verification to "
            "a developer crew member via bin/spawn-crew instead of invoking the "
            "test runner yourself. See issue #17."
        )

sys.exit(0)
' 2>/dev/null

exit 0
