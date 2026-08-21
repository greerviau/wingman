#!/usr/bin/env bash
# orchestrator-guard-sync-gate.sh - a Claude Code PreToolUse hook (empty
# matcher = every tool). The other of claude's two entry points into the
# shared orchestrator bootstrap routine (docs/analysis/2026-08-18-remove-bin-
# wingman-launcher-spec.md, §4.5, §8 step 7) - and the one that actually
# GATES, unlike hooks/session-init.sh (SessionStart), which cannot: Claude
# Code has no hook event capable of literally preventing a session from
# starting, so a bootstrap failure there can only ever be advisory context.
# This is the backstop that turns it into a real refusal, before the
# session's first tool call is allowed to proceed (spec §7 risk 3).
#
# Reads the SAME per-identity status files bin/lib/orchestrator-bootstrap.sh
# writes (see that script's own header for the full contract) - normally
# already fresh, since hooks/session-init.sh already ran the bootstrap
# eagerly moments earlier; this hook's own bootstrap invocation below is a
# fallback for the rare case that never happened (a resumed session whose
# SessionStart hook did not fire for some reason, or the very first tool
# call of a session where it raced).
#
# Fail-CLOSED, deliberately unlike hooks/pilot-preferences-guard.sh's own
# fail-open posture: denies when the outcome is "fail" OR when no outcome
# can be established at all (identity unresolvable, the bootstrap script
# itself missing/unexecutable) - "missing entirely" denies exactly like
# "fail" does, since this is the LAST-RESORT check (bin/wingman's own
# original guard-transport gate was fail-closed and pre-exec; this is its
# direct replacement, so it keeps that posture). A denial always names a
# concrete, allowlisted way out: a direct re-invocation of bin/lib/
# orchestrator-bootstrap.sh, which this hook always allows through
# regardless of any cached outcome - the same escape-hatch shape pilot-
# preferences-guard.sh already ships, so a failed bootstrap can never be a
# dead end with no possible next action.
#
# Registered project-level in this repo's own .claude/settings.json (like
# hooks/pilot-preferences-guard.sh) - ships with a git pull, so this fires
# with zero manual setup for wingman's own top-level session specifically.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(dirname "$HERE")"

PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONPATH

[ -r "$REPO/bin/lib/harness-identity.sh" ] && . "$REPO/bin/lib/harness-identity.sh"

INPUT="$(cat)"

wm_is_wingman_repo_session() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 1
  _proj="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)"
  [ -n "$_proj" ] && [ "$_proj" = "$REPO" ]
}

[ -z "${WINGMAN_CREW_ID:-}" ] || exit 0
wm_is_wingman_repo_session || exit 0

WM_RUN_ID="${WINGMAN_RUN_ID:-}"
if [ -z "$WM_RUN_ID" ]; then
  WM_RUN_ID="$(wm_harness_process_identity 2>/dev/null)" || WM_RUN_ID=""
fi
# No identity resolvable at all: nothing to key a cache entry on, and no
# past-tense evidence to deny over either - this exact machine/process may
# be one `ps` cannot introspect (issue precedent: harness-identity.sh's own
# documented degrade). Falling all the way to a hard deny here would mean a
# session that can never resolve an identity can never do ANYTHING, ever,
# with no escape hatch at all (unlike the "fail"/"missing status" cases
# below, which always have one) - so this one case stays open rather than
# closed.
[ -n "$WM_RUN_ID" ] || exit 0

WM_HOME="${WINGMAN_HOME:-$HOME/.wingman}"
STATUS_DIR="$WM_HOME/orchestrator-bootstrap"
OUTCOME_FILE="$STATUS_DIR/$WM_RUN_ID.outcome"
REASON_FILE="$STATUS_DIR/$WM_RUN_ID.reason"
NOTICE_FILE="$STATUS_DIR/$WM_RUN_ID.notice"
BOOTSTRAP_SCRIPT="$REPO/bin/lib/orchestrator-bootstrap.sh"

# The retry escape hatch: a direct invocation of the bootstrap script itself
# is ALWAYS allowed, regardless of any cached outcome - checked first and
# cheaply (no status-file read needed) via the same hooks/lib/cmd_match.py
# resolver every other guard in this codebase uses, so a failed bootstrap is
# never a dead end. Probed the same way pilot-preferences-guard.sh probes
# its own escape hatch: through the actual resolver, not by string-matching
# the command by hand.
# Both basenames match hooks/lib/guard_dispatch.py's own
# _ORCH_BOOTSTRAP_RETRY_BASENAMES (the identical allowlist for the four
# non-Claude dialects) - bin/doctor is included too, not just a direct
# bootstrap re-run: once bin/doctor reconciles all five guard transports
# (not just claude's), it fixes the same underlying registration this gate
# checks, and the spec's own remedy text for a guard-transport failure
# already names it ("run bin/doctor -y"). Keep both allowlists in sync.
IS_RETRY="$(printf '%s' "$INPUT" | uv run --no-project --quiet python -c '
import json, sys
from cmd_match import command_segments, resolve_command

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
command = ((data.get("tool_input") or {}).get("command") or "") if data.get("tool_name") == "Bash" else ""
segments = command_segments(command) if command else None
RETRY_BASENAMES = ("orchestrator-bootstrap.sh", "doctor")
is_retry = bool(segments) and all(
    resolve_command(seg)[0] in RETRY_BASENAMES for seg in segments)
print("1" if is_retry else "0")
' 2>/dev/null)"
[ "$IS_RETRY" = "1" ] && exit 0

if [ ! -f "$OUTCOME_FILE" ]; then
  # Fallback: hooks/session-init.sh should already have run this moments
  # earlier, but a resumed session whose SessionStart never fired (or a
  # genuine race on the very first tool call) leaves no cache entry yet -
  # run it now rather than deny with nothing to point at.
  "$BOOTSTRAP_SCRIPT" --agent claude --repo "$REPO" >/dev/null 2>&1 </dev/null
fi

OUTCOME="$(cat "$OUTCOME_FILE" 2>/dev/null)"

if [ "$OUTCOME" != pass ]; then
  REASON="$(cat "$REASON_FILE" 2>/dev/null)"
  [ -n "$REASON" ] || REASON="wingman's orchestrator bootstrap produced no recorded outcome for this session at all (identity $WM_RUN_ID) - the bootstrap script may be missing, unexecutable, or crashed before writing a status file."
  printf '%s' "$INPUT" | WM_GATE_REASON="$REASON" WM_GATE_SCRIPT="$BOOTSTRAP_SCRIPT" WM_GATE_REPO="$REPO" uv run --no-project --quiet python -c '
import json, os, sys

reason = os.environ.get("WM_GATE_REASON", "")
script = os.environ.get("WM_GATE_SCRIPT", "")
repo = os.environ.get("WM_GATE_REPO", "")

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "%s\n\nRetry with:\n  %s --agent claude --repo %s" % (
            reason, script, repo),
    }
}))
' 2>/dev/null
  exit 0
fi

# outcome == pass: check for a one-time notice this identity has not been
# shown yet (normally already consumed by hooks/session-init.sh - this is
# the same fallback shape as the missing-outcome case above, for whichever
# rare path reaches here before that hook ever ran).
NOTICE="$(cat "$NOTICE_FILE" 2>/dev/null)"
if [ -n "$NOTICE" ]; then
  rm -f "$NOTICE_FILE"
  printf '%s' "$INPUT" | WM_GATE_NOTICE="$NOTICE" uv run --no-project --quiet python -c '
import json, os

notice = os.environ.get("WM_GATE_NOTICE", "")
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "wingman orchestrator notice (informational, not a problem - just reissue your last command exactly as typed and it will proceed normally):\n%s" % notice,
    }
}))
' 2>/dev/null
  exit 0
fi

exit 0
