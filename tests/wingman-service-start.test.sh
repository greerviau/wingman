#!/usr/bin/env bash
# E2E: issue #250 - bin/wingman-service-start is the ExecStart target for a
# Type=forking wingman.service. It must (1) create the tmux session and run
# the given command the first time, (2) resolve and write the tmux SERVER's
# own pid (not a pane pid) to the pidfile so systemd can adopt it as
# MainPID, (3) be a safe no-op re-run against an already-running session so
# a Restart=on-failure retry or a manual doctor probe never errors out or
# duplicates the session, and (4) never touch ~/.wingman/crew.json - the
# roster lives entirely outside this script's job.
#
# Every probe runs against an isolated tmux server (TMUX_TMPDIR, $TMUX
# unset), the same pattern tmux-reachable.test.sh uses, so nothing here ever
# touches the real ambient tmux server this very test suite may be running
# inside of. Teardown (kill-server) is folded into the same subshell as each
# probe, mirroring that file, rather than relying on the shared EXIT trap,
# which does not know about isolated-socket sessions.
# bash-3.2-safe.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

START="$TEST_REPO/bin/wingman-service-start"

# --- fresh start: creates the session and runs the given command -----------
_iso1="$(wm_mktemp_dir)"
_pidfile1="$_iso1/wingman-main.pid"
_marker1="$_iso1/ran"
(
  unset TMUX
  export TMUX_TMPDIR="$_iso1"
  "$START" probe "$_pidfile1" -- sh -c "echo hi > '$_marker1'; sleep 30"
  _rc=$?
  sleep 0.2
  _server_pid="$(tmux display-message -p -t probe '#{pid}' 2>/dev/null)"
  tmux kill-server 2>/dev/null
  echo "$_rc:$_server_pid"
) > "$_iso1/result"
_result="$(cat "$_iso1/result")"
_rc="${_result%%:*}"
_server_pid="${_result#*:}"
assert_eq "fresh start exits 0" "$_rc" "0"
assert_eq "pidfile holds the tmux server's own pid" "$(cat "$_pidfile1" 2>/dev/null)" "$_server_pid"
assert_true "the given command actually ran in the new session" "[ -f '$_marker1' ]"

# --- idempotent re-run: session already exists -------------------------------
_iso2="$(wm_mktemp_dir)"
_pidfile2="$_iso2/wingman-main.pid"
(
  unset TMUX
  export TMUX_TMPDIR="$_iso2"
  tmux new-session -d -s probe2 -n idle "sleep 30" || exit 1
  _before="$(tmux display-message -p -t probe2 '#{pid}')"
  "$START" probe2 "$_pidfile2" -- sh -c "echo should-not-run > '$_iso2/marker'"
  _rc=$?
  _after="$(tmux display-message -p -t probe2 '#{pid}')"
  tmux kill-server 2>/dev/null
  echo "$_rc:$_before:$_after"
) > "$_iso2/result"
_result="$(cat "$_iso2/result")"
_rc="${_result%%:*}"
_rest="${_result#*:}"
_before="${_rest%%:*}"
_after="${_rest#*:}"
assert_eq "re-run against an already-running session exits 0 (no duplicate-session error)" "$_rc" "0"
assert_eq "the pre-existing server is left running, not replaced" "$_before" "$_after"
assert_eq "the pidfile is refreshed to the (unchanged) server pid" "$(cat "$_pidfile2" 2>/dev/null)" "$_after"
assert_false "the trailing command is ignored on a re-run against an existing session" \
  "[ -f '$_iso2/marker' ]"

# --- missing arguments ------------------------------------------------------
"$START" >/dev/null 2>&1
assert_eq "no arguments at all exits 2 (usage)" "$?" "2"
"$START" only-one-arg >/dev/null 2>&1
assert_eq "a single argument exits 2 (usage)" "$?" "2"

# --- never touches the crew roster ------------------------------------------
test_new_home
_before_roster="$(cat "$WINGMAN_HOME/crew.json")"
_iso3="$(wm_mktemp_dir)"
_pidfile3="$_iso3/wingman-main.pid"
(
  unset TMUX
  export TMUX_TMPDIR="$_iso3"
  "$START" probe3 "$_pidfile3" -- sleep 30 >/dev/null
  sleep 0.2
  tmux kill-server 2>/dev/null
)
assert_eq "crew.json is untouched by a service start" "$(cat "$WINGMAN_HOME/crew.json")" "$_before_roster"

test_summary
