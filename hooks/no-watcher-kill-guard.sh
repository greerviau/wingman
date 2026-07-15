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


# --- fail-closed on a kill/pkill/tmux-`-t` argument this hook cannot
# statically resolve to a literal value (round-4 review finding). Every
# checker below only ever compares an argument TOKEN'"'"'s text against a known-
# protected pid/pattern/pane - `kill $(cat watch.pid)`, `X=<pid>; kill $X`,
# and `pkill -f "$(echo watch-fleet)"` all resolve, at the TEXT level this
# hook actually sees, to cmd_match.py'"'"'s inert substitution placeholder
# (`$(...)`, `` `...` ``, `<(...)`, `>(...)`) or an unexpanded `$VAR`/`${VAR}`
# token (resolve_command() only ever expands a LEADING $VAR in COMMAND
# position - tokens[0] - never an argument, by cmd_match.py'"'"'s own design; see
# its module docstring). Silently treating that unresolved text as "does not
# match" - what every checker did before this - is the exact missed-deny
# class the header above says must never happen, just reached through
# argument-VALUE resolution instead of subcommand-NAME resolution. This hook
# cannot evaluate what the substitution/variable actually resolves to
# (that would mean running untrusted, possibly side-effecting shell content
# merely to decide whether to allow it - unsafe and outside what a
# PreToolUse hook should ever do), so the only safe posture, matching this
# file'"'"'s own already-stated false-deny-only invariant, is to fail closed:
# deny whenever a target/pattern cannot be proven to be something OTHER than
# the live cycle, rather than only when it is proven to BE it.
#
# A literal `$` can never appear in a real decimal/process-group pid or a
# real tmux target name, so its presence anywhere in the token - not only as
# the WHOLE token - is treated as the dynamic signal: a token built by
# concatenating literal text around a substitution (`"$(cat watch.pid)x"`)
# would otherwise slip past a whole-token-only check while still being just
# as unresolvable. The one accepted false-positive this admits (deliberately,
# same tradeoff as the pkill comm-vs-args and tmux process-tree-walk
# conservatism already documented above): a pkill regex pattern that
# legitimately uses a trailing $ as its own end-of-string regex anchor
# (pkill -f, pattern quoted so the shell never touches it) reads identically,
# at this hook'"'"'s text layer, to an unresolved variable -
# cmd_match.py'"'"'s plain token list does not preserve whether a `$` came from
# inside single quotes (syntactically inert) or not. Denied only while a
# cycle is actually live, so this never fires when there is nothing to
# protect.
DYNAMIC_TARGET_REASON = (
    "This command'"'"'s kill/pkill/tmux target is not a literal value - it is "
    "built via command substitution ($(...)/`...`) or a shell variable "
    "($VAR/${VAR}), so this hook cannot statically verify it will not "
    "resolve to the live watch-fleet cycle (pid %d) once bash actually "
    "expands it (issue #64 round 4). Denied conservatively rather than risk "
    "a missed deny: resolve it to a literal pid or pattern first and retry - "
    "a literal value that genuinely targets something unrelated to the "
    "watcher passes through untouched."
)


def is_dynamic_token(tok):
    if tok in ("$(...)", "`...`", "<(...)", ">(...)"):
        return True
    return "$" in tok


def deny_dynamic(protected):
    deny(DYNAMIC_TARGET_REASON % sorted(protected)[0])


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
            if is_dynamic_token(t):
                deny_dynamic(protected)
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
    if is_dynamic_token(pattern):
        # Checked BEFORE the regex-compile attempt below: cmd_match.py'"'"'s
        # substitution placeholder ($(...) etc.) is itself a syntactically
        # valid regex, so compiling it would "succeed" and then simply fail
        # to match any real process'"'"'s comm/args text - silently allowing the
        # exact bypass this fail-closed check exists to catch.
        deny_dynamic(protected)
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


# Anchored on tmux'"'"'s own known kill-window/kill-session subcommand names
# (including killw, kill-window'"'"'s documented alias) rather than enumerating
# tmux'"'"'s global option flags: a leading-global-flag bypass (`tmux -L sock
# kill-session ...`) was fixed once by skipping a specific flag list
# (-L/-S/-f/-c/-2/-8/...), and a later tmux version'"'"'s -T/-D/-h/-N flags -
# absent from that list - reopened the exact same bypass, since the loop
# simply misread the first unrecognized flag as the subcommand. Scanning for
# the subcommand ITSELF, and treating every token before it as global-option
# noise regardless of how many flags that represents or what tmux version
# defines them, closes the global-flag bypass permanently rather than needing
# to track tmux'"'"'s grammar release to release.
#
# Round 3 found the next layer of the same root cause: tmux resolves ANY
# unambiguous PREFIX of a full command name too (`tmux kill-win`, `tmux
# kill-ses`), not just the exact name/alias - so a hand-maintained exact-match
# set (`{"kill-window", "killw", "kill-session"}`) still missed every
# abbreviation tmux itself accepts. A literal set can only ever enumerate
# spellings someone thought to test; it can'"'"'t enumerate a grammar rule.
# Fixed by asking the CONNECTED tmux BINARY what it would itself resolve a
# token to (`tmux list-commands`, introspected fresh every call - never
# cached, never hardcoded) and replicating tmux'"'"'s own two-step resolution
# exactly: an exact match against a full command name or alias wins outright;
# otherwise an UNAMBIGUOUS prefix match against the full command names only
# (never against aliases - confirmed empirically against a live tmux: `tmux
# men` for the `menu` alias of `display-menu` is "unknown command", while
# `tmux menu` resolves, so tmux does not prefix-expand aliases). A token that
# resolves to nothing, or is itself ambiguous (`tmux kill-s` - could be
# kill-server or kill-session), is left unresolved and skipped as noise: real
# tmux refuses to run an unknown/ambiguous command (exit 1, no side effect),
# so there is nothing for this hook to guard against in that case either.
# This is grammar-derived rather than enumerated, so it closes the
# abbreviation bypass for whatever tmux version is actually installed,
# permanently, rather than needing a fourth round the next time tmux adds a
# new command whose prefix happens to collide.
_TMUX_KILL_FULL_NAMES = {"kill-window", "kill-session"}
# Fallback used only if `tmux list-commands` itself cannot be run (tmux
# missing, or the introspection call errors) - the exact/alias forms already
# covered by rounds 1-2 stay caught rather than the guard going fully blind,
# though a bare abbreviation would not be recognized in that narrow case.
_TMUX_KILL_FALLBACK_NAMES = {"kill-window", "kill-session"}
_TMUX_KILL_FALLBACK_ALIASES = {"killw": "kill-window"}


def tmux_command_catalog():
    """(full_names, alias_to_name) introspected live from the CONNECTED tmux
    binary'"'"'s own `list-commands` output - the authoritative source for
    exactly what command names/aliases this installed tmux version accepts,
    so resolution never drifts out of sync with the running tmux the way a
    hand-maintained literal set inevitably does."""
    try:
        out = subprocess.check_output(
            ["tmux", "list-commands", "-F",
             "#{command_list_name}|#{command_list_alias}"],
            stderr=subprocess.DEVNULL, timeout=5).decode()
    except Exception:
        return set(), {}
    names = set()
    aliases = {}
    for line in out.splitlines():
        parts = line.split("|", 1)
        name = parts[0] if parts else ""
        if not name:
            continue
        names.add(name)
        alias = parts[1] if len(parts) > 1 else ""
        if alias:
            aliases[alias] = name
    return names, aliases


def resolve_tmux_subcommand(token, names, aliases):
    """Replicate tmux'"'"'s own subcommand resolution for a single argv token:
    exact name/alias match first, then an unambiguous prefix match against
    full command names only. Returns the resolved full command name, or None
    if the token matches nothing (unknown) or matches more than one full name
    (ambiguous) - both of which real tmux itself refuses to run."""
    if token in names:
        return token
    if token in aliases:
        return aliases[token]
    candidates = [n for n in names if n.startswith(token)]
    if len(candidates) == 1:
        return candidates[0]
    return None


def tmux_kill_subcommand_index(args, names, aliases):
    """args = argv[1:] (everything after the resolved `tmux`). Returns
    (index, resolved_name) for the first token that RESOLVES - via exact
    match, alias, or unambiguous prefix - to kill-window or kill-session, or
    (len(args), None) if none is found."""
    for i, tok in enumerate(args):
        resolved = resolve_tmux_subcommand(tok, names, aliases)
        if resolved in _TMUX_KILL_FULL_NAMES:
            return i, resolved
    return len(args), None


def resolve_pane_pids(kind, target):
    # `-t` omitted: fall back to tmux'"'"'s own default target resolution (via
    # $TMUX, the same context `tmux display-message` would use) rather than
    # a single pane - `kill-session` with no `-t` destroys the WHOLE current
    # session (every window, every pane), not just the pane the command was
    # typed into, and `kill-window` with no `-t` destroys the whole current
    # window (which may itself hold more than one pane, if split). `-s` (no
    # `-t`) lists every pane in the current session; plain `list-panes` (no
    # `-s`, no `-t`) lists every pane in the current window - so, in both
    # cases, "list panes scoped to the right level" rather than "resolve one
    # pid" is what must happen when the target is left implicit.
    cmd = ["tmux", "list-panes"]
    if kind == "kill-session":
        cmd.append("-s")  # every pane across the whole session, not one window
    if target:
        cmd += ["-t", target]
    cmd += ["-F", "#{pane_pid}"]
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
    if target is not None and is_dynamic_token(target):
        # An unresolvable -t value (e.g. built via a nested command
        # substitution) would otherwise reach resolve_pane_pids() as literal
        # garbage text, fail the tmux target lookup, return no pane pids, and
        # be silently ALLOWED by the "if not root_pids: return" below - the
        # same missed-deny shape as check_kill/check_pkill, just reached
        # through tmux -t resolution instead.
        deny_dynamic(protected)
    root_pids = resolve_pane_pids(kind, target)
    if not root_pids:
        return
    hit = protected & ps_tree_descendants(root_pids)
    if hit:
        deny(watcher_kill_reason(sorted(hit)[0]))


def check_tmux(argv, protected):
    # argv[1] is not always the subcommand: tmux accepts its own global
    # options before it (`tmux -L sock kill-session ...`, `tmux -T 256,clipboard
    # kill-window ...`) - anchor on the subcommand name itself (see
    # tmux_kill_subcommand_index) rather than enumerating those flags, so no
    # global option this hook doesn'"'"'t happen to list can ever bypass detection.
    args = argv[1:]
    names, aliases = tmux_command_catalog()
    if not names:
        names, aliases = _TMUX_KILL_FALLBACK_NAMES, _TMUX_KILL_FALLBACK_ALIASES
    idx, kind = tmux_kill_subcommand_index(args, names, aliases)
    if idx >= len(args):
        return
    check_tmux_kill(["tmux", kind] + args[idx + 1:], protected)


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
        elif b == "tmux":
            check_tmux(argv, protected)

sys.exit(0)
' 2>/dev/null

exit 0
