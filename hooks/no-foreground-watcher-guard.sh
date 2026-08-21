#!/usr/bin/env bash
# no-foreground-watcher-guard.sh - a Claude Code PreToolUse hook (matcher "Bash").
# Prevents the wedge issue #202 reports: a delegate told to "arm your own
# watch-fleet cycle" ran bin/watch-fleet in the FOREGROUND of a Bash tool
# call instead of as a harness-tracked background task. bin/watch-fleet (and
# bin/pr-watch, its crew-level analog) BLOCK until an event fires - that is
# their entire wake mechanism - so a foreground arm wedges the calling
# session indefinitely: no tool result ever comes back, the harness has
# nothing to re-invoke, and the stall detector cannot see it either (an
# armed background watcher and a wedged foreground one are indistinguishable
# from a bare execution-probe boolean - see
# docs/analysis/2026-08-03-issue-202-wedge-measurement.md and issue #202).
# The incident this closes ran for 5h27m before a human noticed.
#
# This is layer A (prevention) of the plan's two-layer design; layer B
# (detection - wm-state wedge-check, called from bin/watch-fleet's own pane
# loop) is the independent backstop for a wedge that starts some other way
# (this hook not yet registered, or a shape it cannot parse). Layer A closes
# the class at the tool-call boundary: it is unimplementable from INSIDE
# bin/watch-fleet itself, because a foreground and a `run_in_background:
# true` Bash call are indistinguishable from the invoked process's own point
# of view (same stdio handle kinds, same process ancestry, same environment -
# verified in this session's transcript and independently reproduced by a
# reviewer; see the plan's section 2.4) - only the tool-call boundary itself,
# where the harness's own `run_in_background` flag is still visible, can
# tell the two apart.
#
# What is denied, from EVERY session (no WINGMAN_CREW_ID gating - see
# "Gating" below):
#   - A Bash call that resolves to an ARMING invocation of bin/watch-fleet or
#     bin/pr-watch (i.e. not one of their read-only/one-shot forms - see
#     below) WITHOUT `run_in_background: true` on the tool call.
#   - The same, wrapped in `nohup`/`setsid` - denied UNCONDITIONALLY, even
#     with `run_in_background: true`: both detach the child from the
#     harness's own process tracking, so the process outlives the tracked
#     task and its exit wakes nobody. A detached watcher is not a watcher.
#   - The same, backgrounded with a bare shell `&` (including one that also
#     redirects, e.g. `bin/watch-fleet > /tmp/x 2>&1 &`) - detected via a
#     conservative textual scan, since `command_segments()` discards a bare
#     `&` the same way it discards `;` (see step below).
#   - An arming bin/watch-fleet invocation (regardless of run_in_background)
#     while a run-scoped spurious-repeated failure-budget standdown holds
#     for this session's owner (issue #198) - never bin/pr-watch, which has
#     no standdown concept. This closes the residual prose-only refusal left
#     by fixing the standdown's own composed text: that fix removes the
#     COMPETING instruction that told a model to arm and dissolve its own
#     standdown, but does not make the refusal enforceable on its own.
#     `bin/watch-fleet --clear-standdown` is allowlisted as the one explicit
#     way out (see the read-only forms below) - it is a deliberate, two-step,
#     explicitly-named action, not compliance with a nag.
#
# What is explicitly NOT denied (the read-only/one-shot forms, so a status
# check or a manual stop is never blocked by this hook):
#   - `--status`, `--stop`, `--classify`, `--clear-standdown` for
#     bin/watch-fleet.
#   - `--once` for bin/pr-watch.
#   - `-h`/`--help` for either.
#   - Any of the above under `timeout`/`nice`/`ionice`/`stdbuf` (the flag
#     allowlist is re-applied to the argv AFTER the located watch-fleet/
#     pr-watch token, not to the wrapper's own argv - see step 5 below;
#     without that re-application `timeout 5 bin/watch-fleet --status`
#     resolves as an arming call and is wrongly denied).
#
# NOT allowlisted: `--start` (bin/watch-fleet's own deprecated arm alias -
# it warns and then blocks exactly like a bare invocation) and `arm`
# (a bare positional that also arms). Both fall through to the same
# run_in_background gate as a plain invocation.
#
# Failure posture - specified here, never inherited. The structural model,
# hooks/no-worker-spawn-guard.sh, runs its decision body as
# `... $WM_UV python -c '...' 2>/dev/null` and then `exit 0` unconditionally;
# a deny is JSON on stdout, and an uncaught exception in that body produces
# no JSON, a discarded stderr, and a wrapper that still exits 0 - i.e. it
# ALLOWS, silently. That is fail-open, reached by exactly the contingency
# this hook must not have, since it does more fragile work on more varied
# input than its model (a textual `&` scan, `resolve_command` per segment,
# launcher-wrapper unwrapping, a coerced-text relevance test). So:
#
#   - The shell wrapper does its own cheap, textual relevance test on the
#     raw hook payload (a `case` for `watch-fleet`/`pr-watch`, no parsing) -
#     purely a short-circuit so an unrelated Bash call never pays for a
#     python startup. If that text is relevant, the python subprocess's
#     EXIT STATUS decides what the wrapper does next.
#   - Key this on exit status, never on "no stdout". In this hook family,
#     silence IS the allow decision: a deny is JSON on stdout followed by
#     `sys.exit(0)`, and an allow is a bare `sys.exit(0)` with no output at
#     all. A wrapper that denied on empty stdout would therefore deny every
#     legitimate `run_in_background: true` arm, and every Bash command that
#     merely MENTIONS watch-fleet/pr-watch (a `grep`, a `cat`) - since those
#     are allowed by producing nothing. Both real decisions exit 0; only an
#     uncaught raise or a dead interpreter is non-zero, which is exactly the
#     signal this wrapper acts on: if the payload was relevant (by the cheap
#     textual test above) and the python subprocess exits non-zero, the
#     WRAPPER emits the deny JSON itself.
#   - Inside python, everything after its own (more precise) relevance test
#     runs in a `try` whose `except Exception` denies with a "could not
#     verify this command, denied rather than partially checked" reason -
#     the same posture PARSE_FAIL_REASON already takes for an unlexable
#     command, extended to cover an internal error too.
#   - That inner relevance test is itself computed defensively so it cannot
#     raise: coerce `command` to text (`raw if isinstance(raw, str) else
#     str(raw)`) before the substring check. If the COERCED text is relevant
#     but `raw` was not a string, deny - a shape this hook cannot parse is
#     exactly what it must not wave through.
#
# Gating: none. Active for every session, crew and top-level alike -
# wingman's own top-level session foregrounding its own arm wedges it
# exactly the same way. No WINGMAN_CREW_ID check, for the reason
# hooks/no-worker-spawn-guard.sh states for itself: this hook only ever
# fires on an actual watch-fleet/pr-watch invocation, which no unrelated
# session anywhere else on the machine has any legitimate reason to run.
#
# No override flag. Following hooks/no-worker-spawn-guard.sh: there is no
# legitimate agent-side foreground arm. A human debugging the watcher
# interactively runs it from their own terminal, never through a Bash tool
# call - see the denial text below.
#
# Explicit scope statement (does NOT fire, or fires only partially, here):
#   - hooks/stop-continuity.sh, which legitimately foregrounds
#     bin/watch-fleet inside its OWN harness-tracked async-hook process
#     (docs/architecture.md's wake-loop section) - that is not a Bash tool
#     call, so PreToolUse never sees it.
#   - tests/*.test.sh - only the outer test-runner command is visible at the
#     tool-call boundary; a watch-fleet invocation inside a test's own
#     subshell is not a top-level Bash tool call either.
#   - Inherits hooks/lib/cmd_match.py's documented recognition gaps (`xargs`,
#     `find -exec`, piping a command into a shell) - defense against
#     realistic accidents, not an airtight sandbox (see docs/guards.md).
#
# Registered user-level by bin/doctor (crew sessions have their project root
# in other repos, where this repo's project settings never load) - same
# reasoning as every other crew-facing hook. bash-3.2-safe.
#
# The decision logic below is now ALSO implemented, canonically, as
# guard_policy.evaluate_no_foreground_watcher_guard() - this file's own bash
# pre-gate, failure posture, and stdout contract are unchanged for claude
# (decision-logic move, not a policy change). See guard_policy.py's own
# docstring for the normalized 9-field GuardInput contract this hands off,
# and hooks/lib/guard_dispatch.py for the equivalent entry point the four
# non-Claude dialects use (each with a dialect-aware denial reason, since
# none of them has a background tool-call mode for a model-issued call).
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(dirname "$HERE")"
WM_UV="${WM_UV:-uv run --no-project --quiet}"
# wm_harness_process_identity only - deliberately NOT bin/lib/common.sh; see
# hooks/pilot-preferences-guard.sh's identical comment for why (this hook
# too fires on every Bash tool call, for every session on this machine).
# Tolerates a partial/broken install - see hooks/pilot-preferences-guard.sh's
# identical line for why.
[ -r "$REPO/bin/lib/harness-identity.sh" ] && . "$REPO/bin/lib/harness-identity.sh"

INPUT="$(cat)"

# Cheap, textual pre-gate: every shape this hook cares about mentions
# "watch-fleet" or "pr-watch" somewhere in the raw payload text. This is
# ALSO the signal the failure-posture rule below keys its wrapper-level deny
# on - see the header comment.
case "$INPUT" in
  *watch-fleet*|*pr-watch*) ;;
  *) exit 0 ;;
esac

# Resolve WM_EFFECTIVE_RUN_ID once, here, at THIS SCRIPT's own natural depth
# from claude (2 hops: self -> the `sh -c <command>` Claude Code wraps every
# hook command string in -> claude itself, the same claude row already
# live-verified in docs/analysis/2026-08-19-issue-383-half-a-live-
# verification.md) - review round 2 of #383's Half A found guard_policy.py's
# own fallback shell-out, invoked from deep inside its nested python/uv
# chain when called some other way (i.e. without this pre-resolution),
# measures 6 hops from the harness, one more than WM_HARNESS_WALK_MAX's
# bound allows. Exporting it here (even when empty) means guard_policy._wm_
# effective_run_id() finds it already resolved and never re-walks from its
# own, deeper, call site. hooks/lib/guard_dispatch.py (the shared entry
# point for the four non-Claude dialects) does the identical thing in
# Python, from ITS OWN process, for the same reason.
if [ -z "${WM_EFFECTIVE_RUN_ID:-}" ]; then
  WM_EFFECTIVE_RUN_ID="${WINGMAN_RUN_ID:-}"
  if [ -z "$WM_EFFECTIVE_RUN_ID" ]; then
    # 2>/dev/null guards "command not found" only - see hooks/pilot-
    # preferences-guard.sh's identical block for why.
    WM_EFFECTIVE_RUN_ID="$(wm_harness_process_identity 2>/dev/null)" || WM_EFFECTIVE_RUN_ID=""
  fi
fi
export WM_EFFECTIVE_RUN_ID

OUT="$(printf '%s' "$INPUT" | \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, sys

from guard_policy import GuardDenied, GuardInput, evaluate_no_foreground_watcher_guard

data = json.load(sys.stdin)

if not isinstance(data, dict) or data.get("tool_name") != "Bash":
    sys.exit(0)

tool_input = data.get("tool_input")
if not isinstance(tool_input, dict):
    tool_input = {}
raw_command = tool_input.get("command", "")
command_text = raw_command if isinstance(raw_command, str) else str(raw_command)


def is_relevant(text):
    return "watch-fleet" in text or "pr-watch" in text


if not is_relevant(command_text):
    sys.exit(0)


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


VERIFY_FAIL_REASON = (
    "This command mentions watch-fleet/pr-watch but could not be verified "
    "safe - an unexpected tool_input shape, or an internal error while "
    "checking it - so it is denied rather than partially checked"
    ", since silence is this hook family'"'"'s own allow signal and a "
    "failure is not silence. If this is a legitimate arming call, reissue it "
    "as a plain bin/watch-fleet or bin/pr-watch invocation with "
    "run_in_background: true, on its own, not bundled onto another command."
)

# A coerced-relevant-but-non-string `command` (e.g. a list whose str() text
# happens to mention watch-fleet) is exactly the "shape this hook cannot
# parse" case the header names - denied here, before the try/except below,
# rather than waved through.
if not isinstance(raw_command, str):
    deny(VERIFY_FAIL_REASON)

try:
    gi = GuardInput(
        tool_name=data.get("tool_name") or "",
        command=raw_command,
        cwd=data.get("cwd") or os.getcwd(),
        crew_id=os.environ.get("WINGMAN_CREW_ID", ""),
        crew_type=os.environ.get("WINGMAN_CREW_TYPE", ""),
        file_path="",
        notebook_path="",
        project_dir=os.environ.get("CLAUDE_PROJECT_DIR", ""),
        home=os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman"),
    )
    try:
        evaluate_no_foreground_watcher_guard(
            gi, run_in_background=bool(tool_input.get("run_in_background")), dialect="claude")
    except GuardDenied as e:
        deny(str(e))
except Exception:
    deny(VERIFY_FAIL_REASON)

sys.exit(0)
' 2>/dev/null)"
PY_RC=$?

if [ "$PY_RC" -ne 0 ]; then
  # The relevance pre-gate above already established this command mentions
  # watch-fleet/pr-watch; the python decision body raised or the interpreter
  # died, so - per the failure posture in the header comment - this wrapper
  # denies itself rather than let a discarded stderr and an `exit 0` fall
  # through to a silent allow.
  cat <<'JSON'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "This command mentions watch-fleet/pr-watch but the check for it failed to run (a dead interpreter, or an internal error) - denied rather than partially checked, since silence is this hook family's own allow signal and a failure is not silence. If this is a legitimate arming call, reissue it as a plain bin/watch-fleet or bin/pr-watch invocation with run_in_background: true, on its own, not bundled onto another command."}}
JSON
  exit 0
fi

if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
fi

exit 0
