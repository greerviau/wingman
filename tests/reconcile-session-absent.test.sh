#!/usr/bin/env bash
# E2E: issue #209 - bin/crew-list and bin/watch-fleet must reconcile liveness
# even when the crew tmux session itself does not exist (the exact shape of a
# whole-server tmux crash), and must still never falsely flag a genuinely-live
# prefix-sibling stray window died in that state (issue #44's hazard) - but a
# stray in an arbitrarily-named (non-prefix) session is NOT protected, the
# deliberate narrower-scope tradeoff from the plan's "Chosen approach" (round-1
# review, MF-4): reconcile's --windows input is scoped to the crew session's
# own prefix family, not the whole server, specifically so it cannot fabricate
# orphan-adoption records from an unrelated wingman home or a concurrently
# running test file's fixtures. No decoy/stray session from this file is ever
# named identically to $WM_TMUX_SESSION (test_new_home guarantees a fresh name
# per file), and every stray session this file creates is torn down via
# wm_track_tmux. Every bin/watch-fleet invocation below runs with owner ""
# (test_new_home unsets WINGMAN_CREW_ID), which is required for the
# mass-death block to be reachable at all (bin/watch-fleet's outage-state
# machinery is gated on `[ -z "$OWNER" ]`).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
export WM_WATCH_INTERVAL=1

field_of() {
  wm_state crew-get --id "$1" 2>/dev/null | uv run --no-project --quiet python -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit
v = d.get(sys.argv[1])
print("" if v is None else v)
' "$2"
}

# --- core repro: crew session absent, a live-state member with no window
# anywhere flips to died via bin/crew-list --------------------------------
test_new_home
wm_state crew-add --id d1 --type developer --objective x --repo /tmp \
  --window wm-d1 --session-id s1 >/dev/null
wm_state crew-set --id d1 --status review --delivery "https://example/pr/1" \
  --summary "PR ready" >/dev/null
# $WM_TMUX_SESSION deliberately never created - this is the crash state.
"$TEST_REPO/bin/crew-list" >/dev/null 2>&1
assert_eq "a live member with no window anywhere flips to died with the crew session absent" \
  "$(field_of d1 status)" "died"

# --- same repro via bin/watch-fleet: reconcile fires AND correlated:mass-death
# actually gets a chance to see it (the issue's more serious consequence) ---
test_new_home
wm_state crew-add --id m1 --type developer --objective x --repo /tmp \
  --window wm-m1 --session-id s1 >/dev/null
wm_state crew-set --id m1 --status review --summary "r1" >/dev/null
wm_state crew-add --id m2 --type developer --objective x --repo /tmp \
  --window wm-m2 --session-id s2 >/dev/null
wm_state crew-set --id m2 --status working --summary "r2" >/dev/null
# No third live member: 2 of 2 die together, ratio 1.0 - comfortably above
# the default mass-death threshold, so a single foreground cycle should fire.
out="$(wm_timeout 30 "$TEST_REPO/bin/watch-fleet" 2>/dev/null)"; rc=$?
assert_eq "watch-fleet fires (exits 0) on the reconcile-produced mass death" "$rc" "0"
assert_contains "the fire reason names the correlated mass-death batch" "$out" "correlated:mass-death"
assert_eq "m1 flipped to died" "$(field_of m1 status)" "died"
assert_eq "m2 flipped to died" "$(field_of m2 status)" "died"

# --- #44 non-regression: crew session absent, but the live member's window
# genuinely exists in a DIFFERENT (stray) session on the server - must NOT
# be flagged died, via bin/crew-list -----------------------------------------
test_new_home
STRAY="$WM_TMUX_SESSION-stray"
wm_track_tmux "$STRAY"
tmux new-session -d -s "$STRAY" -n orchestrator "sleep 120"
tmux new-window -d -t "=$STRAY:" -n wm-s1 "sleep 120"
wm_state crew-add --id s1 --type developer --objective x --repo /tmp \
  --window wm-s1 --session-id fake >/dev/null
wm_state crew-set --id s1 --status working --summary "coding" >/dev/null
# $WM_TMUX_SESSION (the real crew session) still never created.
"$TEST_REPO/bin/crew-list" >/dev/null 2>&1
assert_eq "a genuinely-live stray window is never flagged died (issue #44)" \
  "$(field_of s1 status)" "working"

# --- #44 non-regression, same shape via bin/watch-fleet ---------------------
test_new_home
STRAY2="$WM_TMUX_SESSION-stray2"
wm_track_tmux "$STRAY2"
tmux new-session -d -s "$STRAY2" -n orchestrator "sleep 120"
tmux new-window -d -t "=$STRAY2:" -n wm-s2 "sleep 120"
wm_state crew-add --id s2 --type developer --objective x --repo /tmp \
  --window wm-s2 --session-id fake2 >/dev/null
wm_state crew-set --id s2 --status working --summary "coding" >/dev/null
"$TEST_REPO/bin/watch-fleet" >"$WINGMAN_HOME/wf.log" 2>&1 &
wpid=$!
wm_track "$wpid"
sleep 3
assert_true "watch-fleet is still armed (no false death fired)" "kill -0 $wpid"
assert_eq "the stray-but-live member is never flagged died" "$(field_of s2 status)" "working"
kill "$wpid" 2>/dev/null

# --- documents the accepted tradeoff (§3): a stray in an ARBITRARILY-NAMED
# session - not a prefix sibling of the crew session - is NOT protected. This
# is expected, deliberate behavior, not a bug: asserting it here pins the
# actual boundary of the safety property so a future change to the scoping
# doesn't silently narrow or widen it without a test noticing. ---------------
test_new_home
# Textually derived from $WM_TMUX_SESSION (tests/run.sh's static invariant 2
# requires every minted session name to be, so the identity-scoped teardown
# sweep can find it if the trap-based cleanup below is ever skipped) while
# still NOT a runtime prefix of it or vice versa: $WM_TMUX_SESSION appears
# after a literal prefix of its own, so wm_tmux_prefix_windows_csv's
# index($1, s) == 1 test is false for this session - the actual property
# this block exists to pin.
ARBITRARY="unrelated-${WM_TMUX_SESSION}"
wm_track_tmux "$ARBITRARY"
tmux new-session -d -s "$ARBITRARY" -n orchestrator "sleep 120"
tmux new-window -d -t "=$ARBITRARY:" -n wm-s3 "sleep 120"
wm_state crew-add --id s3 --type developer --objective x --repo /tmp \
  --window wm-s3 --session-id fake3 >/dev/null
wm_state crew-set --id s3 --status working --summary "coding" >/dev/null
"$TEST_REPO/bin/crew-list" >/dev/null 2>&1
assert_eq "a stray in a NON-prefix-sibling session is flagged died (the stated tradeoff, not a defect)" \
  "$(field_of s3 status)" "died"

test_summary
