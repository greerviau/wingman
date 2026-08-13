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
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Cheap, textual pre-gate: every shape this hook cares about mentions
# "watch-fleet" or "pr-watch" somewhere in the raw payload text. This is
# ALSO the signal the failure-posture rule below keys its wrapper-level deny
# on - see the header comment.
case "$INPUT" in
  *watch-fleet*|*pr-watch*) ;;
  *) exit 0 ;;
esac

OUT="$(printf '%s' "$INPUT" | \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, re, sys

from cmd_match import basename, command_segments, resolve_command

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
    command = raw_command

    PARSE_FAIL_REASON = (
        "This command could not be fully parsed - an unterminated quote, an "
        "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
        "terminator line was never found, including inside a `bash -c`/`eval` "
        "payload - so it is denied rather than partially checked, "
        "since this command mentions watch-fleet/pr-watch and could not be "
        "verified safe. Reformat it into well-formed shell syntax and retry."
    )

    DENIAL_REASON = (
        "bin/watch-fleet blocks until an event fires - that is the entire "
        "wake mechanism - so running it any way other than as a "
        "harness-tracked background task wedges this session indefinitely "
        "- a session that does this sits wedged indefinitely, invisible to "
        "the stall detector. Re-issue this as a Bash call with "
        "run_in_background: true, on its own, not bundled onto another "
        "command. Never foreground, and never detached (nohup, setsid, a "
        "trailing &) - a detached watcher'"'"'s exit cannot wake anyone, so "
        "it is not a watcher. If you cannot arm it as a background task, arm "
        "nothing: no watcher at all is strictly better than a foreground "
        "one, because a missing watcher is recoverable and a wedged session "
        "is not. Read-only forms (--status, --stop, --classify, and pr-watch "
        "--once) are unaffected, including under a timeout/nice wrapper. To "
        "watch a cycle'"'"'s behaviour interactively, run it from your own "
        "terminal, not through a tool call."
    )

    segments = command_segments(command)
    if segments is None:
        deny(PARSE_FAIL_REASON)

    # An arming invocation is anything OTHER than the read-only/one-shot
    # forms - so a bare invocation, `arm`, and the deprecated `--start` alias
    # (which warns and then blocks exactly like a bare call) are all arming
    # by construction, with nothing to enumerate for them specifically.
    ARM_DENY_FLAGS = {
        "watch-fleet": ("--status", "--stop", "--classify", "--clear-standdown", "-h", "--help"),
        "pr-watch": ("--once", "-h", "--help"),
    }
    LAUNCHER_WRAPPERS = ("nohup", "setsid", "timeout", "nice", "ionice", "stdbuf")
    DETACHED_LAUNCHERS = ("nohup", "setsid")

    def is_arming(target, target_argv):
        deny_flags = ARM_DENY_FLAGS.get(target)
        if deny_flags is None:
            return False
        return not any(f in target_argv for f in deny_flags)

    def find_watcher_invocation(b, argv):
        """(launcher, idx): idx is argv'"'"'s index of the watch-fleet/pr-watch
        token; launcher is the wrapper'"'"'s own resolved basename if reached
        through one of LAUNCHER_WRAPPERS, else None for a direct invocation.
        (None, None) if this segment does not invoke watch-fleet/pr-watch at
        all, directly or through a recognized launcher wrapper."""
        if b in ("watch-fleet", "pr-watch"):
            return None, 0
        if b in LAUNCHER_WRAPPERS:
            for i, tok in enumerate(argv):
                if basename(tok) in ("watch-fleet", "pr-watch"):
                    return b, i
        return None, None

    def extract_owner_flag(target_argv):
        """The command'"'"'s own --owner value, or None if not passed at all -
        matching bin/watch-fleet'"'"'s own arg loop (`--owner) OWNER="${2:-}";
        shift 2`), which takes the very next token unconditionally, including
        an empty string. None (not passed) is distinct from "" (passed
        empty) - only None falls back to $WINGMAN_CREW_ID below."""
        for i, tok in enumerate(target_argv):
            if tok == "--owner":
                return target_argv[i + 1] if i + 1 < len(target_argv) else ""
        return None

    arming_found = False
    watch_fleet_arming = False
    watch_fleet_owner_argv = None
    for seg in segments:
        b, argv = resolve_command(seg)
        if not argv:
            continue
        launcher, idx = find_watcher_invocation(b, argv)
        if idx is None:
            continue
        # Re-apply the flag allowlist to the argv AFTER the located token -
        # never to the launcher'"'"'s own argv - so `timeout 5 bin/watch-fleet
        # --status` reads its `--status` correctly instead of never seeing it.
        target_argv = argv[idx:]
        target = basename(target_argv[0])
        if not is_arming(target, target_argv):
            continue
        if launcher in DETACHED_LAUNCHERS:
            deny(DENIAL_REASON)
        arming_found = True
        if target == "watch-fleet":
            watch_fleet_arming = True
            watch_fleet_owner_argv = target_argv

    if arming_found:
        # issue #198: an arming watch-fleet call (never pr-watch, which has
        # no standdown concept) is denied outright while a run-scoped
        # spurious-repeated standdown holds for this session'"'"'s owner -
        # checked ahead of the &/run_in_background checks below, since
        # neither of those makes an arm under a standdown legitimate.
        # Fixing the standdown'"'"'s own composed text (see bin/watch-fleet'"'"'s
        # spurious_repeated_reason) removes the COMPETING instruction that
        # told a model to arm; it does not make the refusal enforceable on
        # its own - #198'"'"'s own incident was a model reading a correctly-
        # identified deliberate refusal and overriding it anyway. This is
        # what makes it structural instead.
        if watch_fleet_arming:
            _owner_flag = extract_owner_flag(watch_fleet_owner_argv or [])
            def read_standdown_marker(path):
                # None means "genuinely absent" (the overwhelmingly common
                # case - no standdown in force) and must allow. Anything
                # else this raises (e.g. PermissionError from an
                # unreadable $WINGMAN_HOME) propagates to the outer
                # except below, which fails CLOSED via VERIFY_FAIL_REASON -
                # "could not verify" is not the same answer as "not there".
                try:
                    with open(path) as f:
                        return f.read()
                except FileNotFoundError:
                    return None

            # bin/watch-fleet'"'"'s own precedence (`:176-180`): --owner, when the
            # command carries it, wins outright - only its ABSENCE falls back
            # to $WINGMAN_CREW_ID. Checking the marker under $WINGMAN_CREW_ID
            # alone would let `bin/watch-fleet --owner ""` bypass a standing
            # standdown by targeting a different (or unscoped) owner than the
            # one the guard checked (issue #198 plan review, MUST-FIX 3).
            _owner = _owner_flag if _owner_flag is not None else (os.environ.get("WINGMAN_CREW_ID") or "")
            _okey = re.sub(r"[^A-Za-z0-9._-]", "_", _owner) if _owner else ""
            _wm_home = os.environ.get("WINGMAN_HOME") or os.path.join(os.path.expanduser("~"), ".wingman")
            _marker_name = "watch-%s.suppressed" % _okey if _okey else "watch.suppressed"
            _marker_path = os.path.join(_wm_home, _marker_name)
            _marker_content = read_standdown_marker(_marker_path)
            if _marker_content is not None:
                _marker_lines = _marker_content.split("\n", 1)
                _stamp = _marker_lines[0] if _marker_lines else ""
                _body = _marker_lines[1] if len(_marker_lines) > 1 else ""
                _run_id = os.environ.get("WINGMAN_RUN_ID") or ""
                # wm_run_scoped_marker_active'"'"'s own rule (hooks/lib/
                # watcher-liveness.sh): honored if the stamp matches this
                # run, is empty, or this session has no run id to check
                # against - false only for a DIFFERENT, presumably-ended
                # run'"'"'s stamp.
                if not _run_id or not _stamp or _stamp == _run_id:
                    _count_match = re.search(r"died (\d+) times", _body)
                    _count_clause = " (%s deaths in a row)" % _count_match.group(1) if _count_match else ""
                    STANDDOWN_DENIAL_REASON = (
                        "A spurious-repeated failure-budget standdown is in force "
                        "for this session" + _count_clause + ": the "
                        "watcher has died repeatedly with no successful cycle in "
                        "between, and the failure budget is deliberately refusing "
                        "further arms until a human intervenes. Arming now would "
                        "clear the standdown, which is exactly the re-arm churn "
                        "the budget exists to prevent. Lifting the standdown is "
                        "up to the pilot, not a tool call: once the cause is "
                        "understood, run bin/watch-fleet --clear-standdown, then "
                        "fleet continuity re-arms automatically on the next Stop "
                        "event."
                    )
                    deny(STANDDOWN_DENIAL_REASON)
        # command_segments() discards a bare `&` the same way it discards
        # `;` (it is punctuation to the segment splitter, not part of any
        # token), so a trailing background operator is invisible to the
        # segment/argv analysis above and must be caught with a conservative
        # textual scan over the raw command string instead: strip every
        # SAFE `&` shape (&&, a fd-duplication redirect like 2>&1/&>2, &>,
        # <&) and deny if a bare & remains. A false deny here costs nothing;
        # a miss reintroduces the exact class this hook exists to close.
        _safe_amp_re = re.compile(r"&&|[0-9]*>&[0-9]*|&>|<&")
        if "&" in _safe_amp_re.sub("", command_text):
            deny(DENIAL_REASON)
        # Fail CLOSED: absent, false, or any unexpected shape denies. There
        # is deliberately no "cannot verify -> allow" branch here.
        if not tool_input.get("run_in_background"):
            deny(DENIAL_REASON)
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
