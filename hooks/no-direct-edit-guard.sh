#!/usr/bin/env bash
# no-direct-edit-guard.sh - a Claude Code PreToolUse hook. Mechanically
# enforces CLAUDE.md's prime directive ("never do heavy work yourself") by
# blocking direct Edit/Write/NotebookEdit calls against files inside a git
# repo, and direct test-runner Bash invocations, at the orchestrator layer -
# redirecting to bin/spawn-crew instead of letting the call through. See issue
# #17: the prompt-level instruction alone did not stop wingman from editing
# code directly once "it's a small change" felt like an implicit exception.
#
# Registered in user-level ~/.claude/settings.json (by bin/doctor), not this
# repo's project-level settings, so it loads for every Claude Code session on
# the machine regardless of which directory a session launches in - the only
# way a lead spawned with --repo <other-project> or --scope global is actually
# covered (a project-level entry in this repo's .claude/settings.json never
# loads for a session whose project root is elsewhere).
#
# Because it now runs for every session on the machine, activation must not
# rest on WINGMAN_CREW_ID being unset alone - that is true for every unrelated
# Claude Code session the pilot runs that has nothing to do with wingman.
# Active when:
#   - WINGMAN_CREW_TYPE=lead - unconditional, regardless of cwd. A lead's
#     WINGMAN_CREW_TYPE is a wingman-specific signal set only by
#     bin/spawn-crew, so it is never a false positive for an unrelated
#     session; a lead is a conductor over its own crew, the same role wingman
#     plays one layer up.
#   - WINGMAN_CREW_ID is unset (no crew wrapper at all) AND this session's
#     project root ($CLAUDE_PROJECT_DIR) is this wingman checkout - i.e.
#     wingman's own top-level session, not some other repo the pilot happens
#     to be working in.
# Every worker crew type (developer, architect, reviewer, software-analyst,
# research, ...) is a worker for whom editing files and running tests is
# literally the job, so the guard stays inactive there.
#
# Once active, the Edit/Write/NotebookEdit block only fires for a target path
# that resolves inside a tracked git repo - a write outside any repo (e.g.
# wingman's own auto-memory files under ~/.claude/projects/**/memory/*.md,
# which the memory system's own instructions require writing directly, with
# no delegation path) passes through untouched. The intent is to stop direct
# edits to code, not to block every Write/Edit call regardless of target.
#
# issue #25 stage 3 (12a): the activation check above and the decision logic
# below it are now BOTH also implemented, canonically, as
# guard_policy.no_direct_edit_guard_active()/evaluate_no_direct_edit_guard()
# - the bash activation check in this file is kept as a cheap, UNCHANGED
# optimization (every worker session's every Bash/Edit/Write call skips
# spinning up python at all, exactly as before this port), not the thing this
# guard's correctness now rests on: the python core independently re-derives
# the identical activation decision from the same crew_type/crew_id/
# project_dir fields, so a future non-claude transport that gets its own
# pre-gate wrong (or skips one entirely) still gets the right answer from the
# core itself. See guard_policy.py's own docstring for the normalized 9-field
# GuardInput contract this hands off.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(dirname "$HERE")"

WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# True iff this session's project root is this wingman checkout - the only way
# an unset WINGMAN_CREW_ID means "wingman's own top-level session" rather than
# some unrelated Claude Code session running elsewhere on the machine.
wm_is_wingman_repo_session() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 1
  _proj="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)"
  [ -n "$_proj" ] && [ "$_proj" = "$REPO" ]
}

if [ "${WINGMAN_CREW_TYPE:-}" = "lead" ]; then
  : # active unconditionally - see header
elif [ -z "${WINGMAN_CREW_ID:-}" ] && wm_is_wingman_repo_session; then
  : # active - wingman's own top-level session
else
  exit 0
fi

printf '%s' "$INPUT" | \
  WINGMAN_CREW_ID="${WINGMAN_CREW_ID:-}" \
  WINGMAN_CREW_TYPE="${WINGMAN_CREW_TYPE:-}" \
  CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, sys

from guard_policy import GuardDenied, GuardInput, evaluate_no_direct_edit_guard

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

tool_input = data.get("tool_input", {}) or {}
gi = GuardInput(
    tool_name=data.get("tool_name") or "",
    command=tool_input.get("command", "") or "",
    cwd=data.get("cwd") or os.getcwd(),
    crew_id=os.environ.get("WINGMAN_CREW_ID", ""),
    crew_type=os.environ.get("WINGMAN_CREW_TYPE", ""),
    file_path=tool_input.get("file_path", "") or "",
    notebook_path=tool_input.get("notebook_path", "") or "",
    project_dir=os.environ.get("CLAUDE_PROJECT_DIR", ""),
    home=os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman"),
)

try:
    evaluate_no_direct_edit_guard(gi)
except GuardDenied as e:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": str(e),
        }
    }))
sys.exit(0)
' 2>/dev/null

exit 0
