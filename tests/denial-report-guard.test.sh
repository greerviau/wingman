#!/usr/bin/env bash
# E2E: hooks/denial-report-guard.sh (issue #214, Defect B's mechanical
# backstop). A Stop hook that blocks the moment a crew session's transcript
# shows a `toolDenialKind: "user-rejected"` record it has not already
# reported - the one denial kind carrying no remedy of its own (unlike
# `permission-rule`/`automode-blocked`) - naming the denied command and
# whether it was a live interrupt or an ungranted permission. Dedups per
# (crew id, denial uuid) so a single denial only ever blocks one Stop.
# Fails OPEN on any parse/IO problem (the opposite of this repo's other
# guards): this gates ending a turn, not an action that must not happen.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
test_new_home
mkdir -p "$WINGMAN_HOME"

HOOK="$TEST_REPO/hooks/denial-report-guard.sh"

write_jsonl() {
  # write_jsonl <path> <line>... - one JSON object literal per remaining arg.
  _path="$1"; shift
  : > "$_path"
  for _line in "$@"; do
    printf '%s\n' "$_line" >> "$_path"
  done
}

run_hook() {
  # run_hook <stop-json>
  printf '%s' "$1" | bash "$HOOK"
}

stop_payload() {
  # stop_payload <transcript-path> [stop_hook_active: true|false (default false)]
  uv run --no-project --quiet python -c '
import json, sys
path, active = sys.argv[1], sys.argv[2]
payload = {"session_id": "test-session", "transcript_path": path, "cwd": "/tmp",
           "permission_mode": "bypassPermissions", "hook_event_name": "Stop"}
if active == "true":
    payload["stop_hook_active"] = True
print(json.dumps(payload))
' "$1" "${2:-false}"
}

TDIR="$(wm_mktemp_dir)"

# --- a fresh user-rejected denial blocks, naming the denied command ---------
TRANSCRIPT1="$TDIR/t1.jsonl"
write_jsonl "$TRANSCRIPT1" \
  '{"type":"assistant","uuid":"u-tooluse-1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"bin/crew-say lead hello"}}]}}' \
  '{"type":"user","uuid":"u-denial-1","timestamp":"2026-08-03T19:42:31.032Z","toolDenialKind":"user-rejected","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"tool_use_id":"toolu_1","content":"The user doesn'"'"'t want to proceed with this tool use. STOP what you are doing and wait for the user to tell you how to proceed."}]}}' \
  '{"type":"text","uuid":"u-interrupt-1","text":"[Request interrupted by user for tool use]","interruptedMessageId":"toolu_1"}'
export WINGMAN_CREW_ID=denial-guard-t1
out1="$(run_hook "$(stop_payload "$TRANSCRIPT1")")"
assert_contains "a fresh user-rejected denial blocks the Stop" "$out1" '"decision": "block"'
assert_contains "the reason names the denied command" "$out1" "bin/crew-say lead hello"
assert_contains "the reason identifies it as a live interrupt" "$out1" "interrupt"
assert_contains "the reason instructs reporting blocked" "$out1" "report \`blocked\`"

# --- the SAME transcript again (unresolved) does not re-block (dedup) -------
out1b="$(run_hook "$(stop_payload "$TRANSCRIPT1")")"
assert_eq "the identical denial never blocks a second Stop" "$out1b" ""

# --- a permission-rule-only transcript never blocks -------------------------
TRANSCRIPT2="$TDIR/t2.jsonl"
write_jsonl "$TRANSCRIPT2" \
  '{"type":"user","uuid":"u-denial-2","toolDenialKind":"permission-rule","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"tool_use_id":"toolu_2","content":"denied by hooks/no-merge-guard.sh: use the admin override"}]}}'
export WINGMAN_CREW_ID=denial-guard-t2
out2="$(run_hook "$(stop_payload "$TRANSCRIPT2")")"
assert_eq "a permission-rule denial (carries its own remedy) never blocks" "$out2" ""

# --- an automode-blocked-only transcript never blocks -----------------------
TRANSCRIPT3="$TDIR/t3.jsonl"
write_jsonl "$TRANSCRIPT3" \
  '{"type":"user","uuid":"u-denial-3","toolDenialKind":"automode-blocked","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"tool_use_id":"toolu_3","content":"try other tools; if essential, STOP and explain to the user"}]}}'
export WINGMAN_CREW_ID=denial-guard-t3
out3="$(run_hook "$(stop_payload "$TRANSCRIPT3")")"
assert_eq "an automode-blocked denial (carries its own remedy) never blocks" "$out3" ""

# --- stop_hook_active=true never blocks (never loop) ------------------------
export WINGMAN_CREW_ID=denial-guard-t4
out4="$(run_hook "$(stop_payload "$TRANSCRIPT1" true)")"
assert_eq "stop_hook_active suppresses the block unconditionally" "$out4" ""

# --- WINGMAN_CREW_ID unset: never blocks, stdin still drained ---------------
unset WINGMAN_CREW_ID
out5="$(run_hook "$(stop_payload "$TRANSCRIPT1")" 2>&1)"
assert_eq "wingman's own top-level session (no crew id) is never gated" "$out5" ""

# --- a missing transcript file fails open (no block) ------------------------
export WINGMAN_CREW_ID=denial-guard-t6
out6="$(run_hook "$(stop_payload "$TDIR/does-not-exist.jsonl")")"
assert_eq "a missing transcript_path fails open" "$out6" ""

# --- a truncated/garbled transcript fails open (no block) -------------------
TRANSCRIPT7="$TDIR/t7.jsonl"
printf '{"type":"user","toolDenialKind":"user-rejected", NOT VALID JSON\n' > "$TRANSCRIPT7"
export WINGMAN_CREW_ID=denial-guard-t7
out7="$(run_hook "$(stop_payload "$TRANSCRIPT7")")"
assert_eq "a truncated/garbled transcript line fails open" "$out7" ""

# --- a malformed Stop payload itself fails open ------------------------------
export WINGMAN_CREW_ID=denial-guard-t8
out8="$(printf 'NOT VALID JSON AT ALL' | bash "$HOOK")"
assert_eq "a malformed Stop payload fails open" "$out8" ""

# --- an ungranted-permission flavour (no interrupt marker) is named as such -
TRANSCRIPT9="$TDIR/t9.jsonl"
write_jsonl "$TRANSCRIPT9" \
  '{"type":"assistant","uuid":"u-tooluse-9","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"Read","input":{"file_path":"/etc/secret"}}]}}' \
  '{"type":"user","uuid":"u-denial-9","toolDenialKind":"user-rejected","message":{"role":"user","content":[{"type":"tool_result","is_error":true,"tool_use_id":"toolu_9","content":"Claude requested permissions to read from /etc/secret, but you haven'"'"'t granted it yet."}]}}'
export WINGMAN_CREW_ID=denial-guard-t9
out9="$(run_hook "$(stop_payload "$TRANSCRIPT9")")"
assert_contains "an ungranted-permission denial (no interrupt marker) still blocks" "$out9" '"decision": "block"'
assert_contains "the reason identifies it as an ungranted permission, not an interrupt" "$out9" "ungranted permission"
assert_false "the ungranted-permission reason never claims an interrupt" "printf '%s' \"$out9\" | grep -q 'live interrupt'"

unset WINGMAN_CREW_ID

test_summary
