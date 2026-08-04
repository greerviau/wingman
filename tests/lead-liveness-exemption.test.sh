#!/usr/bin/env bash
# E2E: issue #234's state-layer changes.
#
# D1 - wm_state liveness-probe: the same branch-(a) proof-of-life question
# cmd_stall_check's own execution probe already asks, exposed as a standalone
# read-only subcommand so bin/watch-fleet can ask it BEFORE typing a check-in
# nudge, not only afterwards. See bin/watch-fleet's own guard for how the
# answer is used.
#
# D2 - a stall flip that lands on a member with live reports gets an honest
# reason clause naming the likely real failure (a dead wake chain over a
# live sub-crew) instead of implicitly blaming the agent.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

status_of() {
  uv run --no-project --quiet python -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["status"])' \
    "$WINGMAN_HOME/crew/$1.json"
}

reason_of() {
  uv run --no-project --quiet python -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["summary"])' \
    "$WINGMAN_HOME/crew/$1.json"
}

spawn_bg() { "$@" & wm_track "$!"; }

CHECK="--threshold 5 --root-grace 2 --probe-gap 2 --cpu-eps 0.5 --nudge-age 999"

# --- liveness-probe: alive for a late-started descendant ----------------------
test_new_home
spawn_bg sh -c 'sleep 4; sleep 600'
armed_pid=$!
sleep 5   # let the late child exist and lag the root well past --root-grace 2
out="$(wm_state liveness-probe --pane-pid "$armed_pid" --root-grace 2)"
assert_eq "an armed late-started descendant reads alive" "$out" "alive"

# --- liveness-probe: not alive for a bare idle tree ----------------------------
test_new_home
spawn_bg sleep 600
bare_pid=$!
out="$(wm_state liveness-probe --pane-pid "$bare_pid" --root-grace 2)"
assert_eq "a bare idle tree reads not-alive" "$out" ""

# --- liveness-probe: not alive for a launch-time-only child --------------------
test_new_home
spawn_bg sh -c 'sleep 600 & wait'
launch_pid=$!
sleep 3   # root and child age together; the lag stays inside the grace
out="$(wm_state liveness-probe --pane-pid "$launch_pid" --root-grace 2)"
assert_eq "a launch-time-only child is not evidence of execution" "$out" ""

# --- liveness-probe: vanished pid reads not-alive, does not error --------------
test_new_home
sh -c 'exit 0' & gone_pid=$!
wait "$gone_pid" 2>/dev/null
out="$(wm_state liveness-probe --pane-pid "$gone_pid" --root-grace 2)"
rc=$?
assert_eq "a vanished pid reads not-alive" "$out" ""
assert_eq "a vanished pid does not error" "$rc" "0"

# --- D2: a lead with one working report still flips, reason gains the clause --
test_new_home
wm_state crew-add --id lead1 --type lead --objective x --repo /tmp --window wm-lead1 --session-id sl1 >/dev/null
wm_state crew-set --id lead1 --status working --summary "supervising the crew" >/dev/null
wm_state crew-add --id dev1 --type developer --objective y --repo /tmp --window wm-dev1 --session-id sd1 --parent lead1 >/dev/null
wm_state crew-set --id dev1 --status working --summary "implementing the fix" >/dev/null
wm_age_status lead1
spawn_bg sleep 600
lead1_pid=$!
out="$(wm_state stall-check --id lead1 --pane-idle 999 --pane-pid "$lead1_pid" $CHECK)"
assert_eq "a lead with no armed watcher still flips (Q2 shape)" "$out" "stalled"
assert_eq "status file reads stalled" "$(status_of lead1)" "stalled"
r="$(reason_of lead1)"
assert_contains "reason names 1 live report" "$r" "1 live report(s)"
assert_contains "reason names the crew-say remedy" "$r" "crew-say lead1"
assert_contains "reason still carries the base template text" "$r" "the agent likely errored or went idle"

# Over-claim guard: a report parked in `review` is still counted (LIVE_STATES
# includes review), but the reason must never claim it is "running"/progressing.
test_new_home
wm_state crew-add --id lead2 --type lead --objective x --repo /tmp --window wm-lead2 --session-id sl2 >/dev/null
wm_state crew-set --id lead2 --status working --summary "supervising the crew" >/dev/null
wm_state crew-add --id dev2 --type developer --objective y --repo /tmp --window wm-dev2 --session-id sd2 --parent lead2 >/dev/null
wm_state crew-set --id dev2 --status review --artifact /tmp/dev2.md >/dev/null
wm_age_status lead2
spawn_bg sleep 600
lead2_pid=$!
out="$(wm_state stall-check --id lead2 --pane-idle 999 --pane-pid "$lead2_pid" $CHECK)"
assert_eq "a lead with a review-parked report still flips" "$out" "stalled"
r="$(reason_of lead2)"
assert_contains "reason still names 1 live report" "$r" "1 live report(s)"
# Scoped to the appended clause itself (everything from "It still owns"
# onward): the base template's own unrelated "running child process" wording
# would otherwise false-positive a whole-reason word search. assert_not_contains
# does a plain substring match (no eval), unlike assert_false, which is not
# safe to use here - the reason text embeds a literal `bin/crew-say ...`
# backtick-quoted command that eval would re-interpret as command substitution.
clause="${r#*It still owns}"
assert_not_contains "clause never claims the report is running" "$clause" "running"
assert_not_contains "clause never claims the report is progressing" "$clause" "progressing"

# --- D2: a developer with no reports gets the byte-identical template today --
test_new_home
wm_state crew-add --id solo1 --type developer --objective z --repo /tmp --window wm-solo1 --session-id ss1 >/dev/null
wm_state crew-set --id solo1 --status working --summary "compiling the widget" >/dev/null
wm_age_status solo1
spawn_bg sleep 600
solo1_pid=$!
out="$(wm_state stall-check --id solo1 --pane-idle 999 --pane-pid "$solo1_pid" $CHECK)"
assert_eq "a developer with no reports still flips" "$out" "stalled"
r="$(reason_of solo1)"
assert_not_contains "the active-report clause is absent with zero reports" "$r" "live report(s)"
assert_eq "reason is byte-identical to today's default template" "$r" \
  "no pane output, status update, running child process, or CPU activity for >5s while status was 'working', even after a check-in nudge - the agent likely errored or went idle. Inspect with \`bin/crew-takeover solo1\` or stand down with \`bin/crew-standdown solo1\`. (last summary: compiling the widget)"

# --- D2: the clause composes with --api-error 1, both fragments present -------
test_new_home
wm_state crew-add --id lead3 --type lead --objective x --repo /tmp --window wm-lead3 --session-id sl3 >/dev/null
wm_state crew-set --id lead3 --status working --summary "calling the API" >/dev/null
wm_state crew-add --id dev3 --type developer --objective y --repo /tmp --window wm-dev3 --session-id sd3 --parent lead3 >/dev/null
wm_state crew-set --id dev3 --status working --summary "still going" >/dev/null
wm_age_status lead3
spawn_bg sleep 600
lead3_pid=$!
out="$(wm_state stall-check --id lead3 --pane-idle 999 --pane-pid "$lead3_pid" $CHECK --api-error 1)"
assert_eq "an api-error lead with a live report still flips" "$out" "stalled"
r="$(reason_of lead3)"
assert_contains "reason carries the api-error: prefix" "$r" "api-error:"
assert_contains "reason also carries the active-report clause" "$r" "1 live report(s)"

# --- Q1 regression guard: a lead with an armed-watcher tree is still not flipped
test_new_home
wm_state crew-add --id lead4 --type lead --objective x --repo /tmp --window wm-lead4 --session-id sl4 >/dev/null
wm_state crew-set --id lead4 --status working --summary "supervising the crew" >/dev/null
wm_state crew-add --id dev4 --type developer --objective y --repo /tmp --window wm-dev4 --session-id sd4 --parent lead4 >/dev/null
wm_state crew-set --id dev4 --status working --summary "implementing the fix" >/dev/null
wm_age_status lead4
spawn_bg sh -c 'sleep 4; sleep 600'
lead4_pid=$!
sleep 5   # let the late child exist and lag the root well past --root-grace 2
out="$(wm_state stall-check --id lead4 --pane-idle 999 --pane-pid "$lead4_pid" $CHECK)"
assert_eq "a lead with an armed-watcher tree is still not flipped" "$out" ""
assert_eq "member stays working" "$(status_of lead4)" "working"

test_summary
