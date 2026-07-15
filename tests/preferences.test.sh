#!/usr/bin/env bash
# E2E: wm-state pref-get/pref-set/prefs-list, the per-run onboarding-preference
# store (preferences.json). Proves answers are scoped to a wingman run id - a
# fresh run (or no answer yet) is "unanswered" - that multiple keys merge within
# one run, and that two concurrently-alive run ids each keep their own cached
# answers without clobbering each other (issue #85).
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

# --- a different, not-yet-answered run id: treated as unanswered ----------------
assert_false "a fresh run id sees no answer, even though run-a has one" \
  "wm_state pref-get --run-id run-b --key remote >/dev/null 2>&1"
out="$(wm_state prefs-list --run-id run-b)"
assert_eq "prefs-list is empty for a fresh run id" "$out" ""

# --- issue #85: a second run id's first set does NOT clobber the first run -----
wm_state pref-set --run-id run-b --key verbosity --value concise >/dev/null
out="$(wm_state pref-get --run-id run-a --key remote)"; rc=$?
assert_eq "run-a's answer survives run-b's first set" "$rc" "0"
assert_eq "run-a's value is unchanged" "$out" "false"
out="$(wm_state prefs-list --run-id run-a)"
assert_eq "run-a still holds both of its own keys" "$out" "$(printf 'artifact_linking\tartifact\nremote\tfalse')"
out="$(wm_state prefs-list --run-id run-b)"
assert_eq "run-b holds only its own key" "$out" "$(printf 'verbosity\tconcise')"

# --- both runs keep answering independently, interleaved ------------------------
wm_state pref-set --run-id run-a --key direct_spawn_visibility --value each-round >/dev/null
wm_state pref-set --run-id run-b --key remote --value true >/dev/null
out="$(wm_state pref-get --run-id run-a --key direct_spawn_visibility)"
assert_eq "run-a's newest key reads back" "$out" "each-round"
out="$(wm_state pref-get --run-id run-b --key remote)"
assert_eq "run-b's newest key reads back" "$out" "true"
out="$(wm_state prefs-list --run-id run-a)"
assert_eq "run-a is unaffected by run-b's later set" "$out" \
  "$(printf 'artifact_linking\tartifact\ndirect_spawn_visibility\teach-round\nremote\tfalse')"

# --- the file itself is keyed by run id, not a single top-level slot ------------
assert_true "preferences.json exists after a set" "[ -f '$WINGMAN_HOME/preferences.json' ]"
assert_contains "it nests run-a's values under its own run id" "$(cat "$WINGMAN_HOME/preferences.json")" '"run-a"'
assert_contains "it nests run-b's values under its own run id" "$(cat "$WINGMAN_HOME/preferences.json")" '"run-b"'
assert_contains "run-a's value is recorded" "$(cat "$WINGMAN_HOME/preferences.json")" '"remote": "false"'
assert_contains "run-b's value is recorded" "$(cat "$WINGMAN_HOME/preferences.json")" '"remote": "true"'

# --- issue #92: legacy pre-#85 shape ({"wingman_run_id": ..., "prefs": {...}}) --
test_new_home

# Legacy-only file, matching run id reads successfully.
cat > "$WINGMAN_HOME/preferences.json" <<'EOF'
{"wingman_run_id": "run-x", "prefs": {"remote": "true"}}
EOF
out="$(wm_state pref-get --run-id run-x --key remote)"; rc=$?
assert_eq "a legacy-shape file answers for the run id it names" "$rc" "0"
assert_eq "the legacy value is exactly 'true'" "$out" "true"

# Legacy-only file, non-matching run id still reads as unanswered.
assert_false "a legacy-shape file does not answer for a different run id" \
  "wm_state pref-get --run-id run-y --key remote >/dev/null 2>&1"
out="$(wm_state prefs-list --run-id run-y)"
assert_eq "prefs-list is empty for a run id the legacy file doesn't name" "$out" ""

# A pref-set for a different run id fully migrates the legacy pair.
wm_state pref-set --run-id run-y --key verbosity --value concise >/dev/null
out="$(wm_state pref-get --run-id run-x --key remote)"; rc=$?
assert_eq "the legacy answer survives migration triggered by a different run" "$rc" "0"
assert_eq "the legacy value is unchanged after migration" "$out" "true"
out="$(wm_state pref-get --run-id run-y --key verbosity)"
assert_eq "the triggering run's own key reads back" "$out" "concise"
raw="$(cat "$WINGMAN_HOME/preferences.json")"
assert_contains "the migrated file nests run-x under its own run id" "$raw" '"run-x"'
assert_contains "the migrated file nests run-y under its own run id" "$raw" '"run-y"'
assert_not_contains "the migrated file no longer carries the legacy wingman_run_id key" "$raw" '"wingman_run_id"'
assert_not_contains "the migrated file no longer carries the legacy prefs key" "$raw" '"prefs"'

# Hybrid legacy + corrupt-entry file, string-variant corruption, does not crash.
test_new_home
cat > "$WINGMAN_HOME/preferences.json" <<'EOF'
{"wingman_run_id": "run-x", "prefs": {"remote": "true"}, "run-x": "garbage"}
EOF
assert_true "pref-set does not crash on a legacy pair plus a string-corrupt slot" \
  "wm_state pref-set --run-id run-x --key artifact_linking --value artifact >/dev/null 2>&1"
out="$(wm_state pref-get --run-id run-x --key remote)"
assert_eq "the migrated legacy answer survives string-corrupt-slot coercion" "$out" "true"
out="$(wm_state pref-get --run-id run-x --key artifact_linking)"
assert_eq "the newly-set key lands in the same healed slot" "$out" "artifact"

# Hybrid legacy + corrupt-entry file, list-variant corruption, does not crash.
test_new_home
cat > "$WINGMAN_HOME/preferences.json" <<'EOF'
{"wingman_run_id": "run-x", "prefs": {"remote": "true"}, "run-x": []}
EOF
assert_true "pref-set does not crash on a legacy pair plus a list-corrupt slot" \
  "wm_state pref-set --run-id run-x --key artifact_linking --value artifact >/dev/null 2>&1"
out="$(wm_state pref-get --run-id run-x --key remote)"
assert_eq "the migrated legacy answer survives list-corrupt-slot coercion" "$out" "true"
out="$(wm_state pref-get --run-id run-x --key artifact_linking)"
assert_eq "the newly-set key lands in the same healed slot (list-variant)" "$out" "artifact"

test_summary
