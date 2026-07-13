#!/usr/bin/env bash
# pilot-preferences-guard.sh - a Claude Code PreToolUse hook (empty matcher =
# every tool). Mechanically enforces CLAUDE.md's "Confirm onboarding
# preferences (once per run)" step: while any required preference (see
# hooks/lib/pilot-prefs.sh) is unanswered for the current WINGMAN_RUN_ID,
# every tool call is denied except the narrow set that lets the session
# resolve the gate itself and keep an already-running fleet supervised:
#
#   - AskUserQuestion: always allowed - it is how the gate gets satisfied.
#   - Bash resolving to `wm-state.py prefs-list|pref-get`: read-only checks of
#     the preference cache, always allowed.
#   - Bash resolving to `wm-state.py pref-set`: allowed only once an
#     AskUserQuestion call has completed this session (the marker
#     hooks/pilot-preferences-ask-tracker.sh writes) - answers must come from
#     the pilot, never invented under deny pressure.
#   - Bash resolving to `bin/crew-list`, arming `bin/watch-fleet`, or arming
#     `bin/crew-ask await`; and Read of exactly $WINGMAN_HOME/wake: the
#     commands hooks/stop-guard.sh itself directs the session to run, so a
#     wingman restart with crew already in flight (a fresh run id, so every
#     preference is unanswered again) can keep supervising that fleet while
#     the questions are pending. `bin/crew-say` is deliberately NOT exempt:
#     sending a message is closer to "acting", the pilot is present in that
#     moment anyway, and deferring it one turn costs little.
#   - A command chaining an allowed invocation with anything else does not
#     qualify: every ;/&&/||/pipe segment must itself be an allowed shape.
#
# This is prose-turned-mechanism: the same eager-ask instruction has been
# skipped in practice twice as prose (a playbook clause, then a top-level
# CLAUDE.md section - see docs/plans/2026-07-13-onboarding-preferences-hook-
# enforcement.md), so a hard deny, not a reminder, sits in front of every
# other tool call.
#
# The guard never instructs a command it has not verified it accepts. The
# escape hatch it prints is derived from the same paths the guard itself
# resolves ($WM_UV + the absolute wm-state.py), probed through the very
# hooks/lib/cmd_match.py resolver the allowlist keys on, and quoted verbatim in
# the deny reason with the run id filled in. The `$WINGMAN_STATE` short form is
# named only when it resolves too, so a session reading a denial never sees a
# shape this guard would reject - and the way out no longer depends on that
# variable being exported at all. Any future drift between the instruction and
# the acceptance fails the probe rather than stranding the run.
#
# Fail-open valve. Denying is only legitimate while a way out exists, so the
# guard gets out of the way - allowing the tool call - in exactly the three
# conditions under which it could not both deny and name one:
#
#   1. The state engine is unreadable ($REPO/bin/lib/wm-state.py missing or
#      unreadable).
#   2. The state engine is unusable (its prefs-list invocation exits non-zero).
#   3. The escape hatch does not resolve (the probe above fails, so the guard's
#      own canonical pref-set command would not pass its own allowlist).
#
# All three are properties of the installation rather than of the session, and
# none is reachable by cooperative session behaviour while the gate is
# unsatisfied (every mutating tool call is already denied, so a session cannot
# remove the state engine, uninstall uv, or edit the resolver). Reaching one
# therefore means a genuinely broken install - exactly the situation where
# continuing to deny is worse than allowing - so this is not a bypass.
# Failing open emits NO permissionDecision - the call proceeds through
# the normal permission flow and every other hook still applies - plus a
# one-per-session `systemMessage` naming the cause, and it records the reason
# in $WINGMAN_HOME/prefs-guard-failopen-<session_id> (existence-only, same
# convention as prefs-asked-<session_id>) so the failure is durable rather than
# silent. Preferences simply stay unanswered and every consumer applies its
# documented conservative default. A fourth fail-open is implicit and correct:
# if uv itself is missing, the embedded Python cannot run, the hook produces no
# output, and `exit 0` allows the call - a hook that cannot execute must not be
# able to brick the session.
#
# Registered project-level in this repo's .claude/settings.json (like
# stop-guard.sh), not via bin/doctor: it activates only for wingman's own
# top-level session (WINGMAN_CREW_ID unset AND the session's project root is
# this checkout), exactly the sessions this repo's project settings load for -
# so it ships with a git pull and can never be silently "off" the way a
# consent-gated user-level install can.
# bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(dirname "$HERE")"
STATE_PY="$REPO/bin/lib/wm-state.py"
WM_HOME="${WINGMAN_HOME:-$HOME/.wingman}"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

. "$HERE/lib/pilot-prefs.sh"

INPUT="$(cat)"

# True iff this session's project root is this wingman checkout - the only way
# an unset WINGMAN_CREW_ID means "wingman's own top-level session" rather than
# some unrelated Claude Code session running elsewhere on the machine.
wm_is_wingman_repo_session() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 1
  _proj="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)"
  [ -n "$_proj" ] && [ "$_proj" = "$REPO" ]
}

# Active only for wingman's own top-level session: never for crew (leads
# included - per the existing design a lead never does its own eager ask; only
# wingman's top-level session does), and never for unrelated sessions.
[ -z "${WINGMAN_CREW_ID:-}" ] || exit 0
wm_is_wingman_repo_session || exit 0
# Not launched via bin/wingman (no run id to scope answers to): nothing to gate.
[ -n "${WINGMAN_RUN_ID:-}" ] || exit 0

wm_prefs_missing "$STATE_PY" "$WINGMAN_RUN_ID"
[ -n "$WM_PREFS_MISSING_KEYS" ] || exit 0

# The canonical escape hatch, built from the values this hook itself resolved:
# absolute (so it works from any cwd) and independent of $WINGMAN_STATE being
# exported. The Python below probes it through cmd_match before it is allowed
# to print it, and fails open if it does not resolve.
WM_GUARD_ESCAPE="$WM_UV $STATE_PY"

printf '%s' "$INPUT" | \
  WM_GUARD_HOME="$WM_HOME" WM_GUARD_MISSING="$WM_PREFS_MISSING_LINES" \
  WM_GUARD_ESCAPE="$WM_GUARD_ESCAPE" WM_GUARD_RUN_ID="$WINGMAN_RUN_ID" \
  WM_GUARD_ENGINE_OK="$WM_PREFS_ENGINE_OK" WM_GUARD_STATE_PY="$STATE_PY" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, re, shlex, sys

from cmd_match import command_segments, resolve_command

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

tool = data.get("tool_name", "")
tool_input = data.get("tool_input", {}) or {}
wm_home = os.environ.get("WM_GUARD_HOME", "")
missing = os.environ.get("WM_GUARD_MISSING", "").rstrip("\n")
escape = os.environ.get("WM_GUARD_ESCAPE", "")
run_id = os.environ.get("WM_GUARD_RUN_ID", "")
engine_ok = os.environ.get("WM_GUARD_ENGINE_OK", "1") == "1"
state_py = os.environ.get("WM_GUARD_STATE_PY", "")

sid = re.sub(r"[^A-Za-z0-9._-]", "_", data.get("session_id") or "")


def allow():
    sys.exit(0)


def resolves_to_pref_set(prefix):
    """True iff `<prefix> pref-set ...`, typed as-is by the session, would be
    accepted by the allowlist below - checked through the very resolver that
    allowlist keys on, never by assumption."""
    if not prefix:
        return False
    # run_id is always non-empty here: the hook exits before this when
    # WINGMAN_RUN_ID is unset (no run to scope answers to, nothing to gate).
    probe = "%s pref-set --run-id %s --key remote --value true" % (
        prefix, shlex.quote(run_id))
    segs = command_segments(probe)
    if not segs:
        return False
    b, argv = resolve_command(segs[0])
    return b == "wm-state.py" and len(argv) > 1 and argv[1] == "pref-set"


def fail_open(reason):
    """The guard cannot both deny and name a way out, so it gets out of the way:
    no permissionDecision (the call continues through the normal permission flow
    and every other hook still applies), a systemMessage the first time it fires
    in a session, and a durable marker for post-hoc diagnosis."""
    marker = os.path.join(wm_home, "prefs-guard-failopen-%s" % sid) if sid else ""
    first = True
    if marker:
        first = not os.path.exists(marker)
        try:
            with open(marker, "a") as f:
                f.write(reason + "\n")
        except OSError:
            pass
    if first:
        print(json.dumps({"systemMessage":
            "wingman'"'"'s onboarding-preference guard has FAILED OPEN and is no "
            "longer gating tool calls: %s. The preferences for this run are "
            "still uncached and downstream consumers will apply their "
            "conservative defaults. Fix the cause and restart wingman." % reason}))
    sys.exit(0)


# Before any deny can be emitted: is there a way out at all? A guard that denies
# every tool call while unable to name a command it would accept strands the only
# actor that can satisfy it (issue #49), so each of these conditions fails open
# rather than denying.
if not state_py or not os.access(state_py, os.R_OK):
    fail_open("the state engine at %s is missing or unreadable, so no "
              "preference can be cached" % (state_py or "<unset>"))
if not engine_ok:
    fail_open("the state engine at %s exited non-zero when listing preferences, "
              "so no preference can be cached" % state_py)
if not resolves_to_pref_set(escape):
    fail_open("the guard'"'"'s own pref-set escape command (%s) does not resolve to "
              "an allowed shape, so it has no runnable way out to name" % escape)


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56):
# command_segments()/resolved_segments() return None rather than a partial,
# truncated segment list. This guard must deny on that, not skip it.
PARSE_FAIL_REASON = (
    "This command could not be fully parsed - an unterminated quote, an "
    "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
    "terminator line was never found - so it is denied rather than "
    "partially checked (issue #56). If this command embeds a heredoc to "
    "build up an argument (for example a PR body), quote its delimiter "
    "(<<'"'"'EOF'"'"' rather than <<EOF) unless bash must expand "
    "$(...)/`...` inside it; otherwise reformat it into well-formed shell "
    "syntax and retry."
)


# The escape hatch, verified above and now safe to instruct. The $WINGMAN_STATE
# short form is named only when it, too, resolves - so a session reading a
# denial never sees a shape this guard would reject.
escape_cmd = "%s pref-set --run-id %s --key <key> --value <value>" % (
    escape, shlex.quote(run_id))
if resolves_to_pref_set("$WINGMAN_STATE"):
    escape_cmd += ("\n(the same command is exported as $WINGMAN_STATE, which is "
                   "also accepted: $WINGMAN_STATE pref-set --run-id "
                   "\"$WINGMAN_RUN_ID\" --key <key> --value <value>)")

# The gate is satisfied through this tool, so it is always allowed.
if tool == "AskUserQuestion":
    allow()

# Has a real AskUserQuestion completed this session? (Marker written by
# hooks/pilot-preferences-ask-tracker.sh.) Required before pref-set is
# accepted, so a session cannot invent answers without ever asking.
asked = bool(sid) and os.path.exists(os.path.join(wm_home, "prefs-asked-%s" % sid))

# Reading the wake file stop-guard.sh points at is fleet supervision, not
# acting on a directive - allowed (that exact path only).
if tool == "Read":
    target = tool_input.get("file_path") or ""
    if target and os.path.abspath(target) == os.path.abspath(os.path.join(wm_home, "wake")):
        allow()

need_ask = False
if tool == "Bash":
    command = tool_input.get("command", "") or ""
    segments = command_segments(command)
    if segments is None:
        deny(PARSE_FAIL_REASON)
    if segments:
        all_allowed = True
        for seg in segments:
            b, argv = resolve_command(seg)
            sub = argv[1] if len(argv) > 1 else ""
            if b == "wm-state.py" and sub in ("prefs-list", "pref-get"):
                continue
            if b == "wm-state.py" and sub == "pref-set":
                if asked:
                    continue
                need_ask = True
                all_allowed = False
                continue
            if b in ("crew-list", "watch-fleet"):
                continue
            if b == "crew-ask" and sub == "await":
                continue
            all_allowed = False
        if all_allowed:
            allow()

if need_ask:
    deny(
        "Caching an onboarding-preference answer (pref-set) is only accepted "
        "after an AskUserQuestion call has completed this session - the answers "
        "must come from the pilot, never invented. Ask the still-missing "
        "questions below via AskUserQuestion first; this pref-set is then "
        "allowed:\n%s\n"
        "Then cache each answer with:\n  %s" % (missing, escape_cmd)
    )

deny(
    "Onboarding preferences are unanswered for this wingman run, and nothing "
    "else proceeds until they are (see CLAUDE.md, \"Confirm onboarding "
    "preferences\"). Say \"Before I start working, I need to ask you some "
    "preference questions:\" and ask ALL of the following in ONE batched "
    "AskUserQuestion call. Still missing:\n"
    "%s\n"
    "Then cache each answer with:\n  %s\n"
    "(While these are pending you may still run bin/crew-list, arm "
    "bin/watch-fleet or bin/crew-ask await as background watchers, read "
    "$WINGMAN_HOME/wake, and read the preference cache via prefs-list/"
    "pref-get.)" % (missing, escape_cmd)
)
' 2>/dev/null

exit 0
