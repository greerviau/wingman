#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""guard_dispatch: the single entry point every non-Claude guard transport
(codex-json, grok-json, opencode-plugin, pi-extension) invokes, replacing
"three subprocess hops per tool call, per dialect, times four dialects" with
one shared implementation (the orchestrator-guard-transports plan, §5.1).

All POLICY lives in hooks/lib/guard_policy.py - this module translates a
dialect's own payload shape into a guard_policy.GuardInput, runs whichever
guards were requested (in one fixed, canonical order - not the order they
were listed in --guards, so a caller can never influence priority by
reordering the flag), and translates the first denial (or none) into that
dialect's own deny/allow contract.

Usage:
    uv run --no-project --quiet guard_dispatch.py \\
        --dialect codex|grok|opencode|pi \\
        --guards direct-edit,watcher-kill,spawn-pause,merge,worker-spawn,foreground-watcher,foreground-poll-loop

Reads the dialect's own payload as JSON from stdin. Exits 0 on allow (silent
for codex/grok - "allow is silence" is their own documented contract; an
explicit `{"decision": "allow"}` on stdout for opencode/pi, whose JS shims
have no other way to distinguish "the dispatcher denied nothing" from "the
dispatcher never produced a verdict at all" - see guard_policy.py's own
design-principle discussion and §5.4.4/§5.4.5). Exits 2 on deny, printing the
dialect's own deny JSON to stdout - and, for codex and grok specifically,
ALSO to stderr (both channels; both are documented fail-open on hook
crash/timeout/malformed output, so belt-and-braces here costs nothing and
closes a real residual risk).

--emit-fixture <dialect> --case deny|allow prints ONE dialect-shaped synthetic
payload to stdout and exits 0 - the §5.4.0 self-test standard's own fixture
generator, so the fixture and this module's own parser can never drift apart
(both come from the same source). The DENY fixture is a bare arming
`bin/watch-fleet` Bash call (decided by the foreground-watcher guard, which
has no crew-id gating and both of whose branches converge on deny - see
guard_policy.py's own no-foreground-watcher-guard section and the plan's
§5.4.0 table for why this exact fixture, and not e.g. `gh pr merge`, is the
one that cannot pass vacuously in the orchestrator's own preflight scope).
The ALLOW fixture is a bare `ls` - passes every guard in the set.
"""
import argparse
import json
import os
import sys

from guard_policy import GuardDenied, GuardInput, _wm_effective_run_id, \
    evaluate_no_direct_edit_guard, \
    evaluate_no_foreground_poll_loop_guard, evaluate_no_foreground_watcher_guard, \
    evaluate_no_merge_guard, evaluate_no_watcher_kill_guard, evaluate_no_worker_spawn_guard, \
    evaluate_spawn_pause_guards

DIALECTS = ("codex", "grok", "opencode", "pi")

# The one fixed, canonical evaluation order every dialect's --guards list is
# filtered against - never the order the flag's own value happens to list
# them in, so a caller (or a future typo in a reconciler's own --guards
# string) can never change which guard gets first say over a command that
# more than one of them would otherwise deny.
_GUARD_ORDER = (
    "direct-edit", "watcher-kill", "spawn-pause", "merge", "worker-spawn",
    "foreground-watcher", "foreground-poll-loop",
)

# codex and grok both document Bash/apply_patch/Edit/Write as their own
# PreToolUse-matched tool names (plan §5.3) - apply_patch is codex's own
# file-edit tool, mapped to Edit exactly like Claude's own Edit; grok "the
# same map applied inside the dispatcher" per the same table.
_CODEX_GROK_TOOL_MAP = {
    "Bash": "Bash", "apply_patch": "Edit", "Edit": "Edit", "Write": "Write",
}
# opencode and pi both use lowercase built-in tool names (plan §5.3).
_LOWERCASE_TOOL_MAP = {
    "bash": "Bash", "edit": "Edit", "write": "Write", "read": "Read", "task": "Task",
}


def _project_dir():
    # $WINGMAN_PROJECT_DIR is what bin/wingman exports before exec (plan
    # §5.3) - preferred because cwd/workspaceRoot drift the moment a session
    # cd's, unlike Claude's own $CLAUDE_PROJECT_DIR, which every dialect
    # falls back to only when the wingman-specific one is absent (e.g. a
    # direct dispatcher invocation outside bin/wingman's own launch, such as
    # this module's own test suite).
    return os.environ.get("WINGMAN_PROJECT_DIR") or os.environ.get("CLAUDE_PROJECT_DIR") or ""


def _common_fields():
    return dict(
        crew_id=os.environ.get("WINGMAN_CREW_ID", ""),
        crew_type=os.environ.get("WINGMAN_CREW_TYPE", ""),
        project_dir=_project_dir(),
        home=os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman"),
    )


def _parse_codex(data):
    tool_input = data.get("tool_input") or {}
    tool_name = _CODEX_GROK_TOOL_MAP.get(data.get("tool_name") or "", data.get("tool_name") or "")
    return dict(
        tool_name=tool_name,
        command=tool_input.get("command", "") or "",
        file_path=tool_input.get("file_path") or tool_input.get("path") or "",
        notebook_path=tool_input.get("notebook_path", "") or "",
        cwd=data.get("cwd") or "",
        run_in_background=False,
    )


def _parse_grok(data):
    tool_input = data.get("toolInput") or {}
    tool_name = _CODEX_GROK_TOOL_MAP.get(data.get("toolName") or "", data.get("toolName") or "")
    return dict(
        tool_name=tool_name,
        command=tool_input.get("command", "") or "",
        file_path=tool_input.get("file_path") or tool_input.get("path") or "",
        notebook_path=tool_input.get("notebook_path", "") or "",
        cwd=data.get("cwd") or data.get("workspaceRoot") or "",
        run_in_background=False,
    )


def _parse_opencode(data):
    # The shape hooks/lib/agents/opencode/wingman-guard.js.tmpl's own
    # "tool.execute.before" handler composes before piping to this
    # dispatcher: {"tool": input.tool, "args": output.args, "cwd": directory}
    # - opencode's own `tool.execute.before(input, output)` signature (plan
    # §5.4.4), just serialised to stdin JSON instead of passed as two live
    # objects, since the dispatcher runs as a separate process.
    args = data.get("args") or {}
    tool_name = _LOWERCASE_TOOL_MAP.get(data.get("tool") or "", data.get("tool") or "")
    return dict(
        tool_name=tool_name,
        command=args.get("command", "") or "",
        file_path=args.get("filePath") or args.get("path") or "",
        notebook_path="",
        cwd=data.get("cwd") or "",
        run_in_background=False,
    )


def _parse_pi(data):
    # The shape bin/lib/agents/pi/wingman-guard-extension.js's own
    # "tool_call" handler composes before piping to this dispatcher:
    # {"toolName": event.toolName, "input": event.input, "cwd": process.cwd()}
    # - pi's own ToolCallEvent shape (plan §3.2/§5.4.5), serialised the same
    # way as opencode's above.
    tool_input = data.get("input") or {}
    tool_name = _LOWERCASE_TOOL_MAP.get(data.get("toolName") or "", data.get("toolName") or "")
    return dict(
        tool_name=tool_name,
        command=tool_input.get("command", "") or "",
        file_path=tool_input.get("filePath") or tool_input.get("path") or "",
        notebook_path="",
        cwd=data.get("cwd") or "",
        run_in_background=False,
    )


_PARSERS = {
    "codex": _parse_codex,
    "grok": _parse_grok,
    "opencode": _parse_opencode,
    "pi": _parse_pi,
}


def build_guard_input(dialect, data):
    fields = _PARSERS[dialect](data)
    run_in_background = fields.pop("run_in_background")
    common = _common_fields()
    gi = GuardInput(
        tool_name=fields["tool_name"],
        command=fields["command"],
        cwd=fields["cwd"] or common["project_dir"] or os.getcwd(),
        crew_id=common["crew_id"],
        crew_type=common["crew_type"],
        file_path=fields["file_path"],
        notebook_path=fields["notebook_path"],
        project_dir=common["project_dir"],
        home=common["home"],
    )
    return gi, run_in_background


# --- api-outage / usage-limit state, mirroring hooks/api-outage-spawn-
# guard.sh and hooks/usage-limit-spawn-guard.sh's own is_blocking/
# build_message closures exactly (byte-identical wording), so the aggregate
# "spawn-pause" guard tag denies with the identical text those two hooks
# already use for claude. -----------------------------------------------------

def _outage_is_blocking(state):
    return state.get("state") == "active"


def _outage_build_message(state, home):
    since = state.get("since") or "an unknown time"
    count = 0
    try:
        with open(os.path.join(home, "crew.json")) as fh:
            roster = json.load(fh)
        if isinstance(roster, list):
            count = sum(1 for r in roster
                        if r.get("status") in ("working", "blocked", "review", "stalled"))
    except (OSError, ValueError):
        pass
    return (
        "A fleet-wide Anthropic API outage has been detected (active since %s) "
        "- new spawns are paused while it is ongoing so this session "
        "does not add more load into a live burst (roughly %d crew member(s) "
        "currently live). Already-running crew are NOT affected by this pause - "
        "only new spawns are held. Wait: your own watcher already wakes on the "
        "outage-cleared fire, nothing needs to be polled. Or, if this particular "
        "spawn is genuinely needed regardless, override with "
        "--force-during-outage on this one spawn-crew call." % (since, count)
    )


def _usage_limit_is_blocking(state):
    return state.get("state") in ("approaching", "paused")


def _usage_limit_build_message(state, home):
    window = state.get("window") or "usage"
    window_label = {"five_hour": "5-hour", "seven_day": "7-day"}.get(window, window)
    pct = state.get("used_percentage")
    pct_text = ("%.0f%%" % pct) if isinstance(pct, (int, float)) else "an unknown amount"
    resets_at = state.get("resets_at")
    resets_text = str(resets_at) if resets_at is not None else "an unknown time"
    state_word = state.get("state")
    decision_note = (
        "The pilot has not yet decided whether to wait or continue anyway."
        if state_word == "approaching"
        else "The pilot chose to wait for the reset."
    )
    return (
        "The %s usage-limit window is approaching its cap - used "
        "%s, resets at epoch %s. New spawns are paused while this is "
        "unresolved so the fleet stops growing into a known, foreseeable "
        "wall. %s Already-running crew are NOT affected by this pause - only "
        "new spawns are held, and in-flight work can still hit the hard "
        "limit on its own (this design does not checkpoint or park "
        "in-flight crew). Wait: your own watcher already wakes on the "
        "usage-limit-reset fire the moment the window resets, nothing needs "
        "to be polled. Or, if this particular spawn is genuinely needed "
        "regardless, override with --force-during-usage-limit on this one "
        "spawn-crew call." % (window_label, pct_text, resets_text, decision_note)
    )


def _run_spawn_pause(gi):
    home = gi.home
    evaluate_spawn_pause_guards(
        gi, os.path.join(home, "api-outage-state.json"), _outage_is_blocking,
        "--force-during-outage", lambda s: _outage_build_message(s, home))
    evaluate_spawn_pause_guards(
        gi, os.path.join(home, "usage-limit-state.json"), _usage_limit_is_blocking,
        "--force-during-usage-limit", lambda s: _usage_limit_build_message(s, home))


def run_guards(dialect, guard_names, gi, run_in_background):
    """Runs every requested guard (filtered to _GUARD_ORDER's own canonical
    order) and returns the first GuardDenied reason, or None on allow."""
    requested = set(guard_names)
    for name in _GUARD_ORDER:
        if name not in requested:
            continue
        try:
            if name == "direct-edit":
                evaluate_no_direct_edit_guard(gi)
            elif name == "watcher-kill":
                evaluate_no_watcher_kill_guard(gi)
            elif name == "spawn-pause":
                _run_spawn_pause(gi)
            elif name == "merge":
                evaluate_no_merge_guard(gi)
            elif name == "worker-spawn":
                evaluate_no_worker_spawn_guard(gi)
            elif name == "foreground-watcher":
                evaluate_no_foreground_watcher_guard(gi, run_in_background=run_in_background, dialect=dialect)
            elif name == "foreground-poll-loop":
                evaluate_no_foreground_poll_loop_guard(gi, run_in_background=run_in_background, dialect=dialect)
        except GuardDenied as e:
            return str(e)
    return None


def emit_deny(dialect, reason):
    if dialect in ("codex", "grok"):
        payload = json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }) if dialect == "codex" else json.dumps({"decision": "deny", "reason": reason})
        print(payload)
        print(reason, file=sys.stderr)
    else:  # opencode, pi - consumed by the JS shim, stdout only
        print(json.dumps({"decision": "deny", "reason": reason}))
    sys.exit(2)


def emit_allow(dialect):
    if dialect in ("opencode", "pi"):
        # An explicit verdict, not silence: the JS shims have no other way
        # to distinguish "the dispatcher ran and found nothing to deny" from
        # "the dispatcher never produced a verdict at all" (a crash, a
        # timeout) - see guard_policy.py's design-principle discussion and
        # §5.4.4/§5.4.5's fail-closed shim body, which blocks unless this
        # exact shape comes back.
        print(json.dumps({"decision": "allow"}))
    # codex/grok: allow is silence, their own documented contract.
    sys.exit(0)


# --- §5.4.0 fixture generation: the deny/allow synthetic payloads, one per
# dialect, built from THIS module's own parsers so the fixture and the
# parser can never drift apart. ------------------------------------------

def _fixture_payload(dialect, case):
    command = "bin/watch-fleet" if case == "deny" else "ls"
    if dialect == "codex":
        return {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": os.getcwd()}
    if dialect == "grok":
        return {"toolName": "Bash", "toolInput": {"command": command}, "cwd": os.getcwd()}
    if dialect == "opencode":
        return {"tool": "bash", "args": {"command": command}, "cwd": os.getcwd()}
    if dialect == "pi":
        return {"toolName": "bash", "input": {"command": command}, "cwd": os.getcwd()}
    raise ValueError("unknown dialect %r" % dialect)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dialect", choices=DIALECTS, default=None)
    ap.add_argument("--guards", default="", help="comma-separated guard names")
    ap.add_argument("--emit-fixture", choices=DIALECTS, default=None,
                     help="print a synthetic payload for the given dialect and exit")
    ap.add_argument("--case", choices=("deny", "allow"), default=None,
                     help="with --emit-fixture: which fixture case to print")
    args = ap.parse_args()

    if args.emit_fixture:
        if not args.case:
            print("error: --emit-fixture requires --case deny|allow", file=sys.stderr)
            sys.exit(2)
        print(json.dumps(_fixture_payload(args.emit_fixture, args.case)))
        sys.exit(0)

    if not args.dialect:
        print("error: --dialect is required (unless --emit-fixture is given)", file=sys.stderr)
        sys.exit(2)

    guard_names = [g.strip() for g in args.guards.split(",") if g.strip()]
    unknown = sorted(set(guard_names) - set(_GUARD_ORDER))
    if unknown:
        print("error: unknown guard(s): %s" % ", ".join(unknown), file=sys.stderr)
        sys.exit(2)

    # Resolve WM_EFFECTIVE_RUN_ID once, here, at this process's own natural
    # depth from the harness (review round 2) - only when foreground-watcher
    # is actually requested, the one guard that needs it (the standdown-
    # marker check). Without this, guard_policy._wm_effective_run_id()'s own
    # fallback would shell out from wherever evaluate_no_foreground_watcher_
    # guard happens to be called, which is this exact same process anyway
    # for guard_dispatch.py - but resolving and CACHING it into os.environ
    # here (even when empty) means a second call within the same process
    # never re-walks. hooks/no-foreground-watcher-guard.sh (claude's own
    # entry point) does the identical thing in bash, from ITS OWN process,
    # for the same reason - see that file's comment for why claude
    # specifically needed this (guard_policy.py's own shell-out, called from
    # deep inside its nested python/uv chain, measured 6 hops from the
    # harness there).
    if "foreground-watcher" in guard_names:
        os.environ["WM_EFFECTIVE_RUN_ID"] = _wm_effective_run_id()

    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}

    try:
        gi, run_in_background = build_guard_input(args.dialect, data)
        reason = run_guards(args.dialect, guard_names, gi, run_in_background)
    except Exception as e:
        # A payload shape none of the parsers above expects (e.g. tool_input
        # is a string, not an object) must never reach an UNCAUGHT exception
        # - that would decide each dialect's fail direction as an accident
        # of how codex/grok/opencode/pi each happen to treat a crashed
        # subprocess, rather than the deliberate per-guard fail direction
        # this module's own design otherwise holds to throughout. codex and
        # grok are both documented fail-open on a crashed/malformed hook (so
        # allowing here matches their own posture, and matches claude's own
        # equivalent .sh hooks: a GuardInput construction failure there is
        # ALSO never caught, and their own bash wrapper's stdout-empty/exit-0
        # shape is exactly an allow - this is not a policy change, only
        # making the same outcome an explicit branch instead of an accident);
        # opencode and pi's own shims fail closed on ANY dispatcher failure,
        # so denying here matches what they would already do if this
        # exception's rc/empty-stdout reached them unhandled.
        if args.dialect in ("codex", "grok"):
            emit_allow(args.dialect)
        else:
            emit_deny(args.dialect, "wingman guard could not parse this payload, so this call is denied: %s" % e)

    if reason is not None:
        emit_deny(args.dialect, reason)
    else:
        emit_allow(args.dialect)


if __name__ == "__main__":
    main()
