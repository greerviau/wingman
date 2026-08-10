#!/usr/bin/env bash
# E2E: crew-say's --ack-constraints gate (issue #192). A target with no
# recorded constraints is unaffected; a target WITH one or more is refused
# until --ack-constraints is passed, and the refusal reprints every recorded
# constraint so it cannot be silently forgotten. Placed after the team
# guardrail (tests/crew-say-guardrail.test.sh) in the send path - this file
# only ever spawns records already inside the caller's own team so guardrail
# refusals never interfere with what these assertions are isolating.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SAY="$TEST_REPO/bin/crew-say"

test_new_home
wm_state crew-add --id plain1 --type developer --objective x --repo /tmp \
  --window wm-plain1 --session-id s1 >/dev/null
wm_state crew-add --id bound1 --type lead --objective x --repo /tmp \
  --window wm-bound1 --session-id s2 \
  --constraint "go one at a time" >/dev/null
wm_state crew-add --id bound2 --type lead --objective x --repo /tmp \
  --window wm-bound2 --session-id s3 \
  --constraint "go one at a time" --constraint "never touch the payments repo" >/dev/null

# An unconstrained target: no gate friction at all - reaches "no live window"
# with no --ack-constraints.
out="$("$SAY" plain1 "how's it going" 2>&1)"
assert_contains "an unconstrained target passes with no --ack-constraints" "$out" "no live window"

# A constrained target: refused without --ack-constraints, and the refusal
# names the constraint.
out="$("$SAY" bound1 "run these in parallel to go faster" 2>&1)"
assert_contains "a constrained target is refused without --ack-constraints" "$out" "standing constraint"
assert_contains "...the refusal names the actual constraint text" "$out" "go one at a time"
assert_contains "...and points at the remedy" "$out" "--ack-constraints"
case "$out" in *"no live window"*) fail "should have been refused before reaching the window check" ;; *) ok "refused before the window check" ;; esac

# The same call WITH --ack-constraints passes the gate.
out="$("$SAY" --ack-constraints bound1 "run these in parallel to go faster" 2>&1)"
assert_contains "--ack-constraints lets the call through to the window check" "$out" "no live window"

# Multiple constraints: the refusal lists all of them, not just the first.
out="$("$SAY" bound2 "let's move faster" 2>&1)"
assert_contains "a multi-constraint refusal lists constraint 1" "$out" "go one at a time"
assert_contains "...and constraint 2" "$out" "never touch the payments repo"

# --force (the team-guardrail override) does NOT imply --ack-constraints -
# the two gates are independent. Use a cross-team target so --force is
# actually exercising the guardrail bypass, then confirm the constraint gate
# still fires afterward.
wm_state crew-add --id otherlead --type lead --objective y --repo /tmp \
  --window wm-otherlead --session-id s4 >/dev/null
wm_state crew-add --id otherbound --type developer --objective z --repo /tmp \
  --window wm-otherbound --session-id s5 --parent otherlead \
  --constraint "no merges before Friday" >/dev/null
out="$(WINGMAN_CREW_ID=bound1 "$SAY" --force otherbound "go ahead and merge today" 2>&1)"
assert_contains "--force clears the team guardrail but NOT the constraint gate" "$out" "standing constraint"
assert_contains "...naming the actual constraint" "$out" "no merges before Friday"

out="$(WINGMAN_CREW_ID=bound1 "$SAY" --force --ack-constraints otherbound "go ahead and merge today" 2>&1)"
assert_contains "both flags together pass both gates" "$out" "no live window"

unset WINGMAN_CREW_ID

test_summary
