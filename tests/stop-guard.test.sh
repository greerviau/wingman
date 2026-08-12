#!/usr/bin/env bash
# E2E: the Stop hook. With unacked attention pending it blocks the stop and its
# reason demands the complete handling - read the wake file / crew-list and give
# the pilot a compact roster status - and with stop_hook_active set it always
# allows the stop (no loop).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/stop-guard.sh"

# field <id> <key> - extract one field from crew-get's JSON (issue #331's
# announced-stability regression needs the raw announced stamp, not just a
# substring match).
field() {
  wm_state crew-get --id "$1" | uv run --no-project --quiet python3 -c "
import json, sys
v = json.load(sys.stdin).get('$2')
print(v if v is not None else '')
"
}

test_new_home
wm_state crew-add --id h1 --type developer --objective x --repo /tmp --window wm-h1 --session-id s1 >/dev/null
wm_state crew-set --id h1 --status blocked --blocker "need a call on the API shape" >/dev/null

out="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "hook blocks the stop" "$out" '"decision": "block"'
assert_contains "reason lists the member" "$out" "h1"
assert_contains "reason demands the roster report" "$out" "compact roster status"
assert_contains "reason enumerates stalled" "$out" "what is stalled"
assert_contains "reason points at crew-list" "$out" "bin/crew-list"
assert_contains "reason points at the wake file" "$out" "/wake"

# Fix A / #8: acking is not handling. A fresh pass with handling NOT completed
# (stop_hook_active still false) re-blocks on the same surfaced-but-unhandled event,
# rather than being permanently suppressed by the pass-1 ack.
out2="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "an unhandled event re-blocks on the next pass" "$out2" '"decision": "block"'
assert_contains "the re-block still demands the roster report" "$out2" "compact roster status"

# The real second attempt of the turn (stop_hook_active true): mark the scratch set
# handled and allow the stop.
out3="$(printf '{"stop_hook_active": true}' | bash "$HOOK")"
assert_eq "stop_hook_active marks handled and allows the stop" "$out3" ""

# h1 is now handled, so a subsequent fresh pass no longer blocks on it and falls
# through to the no-watcher branch - which is now silent by default (issue
# #185): hooks/stop-continuity.sh owns tokenless re-arming, so the old
# unconditional nudge no longer fires unless the kill switch or a
# spurious-repeated standdown applies (see the companions below).
out4="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_eq "a handled event with no cycle live: silent by default" "$out4" ""

# WM_STOP_AUTOARM=0 (the kill switch): the old text is present, byte-identical
# to today.
export WM_STOP_AUTOARM=0
out4b="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "WM_STOP_AUTOARM=0 restores the routine no-watcher nudge" "$out4b" "watch-fleet"
unset WM_STOP_AUTOARM

# A spurious-repeated standdown active for the CURRENT run: stop-guard nags
# with the marker's own composed remedy text, not the routine nudge.
export WINGMAN_RUN_ID=this-run
printf '%s\n%s\n' "this-run" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch.suppressed"
out4c="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "an active standdown: the composed remedy text, not the routine nudge" "$out4c" "test remedy text"
assert_not_contains "an active standdown: NOT the routine nudge" "$out4c" "Arm one by running 'bin/watch-fleet'"

# A standdown marker stamped with a FOREIGN run id, while the current session
# has its own run id: the shared predicate treats it as inactive, so the hook
# falls through to silence, not the remedy text.
printf '%s\n%s\n' "some-other-run" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch.suppressed"
out4d="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_eq "a foreign-run standdown is treated as inactive: silent" "$out4d" ""
unset WINGMAN_RUN_ID
rm -f "$WINGMAN_HOME/watch.suppressed"

# --- issue #198, R2 regression: the standdown holds under the kill switch too -
# WM_STOP_AUTOARM=0 has never meant "ignore a deliberate standdown" - before
# this fix, the kill switch was tested FIRST, so an active standdown was never
# even consulted under it. The standdown must now be tested first and win.
export WM_STOP_AUTOARM=0
export WINGMAN_RUN_ID=this-run
printf '%s\n%s\n' "this-run" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch.suppressed"
out4r2="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "R2: WM_STOP_AUTOARM=0 plus an active standdown still surfaces the composed remedy text" "$out4r2" "test remedy text"
assert_not_contains "R2: WM_STOP_AUTOARM=0 plus an active standdown does NOT fall back to the routine nudge" "$out4r2" "Arm one by running 'bin/watch-fleet'"
unset WM_STOP_AUTOARM
unset WINGMAN_RUN_ID
rm -f "$WINGMAN_HOME/watch.suppressed"

# --- a marker whose line 2+ is empty falls back to $WM_STANDDOWN_FALLBACK -----
# A pre-fix marker (or a truncated write) must still refuse on the model's
# behalf - never fall back to the routine arm-demanding nudge, which would be
# R1 again for any legacy marker.
export WINGMAN_RUN_ID=this-run
printf '%s\n' "this-run" > "$WINGMAN_HOME/watch.suppressed"
out4e="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "an empty-body marker falls back to WM_STANDDOWN_FALLBACK" "$out4e" "supervision is standing down"
assert_not_contains "an empty-body marker does NOT fall back to the routine nudge" "$out4e" "Arm one by running"
unset WINGMAN_RUN_ID
rm -f "$WINGMAN_HOME/watch.suppressed"

# --- pending ask with no live waiter blocks the stop --------------------------
# A caller asked a delegate but did not arm the wait; it would sleep forever with
# the answer never waking it. The hook must catch this like the no-watcher case.
test_new_home
wm_state ask-new --id ask-abc --from "" --to somew --question "did it change?" >/dev/null
outa="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "a pending ask with no waiter blocks the stop" "$outa" '"decision": "block"'
assert_contains "the reason names the pending request" "$outa" "ask-abc"
assert_contains "the reason points at crew-ask await" "$outa" "crew-ask await"

# With a live waiter (fresh pid + beacon) the ask is covered and does not block.
test_new_home
wm_state ask-new --id ask-live --from "" --to somew --question "covered?" >/dev/null
# Model a live waiter: a real backgrounded process whose pid we record, plus a
# fresh beacon file - the exact liveness shape await maintains.
sleep 30 & lpid=$!
wm_track "$lpid"
mkdir -p "$WINGMAN_HOME/ask"
echo "$lpid" > "$WINGMAN_HOME/ask/ask-live.pid"
: > "$WINGMAN_HOME/ask/ask-live.beat"
outc="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
case "$outc" in *ask-live*) fail "a covered ask must not block the stop" ;; *) ok "a pending ask with a live waiter does not block" ;; esac
kill "$lpid" 2>/dev/null

# --- watcher liveness is owner-scoped, not the global pidfile/beatfile --------
# A lead (WINGMAN_CREW_ID set) has crew in flight and its OWN owner-scoped watcher
# (watch-<_okey>.pid/.beat) live, but no global watch.pid/.beat at all. The hook
# must recognize the owner-scoped watcher and NOT nudge to arm another one.
test_new_home
export WINGMAN_CREW_ID=lead1
wm_state crew-add --id wkr1 --type developer --objective x --repo /tmp --window wm-wkr1 --session-id s1 --parent lead1 >/dev/null
wm_state crew-set --id wkr1 --status working --summary "coding" >/dev/null
sleep 30 & lpid=$!
wm_track "$lpid"
echo "$lpid" > "$WINGMAN_HOME/watch-lead1.pid"
: > "$WINGMAN_HOME/watch-lead1.beat"
outd="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
case "$outd" in *"watch-fleet"*) fail "an owner-scoped watcher must not be reported missing" ;; *) ok "a live owner-scoped watcher satisfies the hook" ;; esac
kill "$lpid" 2>/dev/null
unset WINGMAN_CREW_ID

# The inverse: a live GLOBAL (unscoped) watcher exists, but no owner-scoped one, and
# the hook is checked WITH an owner set. The hook must still complain - proving the
# fix does not just fall back to checking the wrong (global) file. Silent by
# default now (issue #185), same as out4, with the same three companions.
test_new_home
export WINGMAN_CREW_ID=lead2
# issue #331: lead2 itself must be a registered crew member (not just its
# child wkr2) for the new crew-get-based assertions below to succeed at all.
wm_state crew-add --id lead2 --type lead --objective x --repo /tmp --window wm-lead2 --session-id s-lead2 >/dev/null
wm_state crew-set --id lead2 --status working --summary busy >/dev/null
wm_state crew-add --id wkr2 --type developer --objective x --repo /tmp --window wm-wkr2 --session-id s2 --parent lead2 >/dev/null
wm_state crew-set --id wkr2 --status working --summary "coding" >/dev/null
sleep 30 & gpid=$!
wm_track "$gpid"
echo "$gpid" > "$WINGMAN_HOME/watch.pid"
: > "$WINGMAN_HOME/watch.beat"
oute="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_eq "a global watcher does not cover an owner with no watcher of its own: silent by default" "$oute" ""

export WM_STOP_AUTOARM=0
outef="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "WM_STOP_AUTOARM=0 restores the routine nudge (owner-scoped)" "$outef" "watch-fleet"
unset WM_STOP_AUTOARM

printf '%s\n%s\n' "lead2-run" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch-lead2.suppressed"
export WINGMAN_RUN_ID=lead2-run
outeg="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "an active owner-scoped standdown: the composed remedy text" "$outeg" "test remedy text"
assert_not_contains "an active owner-scoped standdown: NOT the routine nudge" "$outeg" "Arm one by running 'bin/watch-fleet'"

# issue #331: the hook's marker-active branch mechanically re-asserts lead2's
# OWN crew-set status too, not just the model-facing Stop-block reason.
lead2_get="$(wm_state crew-get --id lead2)"
assert_contains "the mechanical re-assertion flips lead2 to blocked" "$lead2_get" "\"status\": \"blocked\""
assert_contains "the mechanical re-assertion's blocker carries the standdown tag" "$lead2_get" "\"blocker\": \"watch-fleet-standdown:"

# The announced-stability regression (§1.2 of the plan): calling
# wm_assert_standdown_blocked again on an UNCHANGED already-blocked+tagged
# record must not re-bump `announced` - that bump is what would defeat
# needs-attention's ack/handled dedup and re-surface the same standdown as a
# brand-new event on every Stop event the marker holds (a wake-storm).
announced1="$(field lead2 announced)"
assert_true "announced is stamped after the first re-assertion" "[ -n '$announced1' ]"
bash "$HOOK" <<<'{"stop_hook_active": false}' >/dev/null
announced2="$(field lead2 announced)"
assert_eq "a second Stop event with the marker unchanged does not re-bump announced" "$announced2" "$announced1"

# Case 3, the actual incident regression: the affected session's own errant
# self-report ("not re-arming") clobbers the blocked status set by the trip.
# The hook's own re-assertion, on the very next Stop event, must restore it.
wm_state crew-set --id lead2 --status working --summary "standdown tripped - not re-arming" >/dev/null
assert_contains "the self-report genuinely clobbered the status first" "$(wm_state crew-get --id lead2)" "\"status\": \"working\""
bash "$HOOK" <<<'{"stop_hook_active": false}' >/dev/null
lead2_restored="$(wm_state crew-get --id lead2)"
assert_contains "the hook's re-assertion restores lead2 to blocked" "$lead2_restored" "\"status\": \"blocked\""
assert_contains "the restored blocker again carries the standdown tag" "$lead2_restored" "\"blocker\": \"watch-fleet-standdown:"

printf '%s\n%s\n' "some-other-run" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch-lead2.suppressed"
outeh="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_eq "a foreign-run owner-scoped standdown is treated as inactive: silent" "$outeh" ""
unset WINGMAN_RUN_ID
rm -f "$WINGMAN_HOME/watch-lead2.suppressed"

kill "$gpid" 2>/dev/null
unset WINGMAN_CREW_ID

# =====================================================================
# Wrapper tests (issue #199): hooks/stop-guard-crew.sh, registered ONLY at
# user scope, extends the identical no-idle-blind constraint to crew sessions
# whose project root is some other repo. See hooks/stop-guard-crew.sh's own
# header for why the WINGMAN_CREW_ID gate must live in this wrapper file
# rather than inside hooks/stop-guard.sh itself - which every case above
# already proves is completely unmodified by this change, since none of them
# were touched to add this section.
CREW_HOOK="$TEST_REPO/hooks/stop-guard-crew.sh"

# --- (W1) the wrapper no-ops with WINGMAN_CREW_ID unset -----------------------
test_new_home
wm_state crew-add --id gw1 --type developer --objective x --repo /tmp --window wm-gw1 --session-id s1 >/dev/null
wm_state crew-set --id gw1 --status blocked --blocker "need a call" >/dev/null
unset WINGMAN_CREW_ID
outgw1="$(printf '{"stop_hook_active": false}' | bash "$CREW_HOOK")"
assert_eq "wrapper with WINGMAN_CREW_ID unset: no output" "$outgw1" ""
assert_false "wrapper with WINGMAN_CREW_ID unset: never reaches the real script (no scratch file)" "[ -f '$WINGMAN_HOME/stop-blocked.json' ]"

# --- (W2) the wrapper execs through with WINGMAN_CREW_ID set -------------------
test_new_home
export WINGMAN_CREW_ID=lead-gw2
wm_state crew-add --id gw2 --type developer --objective x --repo /tmp --window wm-gw2 --session-id s2 --parent lead-gw2 >/dev/null
wm_state crew-set --id gw2 --status blocked --blocker "need a call on the API shape" >/dev/null
outgw2="$(printf '{"stop_hook_active": false}' | bash "$CREW_HOOK")"
assert_contains "the wrapper's own invocation blocks the stop" "$outgw2" '"decision": "block"'
assert_contains "the wrapper's own reason lists the member" "$outgw2" "gw2"
assert_true "the wrapper's own invocation writes the owner-scoped scratch file" "[ -f '$WINGMAN_HOME/stop-blocked-lead-gw2.json' ]"
# The real second pass (stop_hook_active true), via the wrapper, marks
# handled and allows the stop - identical to the unwrapped script's own
# pass-2 behavior.
outgw2b="$(printf '{"stop_hook_active": true}' | bash "$CREW_HOOK")"
assert_eq "the wrapper's own pass-2 marks handled and allows the stop" "$outgw2b" ""
assert_false "the wrapper's own pass-2 removes its scratch file" "[ -f '$WINGMAN_HOME/stop-blocked-lead-gw2.json' ]"
unset WINGMAN_CREW_ID

# --- (W3) double registration in the same repo: wrapper + real script, same owner, back-to-back
# Approximates two live hook groups firing for the same Stop event in a crew
# session whose project root IS the wingman repo. Both invocations share the
# identical owner-keyed SCRATCH path, so this proves the duplicate pass
# degrades gracefully: both produce an equivalent block, and a single
# stop_hook_active=true pass (from either invocation path) fully clears it -
# the empirical check for the plan's own "remaining case" discussion.
test_new_home
export WINGMAN_CREW_ID=lead-gw3
wm_state crew-add --id gw3 --type developer --objective x --repo /tmp --window wm-gw3 --session-id s3 --parent lead-gw3 >/dev/null
wm_state crew-set --id gw3 --status blocked --blocker "need a call" >/dev/null
out_wrap="$(printf '{"stop_hook_active": false}' | bash "$CREW_HOOK")"
out_real="$(printf '{"stop_hook_active": false}' | bash "$TEST_REPO/hooks/stop-guard.sh")"
assert_contains "the wrapper's pass-1 blocks" "$out_wrap" '"decision": "block"'
assert_contains "the real script's own pass-1 (same owner) also blocks" "$out_real" '"decision": "block"'
assert_true "the shared owner-scoped scratch file exists after both" "[ -f '$WINGMAN_HOME/stop-blocked-lead-gw3.json' ]"
# Whichever side's pass-2 runs first fully clears it; the other finds no
# scratch file left and exits cleanly (never an error, never a re-block).
out_real2="$(printf '{"stop_hook_active": true}' | bash "$TEST_REPO/hooks/stop-guard.sh")"
assert_eq "the real script's own pass-2 marks handled and allows the stop" "$out_real2" ""
out_wrap2="$(printf '{"stop_hook_active": true}' | bash "$CREW_HOOK")"
assert_eq "the wrapper's own pass-2, run after the real script's, finds nothing left and is silent" "$out_wrap2" ""
unset WINGMAN_CREW_ID

# =====================================================================
# issue #194: an answered blocker's bounded muffle window, end to end through
# the real hook. blocked (hook blocks, as today) -> record-delivery with no
# self-report yet (hook still blocks - a delivered message alone proves
# nothing about whether the delegate acted on it) -> a self-report while
# still blocked (hook stops blocking on this member, within the grace window).
# Every check here stays on pass 1 (stop_hook_active false): the muffle
# window's own `continue` in cmd_needs_attention happens before the ack/
# handled dedup even runs, so it is provable without ever exercising pass 2.
test_new_home
wm_state crew-add --id h9 --type developer --objective x --repo /tmp --window wm-h9 --session-id s9 >/dev/null
wm_state crew-set --id h9 --status blocked --blocker "need a call on the retry policy" >/dev/null

outh9a="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "an unanswered blocker blocks the stop" "$outh9a" '"decision": "block"'
assert_contains "the block names the member" "$outh9a" "h9"

wm_state record-delivery --to h9 --from "" >/dev/null
outh9b="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "a delivery with no self-report since still blocks" "$outh9b" '"decision": "block"'

wm_state crew-set --id h9 --status blocked --summary "acted on the answer" >/dev/null
outh9c="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_eq "a self-report after the reply muffles the row: the stop is not blocked" "$outh9c" ""

test_summary
