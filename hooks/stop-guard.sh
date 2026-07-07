#!/usr/bin/env bash
# stop-guard.sh - a Claude Code Stop hook, wired only for the wingman repo.
# It prevents wingman ending a turn "blind": if crew need attention, or crew are
# in flight while the zero-token watcher is not running, it blocks the stop and
# tells wingman what to do. It never loops (respects stop_hook_active).
#
# Wired in .claude/settings.json of this repo, so it applies only here.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STATE_PY="$REPO/bin/lib/wm-state.py"
WM_HOME="${WINGMAN_HOME:-$HOME/.wingman}"
# Python via uv (matches the rest of the tool); --no-project so a surrounding
# pyproject is ignored.
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Avoid infinite loops: if we already blocked once this turn, allow the stop.
active="$(printf '%s' "$INPUT" | $WM_UV python -c 'import sys,json;
try: print(json.load(sys.stdin).get("stop_hook_active"))
except Exception: print("None")' 2>/dev/null)"
if [ "$active" = "True" ]; then
  exit 0
fi

# No state yet (pre-onboarding) → nothing to guard.
[ -f "$STATE_PY" ] || exit 0
[ -d "$WM_HOME" ] || exit 0

attention="$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" needs-attention 2>/dev/null)"
active_crew="$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" crew-list --active --json 2>/dev/null | $WM_UV python -c 'import sys,json;
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')"

# Is the watcher running?
watcher_up=0
pidfile="$WM_HOME/watch.pid"
if [ -f "$pidfile" ]; then
  pid="$(cat "$pidfile" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && watcher_up=1
fi

reason=""
if [ -n "$attention" ]; then
  reason="Crew need your attention before you go idle:
$attention
Surface each blocker/PR to the CTO (or answer via bin/crew-say), then you may stop."
elif [ "${active_crew:-0}" -gt 0 ] && [ "$watcher_up" = 0 ]; then
  reason="You have crew in flight but the supervisor is not running. Start it with 'bin/watch-fleet --start' so you are woken when they need you, then you may stop."
fi

if [ -n "$reason" ]; then
  printf '%s' "$reason" | $WM_UV python -c 'import sys,json; print(json.dumps({"decision":"block","reason":sys.stdin.read()}))'
  exit 0
fi

exit 0
