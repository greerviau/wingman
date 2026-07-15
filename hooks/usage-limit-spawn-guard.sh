#!/usr/bin/env bash
# usage-limit-spawn-guard.sh - a Claude Code PreToolUse hook (matcher "Bash").
# Denies bin/spawn-crew while the fleet usage-quota-approach state (bin/lib/
# wm-state.py's usage-update, $WM_HOME/usage-limit-state.json) reads
# "approaching" or "paused" - issue #24. Both are "not yet resolved to
# continue": a spawn attempted in the brief window between detection and the
# pilot's wait-vs-continue answer is held exactly like one attempted after an
# explicit "wait" is held. Allowed again once the state is "clear" (nothing
# detected, or the window has since reset) or "acknowledged" (the pilot said
# continue anyway).
#
# Already-running crew are NOT affected by this guard - only NEW spawns are
# held. This does NOT implement the issue's literal "safe checkpoint"/"hold
# existing crew parked" ask: a member already running keeps running and
# keeps consuming quota regardless of the pilot's answer - there is no
# primitive in this codebase to checkpoint-and-hold a crew member mid-turn,
# and forcing a stop risks producing exactly the inconsistent, half-finished
# state the issue is trying to avoid. See docs/architecture.md's "Fleet-wide
# usage-limit-quota detection" section for the full rationale.
#
# A thin wrapper over the shared implementation (hooks/lib/spawn_pause_guard.py) -
# see hooks/api-outage-spawn-guard.sh (issue #23) for the twin guard this one
# is modeled on and shares its machinery with.
#
# Lifted by --force-during-usage-limit on the one spawn-crew call that needs
# it - mirrors --allow-merge/--force-during-outage's existing convention:
# explicit, per-call, never inferred, and visible on the resulting crew
# record via bin/spawn-crew's own stdout.
#
# Registered user-level by bin/doctor, alongside the outage-detection guard
# (crew sessions have their project root in other repos, where this repo's
# project settings never load).
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
import os

from spawn_pause_guard import run

home = os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman")
state_path = os.path.join(home, "usage-limit-state.json")


def is_blocking(state):
    return state.get("state") in ("approaching", "paused")


def build_message(state):
    window = state.get("window") or "usage"
    window_label = {"five_hour": "5-hour", "seven_day": "7-day"}.get(window, window)
    pct = state.get("used_percentage")
    pct_text = ("%.0f%%" % pct) if isinstance(pct, (int, float)) else "an unknown amount"
    resets_at = state.get("resets_at")
    resets_text = str(resets_at) if resets_at is not None else "an unknown time"
    state_word = state.get("state")
    decision_note = (
        "The pilot has not yet decided whether to wait or continue anyway."
        if state_word == "approaching"
        else "The pilot chose to wait for the reset."
    )

    return (
        "The %s usage-limit window is approaching its cap (issue #24) - used "
        "%s, resets at epoch %s. New spawns are paused while this is "
        "unresolved so the fleet stops growing into a known, foreseeable "
        "wall. %s Already-running crew are NOT affected by this pause - only "
        "new spawns are held, and in-flight work can still hit the hard "
        "limit on its own (this design does not checkpoint or park "
        "in-flight crew). Wait: your own watcher already wakes on the "
        "usage-limit-reset fire the moment the window resets, nothing needs "
        "to be polled. Or, if this particular spawn is genuinely needed "
        "regardless, override with --force-during-usage-limit on this one "
        "spawn-crew call." % (window_label, pct_text, resets_text, decision_note)
    )


run(state_path, is_blocking, "--force-during-usage-limit", build_message)
' 2>/dev/null

exit 0
