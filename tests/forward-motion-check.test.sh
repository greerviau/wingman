#!/usr/bin/env bash
# E2E: structural forward-motion / logical-stall detection (issue #199, Gap
# B). A lead whose watcher is live and cycling normally, with N workers
# permanently parked and no reviewer ever spawned (or any other roster shape
# that never changes), produces zero attention events forever through the
# only channel that can wake anyone - the existing liveness stall-check never
# nominates it either, since a lead correctly running its own watch-fleet
# loop always shows a live process tree. wm_state forward-motion-check closes
# this: a WORKING candidate with at least one active report flips directly to
# 'stalled' once its own roster-shape signature (its own summary/blocker/
# artifact/delivery, plus every active report's own status/announced) has
# shown no change for --window-secs - resetting the clock the instant
# anything about that shape genuinely moves. Modeled directly on
# tests/review-resurface.test.sh's structure and helpers. No real
# tmux/claude/forge needed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- 1. baseline fire: a lead + 3 developers all review, no reviewer --------
test_new_home
wm_state crew-add --id lead1 --type developer --objective x --repo /tmp --window wm-lead1 --session-id s1 >/dev/null
wm_state crew-set --id lead1 --status working --summary "leading the effort" >/dev/null
for n in 1 2 3; do
  wm_state crew-add --id dev$n --type developer --objective x --repo /tmp --window wm-dev$n --session-id s-dev$n --parent lead1 >/dev/null
  wm_state crew-set --id dev$n --status review --summary "PR up" --delivery "https://gh/pr/$n" >/dev/null
done

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
sleep 2.5
out1="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "the lead flips to stalled" "$out1" "stalled lead1"
status1="$(wm_state crew-get --id lead1 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "the roster record itself reflects the flip" "$status1" "stalled"
reason1="$(wm_state crew-get --id lead1 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['summary'])")"
assert_contains "the reason mentions the active report count" "$reason1" "3 active report(s)"
assert_contains "the reason points at crew-takeover" "$reason1" "bin/crew-takeover lead1"
assert_contains "the reason points at crew-say for a nudge" "$reason1" "bin/crew-say lead1"
assert_contains "the reason preserves the lead's own last summary" "$reason1" "(last summary: leading the effort)"

# --- 2. silent before the window elapses -------------------------------------
test_new_home
wm_state crew-add --id lead2 --type developer --objective x --repo /tmp --window wm-lead2 --session-id s2 >/dev/null
wm_state crew-set --id lead2 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev2a --type developer --objective x --repo /tmp --window wm-dev2a --session-id s-dev2a --parent lead2 >/dev/null
wm_state crew-set --id dev2a --status review --summary "PR up" --delivery "https://gh/pr/2a" >/dev/null

out2a="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "silent on the very first check (anchor just established)" "$out2a" ""
sleep 2
out2b="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "silent just under the window" "$out2b" ""
status2="$(wm_state crew-get --id lead2 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "lead2 is still working, not stalled" "$status2" "working"

# --- 3. a child's status change resets the anchor ----------------------------
test_new_home
wm_state crew-add --id lead3 --type developer --objective x --repo /tmp --window wm-lead3 --session-id s3 >/dev/null
wm_state crew-set --id lead3 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev3 --type developer --objective x --repo /tmp --window wm-dev3 --session-id s-dev3 --parent lead3 >/dev/null
wm_state crew-set --id dev3 --status review --summary "PR up" --delivery "https://gh/pr/3" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 4 >/dev/null
sleep 2
wm_state forward-motion-check --owner "" --window-secs 4 >/dev/null   # still mid-window, anchor untouched

wm_state crew-set --id dev3 --status blocked --blocker "need a call" >/dev/null
out3a="$(wm_state forward-motion-check --owner "" --window-secs 4)"
assert_eq "the child's status change resets the anchor: no flip yet" "$out3a" ""

# A generous 2.2s later is well PAST the ORIGINAL anchor's window (t0+4 would
# have elapsed by now) but well UNDER a fresh 4s window from the reset point -
# proving the reset genuinely happened, not merely that not enough total time
# has passed.
sleep 2.2
out3b="$(wm_state forward-motion-check --owner "" --window-secs 4)"
assert_eq "still no flip - a FRESH window is required from the reset point" "$out3b" ""

sleep 2.3
out3c="$(wm_state forward-motion-check --owner "" --window-secs 4)"
assert_contains "the fresh window from the reset point eventually elapses and flips" "$out3c" "stalled lead3"

# --- 4. a new child appearing resets the anchor ------------------------------
test_new_home
wm_state crew-add --id lead4 --type developer --objective x --repo /tmp --window wm-lead4 --session-id s4 >/dev/null
wm_state crew-set --id lead4 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev4 --type developer --objective x --repo /tmp --window wm-dev4 --session-id s-dev4 --parent lead4 >/dev/null
wm_state crew-set --id dev4 --status review --summary "PR up" --delivery "https://gh/pr/4" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 3 >/dev/null
sleep 2
# A reviewer finally gets spawned - the direct regression case for "a review
# worker with no reviewer sibling."
wm_state crew-add --id rev4 --type reviewer --objective x --repo /tmp --window wm-rev4 --session-id s-rev4 --parent lead4 >/dev/null
out4="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "a new child appearing resets the anchor: no flip" "$out4" ""
sleep 1.5
out4b="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "still no flip shortly after (fresh window required from the reset point)" "$out4b" ""

# --- 5. the lead's own summary change resets the anchor ----------------------
test_new_home
wm_state crew-add --id lead5 --type developer --objective x --repo /tmp --window wm-lead5 --session-id s5 >/dev/null
wm_state crew-set --id lead5 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev5 --type developer --objective x --repo /tmp --window wm-dev5 --session-id s-dev5 --parent lead5 >/dev/null
wm_state crew-set --id dev5 --status review --summary "PR up" --delivery "https://gh/pr/5" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 3 >/dev/null
sleep 2
wm_state crew-set --id lead5 --status working --summary "still leading, checked CI" >/dev/null
out5="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "the lead's own summary change resets the anchor: no flip" "$out5" ""
sleep 1.5
out5b="$(wm_state forward-motion-check --owner "" --window-secs 3)"
assert_eq "still no flip shortly after (fresh window required from the reset point)" "$out5b" ""

# --- 6. no false positive on a plain worker with no reports of its own ------
test_new_home
wm_state crew-add --id solo6 --type developer --objective x --repo /tmp --window wm-solo6 --session-id s6 >/dev/null
wm_state crew-set --id solo6 --status working --summary "coding away" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
sleep 2.5
out6="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_eq "a worker with no reports of its own is never a candidate" "$out6" ""
status6="$(wm_state crew-get --id solo6 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "solo6 stays working - only the liveness stall-check can ever flip it" "$status6" "working"

# --- 7. resume-then-re-stall does not thrash ---------------------------------
test_new_home
wm_state crew-add --id lead7 --type developer --objective x --repo /tmp --window wm-lead7 --session-id s7 >/dev/null
wm_state crew-set --id lead7 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev7 --type developer --objective x --repo /tmp --window wm-dev7 --session-id s-dev7 --parent lead7 >/dev/null
wm_state crew-set --id dev7 --status review --summary "PR up" --delivery "https://gh/pr/7" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
sleep 2.5
out7a="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "the initial stall flip fires" "$out7a" "stalled lead7"

# A genuine transition out of stalled (bumps announced, per the status contract).
wm_state crew-set --id lead7 --status working --summary "resumed" >/dev/null

# Immediately re-check on the SAME cycle - the episode_announced anchor key
# must prevent an instant re-flip, even though the roster shape (lead7's own
# summary/blocker/artifact/delivery, dev7's status/announced) is otherwise
# identical to what it was right before the flip.
out7b="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_eq "an immediate re-check after resume does not re-flip" "$out7b" ""
status7a="$(wm_state crew-get --id lead7 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "lead7 is genuinely back to working, not re-stalled" "$status7a" "working"

# A second immediate re-check (no time elapsed) must also not thrash.
out7c="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_eq "a second immediate re-check still does not re-flip" "$out7c" ""

# But it is not permanently suppressed either: once a FULL fresh window
# elapses with no further change, it flips again.
sleep 2.5
out7d="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "a fresh full window after the resume flips again" "$out7d" "stalled lead7"

# --- 8. once stalled, the candidate is never renominated (a state, not a repeating reminder) ---
# Unlike cmd_review_resurface_check (which emits a repeating reminder NOTE
# every window while the underlying status stays 'review'), this check flips
# STATUS directly - once 'stalled', status != 'working', so the candidate is
# no longer eligible at all, and no further mutation happens until a
# human/owner explicitly resumes it. Confirmed above at the tail of case 7
# (out7a fires once; nothing re-fires or re-writes until the explicit resume),
# and directly here: further checks against an untouched stalled record never
# print anything and never touch its stored anchor entry again.
test_new_home
wm_state crew-add --id lead8 --type developer --objective x --repo /tmp --window wm-lead8 --session-id s8 >/dev/null
wm_state crew-set --id lead8 --status working --summary "leading" >/dev/null
wm_state crew-add --id dev8 --type developer --objective x --repo /tmp --window wm-dev8 --session-id s-dev8 --parent lead8 >/dev/null
wm_state crew-set --id dev8 --status review --summary "PR up" --delivery "https://gh/pr/8" >/dev/null

wm_state forward-motion-check --owner "" --window-secs 2 >/dev/null
sleep 2.5
out8a="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_contains "the flip fires once" "$out8a" "stalled lead8"

sleep 2.5
out8b="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_eq "a stalled candidate is never renominated - no repeat firing" "$out8b" ""
out8c="$(wm_state forward-motion-check --owner "" --window-secs 2)"
assert_eq "still silent on yet another cycle" "$out8c" ""
status8="$(wm_state crew-get --id lead8 | uv run --no-project --quiet python -c "import json,sys; print(json.load(sys.stdin)['status'])")"
assert_eq "lead8 stays stalled until explicitly resumed" "$status8" "stalled"

test_summary
