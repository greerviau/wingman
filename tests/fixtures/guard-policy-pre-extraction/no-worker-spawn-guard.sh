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
  WINGMAN_CREW_TYPE="${WINGMAN_CREW_TYPE:-}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, sys

from cmd_match import command_segments, resolve_command

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

if not isinstance(data, dict) or data.get("tool_name") != "Bash":
    sys.exit(0)

tool_input = data.get("tool_input", {}) or {}
command = tool_input.get("command", "") or ""

crew_type = os.environ.get("WINGMAN_CREW_TYPE", "")
caller_is_lead = crew_type.rsplit("/", 1)[-1] == "lead"

segments = command_segments(command)

PARSE_FAIL_REASON = (
    "This command could not be fully parsed - an unterminated quote, an "
    "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
    "terminator line was never found, including inside a `bash -c`/`eval` "
    "payload - so it is denied rather than partially checked, "
    "since this command mentions spawn-crew and could not be verified "
    "safe. Reformat it into well-formed shell syntax and retry."
)


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


if segments is None:
    deny(PARSE_FAIL_REASON)


def all_flag_values(argv, *names):
    # Every occurrence of a --type-shaped flag, not just the first: bin/
    # the spawn-crew parsing loop itself (--type) TYPE="$2"; shift 2 is
    # last-wins, so a single call can legally carry more than one --type
    # token. Rather than replicate that last-wins selection exactly, this
    # collects every occurrence and the caller denies if ANY of them
    # resolves to "lead" - simpler than matching the precedence of
    # spawn-crew itself, and strictly safer: it
    # cannot be bypassed by a spawn-crew --type developer --type lead trick
    # that relies on the hook only ever inspecting the first occurrence.
    values = []
    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok in names and i + 1 < len(argv):
            values.append(argv[i + 1])
            i += 2
            continue
        for name in names:
            if tok.startswith(name + "="):
                values.append(tok[len(name) + 1:])
                break
        i += 1
    return values


for seg in segments:
    b, argv = resolve_command(seg)
    if not argv or b != "spawn-crew":
        continue

    if not caller_is_lead:
        deny(
            "Spawning crew is not yours to do from a %s session - "
            "bin/spawn-crew is restricted to orchestrator-type "
            "callers (wingman'"'"'s own top-level session, or a lead) by "
            "CLAUDE.md'"'"'s depth cap (pilot -> wingman -> lead -> worker). "
            "If this work genuinely needs another crew member (e.g. a "
            "reviewer for your PR), report --status blocked naming exactly "
            "what you need - your lead/owner spawns it as its own direct "
            "report instead." % (crew_type or "worker")
        )

    target_types = all_flag_values(argv, "--type")
    if any(t.rsplit("/", 1)[-1] == "lead" for t in target_types):
        deny(
            "A lead may not spawn a further lead - CLAUDE.md'"'"'s "
            "depth cap is \"a lead spawns workers but not further leads.\" "
            "Spawn a software-analyst/architect/developer/reviewer worker "
            "instead; deeper management nesting is a future opt-in (see "
            "playbooks/common/lead.md'"'"'s Guardrails section), not something "
            "to reach for now."
        )

sys.exit(0)
' 2>/dev/null

exit 0
