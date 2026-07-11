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
# through to the no-watcher nudge (the member is still in flight).
out4="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "a handled event falls to the watcher-arm nudge" "$out4" "watch-fleet"

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
trap 'kill "$lpid" 2>/dev/null' EXIT
mkdir -p "$WINGMAN_HOME/ask"
echo "$lpid" > "$WINGMAN_HOME/ask/ask-live.pid"
: > "$WINGMAN_HOME/ask/ask-live.beat"
outc="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
case "$outc" in *ask-live*) fail "a covered ask must not block the stop" ;; *) ok "a pending ask with a live waiter does not block" ;; esac
kill "$lpid" 2>/dev/null

test_summary
