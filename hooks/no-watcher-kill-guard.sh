#!/usr/bin/env bash
# no-watcher-kill-guard.sh - a Claude Code PreToolUse hook (matcher "Bash").
# Mechanically enforces the rule CLAUDE.md's "The wake loop" already states in
# prose ("Never kill a watch-fleet process for any reason during normal
# operation"): a live bin/watch-fleet cycle's liveness is the only channel
# that lets a wake reach an idle orchestrator (wingman's own top-level
# session, or a lead watching its own crew), so nothing should ever kill it.
# Issue #12 first documented a session misreading the pid printed in an
# "already armed" report as an instruction to stop it; that fix only reworded
# the report and added the prose rule. Issue #64 reports the same failure
# shape recurring, so this hook adds the same PreToolUse-deny layer already
# used for issue #46's merge restriction and the onboarding-preferences gate,
# rather than relying on prose alone.
#
# SCOPE (stated explicitly, not left to be discovered as a gap): this is
# best-effort defense-in-depth against REALISTIC, ACCIDENTAL self-kills - the
# failure shape issue #64 actually reports - not an airtight sandbox. It
# reliably recognizes kill/pkill/tmux kill-window/kill-session however they
# are ordinarily spelled (including tmux subcommand abbreviations, leading
# global flags, and a target built via command substitution or a shell
# variable). It does NOT recognize a determined attempt reached through an
# unrecognized command WRAPPER - `xargs kill`, `timeout N kill`, `nice kill`,
# `bash -c 'kill $PID'`, and similar launcher/supervision shapes bypass this
# hook's dispatch entirely, since static command matching has no finite
# grammar to anchor on the way tmux's own subcommand set does. Closing that
# class completely means protecting the watcher at the PROCESS level
# (auto-respawn on death, regardless of cause) - tracked separately as issue
# #107, which this hook complements rather than duplicates.
#
# What is denied, from EVERY session (no WINGMAN_CREW_ID/WINGMAN_CREW_TYPE
# gating at all - killing the watcher is never legitimate from any session,
# not the human's own top-level session, not a lead, not any other crew
# member):
#   - `kill`/`pkill <target>` whose target resolves to a pid that is
#     CURRENTLY a live watch-fleet cycle.
#   - `tmux kill-window`/`tmux kill-session` whose target's pane pid (or one
#     of its process-tree descendants) is currently a live watch-fleet cycle
#     - the shape that kills a session's OWN window/session, taking out a
#     background-armed watcher along with it.
#
# "Currently a live watch-fleet cycle" reuses bin/watch-fleet's own
# owner_lock_alive() identity check exactly (issue #237, part 2): the
# $PIDFILE.owner lock directory's stamped pid answers `kill -0` AND its
# stamped process start time matches the pid's CURRENT start time - never a
# bare pid-alive check, which a pid reused across a host reboot would
# otherwise satisfy. On top of that, protection also requires the same
# beacon-freshness-within-hard-grace term cycle_healthy() adds (issue #237
# round-2 MF-A): a cycle whose beacon has gone stale for WM_WATCH_HARD_GRACE
# (default 300s) is wedged, and bin/watch-fleet's own singleton guard is
# legitimately trying to reap it via a supervised SIGTERM/SIGKILL takeover at
# that point. This hook cannot actually deadlock against that takeover - a
# PreToolUse Bash guard only ever inspects a SESSION's own tool-call command
# string, never a plain in-process `kill` a script issues on its own, so
# bin/watch-fleet's internal takeover kill was never subject to this hook in
# the first place. The real reason to mirror the hard-grace term here is the
# manual kill backstop this whole guard exists to preserve (issue #64): once
# a holder is stale enough that bin/watch-fleet's own logic no longer treats
# it as the protected owner, a human/session killing it manually is the same
# recovery this file's own singleton guard is already entitled to perform -
# staying out of sync here would leave a genuinely wedged watcher unkillable
# by hand for no remaining reason. The set of protected pids is recomputed
# fresh on every hook invocation from
# $WM_HOME/watch*.pid.owner (the owner-keyed naming bin/watch-fleet uses for
# a lead's own cycle) - never cached - so it can never disagree with what
# bin/watch-fleet's own arm logic would currently classify as live/healthy.
#
# `kill -0` (the null-signal liveness probe owner_lock_alive() itself uses,
# plus bin/crew-ask and hooks/stop-guard.sh) is ALWAYS allowed, regardless of
# target: the null signal is detected from the parsed signal spec, before any
# target is even compared against the protected set, so this falls out of the
# kill(1) grammar naturally rather than needing a bolted-on special case.
# `bin/watch-fleet --stop` (the one sanctioned manual-stop path) is naturally
# unaffected too - it never appears as a kill/pkill/tmux-kill-* command at the
# Bash-tool-call level, only as a script invocation this hook does not match.
#
# Two deliberately conservative tradeoffs (false-deny-only, never a missed
# deny):
#   - pkill: the pattern is tested against BOTH a protected pid's `comm` and
#     its full `args` (one `ps -p <pid> -o comm=,args=` call), regardless of
#     whether -f was given. Real pkill's -f-gated comm-vs-args semantics
#     differ subtly between BSD and GNU; replicating them exactly risks a
#     missed deny, which is the one outcome this hook must never produce. A
#     pattern that fails to compile as a regex is treated as a match (fail
#     closed on the specific pid it's checked against), not silently skipped.
#   - tmux kill-window/kill-session: the target's pane pid(s) are resolved via
#     `tmux list-panes` scoped to what the command would actually destroy -
#     every pane in the whole session for kill-session (`-s`), every pane in
#     the window for kill-window (a split window has more than one pane) -
#     never a single pane pid, since `-t` omitted defaults to the CURRENT
#     session/window as a whole, not the one pane the command was typed
#     into. The subcommand may be preceded by any number of tmux's own
#     global options (-L/-S/-f/-c/-T/-D/...); rather than enumerating that
#     flag grammar (which drifts out of sync with tmux's own - a real gap
#     found across two review rounds), detection scans for the subcommand
#     TOKEN itself and skips every token before it as noise, regardless of
#     how many flags that represents or which tmux version defines them. The
#     subcommand token itself is resolved against the CONNECTED tmux
#     binary's own `tmux list-commands` output (never a hardcoded literal
#     set), replicating tmux's real exact-match-then-unambiguous-prefix
#     grammar - so an abbreviation tmux itself would accept (`kill-win`,
#     `kill-ses`, a third review round's finding) is recognized exactly like
#     the full name or the `killw` alias, without needing to enumerate every
#     spelling tmux allows. The WHOLE process tree rooted at every resolved
#     pane pid is then walked with one
#     `ps -ax -o pid=,ppid=` scan (the same approach bin/lib/wm-state.py's
#     _ps_tree() uses for stall detection, reimplemented here as a small
#     self-contained walk rather than a cross-module import, matching this
#     file's siblings). Any protected pid anywhere in that tree denies -
#     conflating "this pid is merely a descendant of the target" with "this
#     pid IS the target" is deliberately conservative.
#   - kill/pkill targets, pkill patterns, and tmux -t values that are not
#     statically-resolvable literals (built via command substitution -
#     $(...)/`...`/<(...)/>(...) - or an unexpanded $VAR/${VAR} shell
#     variable) are DENIED, not silently treated as "does not match," while
#     any watch-fleet cycle is currently live (round-4 review finding: `kill
#     $(cat watch.pid)`, `X=<pid>; kill $X`, and `pkill -f "$(echo
#     watch-fleet)"` all resolved, at this hook's text layer, to inert
#     placeholder/variable text that matched nothing, so the real pid was
#     never compared against the protected set at all - the same missed-deny
#     shape as the tmux subcommand-abbreviation bypass, just reached through
#     an argument's VALUE instead of a subcommand's NAME). This hook cannot
#     evaluate what a substitution or variable actually resolves to without
#     running untrusted shell content, which is not something a PreToolUse
#     hook should ever do merely to decide whether to allow a command - so
#     "cannot prove this ISN'T the watcher" is treated the same as "IS the
#     watcher." A `$` can never appear in a real pid or tmux target, so its
#     presence anywhere in the token (not just as the whole token) is the
#     dynamic signal; see the DYNAMIC_TARGET_REASON comment in the python
#     block below for the one accepted false-positive this admits.
#
# cmd_match.py's command_segments()/resolve_command() are used exactly as the
# other guards use them, including its fail-CLOSED contract on an unlexable
# command (issue #56): unlike no-merge-guard.sh (which only fails closed for
# a crew session), this hook has no session scope to narrow to, so an
# unparsable command that reached this hook's cheap pre-gate is ALWAYS
# denied, from any session.
#
# Registered user-level by bin/doctor (must also fire for a lead or crew
# member whose project root is some other repo entirely, exactly like the
# delegation guard and the merge-authorization pair) - never added to this
# repo's checked-in .claude/settings.json, which would double-register it for
# wingman's own top-level session. bash-3.2-safe.
#
# issue #25 stage 3 / the orchestrator-guard-transports plan: the decision
# logic below is now ALSO implemented, canonically, as
# guard_policy.evaluate_no_watcher_kill_guard() - this file's own bash
# pre-gate and stdout contract are unchanged (decision-logic move, not a
# policy change). See guard_policy.py's own docstring for the normalized
# 9-field GuardInput contract this hands off, and hooks/lib/guard_dispatch.py
# for the equivalent entry point the four non-Claude dialects use.
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
WM_UV="${WM_UV:-uv run --no-project --quiet}"

INPUT="$(cat)"

# Cheap no-op gate: every shape this hook cares about (kill, pkill, tmux
# kill-window, tmux kill-session) contains the substring "kill". Precise
# matching happens in the python block below.
case "$INPUT" in
  *kill*) ;;
  *) exit 0 ;;
esac

printf '%s' "$INPUT" | \
  WINGMAN_HOME="${WINGMAN_HOME:-$HOME/.wingman}" \
  WM_WATCH_HARD_GRACE="${WM_WATCH_HARD_GRACE:-300}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import json, os, sys

from guard_policy import GuardDenied, GuardInput, evaluate_no_watcher_kill_guard

try:
    data = json.load(sys.stdin)
except Exception:
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
    project_dir=os.environ.get("CLAUDE_PROJECT_DIR", ""),
    home=os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman"),
)

try:
    evaluate_no_watcher_kill_guard(gi)
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
