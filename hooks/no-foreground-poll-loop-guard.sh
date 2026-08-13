#!/usr/bin/env bash
# no-foreground-poll-loop-guard.sh - a Claude Code PreToolUse hook (matcher
# "Bash"). Prevents the deadlock issue #268 reports: a hand-rolled shell
# `while`/`until` loop with a `sleep` in its body, run in the FOREGROUND of a
# Bash tool call to wait on some other condition, instead of a harness-
# tracked background task. Two crew sessions in the same effort did exactly
# this and cost roughly four hours combined:
#   - One ran `until ! pgrep -f "tests/run.sh" ...; do sleep 5; done` to wait
#     for a test suite to finish. `pgrep -f` matches the FULL command line of
#     every process on the machine, including the waiting shell's own - whose
#     `-c` payload contains the literal string "tests/run.sh" because that
#     string is `pgrep`'s own argument. The loop's exit condition could
#     therefore never become true: it was finding itself. The suite had
#     finished 45 minutes before the wedge was discovered; the session sat
#     blocked for over an hour, unable to read incoming messages or self-
#     diagnose, because it was blocked inside a foreground tool call.
#   - The other ran `until [ -f .wf_done ]; do sleep 5; done`, waiting on a
#     sentinel file a different process never wrote (it exited before
#     reaching that write). Same structural defect: no independent timeout.
#
# This is layer A (prevention) of the plan's two-layer design; layer B
# (detection - wm-state loop-wedge-check, called from bin/watch-fleet's own
# pane loop, mirroring wedge-check's issue #202 precedent) is the
# independent backstop for a wedge that starts some other way (this hook not
# yet registered, or a shape it cannot parse). Detection alone cannot work
# here: a hand-rolled polling loop is not idle - it spins every `sleep N`
# seconds, forking short-lived children the whole time it is wedged, which
# is exactly what the existing generic stall/liveness probe treats as
# positive evidence of life. Layer A closes the class at the tool-call
# boundary, before the loop is ever created.
#
# What is denied, from EVERY session (no WINGMAN_CREW_ID gating - see
# "Gating" below): a Bash command containing an unbounded `while`/`until`
# loop with a `sleep` invocation somewhere in the same command, unless
# `run_in_background: true`. Detecting the SHAPE (loop keyword + sleep
# invocation), rather than special-casing either incident's own guard
# condition, is both simpler and strictly broader - it also catches a
# self-matching `grep`/`ls`/`test`, a misspelled sentinel, a condition
# referencing a variable that is never set, or any other way a hand-rolled
# wait can go wrong.
#
# What is explicitly NOT denied:
#   - A `for` loop over a fixed, enumerable list (`for i in 1 2 3; do ...;
#     done`) - naturally self-bounding, cannot deadlock. Flagging every
#     `for`+`sleep` combination would create everyday false-positive
#     friction (a common, legitimate short-retry idiom) for a case that
#     is not the actual defect this hook exists to close.
#   - A bounded `while`/`until` loop with no `sleep` invocation anywhere in
#     the command at all (e.g. `while [ $i -lt 5 ]; do i=$((i+1)); done`).
#   - The command is denied with `run_in_background: true` set - reissuing
#     the identical command that way is always the fix, never a different
#     command.
#
# Deliberately NOT required: that the matched `sleep` sits inside the
# matched loop's own `do ... done` block (which would need real nested-
# keyword bracket matching, since `while`/`until`/`for`/`case` all open
# their own `done`/`esac` terminator). A command that happens to contain a
# `while`/`until` keyword AND a `sleep` invocation elsewhere in the same
# Bash call, with neither actually forming a polling wait, is a plausible
# but rare false positive. Per this hook family's established posture (see
# hooks/no-foreground-watcher-guard.sh's own header: "A false deny here
# costs nothing; a miss reintroduces the exact class this hook exists to
# close"), and because the fix is always available and trivial (reissue the
# identical command with run_in_background: true), this is an accepted
# trade-off, not a defect to engineer around. The same reasoning covers a
# hand-maintained-counter-bounded while/until loop (`n=0; while [ $n -lt 5
# ]; ...`): whether such a loop is actually bounded depends on tracing that
# the counter is correctly initialized, incremented, and compared - exactly
# the kind of subtle-to-get-wrong logic the pgrep -f self-match already
# demonstrates a hand-rolled loop can fail at silently, so it is not
# exempted either.
#
# Failure posture, structural model, and the shell-wrapper/python-subprocess
# split below all follow hooks/no-foreground-watcher-guard.sh verbatim - see
# that hook's own header comment for the fully-worked-out rationale. In
# short: the shell wrapper's own cheap textual pre-gate is ALSO the signal
# its failure-posture check keys its wrapper-level deny on (an uncaught
# python exception or a dead interpreter denies, rather than silently
# falling through to an allow); the python decision body denies on any
# unparseable or unverifiable shape; and silence (no stdout, exit 0) is this
# hook family's own allow signal.
#
# Gating: none. Active for every session, crew and top-level alike - this
# hook only ever fires on an actual while/until+sleep shape, which no
# legitimate use case needs to run in the foreground.
#
# No override flag. There is no legitimate foreground use of this shape:
# `run_in_background: true` on the exact same command is always available
# and always removes the deadlock risk - the harness tracks the backgrounded
# task and notifies the session on completion, so no polling loop needs to
# run in the foreground at all. To stream output from an already-
# backgrounded process instead of polling it, use the Monitor tool.
#
# Residual gaps, deliberately out of scope:
#   - A loop hidden inside a script FILE (`bash some-script.sh`, where the
#     loop lives inside the script, not in this Bash tool call's own
#     `command` text) is invisible here - this hook is text-only on the
#     literal tool-call command. Neither reported incident was this shape;
#     both were typed directly into a Bash tool call.
#   - A loop written as a `case` statement's branch action (e.g. `case $x
#     in y) while true; do sleep 5; done ;; esac`) is also invisible:
#     command_segments() only splits on `;`/`&&`/`||`/pipe, so a command
#     immediately after a case pattern's `)` lands mid-segment rather than
#     at a segment's own first token, and this hook's loop-opener check
#     never sees it (issue #268 PR #271 review round 2). Layer B's
#     detection backstop (`loop-wedge-check`), which matches a plain regex
#     against a descendant's own `ps` text rather than depending on segment
#     structure, still catches a real wedge of this shape - just later,
#     not at the tool-call boundary.
#
# Registered user-level by bin/doctor (crew sessions have their project root
# in other repos, where this repo's project settings never load) - same
# reasoning as every other crew-facing hook. bash-3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Cheap, textual pre-gate: every shape this hook cares about mentions both
# "sleep" and a loop keyword ("while"/"until") somewhere in the raw payload
# text. This is ALSO the signal the failure-posture rule below keys its
# wrapper-level deny on - see the header comment.
case "$INPUT" in
  *sleep*) ;;
  *) exit 0 ;;
esac
case "$INPUT" in
  *while*|*until*) ;;
  *) exit 0 ;;
esac

OUT="$(printf '%s' "$INPUT" | \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, sys

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
    return "sleep" in text and ("while" in text or "until" in text)


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
    "This command mentions a while/until loop and sleep but could not be "
    "verified safe - an unexpected tool_input shape, or an internal error "
    "while checking it - so it is denied rather than partially checked"
    ", since silence is this hook family'"'"'s own allow signal "
    "and a failure is not silence. If this is a legitimate polling wait, "
    "reissue the identical command with run_in_background: true."
)

# A coerced-relevant-but-non-string `command` (e.g. a list whose str() text
# happens to mention a while/until+sleep shape) is exactly the "shape this
# hook cannot parse" case - denied here, before the try/except below, rather
# than waved through.
if not isinstance(raw_command, str):
    deny(VERIFY_FAIL_REASON)

try:
    command = raw_command

    PARSE_FAIL_REASON = (
        "This command could not be fully parsed - an unterminated quote, an "
        "unbalanced $(...)/`...`/<(...)/>(...) span, or a heredoc whose "
        "terminator line was never found, including inside a `bash -c`/`eval` "
        "payload - so it is denied rather than partially checked, "
        "since this command mentions a while/until loop and sleep and could "
        "not be verified safe. Reformat it into well-formed shell syntax and "
        "retry."
    )

    DENIAL_REASON_TEMPLATE = (
        "This command runs an unbounded %s loop with a sleep in its body in "
        "the FOREGROUND of a Bash tool call - a hand-rolled polling wait with "
        "no independent timeout. Two crew sessions hard-"
        "deadlocked exactly this way and cost roughly four hours combined: "
        "one ran `until ! pgrep -f \"tests/run.sh\" ...; do sleep 5; done` "
        "and never noticed that `pgrep -f` matches its OWN command line (a "
        "permanent self-match, since the pattern text is also part of the "
        "waiting shell'"'"'s own -c payload); the other waited on a sentinel "
        "file a different process never wrote. Neither loop'"'"'s exit "
        "condition could ever become true, and neither session could read "
        "incoming messages, self-diagnose, or be woken by anything except an "
        "external kill, while blocked inside the foreground tool call. "
        "Reissue the IDENTICAL command with run_in_background: true - the "
        "harness tracks it and notifies this session on completion, so no "
        "polling loop is needed at all. To stream output from an already-"
        "backgrounded process instead of polling it, use the Monitor tool. "
        "Matched loop: `%s`; matched sleep: `%s`."
    )

    segments = command_segments(command)
    if segments is None:
        deny(PARSE_FAIL_REASON)

    LOOP_KEYWORDS = ("while", "until")
    LEADING_KEYWORDS = ("do", "then", "else", "elif")

    loop_opener = None       # (keyword, raw segment text) of the first match
    sleep_invocation = None  # raw segment text of the first match

    for seg in segments:
        if not seg:
            continue

        # Step 3: strip AT MOST ONE leading shell keyword before checking
        # whether this segment invokes `sleep` - a segment immediately
        # following a loop'"'"'s own `;` starts with `do` (or `then`/`else`/
        # `elif`), not the command actually being run.
        body = seg[1:] if seg[0] in LEADING_KEYWORDS else seg

        # Step 4: loop-opener check runs on the segment'"'"'s own first token
        # AS LEXED, and ALSO on the stripped `body`'"'"'s own first token: a
        # nested while/until loop'"'"'s opener can appear immediately after a
        # `do`/`then`/`else`/`elif` belonging to an ENCLOSING block that is
        # not itself a while/until - a `for` or an `if`, neither of which
        # sets loop_opener on its own. `for item in a b c; do until grep -q
        # done x; do sleep 5; done; done` produces the segment [\'"'"'do\'"'"',
        # \'"'"'until\'"'"', \'"'"'!\'"'"', \'"'"'grep\'"'"', ...] - checking only the raw
        # \'"'"'do\'"'"' misses the nested until entirely, since no other segment in
        # that command carries a while/until keyword at all. Checking
        # body[0] in addition to seg[0] catches this with no new false
        # positive: basename() is an exact-token match, and a segment whose
        # stripped body genuinely starts with while/until is opening a loop
        # by shell grammar however it got there.
        body_head = basename(body[0]) if body else ""
        opener_tok = body_head if body_head in LOOP_KEYWORDS else basename(seg[0])
        if loop_opener is None and opener_tok in LOOP_KEYWORDS:
            loop_opener = (opener_tok, " ".join(seg))

        if not body:
            continue
        resolved_b, _resolved_argv = resolve_command(body)
        if sleep_invocation is None and resolved_b == "sleep":
            sleep_invocation = " ".join(seg)

    # Deny iff a loop-opener AND a sleep-invocation both appear SOMEWHERE in
    # the command - not required to be textually paired with each other
    # (see the header comment'"'"'s false-positive discussion) - and
    # run_in_background is not true.
    if loop_opener is not None and sleep_invocation is not None:
        # Fail CLOSED: absent, false, or any unexpected shape denies. There
        # is deliberately no "cannot verify -> allow" branch here, and no
        # override flag (see the header comment).
        if not tool_input.get("run_in_background"):
            deny(DENIAL_REASON_TEMPLATE % (loop_opener[0], loop_opener[1], sleep_invocation))
except Exception:
    deny(VERIFY_FAIL_REASON)

sys.exit(0)
' 2>/dev/null)"
PY_RC=$?

if [ "$PY_RC" -ne 0 ]; then
  # The relevance pre-gate above already established this command mentions
  # a while/until loop and sleep; the python decision body raised or the
  # interpreter died, so - per the failure posture in the header comment -
  # this wrapper denies itself rather than let a discarded stderr and an
  # `exit 0` fall through to a silent allow.
  cat <<'JSON'
{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "This command mentions a while/until loop and sleep but the check for it failed to run (a dead interpreter, or an internal error) - denied rather than partially checked, since silence is this hook family's own allow signal and a failure is not silence. If this is a legitimate polling wait, reissue the identical command with run_in_background: true."}}
JSON
  exit 0
fi

if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT"
fi

exit 0
