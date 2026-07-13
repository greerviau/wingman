#!/usr/bin/env bash
# E2E: hooks/artifact-link-guard.sh, the PreToolUse gate enforcing the crew
# status contract's Artifact-publish condition at report time. A crew member
# reporting a markdown deliverable via `crew-set --status review|done` while
# artifact_linking=artifact is cached for the run is denied unless the
# tracker's marker shows the deliverable was published (current hash), a
# publish attempt failed (current hash), or artifact-scan.sh said not to
# publish. Both call shapes are covered: an explicit --artifact on the call,
# and a bare status change resolved from the member's crew record.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

GUARD="$TEST_REPO/hooks/artifact-link-guard.sh"
TRACKER="$TEST_REPO/hooks/artifact-publish-tracker.sh"
SID="sess-link"

run_guard() {
  # run_guard <bash command string>
  printf '{"tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":"%s"}}' "$SID" "$WORK" "$1" | bash "$GUARD"
}
publish_ok() {
  printf '{"hook_event_name":"PostToolUse","tool_name":"Artifact","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"},"tool_response":{"url":"https://claude.ai/code/artifact/x"}}' "$SID" "$WORK" "$1" | bash "$TRACKER"
}
publish_failed() {
  printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Artifact","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"},"error":"Artifact publish failed"}' "$SID" "$WORK" "$1" | bash "$TRACKER"
}
scan_failed() {
  printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":"bin/lib/artifact-scan.sh %s"},"error":"Exit code 1\\nfail:not under a crew-deliverable directory"}' "$SID" "$WORK" "$1" | bash "$TRACKER"
}

test_new_home
WORK="$(wm_mktemp_dir)"
PLAN="$WORK/plan.md"
printf '# the plan\n' > "$PLAN"

export WINGMAN_CREW_ID=m1
export WINGMAN_RUN_ID=run-link
wm_state pref-set --run-id run-link --key artifact_linking --value artifact >/dev/null
wm_state crew-add --id m1 --type software-analyst --objective x --repo "$WORK" --window wm-m1 --session-id "$SID" >/dev/null

# --- shape 1: explicit --artifact on the call ------------------------------------
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review --artifact $PLAN")"
assert_contains "review with explicit .md artifact and no marker: denied" "$out" '"permissionDecision": "deny"'
assert_contains "the denial names the deliverable" "$out" "$PLAN"
assert_contains "the denial names the scan+publish path" "$out" "artifact-scan.sh"
assert_contains "the denial names the blocked escape hatch" "$out" "blocked"

# The literal $WINGMAN_STATE form (uv run + flags) must be recognized as the
# same gated call, not silently unrecognized-and-allowed.
out="$(run_guard "uv run --no-project --quiet $TEST_REPO/bin/lib/wm-state.py crew-set --id m1 --status review --artifact $PLAN")"
assert_contains "the literal \$WINGMAN_STATE crew-set form is gated too" "$out" '"permissionDecision": "deny"'

publish_ok "$PLAN"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review --artifact $PLAN")"
assert_eq "allowed once a current published marker exists" "$out" ""

printf 'revised content\n' >> "$PLAN"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review --artifact $PLAN")"
assert_contains "denied again once the file changed after publish (stale)" "$out" '"permissionDecision": "deny"'
assert_contains "the stale denial says the file was edited since" "$out" "edited since"

publish_failed "$PLAN"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review --artifact $PLAN")"
assert_eq "allowed once a current publish-failed marker exists (escapable failure)" "$out" ""

printf 'more revisions\n' >> "$PLAN"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review --artifact $PLAN")"
assert_contains "a stale publish-failed marker still denies" "$out" '"permissionDecision": "deny"'

scan_failed "$PLAN"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review --artifact $PLAN")"
assert_eq "allowed once a scan-failed marker exists (correctly skipped publish)" "$out" ""

# --- shape 2: bare --status review, artifact resolved from the crew record -------
REPORT="$WORK/findings.md"
printf '# findings\n' > "$REPORT"
wm_state crew-set --id m1 --artifact "$REPORT" >/dev/null
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review")"
assert_contains "bare review with a recorded .md artifact and no marker: denied" "$out" '"permissionDecision": "deny"'
assert_contains "the record's path is the one named" "$out" "$REPORT"

publish_ok "$REPORT"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review")"
assert_eq "bare review allowed once the record's path has a current marker" "$out" ""

printf 'revised\n' >> "$REPORT"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review")"
assert_contains "bare review denied when the record's marker went stale" "$out" '"permissionDecision": "deny"'

# --- review/done symmetry (the reviewer-type terminal delivery) -------------------
DONE_DOC="$WORK/review-findings.md"
printf '# reviewer findings\n' > "$DONE_DOC"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status done --artifact $DONE_DOC")"
assert_contains "done with explicit .md artifact and no marker: denied" "$out" '"permissionDecision": "deny"'

publish_ok "$DONE_DOC"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status done --artifact $DONE_DOC")"
assert_eq "done allowed once a current marker exists" "$out" ""

wm_state crew-set --id m1 --artifact "$DONE_DOC" >/dev/null
printf 'late edit\n' >> "$DONE_DOC"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status done")"
assert_contains "bare done resolved from the record: denied when stale" "$out" '"permissionDecision": "deny"'

publish_ok "$DONE_DOC"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status done")"
assert_eq "bare done allowed once republished" "$out" ""

# --- unconditional allows ----------------------------------------------------------
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status working --summary progressing")"
assert_eq "a working status change is never gated" "$out" ""

TXT="$WORK/notes.txt"
printf 'notes\n' > "$TXT"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review --artifact $TXT")"
assert_eq "a non-markdown artifact is never gated" "$out" ""

out="$(run_guard "git status")"
assert_eq "an unrelated Bash command is never gated" "$out" ""

wm_state crew-add --id m2 --type reviewer --objective y --repo "$WORK" --window wm-m2 --session-id sess-m2 >/dev/null
out="$(run_guard "bin/lib/wm-state.py crew-set --id m2 --status review")"
assert_eq "a member with no artifact anywhere is never gated" "$out" ""

wm_state pref-set --run-id run-link --key artifact_linking --value local >/dev/null
NEW_DOC="$WORK/another.md"
printf '# another\n' > "$NEW_DOC"
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review --artifact $NEW_DOC")"
assert_eq "artifact_linking=local: never gated" "$out" ""
wm_state pref-set --run-id run-link --key artifact_linking --value artifact >/dev/null

_saved_run_id="$WINGMAN_RUN_ID"
unset WINGMAN_RUN_ID
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review --artifact $NEW_DOC")"
assert_eq "no WINGMAN_RUN_ID: never gated (condition B defaults to local)" "$out" ""
export WINGMAN_RUN_ID="$_saved_run_id"

unset WINGMAN_CREW_ID
out="$(run_guard "bin/lib/wm-state.py crew-set --id m1 --status review --artifact $NEW_DOC")"
assert_eq "no WINGMAN_CREW_ID (not a crew session): never gated" "$out" ""

unset WINGMAN_RUN_ID

test_summary
