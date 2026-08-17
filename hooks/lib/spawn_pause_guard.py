"""spawn_pause_guard: shared implementation behind every "pause new
bin/spawn-crew calls while a fleet-wide condition holds" PreToolUse hook.

Factored out of hooks/api-outage-spawn-guard.sh's own original logic (issue
#23) so hooks/usage-limit-spawn-guard.sh (issue #24) does not duplicate it -
the segment resolution, the parse-fail-closed handling, and the
fail-open-on-missing-state-file posture are subtle enough (see cmd_match.py's
own docstring) that two independent copies drifting apart over time is a
real risk, not a hypothetical one.

The DECISION logic itself now lives once in
guard_policy.evaluate_spawn_pause_guards() - run() below is a thin stdin-
reading wrapper delegating to it, kept for its own sake so this module's
external contract (and tests/spawn-pause-guard.test.sh, which exercises it
directly via a throwaway fixture hook independent of either real guard)
stays unchanged.

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

from guard_policy import GuardDenied, GuardInput, evaluate_spawn_pause_guards


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))


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

    gi = GuardInput(
        tool_name="Bash", command=command, cwd="", crew_id="", crew_type="",
        file_path="", notebook_path="", project_dir="", home="",
    )
    try:
        evaluate_spawn_pause_guards(gi, state_path, is_blocking_state, override_flag, build_message)
    except GuardDenied as e:
        deny(str(e))
