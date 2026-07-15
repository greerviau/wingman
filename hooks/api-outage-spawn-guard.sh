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
#
# A thin wrapper over the shared implementation (hooks/lib/spawn_pause_guard.py,
# issue #24) - the cmd_match-based segment resolution, parse-fail-closed
# handling, and fail-open-on-missing-state-file posture live there once,
# shared with hooks/usage-limit-spawn-guard.sh, so the two guards cannot
# silently drift apart over time.
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
import json, os

from spawn_pause_guard import run

home = os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman")
state_path = os.path.join(home, "api-outage-state.json")


def is_blocking(state):
    return state.get("state") == "active"


def build_message(state):
    since = state.get("since") or "an unknown time"

    # Affected count: every crew member currently live (working/blocked/
    # review/stalled) - roughly "how big is the exposed fleet right now".
    # Cheap and roster-only, no pane access needed here.
    count = 0
    try:
        with open(os.path.join(home, "crew.json")) as fh:
            roster = json.load(fh)
        if isinstance(roster, list):
            count = sum(1 for r in roster
                        if r.get("status") in ("working", "blocked", "review", "stalled"))
    except (OSError, ValueError):
        pass

    return (
        "A fleet-wide Anthropic API outage has been detected (active since %s, "
        "issue #23) - new spawns are paused while it is ongoing so this session "
        "does not add more load into a live burst (roughly %d crew member(s) "
        "currently live). Already-running crew are NOT affected by this pause - "
        "only new spawns are held. Wait: your own watcher already wakes on the "
        "outage-cleared fire, nothing needs to be polled. Or, if this particular "
        "spawn is genuinely needed regardless, override with "
        "--force-during-outage on this one spawn-crew call." % (since, count)
    )


run(state_path, is_blocking, "--force-during-outage", build_message)
' 2>/dev/null

exit 0
