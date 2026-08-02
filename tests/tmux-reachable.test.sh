#!/usr/bin/env bash
# E2E: issue #209 - wm_tmux_reachable distinguishes "no tmux server running"
# - whether the socket file exists with nothing listening (an ordinary
# kill-server) or the socket file is missing outright (a fresh boot, a wiped
# /tmp - the "host reset" shape the issue names) - both of which must proceed
# with reconcile against an empty window set, from a genuine failure to reach
# tmux (skip reconcile, the old guard's behavior). Every probe below runs in a
# subshell with TMUX unset and TMUX_TMPDIR pointed at its own isolated
# directory: TMUX_TMPDIR is ignored by tmux whenever $TMUX is already set
# (round-1 review, MF-3), and tests/run.sh runs from inside a real tmux pane
# in the normal case, so $TMUX IS set - a probe that does not unset it talks
# to the real ambient server instead of the isolated one it is trying to
# construct, silently passing (or failing) for the wrong reason. wm_tmux() /
# wm_tmux_reachable() take no -L/socket-name parameter, so TMUX_TMPDIR is the
# isolation mechanism, not -L; this was verified directly (not assumed) to
# produce each of the three distinct tmux failure messages this test targets.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
. "$TEST_REPO/bin/lib/common.sh"

# --- reachable: a real, currently-running (isolated) tmux server -------------
# Teardown is folded into the SAME subshell as the probe (round-2 review,
# N-3): a first probe that spawned its own subshell for the kill-server would
# both let `tmux new-session` fail silently into a vacuous pass (the "no
# server"/ENOENT arms in wm_tmux_reachable also return 0, so a session that
# never actually started would still show this as "reachable" without ever
# exercising the live-server path) and leak an isolated tmux server (with its
# socket directory later deleted out from under it) if anything aborted
# between the probe and a separately-subshelled kill-server call.
_iso1="$(wm_mktemp_dir)"
(
  unset TMUX
  export TMUX_TMPDIR="$_iso1"
  tmux new-session -d -s probe -n idle "sleep 30" || exit 1
  wm_tmux_reachable
  _rc=$?
  tmux kill-server 2>/dev/null
  exit "$_rc"
)
assert_eq "a running (isolated) tmux server with a session is reachable" "$?" "0"

# --- reachable: socket file present, server gone (an ordinary kill-server) --
_iso2="$(wm_mktemp_dir)"
(
  unset TMUX
  export TMUX_TMPDIR="$_iso2"
  tmux new-session -d -s probe2 -n idle "sleep 5"
  tmux kill-server 2>/dev/null
  sleep 0.2
  wm_tmux_reachable
)
assert_eq "server gone but its socket file is still present is reachable (empty windows)" "$?" "0"

# --- reachable: socket file absent outright - the row round-1 review found
# broken (fresh boot / wiped /tmp / a host reset, the issue's own scenario) --
_iso3="$(wm_mktemp_dir)"
( unset TMUX; export TMUX_TMPDIR="$_iso3"; wm_tmux_reachable )
assert_eq "no socket file at all is still reachable (proceed with empty windows)" "$?" "0"

# --- unreachable: a genuine failure to talk to tmux (unwritable socket dir) -
_broken="$(wm_mktemp_dir)/broken"
mkdir -p "$_broken"
chmod 000 "$_broken"
( unset TMUX; export TMUX_TMPDIR="$_broken"; wm_tmux_reachable )
_rc=$?
chmod 755 "$_broken"   # restore before cleanup can remove it
assert_false "an unwritable tmux socket directory is reported unreachable" "[ $_rc -eq 0 ]"

test_summary
