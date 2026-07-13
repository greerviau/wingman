#!/usr/bin/env bash
# E2E: hooks/pilot-preferences-ask-tracker.sh, the PostToolUse marker writer.
# A completed AskUserQuestion call writes $WINGMAN_HOME/prefs-asked-<session_id>
# (existence-only); any other tool call writes nothing.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TRACKER="$TEST_REPO/hooks/pilot-preferences-ask-tracker.sh"

test_new_home

printf '{"tool_name":"Bash","session_id":"sess-tr","tool_input":{"command":"ls"},"tool_response":{}}' | bash "$TRACKER"
assert_false "an unrelated tool call writes no marker" "[ -f '$WINGMAN_HOME/prefs-asked-sess-tr' ]"

printf '{"tool_name":"AskUserQuestion","session_id":"sess-tr","tool_input":{},"tool_response":{}}' | bash "$TRACKER"
assert_true "a completed AskUserQuestion writes the marker" "[ -f '$WINGMAN_HOME/prefs-asked-sess-tr' ]"

# Session ids are sanitized into the filename (no path traversal).
printf '{"tool_name":"AskUserQuestion","session_id":"a/b c","tool_input":{},"tool_response":{}}' | bash "$TRACKER"
assert_true "a hostile session id is sanitized" "[ -f '$WINGMAN_HOME/prefs-asked-a_b_c' ]"

# Idempotent: a second completion is a no-op, not an error.
printf '{"tool_name":"AskUserQuestion","session_id":"sess-tr","tool_input":{},"tool_response":{}}' | bash "$TRACKER"
assert_true "a second AskUserQuestion leaves the marker in place" "[ -f '$WINGMAN_HOME/prefs-asked-sess-tr' ]"

test_summary
