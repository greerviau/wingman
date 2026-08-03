#!/usr/bin/env bash
# stop-continuity-crew.sh - a Claude Code Stop hook, asyncRewake-registered,
# registered ONLY at user scope (~/.claude/settings.json, via
# bin/lib/install-user-hook.py, wired up by bin/doctor). Extends
# hooks/stop-continuity.sh's own tokenless auto-arm to crew sessions - a
# lead's own session, or any worker - whose project root is some other repo,
# where this repo's own project-scoped .claude/settings.json never loads
# (issue #199; same rationale as hooks/no-interactive-prompt-guard.sh's
# identical crew-only gate for a different hook family, issue #155).
#
# Only ever meaningful for a crew session (WINGMAN_CREW_ID set). Wingman's own
# top-level session is covered exclusively by this repo's own project-scoped
# registration of hooks/stop-continuity.sh in .claude/settings.json, which
# this wrapper never touches. The gate MUST live here, in a wrapper on a path
# the project registration never exercises - not inside
# hooks/stop-continuity.sh itself - because a hook script cannot know which
# registration invoked it, so a gate inside the shared script body would also
# silently disable it for wingman's own top-level session (which has
# WINGMAN_CREW_ID unset), the one session it exists to protect.
#
# Uses exec, not a subshell call or `source`: hooks/stop-continuity.sh's own
# header is explicit that its own process must be the long-lived thing
# tracked under asyncRewake. exec replaces this wrapper's process image with
# the real script, so the real script becomes that tracked process directly -
# a plain call would leave this wrapper as the tracked process while the real
# work happened in a child.
#
# hooks/stop-continuity.sh itself is completely unmodified by this change.
# bash-3.2-safe.
set -u

if [ -z "${WINGMAN_CREW_ID:-}" ]; then
  # Drain stdin (the Stop event JSON) before exiting - never before exec
  # below, which needs it intact. An unread stdin here risks a broken-pipe
  # error on the harness side for what should be a silent no-op.
  cat >/dev/null
  exit 0
fi

exec "$(cd "$(dirname "$0")" && pwd)/stop-continuity.sh"
