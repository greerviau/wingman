#!/usr/bin/env bash
# E2E: wm-state pilot-location-get/set, ask 3's condition B shared cache
# (design: docs/plans/2026-07-12-remote-control-visibility-and-auto-reconnect-
# design.md). Proves the answer is scoped to a wingman run id - a fresh run (or
# no answer yet) is "unanswered", never a stale carry-over from a prior run.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

test_new_home

# --- unanswered: no file yet ---------------------------------------------------
assert_false "no cached answer yet: get fails" "wm_state pilot-location-get --run-id run-a >/dev/null 2>&1"

# --- set, then get with the SAME run id: answered -------------------------------
wm_state pilot-location-set --run-id run-a --remote true >/dev/null
out="$(wm_state pilot-location-get --run-id run-a)"; rc=$?
assert_eq "a cached 'remote' answer is returned for the same run" "$rc" "0"
assert_eq "the value is exactly 'true'" "$out" "true"

wm_state pilot-location-set --run-id run-a --remote false >/dev/null
out="$(wm_state pilot-location-get --run-id run-a)"; rc=$?
assert_eq "overwriting with 'false' is readable for the same run" "$rc" "0"
assert_eq "the value is exactly 'false'" "$out" "false"

# --- a different run id: treated as unanswered (never a stale carry-over) -------
wm_state pilot-location-set --run-id run-a --remote true >/dev/null
assert_false "a fresh run id sees no answer, even though run-a has one" \
  "wm_state pilot-location-get --run-id run-b >/dev/null 2>&1"

# --- the file itself is the documented shape ------------------------------------
assert_true "pilot-location.json exists after a set" "[ -f '$WINGMAN_HOME/pilot-location.json' ]"
assert_contains "it records the run id" "$(cat "$WINGMAN_HOME/pilot-location.json")" "run-a"
assert_contains "it records the remote flag" "$(cat "$WINGMAN_HOME/pilot-location.json")" '"remote": true'

test_summary
