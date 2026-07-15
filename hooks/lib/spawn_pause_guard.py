"""spawn_pause_guard: shared implementation behind every "pause new
bin/spawn-crew calls while a fleet-wide condition holds" PreToolUse hook.

Factored out of hooks/api-outage-spawn-guard.sh's own original logic (issue
#23) so hooks/usage-limit-spawn-guard.sh (issue #24) does not duplicate it -
the segment resolution, the parse-fail-closed handling, and the
fail-open-on-missing-state-file posture are subtle enough (see cmd_match.py's
own docstring) that two independent copies drifting apart over time is a
real risk, not a hypothetical one.

A caller (a thin wrapper .sh, invoking this via `python -c` with
PYTHONPATH=<hooks>/lib) supplies:

  - state_path: the fleet-wide state file to read (e.g.
    $WINGMAN_HOME/api-outage-state.json or .../usage-limit-state.json).
  - is_blocking_state(state_dict) -> bool: whether the parsed state file
    means "deny new spawns".
  - override_flag: the literal --force-during-... token that lifts the
    denial on the one spawn-crew call carrying it (mirrors --allow-merge's
    convention: explicit, per-call, visible on the resulting crew record).
  - build_message(state_dict) -> str: the denial reason text.

Reads the PreToolUse JSON payload from stdin, same as every hook in this
repo. Prints nothing (allow) unless it denies (prints the
hookSpecificOutput deny JSON on stdout). Never raises past run() - any
unexpected failure degrades to allow, matching the fail-open posture this
module documents throughout.
"""
import json
import sys

from cmd_match import command_segments, resolve_command

PARSE_FAIL_REASON = (
    "This command could not be fully parsed - an unterminated quote, an "
    "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
    "terminator line was never found - so it is denied rather than "
    "partially checked (issue #56, the same posture hooks/no-merge-guard.sh "
    "takes on this shape). Reformat it into well-formed shell syntax and "
    "retry."
)


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


def _spawn_calls_and_force(segments, override_flag):
    calls = []
    force = False
    for seg in segments or []:
        b, argv = resolve_command(seg)
        if not argv or b != "spawn-crew":
            continue
        calls.append(seg)
        if any(t == override_flag for t in argv):
            force = True
    return calls, force


def run(state_path, is_blocking_state, override_flag, build_message):
    """Read the PreToolUse payload from stdin and either deny (printing the
    hookSpecificOutput JSON) or allow (printing nothing). Never exits the
    process itself - the caller's own script controls that."""
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}

    if not isinstance(data, dict) or data.get("tool_name") != "Bash":
        return

    tool_input = data.get("tool_input", {}) or {}
    command = tool_input.get("command", "") or ""

    # cmd_match.py fails CLOSED on a command it cannot fully lex:
    # command_segments() returns None rather than a partial, truncated
    # segment list.
    segments = command_segments(command)
    calls, forced = _spawn_calls_and_force(segments, override_flag)

    if not calls:
        # Only fail closed on an unresolvable command if it actually
        # mentions spawn-crew (the caller's own cheap substring pre-gate
        # already guarantees this for the whole script, but re-checked here
        # so this branch is scoped identically regardless of caller).
        if segments is None:
            deny(PARSE_FAIL_REASON)
        return

    if forced:
        return

    try:
        with open(state_path) as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        state = {}

    if not isinstance(state, dict) or not is_blocking_state(state):
        return

    deny(build_message(state))
