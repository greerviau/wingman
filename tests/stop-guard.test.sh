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

# Blocking was a delivery: the event is acked, so a second pass has no attention
# left and falls through to the no-watcher nudge (the member is still in flight).
out2="$(printf '{"stop_hook_active": false}' | bash "$HOOK")"
assert_contains "second pass falls to the watcher-arm nudge" "$out2" "watch-fleet"

# A turn that was already blocked once is always allowed to stop.
out3="$(printf '{"stop_hook_active": true}' | bash "$HOOK")"
assert_eq "stop_hook_active allows the stop" "$out3" ""

test_summary
