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

from cmd_match import command_segments, redirect_write_targets, resolve_command

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


# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56):
# command_segments() returns None rather than a partial, truncated segment
# list. This guard has no cheap substring pre-gate (unlike no-merge-guard.sh
# and the Artifact-publish contract hooks) - it reaches command_segments()
# for every Bash call, so it must deny on None here rather than skip it.
PARSE_FAIL_REASON = (
    "This command could not be fully parsed - an unterminated quote, an "
    "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
    "terminator line was never found, including inside a `bash -c`/`eval` "
    "payload - so it is denied rather than "
    "partially checked. If this command embeds a heredoc to "
    "build up an argument (for example a PR body), quote its delimiter "
    "(<<'"'"'EOF'"'"' rather than <<EOF) unless bash must expand "
    "$(...)/`...` inside it; otherwise reformat it into well-formed shell "
    "syntax and retry."
)


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
            "plan)." % tool
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

    segments = command_segments(command)
    if segments is None:
        deny(PARSE_FAIL_REASON)

    if any(is_test_runner_segment(seg) for seg in segments):
        deny(
            "Running the test suite directly is not yours to do here - you are "
            "acting as an orchestrator. Hand the change and its verification to "
            "a developer crew member via bin/spawn-crew instead of invoking the "
            "test runner yourself."
        )

    # Bash file-writing commands (issue #171): sed -i, output redirection
    # (>, >>, &>, tee), and cp/mv all write to a path given as an ordinary
    # positional/flag argument or shell operator, bypassing the Edit/Write
    # check above entirely even though the identical bytes to the identical
    # path would be denied there. Redirection is a shell operator (applies to
    # ANY command'"'"'s output), recognized via cmd_match.redirect_write_targets()
    # on the sentinel tokens command_segments() already emits; sed/tee/cp/mv
    # are command-specific argument shapes, recognized locally here.
    FILE_WRITE_DENY = (
        "This Bash command writes directly to %s inside a git repo (%s) - not "
        "yours to do here as an orchestrator, for the same reason a direct "
        "Edit/Write call is denied. This same guard covers shell-level "
        "writes: sed -i, output "
        "redirection (>, >>, &>, tee), and cp/mv are just as much \"heavy "
        "work\" as an Edit/Write call, and are now recognized the same way, "
        "no size exception. Spawn a developer crew member to make this change "
        "instead: bin/spawn-crew --type developer --repo <name> --objective "
        "\"<the change>\" (or --input <plan-path> if an analyst already "
        "produced a plan)."
    )

    def check_write_targets(targets, mechanism):
        for t in targets:
            if t and is_inside_git_repo(t):
                deny(FILE_WRITE_DENY % (t, mechanism))

    redirect_targets = []
    for seg in segments:
        redirect_targets.extend(redirect_write_targets(seg))
    check_write_targets(redirect_targets, "output redirection")

    _SED_BOOL_SHORT = set("nrEsuz")     # no-argument short flags
    _SED_SCRIPT_SHORT = set("ef")       # short flags supplying the script (glued or separate)
    _SED_OTHER_VALUE_SHORT = set("l")   # other value-taking short flags (line-wrap length)

    def _consume_short_cluster(tok):
        # Character-level parse of one '"'"'-xyz'"'"' short-option cluster token.
        # Returns (has_inplace, explicit_script, consumed_next) for THIS
        # token - consumed_next is True iff a value-taking flag (e/f/l) was
        # the cluster'"'"'s last character with no glued value, so its value is
        # the NEXT argv token, not a positional argument.
        has_inplace = False
        explicit_script = False
        consumed_next = False
        k, n = 1, len(tok)
        while k < n:
            ch = tok[k]
            if ch == "i":
                has_inplace = True
                k = n  # everything after '"'"'i'"'"' in this token is its backup suffix
                break
            if ch in _SED_SCRIPT_SHORT or ch in _SED_OTHER_VALUE_SHORT:
                if ch in _SED_SCRIPT_SHORT:
                    explicit_script = True
                if k + 1 >= n:
                    consumed_next = True  # no glued value - next token is the value
                k = n
                break
            k += 1  # an ordinary boolean flag char - keep scanning this cluster
        return has_inplace, explicit_script, consumed_next

    def sed_inplace_targets(argv):
        has_inplace = False
        explicit_script = False
        positional = []
        i, n = 1, len(argv)
        while i < n:
            tok = argv[i]
            if tok == "--":
                positional.extend(argv[i + 1:])
                break
            if tok.startswith("--in-place"):
                has_inplace = True
                i += 1
                continue
            if tok in ("--expression", "--file"):
                explicit_script = True
                i += 2  # long form always takes a separate-token value
                continue
            if tok == "--line-length":
                i += 2
                continue
            if tok.startswith("--expression=") or tok.startswith("--file="):
                explicit_script = True
                i += 1
                continue
            if tok.startswith("--line-length="):
                i += 1
                continue
            if tok.startswith("--"):
                # Any other GNU sed long flag (--posix, --debug, --sandbox,
                # --unbuffered, --separate, --quiet, --silent,
                # --regexp-extended, --null-data, ...) is boolean - skipped
                # as a flag, never left to fall through to positional. A
                # naive fallthrough here wrongly treated an unrecognized long
                # flag as sed'"'"'s own script/file positional argument,
                # corrupting target detection the same way an unhandled
                # short flag did before the character-level cluster parse
                # below (review round 2).
                i += 1
                continue
            if tok.startswith("-") and tok != "-" and not tok.startswith("--"):
                cl_inplace, cl_script, consumed_next = _consume_short_cluster(tok)
                has_inplace = has_inplace or cl_inplace
                explicit_script = explicit_script or cl_script
                i += 2 if consumed_next else 1
                continue
            positional.append(tok)
            i += 1
        if not has_inplace:
            return []
        # With no -e/-f, sed'"'"'s own first positional argument is the SCRIPT, not a
        # file - strip it. With -e/-f already supplying the script, every
        # remaining positional is a file (sed -i can edit several at once).
        if not explicit_script and positional:
            positional = positional[1:]
        return positional

    def cp_mv_targets(argv):
        positional = []
        target_dir = None
        i = 1
        n = len(argv)
        while i < n:
            tok = argv[i]
            if tok in ("-t", "--target-directory"):
                if i + 1 < n:
                    target_dir = argv[i + 1]
                i += 2
                continue
            if tok.startswith("--target-directory="):
                target_dir = tok.split("=", 1)[1]
                i += 1
                continue
            if tok == "--":
                positional.extend(argv[i + 1:])
                break
            if tok.startswith("-") and tok != "-":
                i += 1
                continue
            positional.append(tok)
            i += 1
        if target_dir is not None:
            return [target_dir]
        if len(positional) >= 2:
            return [positional[-1]]
        return []

    for seg in segments:
        b, argv = resolve_command(seg)
        if not argv:
            continue
        if b == "tee":
            check_write_targets(
                [t for t in argv[1:] if not t.startswith("-")], "tee"
            )
        elif b == "sed":
            check_write_targets(sed_inplace_targets(argv), "sed -i")
        elif b in ("cp", "mv"):
            check_write_targets(cp_mv_targets(argv), "%s" % b)

sys.exit(0)
' 2>/dev/null

exit 0
