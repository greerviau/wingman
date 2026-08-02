#!/usr/bin/env bash
# E2E: the Stop hook. With unacked attention pending it blocks the stop and its
# reason demands the complete handling - read the wake file / crew-list and give
# the pilot a compact roster status - and with stop_hook_active set it always
# allows the stop (no loop).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/stop-guard.sh"

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

printf '%s\n%s\n' "some-other-run" "the watcher for this session has died 3 times in a row (test remedy text)" > "$WINGMAN_HOME/watch-lead2.suppressed"
outeh="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_eq "a foreign-run owner-scoped standdown is treated as inactive: silent" "$outeh" ""
unset WINGMAN_RUN_ID
rm -f "$WINGMAN_HOME/watch-lead2.suppressed"

kill "$gpid" 2>/dev/null
unset WINGMAN_CREW_ID

test_summary
