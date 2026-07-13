#!/usr/bin/env bash
# pilot-preferences-nudge.sh - a Claude Code SessionStart hook (all sources:
# startup, resume, clear, compact). When any required onboarding preference
# (hooks/lib/pilot-prefs.sh) is unanswered for the current WINGMAN_RUN_ID, it
# injects the full list of still-missing questions as additionalContext,
# phrased so the session's natural next action is the one batched
# AskUserQuestion call CLAUDE.md's "Confirm onboarding preferences" section
# describes.
#
# The questions come with the same concrete, absolute pref-set command the
# guard derives and verifies, so the instruction a session is front-loaded with
# is the one the guard enforces. When the state engine is unusable (the guard's
# fail-open condition), the question list is replaced by a plain statement that
# preferences cannot be cached and the guard is not gating - a session that
# starts into a broken install learns it here rather than through a wall of
# denials.
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

# The same concrete, absolute escape command hooks/pilot-preferences-guard.sh
# derives and verifies, so the front-loaded instruction and the enforced one are
# one string. The nudge needs no cmd_match self-check of its own: it never
# denies anything, so it cannot strand a session by naming a shape the guard
# would reject - the guard's own probe is what stands behind the command.
printf '%s' "$WM_PREFS_MISSING_LINES" | \
  WM_NUDGE_ESCAPE="$WM_UV $STATE_PY" WM_NUDGE_RUN_ID="$WINGMAN_RUN_ID" \
  WM_NUDGE_ENGINE_OK="$WM_PREFS_ENGINE_OK" WM_NUDGE_STATE_PY="$STATE_PY" \
  $WM_UV python -c '
import json, os, shlex, sys

missing = sys.stdin.read().rstrip("\n")
escape = os.environ.get("WM_NUDGE_ESCAPE", "")
run_id = os.environ.get("WM_NUDGE_RUN_ID", "")
engine_ok = os.environ.get("WM_NUDGE_ENGINE_OK", "1") == "1"
state_py = os.environ.get("WM_NUDGE_STATE_PY", "")

if not engine_ok:
    # A session starting into a broken install is told so here, rather than
    # discovering it through a wall of denials it cannot act on.
    ctx = (
        "wingman'"'"'s state engine at %s is unusable (missing, unreadable, or "
        "failing to run), so onboarding preferences cannot be cached for this "
        "run. The PreToolUse guard (hooks/pilot-preferences-guard.sh) has "
        "failed open and is not gating tool calls; every consumer of a "
        "preference will apply its conservative default. Tell the pilot, and "
        "fix the install (check `uv` and %s) before relying on preferences."
        % (state_py or "<unset>", state_py or "bin/lib/wm-state.py")
    )
else:
    ctx = (
        "Onboarding preferences for this wingman run are still unanswered. "
        "Before touching any directive, say to the pilot: \"Before I start "
        "working, I need to ask you some preference questions:\" and ask ALL of "
        "the following in ONE batched AskUserQuestion call:\n%s\n"
        "Then cache each answer with:\n  %s pref-set --run-id %s --key <key> "
        "--value <value>\n"
        "(the same command is exported as $WINGMAN_STATE: $WINGMAN_STATE "
        "pref-set --run-id \"$WINGMAN_RUN_ID\" --key <key> --value <value>)\n"
        "A PreToolUse guard (hooks/pilot-preferences-guard.sh) denies every "
        "other tool call until all of them are cached."
        % (missing, escape, shlex.quote(run_id))
    )
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx,
    }
}))
' 2>/dev/null

exit 0
