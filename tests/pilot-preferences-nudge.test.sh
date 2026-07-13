#!/usr/bin/env bash
# E2E: hooks/pilot-preferences-nudge.sh, the SessionStart context injection
# naming every still-missing onboarding preference. Front-loaded visibility
# only - the guard is the enforcement - so it emits for every SessionStart
# source and stays silent when fully answered or inactive.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

NUDGE="$TEST_REPO/hooks/pilot-preferences-nudge.sh"

run_nudge() { printf '{"session_id":"sess-nudge","source":"%s"}' "${1:-startup}" | bash "$NUDGE"; }

OUTSIDE_DIR="$(wm_mktemp_dir)"

test_new_home
export CLAUDE_PROJECT_DIR="$TEST_REPO"
export WINGMAN_RUN_ID="run-nudge"
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# --- everything missing: every prompt is named, for every source ---------------
for src in startup resume clear compact; do
  out="$(run_nudge "$src")"
  assert_contains "source=$src: emits additionalContext" "$out" '"additionalContext"'
  assert_contains "source=$src: names the remote prompt" "$out" "Remote Control right now"
  assert_contains "source=$src: names the artifact_linking prompt" "$out" "hosted Artifact link"
  assert_contains "source=$src: names the verbosity prompt" "$out" "narrate my own reasoning"
  assert_contains "source=$src: names the direct_spawn_visibility prompt" "$out" "each round of a revise loop"
  assert_contains "source=$src: points at the one batched ask" "$out" "ONE batched AskUserQuestion"
  # The same concrete, absolute command the guard derives and verifies, so the
  # front-loaded instruction and the enforced one are one string.
  assert_contains "source=$src: quotes the concrete absolute pref-set command" \
    "$out" "$TEST_REPO/bin/lib/wm-state.py pref-set"
  assert_contains "source=$src: fills in the actual run id" "$out" "run-nudge"
done

# --- partially answered: only what is left is named -----------------------------
wm_state pref-set --run-id run-nudge --key remote --value false >/dev/null
out="$(run_nudge startup)"
assert_contains "partially answered: still emits" "$out" '"additionalContext"'
assert_not_contains "partially answered: the answered prompt is gone" "$out" "Remote Control right now"
assert_contains "partially answered: a missing prompt is still named" "$out" "hosted Artifact link"

# --- fully answered: silent ------------------------------------------------------
wm_state pref-set --run-id run-nudge --key artifact_linking --value local >/dev/null
wm_state pref-set --run-id run-nudge --key verbosity --value concise >/dev/null
wm_state pref-set --run-id run-nudge --key direct_spawn_visibility --value each-round >/dev/null
out="$(run_nudge startup)"
assert_eq "fully answered: no output" "$out" ""

# --- the state engine is unusable: say so, do not ask the unanswerable -----------
# A session starting into a broken install learns it here, rather than through a
# wall of denials it cannot act on: no preference can be cached, so the guard has
# failed open and the questions are pointless.
FIXTURE="$(wm_mktemp_dir)/broken-repo"
mkdir -p "$FIXTURE/hooks/lib" "$FIXTURE/bin/lib"   # bin/lib deliberately left empty
cp "$TEST_REPO/hooks/pilot-preferences-nudge.sh" "$FIXTURE/hooks/"
cp "$TEST_REPO/hooks/lib/pilot-prefs.sh" "$FIXTURE/hooks/lib/"

test_new_home
export CLAUDE_PROJECT_DIR="$FIXTURE"
export WINGMAN_RUN_ID="run-nudge-broken"
out="$(printf '{"session_id":"sess-nudge","source":"startup"}' | bash "$FIXTURE/hooks/pilot-preferences-nudge.sh")"
assert_contains "engine unusable: still emits additionalContext" "$out" '"additionalContext"'
assert_contains "engine unusable: says the engine cannot be used" "$out" "unusable"
assert_contains "engine unusable: says the guard has failed open" "$out" "failed open"
assert_not_contains "engine unusable: does not ask questions it cannot cache" \
  "$out" "ONE batched AskUserQuestion"

# --- inactive shapes -------------------------------------------------------------
test_new_home
export CLAUDE_PROJECT_DIR="$TEST_REPO"
unset WINGMAN_RUN_ID
out="$(run_nudge startup)"
assert_eq "no WINGMAN_RUN_ID: no output" "$out" ""

export WINGMAN_RUN_ID="run-nudge2"
export WINGMAN_CREW_ID=w1
out="$(run_nudge startup)"
assert_eq "a crew session: no output" "$out" ""

unset WINGMAN_CREW_ID
export CLAUDE_PROJECT_DIR="$OUTSIDE_DIR"
out="$(run_nudge startup)"
assert_eq "a non-wingman project root: no output" "$out" ""

unset CLAUDE_PROJECT_DIR WINGMAN_RUN_ID

test_summary
