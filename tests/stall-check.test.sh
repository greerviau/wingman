#!/usr/bin/env bash
# E2E: the silent-stall detector's state layer (wm-state stall-check), driven
# directly against synthetic process trees - no tmux needed. Proves the two
# staleness gates nominate (and fail fast), the execution probe distinguishes a
# truly idle tree from late-started descendants (a parked member's armed watcher)
# and from CPU activity, and the stalled state flows through needs-attention,
# the ack store, and the board without disturbing `review`.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# Fast probe knobs for every stall-check call in this file.
CHECK="--threshold 5 --root-grace 2 --probe-gap 2 --cpu-eps 0.5"

wm_py() { uv run --no-project --quiet python "$@"; }

status_of() {
  wm_py -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' \
    "$WINGMAN_HOME/crew/$1.json"
}

roster_status_of() {
  wm_py -c '
import json, sys
for r in json.load(open(sys.argv[1])):
    if r["id"] == sys.argv[2]:
        print(r["status"])
' "$WINGMAN_HOME/crew.json" "$1"
}

_BG_PIDS=""
spawn_bg() { "$@" & _BG_PIDS="$_BG_PIDS $!"; }
cleanup_bg() { for p in $_BG_PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; }
trap cleanup_bg EXIT

# --- gates: fresh signals never reach the probe -------------------------------
test_new_home
wm_state crew-add --id g1 --type developer --objective x --repo /tmp --window wm-g1 --session-id s1 >/dev/null
wm_state crew-set --id g1 --status working --summary "digging through logs" >/dev/null

# Fresh pane: the bogus pane-pid must not matter because the probe is unreached.
out="$(wm_state stall-check --id g1 --pane-idle 0 --pane-pid 1 $CHECK)"
assert_eq "fresh pane is never nominated" "$out" ""
assert_eq "status untouched by a failed gate" "$(status_of g1)" "working"

# Stale status but fresh pane (AND fails).
wm_age_status g1
out="$(wm_state stall-check --id g1 --pane-idle 2 --pane-pid 1 $CHECK)"
assert_eq "stale status + fresh pane is not nominated" "$out" ""

# Fresh status but stale pane (AND fails the other way).
wm_state crew-set --id g1 --status working --summary "still digging" >/dev/null
out="$(wm_state stall-check --id g1 --pane-idle 999 --pane-pid 1 $CHECK)"
assert_eq "fresh status + stale pane is not nominated" "$out" ""
assert_eq "member is still working after all gate checks" "$(status_of g1)" "working"

# --- non-working members are never stall-checked ------------------------------
test_new_home
wm_state crew-add --id r1 --type analyst --objective y --repo /tmp --window wm-r1 --session-id s2 >/dev/null
wm_state crew-set --id r1 --status review --artifact /tmp/plan.md >/dev/null
wm_age_status r1
out="$(wm_state stall-check --id r1 --pane-idle 999 --pane-pid 1 $CHECK)"
assert_eq "a review member is a no-op regardless of ages" "$out" ""
assert_eq "review member keeps its status" "$(status_of r1)" "review"
# Guard the constant-append against an inline-tuple regression: `review` must
# stay in the attention set and on the board's Active list.
assert_contains "review still surfaces via needs-attention" "$(wm_state needs-attention)" "r1"
wm_state render-board >/dev/null
assert_contains "review still renders under Active" "$(sed -n '/## Active/,/## Closed/p' "$WINGMAN_HOME/board.md")" "r1"

# --- probe: truly idle tree -> flagged ----------------------------------------
test_new_home
wm_state crew-add --id p1 --type developer --objective z --repo /tmp --window wm-p1 --session-id s3 >/dev/null
wm_state crew-set --id p1 --status working --summary "compiling the widget" >/dev/null
wm_age_status p1
spawn_bg sleep 600
idle_pid=$!
out="$(wm_state stall-check --id p1 --pane-idle 999 --pane-pid "$idle_pid" $CHECK)"
assert_eq "truly idle tree is flagged" "$out" "stalled"
assert_eq "status file reads stalled" "$(status_of p1)" "stalled"
assert_eq "roster mirrors stalled" "$(roster_status_of p1)" "stalled"
assert_contains "stall reason preserves the prior summary" \
  "$(cat "$WINGMAN_HOME/crew/p1.json")" "compiling the widget"
assert_contains "stall reason names the takeover remedy" \
  "$(cat "$WINGMAN_HOME/crew/p1.json")" "crew-takeover p1"
out="$(wm_state stall-check --id p1 --pane-idle 999 --pane-pid "$idle_pid" $CHECK)"
assert_eq "second identical call is a silent no-op" "$out" ""

# needs-attention surfaces the stall once; ack suppresses; a new event re-surfaces.
att="$(wm_state needs-attention)"
assert_contains "needs-attention surfaces the stalled member" "$att" "p1"
upd="$(printf '%s\n' "$att" | awk -F'\t' '$1=="p1" {print $3}')"
wm_state ack --id p1 --updated "$upd" >/dev/null
assert_eq "acked stall is suppressed" "$(wm_state needs-attention | grep -c p1 || true)" "0"
wm_state crew-set --id p1 --status blocked --blocker "need direction after stall" >/dev/null
assert_contains "a later status change re-surfaces" "$(wm_state needs-attention)" "p1"

# --- probe: late-started descendant (armed watcher analog) -> not flagged -----
test_new_home
wm_state crew-add --id p2 --type lead --objective w --repo /tmp --window wm-p2 --session-id s4 >/dev/null
wm_age_status p2
spawn_bg sh -c 'sleep 4; sleep 600'
parked_pid=$!
sleep 5   # let the late child exist and lag the root well past --root-grace 2
out="$(wm_state stall-check --id p2 --pane-idle 999 --pane-pid "$parked_pid" $CHECK)"
assert_eq "late-started descendant suppresses the flag" "$out" ""
assert_eq "parked member stays working" "$(status_of p2)" "working"

# --- probe: launch-time child only (MCP-server baseline) -> still flagged -----
test_new_home
wm_state crew-add --id p3 --type developer --objective v --repo /tmp --window wm-p3 --session-id s5 >/dev/null
wm_age_status p3
spawn_bg sh -c 'sleep 600 & wait'
launch_pid=$!
sleep 3   # root and child age together; the lag stays inside the grace
out="$(wm_state stall-check --id p3 --pane-idle 999 --pane-pid "$launch_pid" $CHECK)"
assert_eq "launch-time child is not evidence of execution" "$out" "stalled"

# --- probe: CPU activity -> not flagged ---------------------------------------
test_new_home
wm_state crew-add --id p4 --type developer --objective u --repo /tmp --window wm-p4 --session-id s6 >/dev/null
wm_age_status p4
spawn_bg sh -c 'while :; do :; done'
busy_pid=$!
out="$(wm_state stall-check --id p4 --pane-idle 999 --pane-pid "$busy_pid" $CHECK)"
assert_eq "CPU activity suppresses the flag" "$out" ""
assert_eq "busy member stays working" "$(status_of p4)" "working"
kill "$busy_pid" 2>/dev/null
wait "$busy_pid" 2>/dev/null

# --- probe: vanished root -> staleness verdict stands -------------------------
test_new_home
wm_state crew-add --id p5 --type developer --objective t --repo /tmp --window wm-p5 --session-id s7 >/dev/null
wm_age_status p5
sh -c 'exit 0' & gone_pid=$!
wait "$gone_pid" 2>/dev/null
out="$(wm_state stall-check --id p5 --pane-idle 999 --pane-pid "$gone_pid" $CHECK)"
assert_eq "vanished root falls back to the staleness verdict" "$out" "stalled"

# --- a self-report during the probe gap wins over the pre-gap snapshot --------
test_new_home
wm_state crew-add --id p6 --type developer --objective s --repo /tmp --window wm-p6 --session-id s8 >/dev/null
wm_state crew-set --id p6 --status working --summary "finishing the report" >/dev/null
wm_age_status p6
spawn_bg sleep 600
idle2_pid=$!
wm_state stall-check --id p6 --pane-idle 999 --pane-pid "$idle2_pid" \
  --threshold 5 --root-grace 2 --probe-gap 5 --cpu-eps 0.5 > "$WINGMAN_HOME/sc.out" &
scpid=$!
sleep 2
wm_state crew-set --id p6 --status review --artifact /tmp/p6-report.md >/dev/null
wait "$scpid"
assert_eq "mid-gap self-report is not clobbered" "$(status_of p6)" "review"
assert_eq "no stall is reported for the self-reporting member" "$(cat "$WINGMAN_HOME/sc.out")" ""

# --- --api-error 1 swaps only the reason template (#23) -----------------------
test_new_home
wm_state crew-add --id ae1 --type developer --objective x --repo /tmp --window wm-ae1 --session-id s9 >/dev/null
wm_state crew-set --id ae1 --status working --summary "calling the API" >/dev/null
wm_age_status ae1
spawn_bg sleep 600
ae_idle_pid=$!
out="$(wm_state stall-check --id ae1 --pane-idle 999 --pane-pid "$ae_idle_pid" $CHECK --api-error 1)"
assert_eq "an api-error stall is still reported as 'stalled'" "$out" "stalled"
assert_eq "status file reads stalled" "$(status_of ae1)" "stalled"
assert_contains "reason carries the api-error: prefix" \
  "$(cat "$WINGMAN_HOME/crew/ae1.json")" "api-error:"
assert_contains "reason names the resume remedy" \
  "$(cat "$WINGMAN_HOME/crew/ae1.json")" "crew-resume ae1"
assert_false "the default (non-api-error) reason text is not used" \
  "grep -q 'the agent likely errored or went' '$WINGMAN_HOME/crew/ae1.json'"

test_summary
