#!/usr/bin/env bash
# E2E: wm-state pref-get/pref-set/prefs-list, the per-run onboarding-preference
# store (preferences.json). Proves answers are scoped to a wingman run id - a
# fresh run (or no answer yet) is "unanswered", never a stale carry-over from a
# prior run - and that multiple keys merge within one run.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

test_new_home

# --- unanswered: no file yet ---------------------------------------------------
assert_false "no cached answer yet: pref-get fails" \
  "wm_state pref-get --run-id run-a --key remote >/dev/null 2>&1"
out="$(wm_state prefs-list --run-id run-a)"
assert_eq "prefs-list prints nothing for an unanswered run" "$out" ""

# --- set, then get with the SAME run id: answered -------------------------------
wm_state pref-set --run-id run-a --key remote --value true >/dev/null
out="$(wm_state pref-get --run-id run-a --key remote)"; rc=$?
assert_eq "a cached 'remote' answer is returned for the same run" "$rc" "0"
assert_eq "the value is exactly 'true'" "$out" "true"

wm_state pref-set --run-id run-a --key remote --value false >/dev/null
out="$(wm_state pref-get --run-id run-a --key remote)"; rc=$?
assert_eq "overwriting a key's value is readable for the same run" "$rc" "0"
assert_eq "the value is exactly 'false'" "$out" "false"

# --- multi-key merge: a second key joins the first, both stay readable ----------
wm_state pref-set --run-id run-a --key artifact_linking --value artifact >/dev/null
out="$(wm_state pref-get --run-id run-a --key remote)"
assert_eq "the first key survives setting a second" "$out" "false"
out="$(wm_state pref-get --run-id run-a --key artifact_linking)"
assert_eq "the second key reads back individually" "$out" "artifact"
out="$(wm_state prefs-list --run-id run-a)"
assert_eq "prefs-list returns both keys as key<TAB>value lines" "$out" "$(printf 'artifact_linking\tartifact\nremote\tfalse')"

# --- an unset key on an answered run is still unanswered -------------------------
assert_false "an unset key fails pref-get even when other keys are set" \
  "wm_state pref-get --run-id run-a --key verbosity >/dev/null 2>&1"

# --- a different run id: treated as unanswered (never a stale carry-over) -------
assert_false "a fresh run id sees no answer, even though run-a has one" \
  "wm_state pref-get --run-id run-b --key remote >/dev/null 2>&1"
out="$(wm_state prefs-list --run-id run-b)"
assert_eq "prefs-list is empty for a fresh run id" "$out" ""

# --- the first set under a new run id replaces the file wholesale ---------------
wm_state pref-set --run-id run-b --key verbosity --value concise >/dev/null
assert_false "run-a's keys are gone after run-b's first set" \
  "wm_state pref-get --run-id run-a --key remote >/dev/null 2>&1"
out="$(wm_state prefs-list --run-id run-b)"
assert_eq "run-b holds only its own key" "$out" "$(printf 'verbosity\tconcise')"

# --- the file itself is the documented shape ------------------------------------
assert_true "preferences.json exists after a set" "[ -f '$WINGMAN_HOME/preferences.json' ]"
assert_contains "it records the run id" "$(cat "$WINGMAN_HOME/preferences.json")" '"wingman_run_id": "run-b"'
assert_contains "it nests values under a prefs dict" "$(cat "$WINGMAN_HOME/preferences.json")" '"prefs"'
assert_contains "it records the value" "$(cat "$WINGMAN_HOME/preferences.json")" '"verbosity": "concise"'

test_summary
