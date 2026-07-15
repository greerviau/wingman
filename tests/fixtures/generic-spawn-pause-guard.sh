#!/usr/bin/env bash
# generic-spawn-pause-guard.sh - a minimal, throwaway PreToolUse hook whose
# entire business logic is "deny spawn-crew while $WM_TEST_STATE_FILE
# contains a JSON object with 'blocked': true", used ONLY by
# tests/spawn-pause-guard.test.sh to exercise hooks/lib/spawn_pause_guard.py
# generically - independent of either real guard's own state-file shape or
# wording, so this proves the SHARED machinery (segment resolution,
# parse-fail-closed, fail-open-on-missing-state-file) works on its own
# terms, not indirectly through one specific guard's business rules.
set -u

HERE="$(cd "$(dirname "$0")/../.." && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

case "$INPUT" in
  *spawn-crew*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | \
  PYTHONPATH="$HERE/hooks/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import os

from spawn_pause_guard import run

state_path = os.environ["WM_TEST_STATE_FILE"]


def is_blocking(state):
    return bool(state.get("blocked"))


def build_message(state):
    return "TEST_DENY: generic spawn-pause-guard fixture reason"


run(state_path, is_blocking, "--force-test", build_message)
' 2>/dev/null

exit 0
