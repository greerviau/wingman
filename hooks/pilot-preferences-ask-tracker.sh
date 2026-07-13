#!/usr/bin/env bash
# pilot-preferences-ask-tracker.sh - a Claude Code PostToolUse hook (matcher
# AskUserQuestion). Writes an existence-only marker,
# $WINGMAN_HOME/prefs-asked-<session_id>, the instant any AskUserQuestion call
# completes this session.
#
# hooks/pilot-preferences-guard.sh accepts a `pref-set` Bash call only once
# this marker exists: it proves a real question was put to the pilot at some
# point this session before any answer is cached, closing the self-answer gap
# (a session under deny pressure inventing plausible answers without ever
# asking). It does not verify the question's content matched the required
# preferences - an explicitly-accepted residual gap (see the plan's Open
# Questions).
#
# Registered project-level in this repo's .claude/settings.json alongside the
# guard and nudge. The marker is written by this hook, never by an instruction
# the agent might skip.
# bash-3.2-safe.
set -u

WM_UV="${WM_UV:-uv run --no-project --quiet}"

WINGMAN_HOME="${WINGMAN_HOME:-$HOME/.wingman}" $WM_UV python -c '
import json, os, re, sys

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
if data.get("tool_name") != "AskUserQuestion":
    sys.exit(0)
sid = re.sub(r"[^A-Za-z0-9._-]", "_", data.get("session_id") or "")
if not sid:
    sys.exit(0)
home = os.path.expanduser(os.environ["WINGMAN_HOME"])
try:
    os.makedirs(home, exist_ok=True)
    open(os.path.join(home, "prefs-asked-%s" % sid), "a").close()
except OSError:
    pass
' 2>/dev/null

exit 0
