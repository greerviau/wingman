#!/usr/bin/env bash
# api-outage-spawn-guard.sh - a Claude Code PreToolUse hook (matcher "Bash").
# Denies bin/spawn-crew while the fleet outage-state (bin/lib/wm-state.py's
# outage-update, $WM_HOME/api-outage-state.json) reads "active" - issue #23,
# item 2 (PAUSE). A detected Anthropic API outage should not have wingman (or
# any lead) add new spawns into a live burst: each spawn is real compute that
# plausibly worsens the very overload triggering the outage signal, and a
# freshly spawned session risks dying into the same burst immediately (the
# exact risk issue #23's own comment names for a bare `crew-resume` run
# during an ongoing burst - the same reasoning applies just as much to a
# fresh spawn).
#
# Already-running crew are NOT affected by this guard - only NEW spawns are
# held (the pilot's own PAUSE decision for this plan: hold new spawns, never
# stand down or otherwise interrupt in-flight work).
#
# Modeled directly on hooks/no-merge-guard.sh: same cheap substring pre-gate,
# same cmd_match segment resolution (so `bin/spawn-crew`, `$WINGMAN_BIN/spawn-
# crew`, and a bare `spawn-crew` on PATH are all recognized identically -
# resolve_command already reduces every one of these to the basename
# "spawn-crew"), and the same fail-open posture on a missing/unreadable state
# file (reads as "clear", matching cmd_outage_update's own default) so a
# fresh install or a state file cleared out from under this hook never wedges
# every spawn.
#
# Lifted by --force-during-outage on the one spawn-crew call that needs it -
# mirrors --allow-merge's convention exactly: explicit, per-call, never
# inferred, and visible on the resulting crew record via bin/spawn-crew's own
# stdout. This applies uniformly to wingman's own spawns and any lead's,
# since both call the identical bin/spawn-crew.
#
# Registered user-level by bin/doctor, alongside no-merge-guard.sh (crew
# sessions have their project root in other repos, where this repo's project
# settings never load).
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Cheap no-op gate: only a command mentioning spawn-crew can possibly match
# anything below. Precise matching happens in the python block.
case "$INPUT" in
  *spawn-crew*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | \
  WINGMAN_HOME="${WINGMAN_HOME:-$HOME/.wingman}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, sys

from cmd_match import command_segments, resolve_command

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

if data.get("tool_name") != "Bash":
    sys.exit(0)

tool_input = data.get("tool_input", {}) or {}
command = tool_input.get("command", "") or ""
home = os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman")


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


PARSE_FAIL_REASON = (
    "This command could not be fully parsed - an unterminated quote, an "
    "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
    "terminator line was never found - so it is denied rather than "
    "partially checked (issue #56, the same posture hooks/no-merge-guard.sh "
    "takes on this shape). Reformat it into well-formed shell syntax and "
    "retry."
)

# cmd_match.py fails CLOSED on a command it cannot fully lex: command_segments()
# returns None rather than a partial, truncated segment list.
segments = command_segments(command)


def spawn_calls_and_force():
    calls = []
    force = False
    for seg in segments or []:
        b, argv = resolve_command(seg)
        if not argv or b != "spawn-crew":
            continue
        calls.append(seg)
        if any(t == "--force-during-outage" for t in argv):
            force = True
    return calls, force


calls, forced = spawn_calls_and_force()
if not calls:
    # Only fail closed on an unresolvable command if it actually mentions
    # spawn-crew (the pre-gate already guarantees that for this whole script,
    # but re-stated here so the None-segments branch is scoped identically to
    # every other check in this hook).
    if segments is None:
        deny(PARSE_FAIL_REASON)
    sys.exit(0)

if forced:
    sys.exit(0)

state_path = os.path.join(home, "api-outage-state.json")
try:
    with open(state_path) as fh:
        state = json.load(fh)
except (OSError, ValueError):
    state = {}
if not isinstance(state, dict) or state.get("state") != "active":
    sys.exit(0)

since = state.get("since") or "an unknown time"

# Affected count: every crew member currently live (working/blocked/review/
# stalled) - roughly "how big is the exposed fleet right now". Cheap and
# roster-only, no pane access needed here.
count = 0
try:
    with open(os.path.join(home, "crew.json")) as fh:
        roster = json.load(fh)
    if isinstance(roster, list):
        count = sum(1 for r in roster
                    if r.get("status") in ("working", "blocked", "review", "stalled"))
except (OSError, ValueError):
    pass

deny(
    "A fleet-wide Anthropic API outage has been detected (active since %s, "
    "issue #23) - new spawns are paused while it is ongoing so this session "
    "does not add more load into a live burst (roughly %d crew member(s) "
    "currently live). Already-running crew are NOT affected by this pause - "
    "only new spawns are held. Wait: your own watcher already wakes on the "
    "outage-cleared fire, nothing needs to be polled. Or, if this particular "
    "spawn is genuinely needed regardless, override with "
    "--force-during-outage on this one spawn-crew call." % (since, count)
)
' 2>/dev/null

exit 0
