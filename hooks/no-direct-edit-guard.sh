#!/usr/bin/env bash
# no-direct-edit-guard.sh - a Claude Code PreToolUse hook. Mechanically
# enforces CLAUDE.md's prime directive ("never do heavy work yourself") by
# blocking direct Edit/Write/NotebookEdit calls and direct test-runner Bash
# invocations at the orchestrator layer, redirecting to bin/spawn-crew instead
# of letting the call through. See issue #17: the prompt-level instruction
# alone did not stop wingman from editing code directly once "it's a small
# change" felt like an implicit exception.
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

printf '%s' "$INPUT" | $WM_UV python -c '
import json, re, shlex, sys

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
    # Matched against the command actually being invoked in each ;/&&/||/pipe
    # segment - not a raw substring search over the whole line - so a runner
    # word appearing as someone else'"'"'s argument (a grep pattern, a `git log
    # --grep`, a filename, a package name, free text after echo) does not trip
    # the same deny path as an actual invocation.
    RUNNER_BINS = {"pytest", "rspec", "jest", "mocha"}

    def basename(tok):
        return tok.rsplit("/", 1)[-1]

    def is_test_runner_segment(tokens):
        i = 0
        while i < len(tokens) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[i]):
            i += 1
        tokens = tokens[i:]
        if not tokens:
            return False
        cmd = tokens[0]
        b = basename(cmd)

        if re.search(r"tests?/[^/\s]*\.test\.sh$", cmd) or re.search(r"tests?/run\.sh$", cmd):
            return True
        if b in ("sudo", "env"):
            return is_test_runner_segment(tokens[1:])
        if b in ("bash", "sh", "zsh") and len(tokens) > 1:
            rest = [t for t in tokens[1:] if not t.startswith("-")]
            return bool(rest) and is_test_runner_segment(rest)
        if b == "uv" and len(tokens) > 1 and tokens[1] == "run":
            return is_test_runner_segment(tokens[2:])
        if b in ("python", "python3") and "-m" in tokens:
            idx = tokens.index("-m")
            return idx + 1 < len(tokens) and tokens[idx + 1] in ("pytest", "unittest")
        if b in ("npm", "yarn", "pnpm"):
            rest = [t for t in tokens[1:] if t != "run"]
            return bool(rest) and rest[0] == "test"
        if b == "go" and len(tokens) > 1 and tokens[1] == "test":
            return True
        if b == "cargo" and len(tokens) > 1 and tokens[1] == "test":
            return True
        if b == "make" and "test" in tokens[1:]:
            return True
        return b in RUNNER_BINS

    def command_segments(cmd_str):
        segments = []
        for line in cmd_str.split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                lex = shlex.shlex(line, posix=True, punctuation_chars=";&|")
                lex.whitespace_split = True
                tokens = list(lex)
            except ValueError:
                continue
            current = []
            for tok in tokens:
                if tok and set(tok) <= set(";&|"):
                    if current:
                        segments.append(current)
                    current = []
                else:
                    current.append(tok)
            if current:
                segments.append(current)
        return segments

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
