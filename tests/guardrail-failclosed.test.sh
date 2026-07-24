#!/usr/bin/env bash
# E2E: the team guardrail fails CLOSED, loudly, when the policy cannot run
# (robustness audit finding 3). A broken state engine used to yield an empty/
# `no-target` verdict that crew-say/crew-ask silently treated as allow - the
# guardrail was disabled with no signal. Now an unreadable roster refuses with
# a distinct "could not run" message, and --force remains the human override.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SAY="$TEST_REPO/bin/crew-say"
ASK="$TEST_REPO/bin/crew-ask"

# WM_UV=false makes every `wm_state` invocation fail immediately - the
# state-engine-broken shape (uv missing, wm-state.py unrunnable).
test_new_home

out="$(WM_UV=false "$SAY" someone "hello" 2>&1)" && rc=0 || rc=$?
assert_true "crew-say refuses when the guardrail cannot run" "[ $rc -ne 0 ]"
assert_contains "the refusal says the guardrail could not run, not that policy denied" \
  "$out" "team guardrail could not run"
assert_contains "the refusal names --force as the human override" "$out" "--force"

out="$(WM_UV=false "$ASK" someone "a question" 2>&1)" && rc=0 || rc=$?
assert_true "crew-ask refuses when the guardrail cannot run" "[ $rc -ne 0 ]"
assert_contains "crew-ask's refusal says the guardrail could not run" \
  "$out" "team guardrail could not run"

# --force still bypasses (a human can always override); it then proceeds to
# the window check, which is how we prove the guardrail was skipped.
out="$(WM_UV=false "$SAY" --force someone "hello" 2>&1)" && rc=0 || rc=$?
assert_contains "--force bypasses the failed guardrail to the window check" \
  "$out" "no live window"

# A healthy engine with an unknown target still passes through to the window
# check (no-target has never been a deny - an orphan window may legitimately
# exist without a roster record).
out="$("$SAY" ghost "hello" 2>&1)" && rc=0 || rc=$?
assert_contains "an unknown target still reaches the window check" "$out" "no live window"

test_summary
