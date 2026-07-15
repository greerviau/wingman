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
# What is denied, from EVERY session (no WINGMAN_CREW_ID/WINGMAN_CREW_TYPE
# gating at all - killing the watcher is never legitimate from any session,
# not the pilot's own top-level session, not a lead, not any other crew
# member):
#   - `kill`/`pkill <target>` whose target resolves to a pid that is
#     CURRENTLY a live watch-fleet cycle.
#   - `tmux kill-window`/`tmux kill-session` whose target's pane pid (or one
#     of its process-tree descendants) is currently a live watch-fleet cycle
#     - the shape that kills a session's OWN window/session, taking out a
#     background-armed watcher along with it.
#
# "Currently a live watch-fleet cycle" reuses bin/watch-fleet's own
# cycle_live() definition exactly (bin/watch-fleet:250-255), never a bare
# pid-alive check: the pidfile exists, its pid answers `kill -0`, AND its
# companion beat file's mtime is younger than WM_WATCH_GRACE (default 30s).
# This is what keeps a dead watcher's leaked pidfile (a SIGKILL skips the
# INT/TERM trap that removes it) whose pid number is later reused by an
# unrelated process from being falsely protected forever: a bare pid-alive
# check would pass, but the beat file goes stale and stops refreshing since
# nothing else touches it. The set of protected pids is recomputed fresh on
# every hook invocation from $WM_HOME/watch.pid and $WM_HOME/watch-*.pid (the
# owner-keyed naming bin/watch-fleet:107-123 uses for a lead's own cycle) -
# never cached - so it can never disagree with what bin/watch-fleet's own arm
# logic would currently classify as live.
#
# `kill -0` (the null-signal liveness probe cycle_live() itself uses, plus
# bin/crew-ask and hooks/stop-guard.sh) is ALWAYS allowed, regardless of
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
#   - tmux kill-window/kill-session: the target (or, if -t is omitted, the
#     calling session's own current pane, via `tmux display-message -p
#     '#{pane_pid}'`) is resolved to its pane pid(s), then the WHOLE process
#     tree rooted there is walked with one `ps -ax -o pid=,ppid=` scan (the
#     same approach bin/lib/wm-state.py's _ps_tree() uses for stall
#     detection, reimplemented here as a small self-contained walk rather
#     than a cross-module import, matching this file's siblings). Any
#     protected pid anywhere in that tree denies - conflating "this pid is
#     merely a descendant of the target" with "this pid IS the target" is
#     deliberately conservative.
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
  WM_WATCH_GRACE="${WM_WATCH_GRACE:-30}" \
  PYTHONPATH="$HERE/lib${PYTHONPATH:+:$PYTHONPATH}" $WM_UV python -c '
import glob, json, os, re, subprocess, sys, time

from cmd_match import command_segments, resolve_command

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

if data.get("tool_name") != "Bash":
    sys.exit(0)

tool_input = data.get("tool_input", {}) or {}
command = tool_input.get("command", "") or ""
home = os.path.expanduser(os.environ.get("WINGMAN_HOME") or "~/.wingman")
try:
    grace = int(os.environ.get("WM_WATCH_GRACE") or "30")
except ValueError:
    grace = 30


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


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


def watcher_kill_reason(pid):
    return (
        "Killing a live watch-fleet cycle (pid %d) is never something to do "
        "from a session (issue #64 / #12): its liveness is the only channel "
        "that lets a wake reach an idle orchestrator, and this exact shape - "
        "a session misreading the pid as an instruction to stop it - has "
        "happened before. Leave it running; it exits on its own the instant "
        "there is an actionable event. If you genuinely need to stop this "
        "cycle for manual testing (rare - normal operation never requires "
        "it), use `bin/watch-fleet --stop` instead of killing the pid "
        "directly." % pid
    )


# --- protected-pid discovery: the cycle_live() definition from
# bin/watch-fleet, replicated exactly (pid alive via kill -0 AND beat file
# fresher than the grace window),
# never a bare pid-alive check. Recomputed fresh every call, never cached.
def protected_pids():
    home_pidfiles = [os.path.join(home, "watch.pid")]
    home_pidfiles += glob.glob(os.path.join(home, "watch-*.pid"))
    pids = set()
    now = time.time()
    for pidfile in home_pidfiles:
        if not os.path.isfile(pidfile):
            continue
        try:
            with open(pidfile) as fh:
                pid = int(fh.read().strip())
        except (OSError, ValueError):
            continue
        try:
            os.kill(pid, 0)
        except OSError:
            continue
        beatfile = pidfile[:-4] + ".beat" if pidfile.endswith(".pid") else pidfile + ".beat"
        try:
            mtime = os.path.getmtime(beatfile)
        except OSError:
            continue
        if (now - mtime) < grace:
            pids.add(pid)
    return pids


# --- kill: an optional leading signal spec (-s <name>, -n <num>, or a fused
# -<name-or-num> token), then a list of pid/pgid targets.
def parse_kill(argv):
    """Returns (listmode, signal, targets) for a resolved `kill` argv."""
    args = argv[1:]
    if not args:
        return False, None, []
    if args[0] in ("-l", "-L"):
        return True, None, []
    tok0 = args[0]
    signal = None
    idx = 0
    if tok0 == "-s":
        signal = args[1] if len(args) > 1 else None
        idx = 2
    elif tok0.startswith("-s") and len(tok0) > 2:
        signal = tok0[2:]
        idx = 1
    elif tok0 == "-n":
        signal = args[1] if len(args) > 1 else None
        idx = 2
    elif tok0.startswith("-n") and len(tok0) > 2:
        signal = tok0[2:]
        idx = 1
    elif tok0.startswith("-") and tok0 != "-":
        signal = tok0[1:]
        idx = 1
    return False, signal, args[idx:]


def is_null_signal(signal):
    if signal is None:
        return False
    s = signal.strip()
    if s.upper().startswith("SIG"):
        s = s[3:]
    return s == "0"


def check_kill(argv, protected):
    if not protected:
        return
    listmode, signal, targets = parse_kill(argv)
    if listmode or is_null_signal(signal):
        return  # -l takes no targets; the null signal is a liveness probe, never a kill
    for tok in targets:
        # Strip an optional leading "-" (the process-group form, e.g. `kill
        # -TERM -1234`) before parsing as an integer. Conflating a literal pid
        # target with a same-numbered process-group target is deliberately
        # conservative: it can only cause an extra deny, never a missed one.
        t = tok[1:] if tok.startswith("-") else tok
        try:
            val = int(t)
        except ValueError:
            continue
        if abs(val) in protected:
            deny(watcher_kill_reason(abs(val)))


# --- pkill: extract the final positional, non-option token as the pattern.
_PKILL_BOOL_FLAGS = ("-f", "-x", "-v", "-n", "-o")
_PKILL_VALUE_FLAGS = ("-s", "--signal", "-P", "-u", "-U", "-g", "-G", "-t")


def extract_pkill_pattern(argv):
    args = argv[1:]
    pattern = None
    i = 0
    while i < len(args):
        tok = args[i]
        if tok in _PKILL_VALUE_FLAGS:
            i += 2
            continue
        if tok.startswith("--signal="):
            i += 1
            continue
        if tok in _PKILL_BOOL_FLAGS:
            i += 1
            continue
        if tok.startswith("-") and tok != "-":
            i += 1
            continue
        pattern = tok
        i += 1
    return pattern


def ps_identity(pid):
    try:
        out = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "comm=,args="],
            stderr=subprocess.DEVNULL, timeout=5).decode()
    except Exception:
        return None, None
    line = out.strip("\n")
    if not line.strip():
        return None, None
    parts = line.split(None, 1)
    comm = parts[0] if parts else ""
    args_str = parts[1] if len(parts) > 1 else ""
    return comm, args_str


def check_pkill(argv, protected):
    if not protected:
        return
    pattern = extract_pkill_pattern(argv)
    if pattern is None:
        return
    try:
        rx = re.compile(pattern)
    except re.error:
        # A pattern that fails to compile is treated as a match against every
        # protected pid (fail closed), not silently skipped.
        deny(watcher_kill_reason(sorted(protected)[0]))
        return
    for pid in protected:
        comm, args_str = ps_identity(pid)
        if comm is None:
            continue
        if rx.search(comm) or rx.search(args_str):
            deny(watcher_kill_reason(pid))


# --- tmux kill-window / tmux kill-session.
def tmux_target_value(rest):
    for i, tok in enumerate(rest):
        if tok == "-t" and i + 1 < len(rest):
            return rest[i + 1]
        if tok.startswith("-t") and len(tok) > 2:
            return tok[2:]
    return None


def current_pane_pid():
    try:
        out = subprocess.check_output(
            ["tmux", "display-message", "-p", "#{pane_pid}"],
            stderr=subprocess.DEVNULL, timeout=5).decode().strip()
    except Exception:
        return None
    return int(out) if out.isdigit() else None


def resolve_pane_pids(kind, target):
    cmd = ["tmux", "list-panes"]
    if kind == "kill-session":
        cmd.append("-s")  # list every pane across the whole session, not one window
    cmd += ["-t", target, "-F", "#{pane_pid}"]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=5).decode()
    except Exception:
        return []
    return [int(ln.strip()) for ln in out.splitlines() if ln.strip().isdigit()]


def ps_tree_descendants(root_pids):
    """{pid, ...} for every pid in root_pids plus all of their descendants,
    from one `ps -ax -o pid=,ppid=` pass - a small, self-contained
    parent/child walk mirroring the _ps_tree() helper in bin/lib/wm-state.py."""
    try:
        out = subprocess.check_output(
            ["ps", "-ax", "-o", "pid=,ppid="],
            stderr=subprocess.DEVNULL, timeout=5).decode()
    except Exception:
        return set()
    children = {}
    known = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        children.setdefault(ppid, []).append(pid)
        known.add(pid)
    result = set()
    stack = list(root_pids)
    while stack:
        p = stack.pop()
        if p in result:
            continue
        if p in known or p in root_pids:
            result.add(p)
        stack.extend(children.get(p, []))
    return result


def check_tmux_kill(argv, protected):
    if not protected:
        return
    kind = argv[1]
    target = tmux_target_value(argv[2:])
    if target:
        root_pids = resolve_pane_pids(kind, target)
    else:
        cpp = current_pane_pid()
        root_pids = [cpp] if cpp is not None else []
    if not root_pids:
        return
    hit = protected & ps_tree_descendants(root_pids)
    if hit:
        deny(watcher_kill_reason(sorted(hit)[0]))


# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56):
# command_segments() returns None rather than a partial, truncated segment
# list. This guard has no session scope to narrow the fail-closed behavior to
# (unlike no-merge-guard.sh) - it applies to every session unconditionally -
# so an unresolvable command that reached the cheap pre-gate above is ALWAYS
# denied here, regardless of who issued it.
segments = command_segments(command)
if segments is None:
    deny(PARSE_FAIL_REASON)

protected = protected_pids()
if protected:
    for seg in segments:
        b, argv = resolve_command(seg)
        if not argv:
            continue
        if b == "kill":
            check_kill(argv, protected)
        elif b == "pkill":
            check_pkill(argv, protected)
        elif b == "tmux" and len(argv) > 1 and argv[1] in ("kill-window", "kill-session"):
            check_tmux_kill(argv, protected)

sys.exit(0)
' 2>/dev/null

exit 0
