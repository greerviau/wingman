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

printf '%s' "$INPUT" | PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, re, subprocess, sys

from cmd_match import command_segments, resolve_command

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


def is_inside_git_repo(path):
    d = os.path.dirname(os.path.abspath(path)) or "/"
    while d != "/" and not os.path.isdir(d):
        d = os.path.dirname(d)
    try:
        r = subprocess.run(
            ["git", "-C", d, "rev-parse", "--is-inside-work-tree"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
        )
        return r.returncode == 0 and r.stdout.strip() == b"true"
    except Exception:
        return False


if tool in ("Edit", "Write", "NotebookEdit"):
    path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not path or is_inside_git_repo(path):
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
    # Matched against the command actually being invoked in each ;/&&/||/pipe
    # segment - resolved through env/sudo/shell/uv-run wrappers by the shared
    # hooks/lib/cmd_match.py helper, never a raw substring search over the
    # whole line - so a runner word appearing as someone else'"'"'s argument (a
    # grep pattern, a `git log --grep`, a filename, a package name, free text
    # after echo) does not trip the same deny path as an actual invocation.
    RUNNER_BINS = {"pytest", "rspec", "jest", "mocha"}

    def is_test_runner_segment(tokens):
        b, argv = resolve_command(tokens)
        if not argv:
            return False
        cmd = argv[0]
        if re.search(r"tests?/[^/\s]*\.test\.sh$", cmd) or re.search(r"tests?/run\.sh$", cmd):
            return True
        if b in ("python", "python3") and "-m" in argv:
            idx = argv.index("-m")
            return idx + 1 < len(argv) and argv[idx + 1] in ("pytest", "unittest")
        if b in ("npm", "yarn", "pnpm"):
            rest = [t for t in argv[1:] if t != "run"]
            return bool(rest) and rest[0] == "test"
        if b == "go" and len(argv) > 1 and argv[1] == "test":
            return True
        if b == "cargo" and len(argv) > 1 and argv[1] == "test":
            return True
        if b == "make" and "test" in argv[1:]:
            return True
        return b in RUNNER_BINS

    if any(is_test_runner_segment(seg) for seg in command_segments(command)):
        deny(
            "Running the test suite directly is not yours to do here - you are "
            "acting as an orchestrator. Hand the change and its verification to "
            "a developer crew member via bin/spawn-crew instead of invoking the "
            "test runner yourself. See issue #17."
        )

sys.exit(0)
' 2>/dev/null

exit 0
