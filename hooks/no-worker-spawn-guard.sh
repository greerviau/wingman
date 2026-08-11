#!/usr/bin/env bash
# no-worker-spawn-guard.sh - a Claude Code PreToolUse hook (matcher "Bash").
# Mechanically enforces BOTH halves of CLAUDE.md's depth cap (issue #212,
# recommendation 3): "pilot -> wingman -> lead -> worker... a lead spawns
# workers but not further leads." Denies bin/spawn-crew outright for every
# worker crew type (developer, reviewer, architect, software-analyst,
# research, ...), and denies it for a lead too when the thing being spawned
# is itself a lead. See docs/analysis/2026-07-30-lead-rollup-gap-and-
# depth-cap-anomaly.md: a developer spawned its own reviewer after its
# lead's own spawn-objective text implied it should - a prompt-level cap
# already failed once under instructed pressure, so this makes it
# structurally true instead of aspirational.
#
# Active whenever WINGMAN_CREW_ID is set (a real crew session). Inactive for
# wingman's own top-level session (WINGMAN_CREW_ID unset entirely - it must
# remain able to spawn a lead or a worker directly) with no cwd check
# needed: unlike hooks/no-direct-edit-guard.sh (which blocks a broad action,
# Edit/Write, that legitimate unrelated sessions perform constantly in
# arbitrary repos, and so must distinguish wingman's own top-level session
# from an unrelated one sharing the same "no WINGMAN_CREW_ID" shape), this
# hook only ever fires on an actual bin/spawn-crew invocation - no unrelated
# Claude Code session anywhere else on the machine has any legitimate
# reason to invoke this repo's bin/spawn-crew at all, so exempting every
# "no WINGMAN_CREW_ID" session uniformly introduces no real gap.
#
# Both the caller's own type and the TARGET type it is trying to spawn are
# matched on their base role name (rsplit("/", 1)[-1]), not the full/
# qualified string, so a category-qualified spawn (--type
# software-development/developer, or a lead's own --type common/lead) is
# recognized identically to the bare form.
#
# A crew session with WINGMAN_CREW_ID set but WINGMAN_CREW_TYPE empty/unset
# (should never happen post-spawn, but not proven impossible) is treated as
# a worker, not exempted - fail CLOSED on this specific security-relevant
# restriction, the same posture hooks/no-merge-guard.sh takes throughout,
# rather than the fail-open posture hooks/no-direct-edit-guard.sh takes for
# the SAME missing-type shape (there, failing open means "allow the edit,"
# the safe direction for that hook's opposite restriction; here, failing
# open would mean "allow the spawn," exactly the gap this hook exists to
# close).
#
# No override flag: unlike --force-during-outage/--force-during-usage-limit
# (both transient fleet-wide conditions any legitimate spawn will want to
# proceed past once cleared), this is a standing architectural rule. A
# worker with a genuine need for another crew member reports it to its own
# owner (lead/wingman) via --status blocked instead - see the denial
# message. A lead that genuinely needs deeper management nesting is the
# "future opt-in" playbooks/common/lead.md's own Guardrails section already
# names as out of scope for now, not something to route around here.
#
# Modeled on hooks/api-outage-spawn-guard.sh for the spawn-crew detection
# shape (cheap substring pre-gate, then hooks/lib/cmd_match.py segment
# resolution so bin/spawn-crew, $WINGMAN_BIN/spawn-crew, and a bare
# spawn-crew on PATH are all recognized identically), and on
# hooks/no-merge-guard.sh for the parse-fail-closed posture on a command
# mentioning spawn-crew that cmd_match cannot fully lex (issue #56). Reads
# stdin (json.load) before any decision logic, matching every other hook in
# this repo - unlike an earlier draft of this hook, which computed the
# lead/worker exemption from the WINGMAN_CREW_TYPE env var (never stdin)
# and could exit before stdin was ever read; on a large payload that risks
# the upstream printf taking SIGPIPE on an unread pipe. There is no
# equivalent bash-level shortcut available now: because a LEAD's own calls
# must still be inspected (to catch lead-spawns-lead), only the
# WINGMAN_CREW_ID-unset case can skip invoking this hook's python entirely,
# and that shortcut already lives in bash, before stdin is ever piped in.
#
# Registered user-level by bin/doctor (crew sessions have their project root
# in other repos, where this repo's project settings never load) - same
# reasoning as every other crew-facing hook.
#
# issue #25 stage 3 (12a): the decision logic above is now a transport-
# agnostic function, evaluate_no_worker_spawn_guard(), in
# hooks/lib/guard_policy.py - this file is the Claude Code entry point only.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

case "$INPUT" in
  *spawn-crew*) ;;
  *) exit 0 ;;
esac

if [ -z "${WINGMAN_CREW_ID:-}" ]; then
  exit 0
fi

printf '%s' "$INPUT" | \
  WINGMAN_CREW_ID="${WINGMAN_CREW_ID:-}" \
  WINGMAN_CREW_TYPE="${WINGMAN_CREW_TYPE:-}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, sys

from guard_policy import GuardDenied, GuardInput, evaluate_no_worker_spawn_guard

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

if not isinstance(data, dict):
    data = {}

tool_input = data.get("tool_input", {}) or {}
gi = GuardInput(
    tool_name=data.get("tool_name") or "",
    command=tool_input.get("command", "") or "",
    cwd=data.get("cwd") or os.getcwd(),
    crew_id=os.environ.get("WINGMAN_CREW_ID", ""),
    crew_type=os.environ.get("WINGMAN_CREW_TYPE", ""),
    file_path="",
    notebook_path="",
    project_dir="",
    home=os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman"),
)

try:
    evaluate_no_worker_spawn_guard(gi)
except GuardDenied as e:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": str(e),
        }
    }))
sys.exit(0)
' 2>/dev/null

exit 0
