#!/usr/bin/env bash
# bin/lib/harness-identity.sh - wm_harness_process_identity(), the
# harness-agnostic run-id substitute (docs/analysis/2026-08-18-remove-bin-
# wingman-launcher-spec.md, §4.3): the effective run identity for any
# consumer is the (pid, start-time) of the harness CLI's own root process -
# the same technique wm_ps_lstart (bin/lib/common.sh) already provides
# elsewhere for "is this the same live process, or a different one". Every
# consumer that used to read a possibly-empty $WINGMAN_RUN_ID now falls back
# to this when that variable is unset, instead of silently treating "no run
# id" as "no ownership to enforce".
#
# Factored into its own tiny, side-effect-free file - not written inline in
# bin/lib/common.sh, though every common.sh consumer still gets it (common.sh
# sources this file, the same wm_backend_select precedent already used for
# bin/lib/backend.sh) - so a per-tool-call consumer (hooks/pilot-preferences-
# guard.sh and its three siblings, hooks/lib/watcher-liveness.sh, none of
# which source common.sh today) can source just this: a couple of `ps` forks,
# nothing else. Sourcing common.sh itself on every tool call would also pay
# its config.local.toml load - a real `uv run` subprocess on any machine that
# has one - which is exactly why those hooks avoid it already (they
# re-derive HERE/REPO by hand rather than sourcing common.sh for that either).
#
# Sourced, never executed directly. bash-3.2-safe: no associative arrays, no
# ${x,,}, no mapfile/readarray.

# The harness CLI binaries this codebase supports (bin/lib/agents/*.sh, one
# descriptor per name) - what wm_harness_process_identity recognizes by
# `ps -o comm=` while walking its own ancestry. None of these names exceed
# the 15-character TASK_COMM_LEN Linux truncates `ps -o comm=` to, so no
# truncation risk.
WM_HARNESS_NAMES="claude codex grok opencode pi"

# wm_harness_process_identity
#
# Prints a single opaque, filesystem-and-argv-safe token identifying the
# nearest ancestor of THIS process (starting at $$, walking upward through
# parent pids) whose command name matches one of $WM_HARNESS_NAMES - i.e.
# the harness CLI's own root process - or prints nothing and returns 1 if no
# such ancestor is found within a bounded walk, or if `ps` itself is
# unavailable/unreadable. The token is "<pid>_<sanitized-lstart>" (the same
# sanitizing idiom bin/lib/common.sh already uses for its own filename-safe
# keys, `tr -c 'A-Za-z0-9._-' '_'`, applied to wm_ps_lstart's own
# space-separated rendering) - safe to pass as a single, unquoted shell word
# or embed in a filename, with no quoting burden pushed onto callers.
#
# Every property this needs falls out for free from (pid, start-time) alone:
# fresh per genuine restart (a new OS process has a new pid/start-time),
# stable across /clear or /compact (in-process context operations that never
# touch the harness's own root process), and correct for `--resume` without
# separate verification (mechanically just a fresh process the shell started,
# so the derived identity is naturally fresh - the same conservative,
# correct-for-a-restart semantics a minted run id would need a write step to
# get right).
#
# Live-verified hop counts (2026-08-19, against the real installed CLIs on
# this machine, each given a genuine tool-call - a mock local OpenAI-
# compatible backend for codex/grok/pi's guard-rail-free verification since
# this machine carries no working credentials for them, and opencode's own
# real free default model, "Big Pickle", needing no credentials at all):
#   claude:   2 hops (self -> the `sh -c <command>` Claude Code wraps every
#             hook "command" string in, confirmed even for a bare script
#             path with no shell metacharacters at all -> claude itself).
#   codex:    1 hop (self -> the vendored codex binary directly, a real
#             compiled executable named "codex"; its own `codex.js` launch
#             shim, a further node ancestor above that, is never reached
#             because the walk stops at the first match).
#   grok:     2 hops (self -> grok's own sandboxed `bash -O extglob -c ...`
#             command wrapper, comm "bash", not a match -> the real grok
#             binary, a compiled executable named "grok"; its own node.js
#             trampoline, a further ancestor above that, is likewise never
#             reached).
#   opencode: 1 hop (self -> opencode directly, a real compiled executable,
#             no wrapper at all for its own Bash-tool subprocess).
#   pi:       1 hop (self -> pi directly; pi's own Bash tool spawns the
#             command's configured shell as a DIRECT child with no
#             intermediate wrapper of its own, and for a single simple
#             command that shell's own tail-call exec optimization can
#             additionally collapse what would otherwise be its own extra
#             hop into the same pid - confirmed by reading pi's own shipped
#             source, dist/core/tools/bash.js, which calls Node's `spawn()`
#             directly with an argv array, never a `shell: true`/string
#             command).
# All five are comfortably inside the walk's own bound (WM_HARNESS_WALK_MAX,
# default 5 - 2x the worst live-verified case below). The claude/grok results
# are the load-bearing case for a bound greater than 1: a compound or piped
# real-world command defeats a shell's own tail-call exec optimization
# (confirmed for claude's `sh -c`, which persisted as its own live process
# rather than exec'ing away even for a bare, non-compound command - some
# other property of how Claude Code invokes it, not the command shape,
# defeats the optimization there), which is exactly why this walks a small
# bound rather than assuming any one fixed depth. The bound is deliberately
# TIGHT, not generously large: this function sits on bin/watch-fleet's own
# startup path (computed once per process, but that process is created
# freely - every re-arm pays it), and the NO-MATCH case (no WINGMAN_RUN_ID,
# no recognizable harness ancestor anywhere in this process's tree - the
# shape any CI runner or test suite invocation actually has) always walks
# the FULL bound before giving up, at roughly two `ps` forks per hop. Live-
# measured: a bound of 12 (the original, unmeasured "generous" choice) added
# enough latency to a `ps`-heavy CI runner to make a real, timing-sensitive
# test (tests/stop-continuity-pr-watch.test.sh's re-arm-within-window check)
# fail intermittently in CI specifically - reproduced by forcing the same
# no-match shape locally (WM_HARNESS_NAMES set to a name nothing matches) and
# confirming the test passes again once the walk is bounded to WM_HARNESS_
# WALK_MAX=0 (near-zero latency) but not at the original 12. 5 keeps 2x
# headroom over every live-verified real case (2 hops) plus the one
# reasoned-but-unverified extra hop a compound command could add (3), while
# cutting worst-case no-match latency well below what broke that test.
#
# Constraint on recognition (not just on the five installs verified above):
# `ps -o comm=` reports the EXECUTED FILE's own basename, not argv[0] and not
# a shebang script's own filename - a shebang interpreter's basename shows
# instead (confirmed live: a plain `#!/usr/bin/env bash` or `#!/usr/bin/env
# node` script named e.g. "claude" surfaces comm "bash"/"node", never
# "claude"). Recognition by comm therefore requires the harness's own process
# image to carry its own name - true of a native/compiled binary (codex,
# grok, opencode, all vendored binaries here) or a runtime entry point that
# explicitly sets its own process title (confirmed for pi:
# dist/cli.js sets process.title early in startup, which is WHY `ps -o comm=`
# reports "pi" rather than "node" for it - this is pi's own choice, not a
# property every Node CLI gets for free). A shebang shim that does neither
# would surface its interpreter's name and match nothing here - this codebase
# ships no such install for any of the five today (verified per-harness
# above), but a future or third-party install shaped that way would silently
# get an unresolvable identity (see the walk's own final return-1 branch,
# which traces this to stderr specifically for that reason).
# Every failure path traces one line to stderr naming which of the four ways
# this can fail actually happened - "at minimum" visibility for the no-match
# case above (a shebang-shimmed install whose process image never carries
# the harness's own name), so a silently unresolvable identity leaves
# SOME trace rather than nothing. A caller in a context where this would be
# noise (a per-tool-call hook that has already decided "no identity
# resolvable" is an ordinary, expected outcome, not a diagnostic) is free to
# redirect it away at the call site; none of the callers in this codebase do.
wm_harness_process_identity() {
  _whpi_pid=$$
  _whpi_hops=0
  _whpi_max="${WM_HARNESS_WALK_MAX:-5}"
  while [ "$_whpi_hops" -le "$_whpi_max" ]; do
    _whpi_comm="$(ps -o comm= -p "$_whpi_pid" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
    if [ -z "$_whpi_comm" ]; then
      echo "wm_harness_process_identity: no such process (pid $_whpi_pid vanished mid-walk, or ps is unavailable) - no identity resolvable" >&2
      unset _whpi_pid _whpi_hops _whpi_max _whpi_comm
      return 1
    fi
    case " $WM_HARNESS_NAMES " in
      *" $_whpi_comm "*)
        _whpi_lstart="$(TZ=UTC LC_ALL=C ps -o lstart= -p "$_whpi_pid" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
        if [ -n "$_whpi_lstart" ]; then
          printf '%s_%s\n' "$_whpi_pid" "$(printf '%s' "$_whpi_lstart" | tr -c 'A-Za-z0-9._-' '_')"
          unset _whpi_pid _whpi_hops _whpi_max _whpi_comm _whpi_lstart
          return 0
        fi
        echo "wm_harness_process_identity: matched harness ancestor pid $_whpi_pid (comm=$_whpi_comm) but could not read its start time - no identity resolvable" >&2
        unset _whpi_pid _whpi_hops _whpi_max _whpi_comm _whpi_lstart
        return 1
        ;;
    esac
    _whpi_ppid="$(ps -o ppid= -p "$_whpi_pid" 2>/dev/null | tr -d ' ')"
    if [ -z "$_whpi_ppid" ] || [ "$_whpi_ppid" = 0 ] || [ "$_whpi_ppid" = "$_whpi_pid" ]; then
      echo "wm_harness_process_identity: reached the top of the process tree (pid $_whpi_pid, comm=$_whpi_comm) after $_whpi_hops hop(s) with no recognized harness ancestor ($WM_HARNESS_NAMES) - no identity resolvable. If this process's own harness IS one of those five, its process image does not carry its own name (see this file's header comment on the comm-recognition constraint)." >&2
      unset _whpi_pid _whpi_hops _whpi_max _whpi_comm _whpi_ppid
      return 1
    fi
    _whpi_pid="$_whpi_ppid"
    _whpi_hops=$((_whpi_hops+1))
  done
  echo "wm_harness_process_identity: walked the full bound (WM_HARNESS_WALK_MAX=$_whpi_max hops) from pid $$ with no recognized harness ancestor ($WM_HARNESS_NAMES) - no identity resolvable" >&2
  unset _whpi_pid _whpi_hops _whpi_max _whpi_comm
  return 1
}
