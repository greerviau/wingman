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
# All five are comfortably inside the walk's own bound. The claude/grok
# results are the load-bearing case for a bound greater than 1: a compound or
# piped real-world command defeats a shell's own tail-call exec optimization
# (confirmed for claude's `sh -c`, which persisted as its own live process
# rather than exec'ing away even for a bare, non-compound command - some
# other property of how Claude Code invokes it, not the command shape,
# defeats the optimization there), which is exactly why this walks a small
# bound rather than assuming any one fixed depth.
wm_harness_process_identity() {
  _whpi_pid=$$
  _whpi_hops=0
  _whpi_max="${WM_HARNESS_WALK_MAX:-12}"
  while [ "$_whpi_hops" -le "$_whpi_max" ]; do
    _whpi_comm="$(ps -o comm= -p "$_whpi_pid" 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//')"
    if [ -z "$_whpi_comm" ]; then
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
        unset _whpi_pid _whpi_hops _whpi_max _whpi_comm _whpi_lstart
        return 1
        ;;
    esac
    _whpi_ppid="$(ps -o ppid= -p "$_whpi_pid" 2>/dev/null | tr -d ' ')"
    if [ -z "$_whpi_ppid" ] || [ "$_whpi_ppid" = 0 ] || [ "$_whpi_ppid" = "$_whpi_pid" ]; then
      unset _whpi_pid _whpi_hops _whpi_max _whpi_comm _whpi_ppid
      return 1
    fi
    _whpi_pid="$_whpi_ppid"
    _whpi_hops=$((_whpi_hops+1))
  done
  unset _whpi_pid _whpi_hops _whpi_max _whpi_comm
  return 1
}
