#!/usr/bin/env bash
# denial-report-guard.sh - a Claude Code Stop hook, registered ONLY at user
# scope (~/.claude/settings.json, via bin/lib/install-user-hook.py, wired up
# by bin/doctor), like hooks/stop-guard-crew.sh - a crew session's project
# root is usually another repo, where this repo's own .claude/settings.json
# never loads.
#
# Defect B's mechanical backstop (issue #214): a denied tool call must never
# be absorbed into silence. The prior incident's lead saw exactly this - a
# `crew-say` call denied `user-rejected`, followed one millisecond later by
# "[Request interrupted by user for tool use]" - and, with no rule telling it
# what that meant for an unattended session, simply carried on. The harness's
# own denial text ("...STOP what you are doing and wait for the user to tell
# you how to proceed") is written for an attended, interactive session; a
# crew session is never attended that way, so playbooks/_status-contract.md's
# prose rule (§3.8) translates it to "report `blocked`" - but prose alone
# re-runs the experiment that already failed once. This hook detects the same
# condition mechanically, from an exact harness field (`toolDenialKind`), and
# blocks the Stop until the member has actually reported it.
#
# `user-rejected` is the one denial kind with no remedy of its own carried in
# its own text (unlike `permission-rule`, which carries the denying hook's
# own remedy, and `automode-blocked`, which carries "try other tools ... if
# essential, STOP and explain to the user") - see
# hooks/lib/denial_report_guard.py's own docstring for the corpus survey this
# scoping is based on. It covers both flavours a crew session can hit: a live
# interrupt of an in-flight tool call, and an ungranted permission in an
# unattended session; the reason text names which one occurred but blocks on
# both the same way.
#
# Dedup is per (crew id, denial record uuid) via
# $WINGMAN_HOME/denial-seen-<id>.json - once a given denial has produced one
# blocked Stop, it never blocks again, bounding this hook's cost at exactly
# one blocked Stop per denial event, ever (a member that reports it, or that
# already recovered and says so, is free to stop normally afterward).
#
# Failure posture: FAIL OPEN. A malformed, truncated, or missing
# transcript_path, or any parse error, exits 0 (allow) - the opposite of this
# repo's other guards (hooks/no-foreground-watcher-guard.sh and
# tests/guardrail-failclosed.test.sh fail closed), because those gate an
# action that must not happen, while this one gates ENDING a turn - a hook
# that fails closed here would wedge every crew session's Stop indefinitely.
# See hooks/lib/denial_report_guard.py for the actual scanning logic.
#
# Only ever meaningful for a crew session (WINGMAN_CREW_ID set); wingman's own
# top-level session is attended, so it is exempt exactly like
# hooks/stop-guard-crew.sh's own identical gate.
#
# Interaction with the existing Stop chain: this becomes the THIRD user-scope
# Stop hook alongside hooks/stop-guard-crew.sh and hooks/stop-continuity-crew.sh
# (the latter registered with asyncRewake: true). A `decision: block` from one
# Stop hook composing correctly alongside an asyncRewake hook is not a new
# combination for this harness to prove out - this repo's OWN project-scoped
# .claude/settings.json already registers exactly that pairing today (a plain
# `decision: block` hooks/stop-guard.sh alongside the asyncRewake
# hooks/stop-continuity.sh, both live for wingman's own top-level session), so
# a third block-capable hook joining the crew-scoped mirror of that same pair
# is the identical, already-proven composition, not an untested one.
# bash-3.2-safe.
set -u

if [ -z "${WINGMAN_CREW_ID:-}" ]; then
  # Drain stdin (the Stop event JSON) before exiting - never skip this, or an
  # unread stdin risks a broken-pipe error on the harness side for what
  # should be a silent no-op.
  cat >/dev/null
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"
WM_HOME="${WINGMAN_HOME:-$HOME/.wingman}"

INPUT="$(cat)"
[ -n "$INPUT" ] || exit 0

printf '%s' "$INPUT" | \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, sys

from denial_report_guard import run

payload = sys.stdin.read()
crew_id = os.environ.get("WINGMAN_CREW_ID", "")
wm_home = os.environ.get("WINGMAN_HOME") or os.path.expanduser("~/.wingman")
result = run(payload, crew_id, wm_home)
if result is not None:
    print(json.dumps(result))
' "$WINGMAN_CREW_ID" 2>/dev/null

exit 0
