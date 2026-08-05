#!/usr/bin/env bash
# E2E: bin/crew-standdown reaps a scoped bin/watch-fleet cycle (issue #237,
# part 1). Before this fix, a stood-down owner's watcher - already reparented
# off the pane's process tree - kept polling forever, since nothing ever told
# it to stop: crew-standdown never called bin/watch-fleet --owner <id> --stop,
# and the blocking loop itself had no self-check against its own owner's
# health. This is the exact real-world path the reported incident went
# through (two live watchers found alive after 9h15m, both scoped to an
# already-stood-down owner from a previous, ended run).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
STANDDOWN="$TEST_REPO/bin/crew-standdown"
export WM_WATCH_INTERVAL=1

wait_for_owner_cycle_live() {
  _i=0
  while [ "$_i" -lt 50 ]; do
    "$WF" --owner "$1" --status >/dev/null 2>&1 && return 0
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

wait_for_pid_gone() {
  _i=0
  while [ "$_i" -lt 50 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

# --- standing down a lead reaps its own scoped watcher -----------------------
test_new_home
wm_state crew-add --id lead1 --type lead --objective x --repo /tmp --window wm-lead1 --session-id slead1 >/dev/null
wm_state crew-set --id lead1 --status working --summary "in progress" >/dev/null

"$WF" --owner lead1 >"$WINGMAN_HOME/watcher.log" 2>&1 &
wpid=$!
wm_track "$wpid"
assert_true "the lead's scoped watcher comes up live" "wait_for_owner_cycle_live lead1"

"$STANDDOWN" lead1 >"$WINGMAN_HOME/standdown.log" 2>&1
assert_contains "crew-standdown reports success" "$(cat "$WINGMAN_HOME/standdown.log")" "stood down lead1"

assert_true "the scoped watcher exits once crew-standdown runs" "wait_for_pid_gone $wpid"
classify_out="$(wm_timeout 10 "$WF" --owner lead1 --classify 2>/dev/null)"
assert_eq "the reaped watcher classifies as a deliberate stop, not a spurious failure" "$classify_out" "stopped"

# --- a cascaded descendant's own watcher is reaped too (both ids in $AFFECTED) -
test_new_home
wm_state crew-add --id lead2 --type lead --objective x --repo /tmp --window wm-lead2 --session-id slead2 >/dev/null
wm_state crew-add --id worker2 --type developer --objective y --repo /tmp --window wm-worker2 --session-id sworker2 --parent lead2 >/dev/null
wm_state crew-set --id lead2 --status working --summary "in progress" >/dev/null
wm_state crew-set --id worker2 --status working --summary "in progress" >/dev/null

"$WF" --owner worker2 >"$WINGMAN_HOME/watcher2.log" 2>&1 &
wpid2=$!
wm_track "$wpid2"
assert_true "the descendant's own scoped watcher comes up live" "wait_for_owner_cycle_live worker2"

"$STANDDOWN" lead2 >/dev/null 2>&1
assert_true "the cascaded descendant's watcher exits too" "wait_for_pid_gone $wpid2"
classify_out2="$(wm_timeout 10 "$WF" --owner worker2 --classify 2>/dev/null)"
assert_eq "the descendant's reaped watcher also classifies as stopped" "$classify_out2" "stopped"

# --- standing down an ordinary member that never armed a scoped cycle is a
# harmless no-op (the --stop call is unconditional, per Fix 1's own design) ---
test_new_home
wm_state crew-add --id plain1 --type analyst --objective x --repo /tmp --window wm-plain1 --session-id splain1 >/dev/null
wm_state crew-set --id plain1 --status done --summary "finished" >/dev/null
out="$("$STANDDOWN" plain1 2>&1)"; rc=$?
assert_eq "standing down a member with no scoped cycle still exits 0" "$rc" "0"
assert_contains "standing down a member with no scoped cycle still reports success" "$out" "stood down plain1"

test_summary
