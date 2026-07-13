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

# --- the Stop hook acks what it blocks on, and only HANDLED events stop blocking -
# (Fix A / #8): acking alone must NOT permanently suppress the Stop hook; only a
# completed handling (marked on the stop_hook_active pass) does.
test_new_home
wm_state crew-add --id f1 --type analyst --objective z --repo /tmp --window wm-f1 --session-id s4 >/dev/null
wm_state crew-set --id f1 --status done --summary "done z" >/dev/null

# First stop attempt (stop_hook_active false): the hook blocks and acks.
r1="$(printf '{"stop_hook_active": false}' | WINGMAN_HOME="$WINGMAN_HOME" bash "$STOP_GUARD")"
assert_contains "Stop hook blocks the first time on a done member" "$r1" '"decision": "block"'
assert_contains "Stop hook names the member in its reason" "$r1" "f1"

# A fresh stop attempt (stop_hook_active false) with handling NOT completed: the
# acked-but-unhandled event RE-BLOCKS - the core #8 fix (a premature ack no longer
# permanently suppresses it).
r2="$(printf '{"stop_hook_active": false}' | WINGMAN_HOME="$WINGMAN_HOME" bash "$STOP_GUARD")"
assert_contains "an acked-but-unhandled event re-blocks the stop" "$r2" '"decision": "block"'

# The real second attempt of the turn (stop_hook_active true): mark handled, allow.
r3="$(printf '{"stop_hook_active": true}' | WINGMAN_HOME="$WINGMAN_HOME" bash "$STOP_GUARD")"
assert_eq "stop_hook_active marks handled and allows the stop" "$r3" ""

# Now the event is fully handled: a subsequent fresh stop no longer blocks on it.
r4="$(printf '{"stop_hook_active": false}' | WINGMAN_HOME="$WINGMAN_HOME" bash "$STOP_GUARD")"
assert_eq "a handled event no longer blocks the stop" "$r4" ""

# --- --silent / announced: self-managed review churn does not re-fire ---------
# (see playbooks/_status-contract.md, "Re-entering review without re-announcing")
test_new_home
wm_state crew-add --id g1 --type developer --objective w --repo /tmp --window wm-g1 --session-id s5 >/dev/null
wm_state crew-set --id g1 --status review --delivery "https://gh/pr/1" --summary "PR open" >/dev/null

na_g1="$(wm_state needs-attention)"
assert_contains "a plain review entry (no prior review) emits a row" "$na_g1" "g1"
upd_g1="$(printf '%s\n' "$na_g1" | head -n1 | cut -f3)"
wm_state ack --id g1 --updated "$upd_g1" >/dev/null
assert_eq "acking it suppresses a repeat with the same announced" "$(wm_state needs-attention)" ""

# working -> review --silent: self-managed churn, nothing to re-fire, but
# crew-list/board.md still show the fresh summary.
wm_state crew-set --id g1 --status working --summary "fixing ci" >/dev/null
wm_state crew-set --id g1 --status review --silent --summary "ci fixed, settled again" >/dev/null
assert_eq "a silent review re-entry emits nothing" "$(wm_state needs-attention)" ""
assert_contains "crew-list shows the fresh summary despite the silent write" \
  "$(wm_state crew-list)" "ci fixed, settled again"
assert_contains "board.md shows the fresh summary despite the silent write" \
  "$(cat "$WINGMAN_HOME/board.md")" "ci fixed, settled again"

# a subsequent PLAIN review re-entry (answering real feedback) does emit a fresh row
wm_state crew-set --id g1 --status working --summary "addressing feedback" >/dev/null
wm_state crew-set --id g1 --status review --summary "responded to feedback" >/dev/null
na_g1b="$(wm_state needs-attention)"
assert_contains "a plain review re-entry emits a fresh row" "$na_g1b" "g1"
upd_g1b="$(printf '%s\n' "$na_g1b" | head -n1 | cut -f3)"
assert_false "the fresh row carries a new announced stamp" "[ \"$upd_g1b\" = \"$upd_g1\" ]"

# --silent is refused with blocked/done - always genuine, always announce
err_blocked="$(wm_state crew-set --id g1 --status blocked --silent --blocker "x" 2>&1)"; rc_blocked=$?
assert_false "--silent with --status blocked exits non-zero" "[ $rc_blocked -eq 0 ]"
assert_contains "the blocked refusal names the reason" "$err_blocked" "silent"
err_done="$(wm_state crew-set --id g1 --status done --silent --summary "shipped" 2>&1)"; rc_done=$?
assert_false "--silent with --status done exits non-zero" "[ $rc_done -eq 0 ]"

# A record written before `announced` existed (only `updated` present) still
# dedups correctly via the r.get("announced") or r.get("updated") fallback.
wm_state crew-add --id g2 --type developer --objective v --repo /tmp --window wm-g2 --session-id s6 >/dev/null
wm_state crew-set --id g2 --status review --delivery "https://gh/pr/2" >/dev/null
uv run --no-project --quiet python - "$WINGMAN_HOME/crew/g2.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.pop("announced", None)
json.dump(d, open(p, "w"))
EOF
na_g2="$(wm_state needs-attention)"
assert_contains "a pre-announced-field record still surfaces via the updated fallback" "$na_g2" "g2"
upd_g2="$(printf '%s\n' "$na_g2" | grep '^g2' | cut -f3)"
wm_state ack --id g2 --updated "$upd_g2" >/dev/null
assert_not_contains "acking a fallback-keyed record suppresses it" "$(wm_state needs-attention)" "g2"

test_summary
