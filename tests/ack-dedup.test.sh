#!/usr/bin/env bash
# E2E: terminal-event de-duplication via the ack store. Proves a done/died/blocked
# event surfaces to wingman exactly once - needs-attention suppresses it after it
# is acked, the watcher acks what it fires so a re-arm stays quiet, the Stop hook
# acks what it blocks on, and a genuine state change (new `updated`) re-surfaces so
# gap-safety is preserved. No real crew/tmux/claude needed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"
STOP_GUARD="$TEST_REPO/hooks/stop-guard.sh"
export WM_WATCH_INTERVAL=1
# Never let a blocking watcher wedge the suite: every foreground watch-fleet run is
# bounded by wm_timeout, and any backgrounded one is reaped on exit.
trap wm_kill_tracked EXIT

# --- needs-attention emits once, then is quiet after an explicit ack ----------
test_new_home
wm_state crew-add --id d1 --type analyst --objective x --repo /tmp --window wm-d1 --session-id s1 >/dev/null
wm_state crew-set --id d1 --status done --summary "finished x" >/dev/null

na="$(wm_state needs-attention)"
assert_contains "needs-attention reports the done member" "$na" "d1"
# Output is tab-separated: id status updated note. Ack the exact tuple surfaced.
upd="$(printf '%s\n' "$na" | head -n1 | cut -f3)"
assert_true "needs-attention emits a non-empty updated stamp" "[ -n \"$upd\" ]"

wm_state ack --id d1 --updated "$upd" >/dev/null
na2="$(wm_state needs-attention)"
assert_eq "acked done event no longer surfaces" "$na2" ""

# --- a genuine state change (new updated) re-surfaces after an ack -------------
wm_state crew-set --id d1 --status done --summary "finished x again" >/dev/null
na3="$(wm_state needs-attention)"
assert_contains "a new updated re-surfaces the member" "$na3" "d1"
upd3="$(printf '%s\n' "$na3" | head -n1 | cut -f3)"
assert_false "the new updated differs from the acked one" "[ \"$upd3\" = \"$upd\" ]"

# --- the watcher acks what it fires: a re-arm stays quiet ----------------------
test_new_home
wm_state crew-add --id e1 --type analyst --objective y --repo /tmp --window wm-e1 --session-id s2 >/dev/null
wm_state crew-set --id e1 --status done --summary "done y" >/dev/null

out="$(wm_timeout 30 "$WF" 2>/dev/null)"; rc=$?
assert_eq "first arm fires and exits 0" "$rc" "0"
assert_contains "first arm surfaces the done member" "$out" "done: e1"
assert_true "watcher recorded an ack store" "[ -f \"$WINGMAN_HOME/acked.json\" ]"

# Re-arm: the same done event is now acked, so the fresh cycle must NOT fire
# immediately - it blocks. (Before the fix it re-fired on every arm, forever.)
"$WF" >"$WINGMAN_HOME/rearm.log" 2>&1 &
wpid=$!
wm_track "$wpid"
sleep 3
assert_true "re-arm keeps blocking on the already-acked done event" "kill -0 $wpid"
assert_false "re-arm did not re-fire the acked event" "grep -q 'done: e1' \"$WINGMAN_HOME/rearm.log\""

# A different crew finishing in the meantime is unacked and still surfaces.
wm_state crew-add --id e2 --type developer --objective y2 --repo /tmp --window wm-e2 --session-id s3 >/dev/null
wm_state crew-set --id e2 --status done --summary "done y2" >/dev/null
sleep 3
assert_false "watcher exits after a NEW member becomes actionable" "kill -0 $wpid"
assert_contains "gap event for the new member is delivered" "$(cat "$WINGMAN_HOME/rearm.log")" "done: e2"
assert_false "the already-acked member is not re-surfaced" "grep -q 'done: e1' \"$WINGMAN_HOME/rearm.log\""
kill "$wpid" 2>/dev/null

# --- the Stop hook acks what it blocks on -------------------------------------
test_new_home
wm_state crew-add --id f1 --type analyst --objective z --repo /tmp --window wm-f1 --session-id s4 >/dev/null
wm_state crew-set --id f1 --status done --summary "done z" >/dev/null

# First stop attempt (stop_hook_active false): the hook blocks and acks.
r1="$(printf '{"stop_hook_active": false}' | WINGMAN_HOME="$WINGMAN_HOME" bash "$STOP_GUARD")"
assert_contains "Stop hook blocks the first time on a done member" "$r1" '"decision": "block"'
assert_contains "Stop hook names the member in its reason" "$r1" "f1"

# Next turn's stop (stop_hook_active false again): the event is acked → allow.
r2="$(printf '{"stop_hook_active": false}' | WINGMAN_HOME="$WINGMAN_HOME" bash "$STOP_GUARD")"
assert_eq "Stop hook allows the stop once the event is acked" "$r2" ""

test_summary
