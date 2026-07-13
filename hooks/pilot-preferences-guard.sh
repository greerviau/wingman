#!/usr/bin/env bash
# pilot-preferences-guard.sh - a Claude Code PreToolUse hook (empty matcher =
# every tool). Mechanically enforces CLAUDE.md's "Confirm onboarding
# preferences (once per run)" step: while any required preference (see
# hooks/lib/pilot-prefs.sh) is unanswered for the current WINGMAN_RUN_ID,
# every tool call is denied except the narrow set that lets the session
# resolve the gate itself and keep an already-running fleet supervised:
#
#   - AskUserQuestion: always allowed - it is how the gate gets satisfied.
#   - Bash resolving to `wm-state.py prefs-list|pref-get`: read-only checks of
#     the preference cache, always allowed.
#   - Bash resolving to `wm-state.py pref-set`: allowed only once an
#     AskUserQuestion call has completed this session (the marker
#     hooks/pilot-preferences-ask-tracker.sh writes) - answers must come from
#     the pilot, never invented under deny pressure.
#   - Bash resolving to `bin/crew-list`, arming `bin/watch-fleet`, or arming
#     `bin/crew-ask await`; and Read of exactly $WINGMAN_HOME/wake: the
#     commands hooks/stop-guard.sh itself directs the session to run, so a
#     wingman restart with crew already in flight (a fresh run id, so every
#     preference is unanswered again) can keep supervising that fleet while
#     the questions are pending. `bin/crew-say` is deliberately NOT exempt:
#     sending a message is closer to "acting", the pilot is present in that
#     moment anyway, and deferring it one turn costs little.
#   - A command chaining an allowed invocation with anything else does not
#     qualify: every ;/&&/||/pipe segment must itself be an allowed shape.
#
# This is prose-turned-mechanism: the same eager-ask instruction has been
# skipped in practice twice as prose (a playbook clause, then a top-level
# CLAUDE.md section - see docs/plans/2026-07-13-onboarding-preferences-hook-
# enforcement.md), so a hard deny, not a reminder, sits in front of every
# other tool call.
#
# Registered project-level in this repo's .claude/settings.json (like
# stop-guard.sh), not via bin/doctor: it activates only for wingman's own
# top-level session (WINGMAN_CREW_ID unset AND the session's project root is
# this checkout), exactly the sessions this repo's project settings load for -
# so it ships with a git pull and can never be silently "off" the way a
# consent-gated user-level install can.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(dirname "$HERE")"
STATE_PY="$REPO/bin/lib/wm-state.py"
WM_HOME="${WINGMAN_HOME:-$HOME/.wingman}"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

. "$HERE/lib/pilot-prefs.sh"

INPUT="$(cat)"

# True iff this session's project root is this wingman checkout - the only way
# an unset WINGMAN_CREW_ID means "wingman's own top-level session" rather than
# some unrelated Claude Code session running elsewhere on the machine.
wm_is_wingman_repo_session() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 1
  _proj="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)"
  [ -n "$_proj" ] && [ "$_proj" = "$REPO" ]
}

# Active only for wingman's own top-level session: never for crew (leads
# included - per the existing design a lead never does its own eager ask; only
# wingman's top-level session does), and never for unrelated sessions.
[ -z "${WINGMAN_CREW_ID:-}" ] || exit 0
wm_is_wingman_repo_session || exit 0
# Not launched via bin/wingman (no run id to scope answers to): nothing to gate.
[ -n "${WINGMAN_RUN_ID:-}" ] || exit 0

wm_prefs_missing "$STATE_PY" "$WINGMAN_RUN_ID"
[ -n "$WM_PREFS_MISSING_KEYS" ] || exit 0

printf '%s' "$INPUT" | \
  WM_GUARD_HOME="$WM_HOME" WM_GUARD_MISSING="$WM_PREFS_MISSING_LINES" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, re, sys

from cmd_match import command_segments, resolve_command

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

tool = data.get("tool_name", "")
tool_input = data.get("tool_input", {}) or {}
wm_home = os.environ.get("WM_GUARD_HOME", "")
missing = os.environ.get("WM_GUARD_MISSING", "").rstrip("\n")


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def allow():
    sys.exit(0)


# The gate is satisfied through this tool, so it is always allowed.
if tool == "AskUserQuestion":
    allow()

# Has a real AskUserQuestion completed this session? (Marker written by
# hooks/pilot-preferences-ask-tracker.sh.) Required before pref-set is
# accepted, so a session cannot invent answers without ever asking.
sid = re.sub(r"[^A-Za-z0-9._-]", "_", data.get("session_id") or "")
asked = bool(sid) and os.path.exists(os.path.join(wm_home, "prefs-asked-%s" % sid))

# Reading the wake file stop-guard.sh points at is fleet supervision, not
# acting on a directive - allowed (that exact path only).
if tool == "Read":
    target = tool_input.get("file_path") or ""
    if target and os.path.abspath(target) == os.path.abspath(os.path.join(wm_home, "wake")):
        allow()

need_ask = False
if tool == "Bash":
    command = tool_input.get("command", "") or ""
    segments = command_segments(command)
    if segments:
        all_allowed = True
        for seg in segments:
            b, argv = resolve_command(seg)
            sub = argv[1] if len(argv) > 1 else ""
            if b == "wm-state.py" and sub in ("prefs-list", "pref-get"):
                continue
            if b == "wm-state.py" and sub == "pref-set":
                if asked:
                    continue
                need_ask = True
                all_allowed = False
                continue
            if b in ("crew-list", "watch-fleet"):
                continue
            if b == "crew-ask" and sub == "await":
                continue
            all_allowed = False
        if all_allowed:
            allow()

if need_ask:
    deny(
        "Caching an onboarding-preference answer (pref-set) is only accepted "
        "after an AskUserQuestion call has completed this session - the answers "
        "must come from the pilot, never invented. Ask the still-missing "
        "questions below via AskUserQuestion first; this pref-set is then "
        "allowed.\n%s" % missing
    )

deny(
    "Onboarding preferences are unanswered for this wingman run, and nothing "
    "else proceeds until they are (see CLAUDE.md, \"Confirm onboarding "
    "preferences\"). Say \"Before I start working, I need to ask you some "
    "preference questions:\" and ask ALL of the following in ONE batched "
    "AskUserQuestion call, then cache each answer with $WINGMAN_STATE pref-set "
    "--run-id \"$WINGMAN_RUN_ID\" --key <key> --value <value>. Still missing:\n"
    "%s\n"
    "(While these are pending you may still run bin/crew-list, arm "
    "bin/watch-fleet or bin/crew-ask await as background watchers, read "
    "$WINGMAN_HOME/wake, and read the preference cache via prefs-list/"
    "pref-get.)" % missing
)
' 2>/dev/null

exit 0
