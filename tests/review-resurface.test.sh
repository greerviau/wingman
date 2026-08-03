#!/usr/bin/env bash
# E2E: bounded resurface for a `review` member with no live dependency watcher
# (issue #187). A `review` member is announced once, on entry - correct for one
# actively shepherded by something pollable (a developer's PR under bin/pr-watch),
# but silent forever for one with nothing polling on its behalf (an analyst
# idling for pilot feedback, a developer whose delivery has no forge signal, or
# one that simply isn't currently running pr-watch). wm_state
# review-resurface-check adds exactly one bounded reminder per --window-secs for
# that narrow population, gated on a liveness beacon bin/pr-watch's blocking loop
# now touches every iteration, and leaves a member WITH a live waker on its
# current once-only behavior. No real tmux/claude/forge needed.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WF="$TEST_REPO/bin/watch-fleet"

beat_path() { printf '%s/pr-watch-%s.beat' "$WINGMAN_HOME" "$1"; }

# --- 1. no live waker -> exactly one bounded resurface per window, not more ---
test_new_home
wm_state crew-add --id a1 --type analyst --objective x --repo /tmp --window wm-a1 --session-id s1 >/dev/null
wm_state crew-set --id a1 --status review --artifact /tmp/scratch/a1.txt --summary "plan ready" >/dev/null

r1="$(wm_state review-resurface-check --window-secs 2)"
assert_eq "silent before the window elapses" "$r1" ""

sleep 2.5
r2="$(wm_state review-resurface-check --window-secs 2)"
assert_contains "fires exactly once the window has elapsed" "$r2" "a1"
assert_contains "the fired row carries the review status" "$r2" "	review	"

r3="$(wm_state review-resurface-check --window-secs 2)"
assert_eq "silent again immediately after firing (not once ever)" "$r3" ""
r4="$(wm_state review-resurface-check --window-secs 2)"
assert_eq "still silent on a second immediate re-check" "$r4" ""

# Advance past a SECOND window: fires again - proves "one per window", not
# "once ever" (the store's own stamp, not the window's mere existence, gates
# it - see cmd_review_resurface_check's docstring).
sleep 2.5
r5="$(wm_state review-resurface-check --window-secs 2)"
assert_contains "fires again once a second window elapses" "$r5" "a1"

# --- 2. a live waker (CI/forge-watched) is unaffected, keeps once-only --------
test_new_home
wm_state crew-add --id d2 --type developer --objective y --repo /tmp --window wm-d2 --session-id s2 >/dev/null
wm_state crew-set --id d2 --status review --delivery "https://gh/pr/2" --summary "PR open" >/dev/null

BEAT="$(beat_path d2)"
touch "$BEAT"
sleep 2.5
r6="$(wm_state review-resurface-check --window-secs 2 --waker-grace 30)"
assert_eq "a fresh beacon suppresses the resurface even past the window" "$r6" ""
touch "$BEAT"
sleep 2.5
r7="$(wm_state review-resurface-check --window-secs 2 --waker-grace 30)"
assert_eq "still suppressed while the beacon keeps getting refreshed" "$r7" ""

# Stop refreshing the beacon and let it age past --waker-grace: the member
# becomes eligible and fires on the next window boundary - proves the gate is
# genuinely liveness-based, not a permanent one-time classification.
sleep 3
r8="$(wm_state review-resurface-check --window-secs 2 --waker-grace 2)"
assert_contains "a stale beacon (past waker-grace) makes the member eligible" "$r8" "d2"

# --- 3. resurface wording is distinguishable from a fresh delivery -----------
test_new_home
wm_state crew-add --id d3 --type developer --objective z --repo /tmp --window wm-d3 --session-id s3 >/dev/null
wm_state crew-set --id d3 --status review --delivery "https://gh/pr/3" --summary "PR open" >/dev/null

na="$(wm_state needs-attention)"
assert_contains "a fresh review transition surfaces via needs-attention" "$na" "d3"
na_note="$(printf '%s\n' "$na" | grep '^d3' | cut -f4)"
case "$na_note" in
  "REMINDER ("*) fail "a fresh needs-attention note must not start with REMINDER (" ;;
  *)             ok "a fresh needs-attention note does not start with REMINDER (" ;;
esac

sleep 2.5
rr="$(wm_state review-resurface-check --window-secs 2)"
assert_contains "the resurface row fires" "$rr" "d3"
rr_note="$(printf '%s\n' "$rr" | grep '^d3' | cut -f4)"
case "$rr_note" in
  "REMINDER ("*) ok "the resurface note starts with the REMINDER ( marker" ;;
  *)             fail "the resurface note must start with REMINDER (" ;;
esac
assert_contains "the resurface note mentions the missing watcher" "$rr_note" "no live watcher"
assert_contains "the resurface note still carries the delivery pointer" "$rr_note" "https://gh/pr/3"

# --- 4. the cadence stamp survives a check that doesn't fire -----------------
test_new_home
wm_state crew-add --id a4 --type analyst --objective w --repo /tmp --window wm-a4 --session-id s4 >/dev/null
wm_state crew-set --id a4 --status review --artifact /tmp/scratch/a4.txt --summary "plan ready" >/dev/null
sleep 2.5
r_fire="$(wm_state review-resurface-check --window-secs 2)"
assert_contains "the first bounded resurface fires" "$r_fire" "a4"
at_1="$(uv run --no-project --quiet python -c "
import json
print(json.load(open('$WINGMAN_HOME/review-resurfaced.json'))['a4']['at'])
")"
assert_true "the stored 'at' stamp for a4 was actually captured" "[ -n '$at_1' ]"

# A check well within the NEXT window must stay silent AND must not touch the
# stored 'at' - a check that doesn't fire is a pure read, so a watch-fleet
# restart or re-arm mid-window can never reset the countdown.
r_quiet="$(wm_state review-resurface-check --window-secs 2)"
assert_eq "silent well within the next window" "$r_quiet" ""
at_2="$(uv run --no-project --quiet python -c "
import json
print(json.load(open('$WINGMAN_HOME/review-resurfaced.json'))['a4']['at'])
")"
assert_eq "the stored 'at' stamp is untouched by a check that didn't fire" "$at_1" "$at_2"

# Now exercise this through the REAL bin/watch-fleet binary: kill a cycle
# mid-window and re-arm a fresh one, and confirm the countdown resumes from
# the persisted stamp rather than restarting - a resurface already partway
# through its window when the cycle died still fires close to its ORIGINAL
# due time, not --window-secs later from the restart.
#
# `review` is a LIVE_STATES status, so bin/watch-fleet's reconcile pass
# (issue #209) flips a5 straight to `died` unless its own tmux window
# genuinely exists - a real (harmless) window is required here, matching the
# pattern tests/outbox-redelivery.test.sh already uses for the same reason.
test_new_home
wm_state crew-add --id a5 --type analyst --objective v --repo /tmp --window wm-a5 --session-id s5 >/dev/null
t0=$(date +%s)
wm_state crew-set --id a5 --status review --artifact /tmp/scratch/a5.txt --summary "plan ready" >/dev/null
tmux new-session -d -s "$WM_TMUX_SESSION" -n wm-a5 "sleep 60"

# Consume the ordinary once-only #57 announcement first (a fresh `review`
# transition, unrelated to this feature) so the background cycles below start
# from a quiescent baseline and only the bounded-resurface path is under
# test - otherwise a fresh cycle's own top-of-loop check would immediately
# fire on THAT pending event instead.
wm_timeout 10 "$WF" >/dev/null 2>&1
# Classify that consumed fire before re-arming (issue #197: a bare re-arm
# over it now refuses instead of claiming).
wm_timeout 10 "$WF" --classify >/dev/null 2>&1

export WM_WATCH_INTERVAL=1
export WM_REVIEW_RESURFACE_SECS=8
export WM_REVIEW_WAKER_GRACE=120

"$WF" >"$WINGMAN_HOME/a5-cycle1.log" 2>&1 &
pid1=$!
wm_track "$pid1"
sleep 4
assert_true "cycle 1 is still blocking mid-window" "kill -0 $pid1"
assert_false "no resurface fired yet mid-window" "grep -q 'REMINDER' \"$WINGMAN_HOME/a5-cycle1.log\""
kill "$pid1" 2>/dev/null
wait "$pid1" 2>/dev/null

"$WF" >"$WINGMAN_HOME/a5-cycle2.log" 2>&1 &
pid2=$!
wm_track "$pid2"
_i=0
while [ "$_i" -lt 24 ]; do
  grep -q 'REMINDER' "$WINGMAN_HOME/a5-cycle2.log" 2>/dev/null && break
  sleep 0.5; _i=$((_i+1))
done
t_fired=$(date +%s)
kill "$pid2" 2>/dev/null
wait "$pid2" 2>/dev/null
unset WM_WATCH_INTERVAL WM_REVIEW_RESURFACE_SECS WM_REVIEW_WAKER_GRACE

assert_contains "the re-armed cycle fires the resurface" "$(cat "$WINGMAN_HOME/a5-cycle2.log")" "REMINDER"
elapsed=$((t_fired - t0))
# Correct behavior (resumes from the persisted announced stamp): fires close
# to the original 8s mark. A restart-reset bug would instead fire close to
# 4s (the kill point) + 8s (a fresh window) = ~12s. The bound below accepts
# the former and rejects the latter, with slack for process/poll overhead.
assert_true "fires close to the ORIGINAL due time (~8s), not window-secs after the restart (~12s)" \
  "[ $elapsed -ge 7 ] && [ $elapsed -le 11 ]"

# --- 5. existing regression coverage: run separately (tests/ack-dedup.test.sh,
# tests/pr-watch.test.sh) as part of the full suite - not duplicated here.

test_summary
