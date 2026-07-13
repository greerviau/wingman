#!/usr/bin/env bash
# pilot-preferences-nudge.sh - a Claude Code SessionStart hook (all sources:
# startup, resume, clear, compact). When any required onboarding preference
# (hooks/lib/pilot-prefs.sh) is unanswered for the current WINGMAN_RUN_ID, it
# injects the full list of still-missing questions as additionalContext,
# phrased so the session's natural next action is the one batched
# AskUserQuestion call CLAUDE.md's "Confirm onboarding preferences" section
# describes.
#
# This is front-loaded visibility, not the enforcement - context injection is
# exactly the class of thing that has already failed twice here as static
# CLAUDE.md prose. hooks/pilot-preferences-guard.sh (PreToolUse) is the
# load-bearing gate; this nudge just means the guard rarely has to actually
# deny anything in practice.
#
# Same activation as the guard: wingman's own top-level session only,
# registered project-level in this repo's .claude/settings.json.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(dirname "$HERE")"
STATE_PY="$REPO/bin/lib/wm-state.py"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

. "$HERE/lib/pilot-prefs.sh"

# Consume stdin (the hook input JSON); the nudge behaves identically for every
# SessionStart source, so nothing in it is needed.
cat >/dev/null

wm_is_wingman_repo_session() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 1
  _proj="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)"
  [ -n "$_proj" ] && [ "$_proj" = "$REPO" ]
}

[ -z "${WINGMAN_CREW_ID:-}" ] || exit 0
wm_is_wingman_repo_session || exit 0
[ -n "${WINGMAN_RUN_ID:-}" ] || exit 0

wm_prefs_missing "$STATE_PY" "$WINGMAN_RUN_ID"
[ -n "$WM_PREFS_MISSING_KEYS" ] || exit 0

printf '%s' "$WM_PREFS_MISSING_LINES" | $WM_UV python -c '
import json, sys

missing = sys.stdin.read().rstrip("\n")
ctx = (
    "Onboarding preferences for this wingman run are still unanswered. Before "
    "touching any directive, say to the pilot: \"Before I start working, I "
    "need to ask you some preference questions:\" and ask ALL of the following "
    "in ONE batched AskUserQuestion call, then cache each answer with "
    "$WINGMAN_STATE pref-set --run-id \"$WINGMAN_RUN_ID\" --key <key> "
    "--value <value>:\n%s\n"
    "A PreToolUse guard (hooks/pilot-preferences-guard.sh) denies every other "
    "tool call until all of them are cached." % missing
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx,
    }
}))
' 2>/dev/null

exit 0
