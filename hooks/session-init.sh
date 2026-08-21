#!/usr/bin/env bash
# session-init.sh - a Claude Code SessionStart hook (all sources: startup,
# resume, clear, compact). One of claude's two entry points into the shared
# orchestrator bootstrap routine (docs/analysis/2026-08-18-remove-bin-
# wingman-launcher-spec.md, §4.5, §8 step 7) - bin/lib/orchestrator-
# bootstrap.sh does the actual work (guard-transport reconcile+self-test,
# self-pane registration, tmux-guardian launch, the freshness/continuity-
# transport notice); this hook's own job is only to call it EAGERLY, before
# the model's first tool call is even proposed, and surface the result as
# additionalContext. hooks/orchestrator-guard-sync-gate.sh (PreToolUse) is
# the other entry point, and the actual gate - see its own header for why
# SessionStart alone can never BE the gate (it cannot block a session from
# starting; a PreToolUse denial is the only thing that can).
#
# Always runs the bootstrap FRESH on every trigger (start, resume, clear,
# compact) - deliberately not cache-gated the way the PreToolUse backstop is:
# SessionStart fires rarely enough that paying the reconcile cost every time
# is cheap, and doing so gives the eager path a real self-healing property a
# cache-gated path would not (a bootstrap that failed on session start can
# succeed on the next /compact once the operator fixes the underlying
# problem, with no tool call needed to trigger a retry).
#
# Registered project-level in this repo's own .claude/settings.json (like
# pilot-preferences-nudge.sh, hooks/session-init.sh's own sibling) - ships
# with a git pull, so this fires with zero manual setup for wingman's own
# top-level session specifically. bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(dirname "$HERE")"

# wm_harness_process_identity only - deliberately NOT bin/lib/common.sh,
# which this hook avoids sourcing for the same reason hooks/pilot-
# preferences-nudge.sh does (a real `uv run` subprocess on every fire, just
# to read config.local.toml, which this hook never needs).
[ -r "$REPO/bin/lib/harness-identity.sh" ] && . "$REPO/bin/lib/harness-identity.sh"

# Consume stdin (the hook input JSON); this hook behaves identically for
# every SessionStart source, so nothing in it is needed.
cat >/dev/null

wm_is_wingman_repo_session() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 1
  _proj="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)"
  [ -n "$_proj" ] && [ "$_proj" = "$REPO" ]
}

# Active only for wingman's own top-level session: never for crew (a crew
# member's own bootstrap, if it ever needs one, is a different, unbuilt
# mechanism entirely - see docs/guards.md's own stated precondition on that
# follow-on), and never for an unrelated session that merely has claude
# installed.
[ -z "${WINGMAN_CREW_ID:-}" ] || exit 0
wm_is_wingman_repo_session || exit 0

WM_RUN_ID="${WINGMAN_RUN_ID:-}"
if [ -z "$WM_RUN_ID" ]; then
  WM_RUN_ID="$(wm_harness_process_identity 2>/dev/null)" || WM_RUN_ID=""
fi
[ -n "$WM_RUN_ID" ] || exit 0

"$REPO/bin/lib/orchestrator-bootstrap.sh" --agent claude --repo "$REPO" \
  >/dev/null 2>&1 </dev/null

WM_HOME="${WINGMAN_HOME:-$HOME/.wingman}"
STATUS_DIR="$WM_HOME/orchestrator-bootstrap"
OUTCOME_FILE="$STATUS_DIR/$WM_RUN_ID.outcome"
REASON_FILE="$STATUS_DIR/$WM_RUN_ID.reason"
NOTICE_FILE="$STATUS_DIR/$WM_RUN_ID.notice"

OUTCOME="$(cat "$OUTCOME_FILE" 2>/dev/null)"
REASON=""
[ "$OUTCOME" = fail ] && REASON="$(cat "$REASON_FILE" 2>/dev/null)"
NOTICE="$(cat "$NOTICE_FILE" 2>/dev/null)"
# Consumed here, once - claude gets this notice as context text right now,
# so the PreToolUse backstop must never ALSO deny the first tool call over
# the identical notice (that would be the same information delivered twice,
# once as a friendly note and once as a confusing denial).
[ -n "$NOTICE" ] && rm -f "$NOTICE_FILE"

WM_BIN_ABS="$REPO/bin"

WM_SI_OUTCOME="$OUTCOME" WM_SI_REASON="$REASON" WM_SI_NOTICE="$NOTICE" \
  WM_SI_BIN="$WM_BIN_ABS" WM_SI_REPO="$REPO" \
  uv run --no-project --quiet python -c '
import json, os

outcome = os.environ.get("WM_SI_OUTCOME", "")
reason = os.environ.get("WM_SI_REASON", "")
notice = os.environ.get("WM_SI_NOTICE", "")
wm_bin = os.environ.get("WM_SI_BIN", "")
wm_repo = os.environ.get("WM_SI_REPO", "")

parts = [
    "Wingman self-bootstrap: WINGMAN_BIN=%s, WINGMAN_REPO=%s, WINGMAN_STATE=\"uv run --no-project --quiet %s/lib/wm-state.py\" "
    "(nothing exports these into your shell - substitute these literal values everywhere this repo'"'"'s docs write $WINGMAN_BIN/$WINGMAN_REPO/$WINGMAN_STATE)."
    % (wm_bin, wm_repo, wm_bin)
]

if outcome == "fail":
    parts.append(
        "wingman'"'"'s own guard-hook bootstrap FAILED: %s A PreToolUse hook "
        "(hooks/orchestrator-guard-sync-gate.sh) will deny every tool call "
        "except a retry of the bootstrap itself until this is fixed."
        % (reason or "(no reason recorded)")
    )
elif notice:
    parts.append(notice)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "\n\n".join(parts),
    }
}))
' 2>/dev/null

exit 0
