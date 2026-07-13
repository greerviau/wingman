#!/usr/bin/env bash
# E2E: hooks/artifact-publish-tracker.sh, the PostToolUse/PostToolUseFailure
# marker writer behind hooks/artifact-link-guard.sh. A successful Artifact
# call records "published" (with URL and content hash), a failed one records
# "publish-failed" (with its own hash), a fail:-verdict artifact-scan.sh run
# records "scan-failed", a pass verdict records nothing, and unrelated tool
# calls write nothing at all.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TRACKER="$TEST_REPO/hooks/artifact-publish-tracker.sh"
SID="sess-pub"

marker_field() {
  # marker_field <path> <field>
  uv run --no-project --quiet python -c "
import json, sys
store = json.load(open('$WINGMAN_HOME/artifact-markers/$SID.json'))
entry = store.get(sys.argv[1]) or {}
print(entry.get(sys.argv[2]) or '')" "$1" "$2" 2>/dev/null
}

sha_of() { uv run --no-project --quiet python -c "
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())" "$1"; }

test_new_home
WORK="$(wm_mktemp_dir)"
DOC="$WORK/plan.md"
printf '# a plan\n' > "$DOC"
DOC_REAL="$(uv run --no-project --quiet python -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$DOC")"

# --- an unrelated tool call writes nothing --------------------------------------
printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":"git status"},"tool_response":{"stdout":"clean"}}' "$SID" "$WORK" | bash "$TRACKER"
assert_false "an unrelated Bash call writes no marker file" "[ -f '$WINGMAN_HOME/artifact-markers/$SID.json' ]"

# --- a successful Artifact call records published + URL + current hash ----------
printf '{"hook_event_name":"PostToolUse","tool_name":"Artifact","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"},"tool_response":{"url":"https://claude.ai/code/artifact/abc123","path":"%s"}}' "$SID" "$WORK" "$DOC" "$DOC" | bash "$TRACKER"
assert_eq "a successful Artifact call records published" "$(marker_field "$DOC_REAL" status)" "published"
assert_eq "the published record carries the URL" "$(marker_field "$DOC_REAL" url)" "https://claude.ai/code/artifact/abc123"
assert_eq "the published record hashes the file's current contents" "$(marker_field "$DOC_REAL" sha256)" "$(sha_of "$DOC")"

# --- a text-shaped tool_response still yields the URL ----------------------------
DOC2="$WORK/report.md"
printf '# a report\n' > "$DOC2"
DOC2_REAL="$(uv run --no-project --quiet python -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$DOC2")"
printf '{"hook_event_name":"PostToolUse","tool_name":"Artifact","session_id":"%s","cwd":"%s","tool_input":{"file_path":"report.md"},"tool_response":"Published report.md at https://claude.ai/code/artifact/def456\\n\\nTo update: republish."}' "$SID" "$WORK" | bash "$TRACKER"
assert_eq "a relative file_path resolves against the hook cwd" "$(marker_field "$DOC2_REAL" status)" "published"
assert_eq "the URL is extracted from a text response" "$(marker_field "$DOC2_REAL" url)" "https://claude.ai/code/artifact/def456"

# --- a failed/refused Artifact call records publish-failed with its own hash ----
DOC3="$WORK/failed.md"
printf '# will fail\n' > "$DOC3"
DOC3_REAL="$(uv run --no-project --quiet python -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$DOC3")"
printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Artifact","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"},"error":"Artifact publish failed: upstream 503"}' "$SID" "$WORK" "$DOC3" | bash "$TRACKER"
assert_eq "a failed Artifact call records publish-failed" "$(marker_field "$DOC3_REAL" status)" "publish-failed"
assert_contains "the failure reason is captured" "$(marker_field "$DOC3_REAL" reason)" "upstream 503"
assert_eq "the failed record still hashes the file (staleness applies to it too)" "$(marker_field "$DOC3_REAL" sha256)" "$(sha_of "$DOC3")"

# --- entries accumulate per path, not overwrite wholesale ------------------------
assert_eq "the earlier published record survives later writes" "$(marker_field "$DOC_REAL" status)" "published"

# --- a fail:-verdict artifact-scan.sh run records scan-failed --------------------
DOC4="$WORK/secret.md"
printf '# secrets\n' > "$DOC4"
DOC4_REAL="$(uv run --no-project --quiet python -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$DOC4")"
printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":"$TEST_REPO/bin/lib/artifact-scan.sh %s"},"error":"Exit code 1\\nfail:matches a credential/secret pattern (gitleaks)"}' "$SID" "$WORK" "$DOC4" | bash "$TRACKER"
assert_eq "a fail: verdict records scan-failed" "$(marker_field "$DOC4_REAL" status)" "scan-failed"

# --- a pass/pass-soft verdict records nothing ------------------------------------
DOC5="$WORK/clean.md"
printf '# clean\n' > "$DOC5"
DOC5_REAL="$(uv run --no-project --quiet python -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$DOC5")"
printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":"$TEST_REPO/bin/lib/artifact-scan.sh %s"},"tool_response":{"stdout":"pass","stderr":""}}' "$SID" "$WORK" "$DOC5" | bash "$TRACKER"
assert_eq "a pass verdict records nothing" "$(marker_field "$DOC5_REAL" status)" ""

# --- a failing NON-scan Bash command records nothing ------------------------------
printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":"cat %s"},"error":"Exit code 1\\nfail:looks-like-a-verdict-but-not-a-scan"}' "$SID" "$WORK" "$DOC5" | bash "$TRACKER"
assert_eq "a failing non-scan command records nothing" "$(marker_field "$DOC5_REAL" status)" ""

# --- cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56):
# command_segments() returns None rather than a partial segment list. This
# tracker is a best-effort PostToolUse recorder, not a deny-gate, so it must
# not crash on that - just record nothing.
out="$(printf '{"hook_event_name":"PostToolUseFailure","tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":"artifact-scan.sh '"'"'oops"},"error":"Exit code 1\\nfail:whatever"}' "$SID" "$WORK" | bash "$TRACKER")"
assert_eq "an unresolvable artifact-scan.sh invocation does not crash the tracker (no output)" "$out" ""

test_summary
