#!/usr/bin/env bash
# E2E: bin/lib/usage-statusline.py, the statusLine command wingman installs
# to capture the Claude Code CLI's own proactive usage-quota signal (issue
# #24). No tmux needed - pure stdin-in/file-out invocations.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SCRIPT="$TEST_REPO/bin/lib/usage-statusline.py"
FIXTURE="$TEST_REPO/tests/fixtures/statusline-payload-with-rate-limits.json"

run_statusline() {
  # run_statusline <stdin-json> [extra args...]
  _stdin="$1"; shift
  printf '%s' "$_stdin" | uv run --no-project --quiet "$SCRIPT" "$@"
}

# ============================================================================
# A full, schema-accurate payload (tests/fixtures/statusline-payload-with-
# rate-limits.json) - every field the CLI's own embedded statusLine schema
# doc describes (byte-for-byte verified against the installed binary,
# /home/agents/.local/share/claude/versions/2.1.210, during this plan's own
# investigation and independently re-verified in round-2 review), not just a
# hand-picked minimal shape. This is the cheapest available guard against
# the schema having subtly drifted from what the doc string claims, short of
# spending real account quota to capture a live transcript (declined here as
# out of proportion for a test fixture - the whole point of this feature is
# not to waste quota).
# ============================================================================
test_new_home
run_statusline "$(cat "$FIXTURE")" >/dev/null
WRITTEN="$WINGMAN_HOME/usage/550e8400-e29b-41d4-a716-446655440000.json"
assert_true "the full fixture payload writes a per-session file" "[ -f '$WRITTEN' ]"
assert_contains "five_hour used_percentage is captured" "$(cat "$WRITTEN")" '"used_percentage": 62.5'
assert_contains "five_hour resets_at is captured" "$(cat "$WRITTEN")" '"resets_at": 1784160000'
assert_contains "seven_day used_percentage is captured" "$(cat "$WRITTEN")" '"used_percentage": 18.3'
assert_contains "seven_day resets_at is captured" "$(cat "$WRITTEN")" '"resets_at": 1784500000'
assert_contains "captured_at is stamped" "$(cat "$WRITTEN")" '"captured_at"'

# ============================================================================
# A minimal payload with only five_hour present (seven_day absent, as the
# schema documents both being independently optional).
# ============================================================================
test_new_home
run_statusline '{"session_id": "s-five-only", "rate_limits": {"five_hour": {"used_percentage": 10, "resets_at": 1999999999}}}' >/dev/null
WRITTEN="$WINGMAN_HOME/usage/s-five-only.json"
assert_true "a five_hour-only payload still writes a file" "[ -f '$WRITTEN' ]"
assert_contains "five_hour is present" "$(cat "$WRITTEN")" 'five_hour'
assert_not_contains "seven_day is absent from the written record" "$(cat "$WRITTEN")" 'seven_day'

# ============================================================================
# No rate_limits at all (a non-subscription session, or one with no first
# API response yet): no-op - no file, no directory even.
# ============================================================================
test_new_home
run_statusline '{"session_id": "s-no-limits", "model": {"id": "x", "display_name": "x"}}' >/dev/null
assert_false "no rate_limits at all: no per-session file is written" \
  "[ -f '$WINGMAN_HOME/usage/s-no-limits.json' ]"

# rate_limits present but both sub-keys empty (an edge shape, still "no
# usable data") is the same no-op.
test_new_home
run_statusline '{"session_id": "s-empty-limits", "rate_limits": {}}' >/dev/null
assert_false "an empty rate_limits object: no per-session file is written" \
  "[ -f '$WINGMAN_HOME/usage/s-empty-limits.json' ]"

# ============================================================================
# --chain re-execs the pilot's own prior statusline command with the same
# stdin and passes its stdout straight through unchanged, so installing this
# never silently changes what the pilot visually sees in their terminal.
# ============================================================================
test_new_home
FAKE_STATUSLINE="$(wm_mktemp_file)"
cat > "$FAKE_STATUSLINE" <<'FAKE'
#!/bin/sh
cat >/dev/null
printf 'MY CUSTOM STATUSLINE OUTPUT'
FAKE
chmod +x "$FAKE_STATUSLINE"
out="$(run_statusline '{"session_id": "s-chain", "rate_limits": {"five_hour": {"used_percentage": 5, "resets_at": 1999999999}}}' --chain "$FAKE_STATUSLINE")"
assert_eq "chained stdout passes through unchanged" "$out" "MY CUSTOM STATUSLINE OUTPUT"
assert_true "the capture side effect still happens while chaining" "[ -f '$WINGMAN_HOME/usage/s-chain.json' ]"

# Without --chain, nothing is printed (crew sessions run unattended).
test_new_home
out="$(run_statusline '{"session_id": "s-nochain", "rate_limits": {"five_hour": {"used_percentage": 5, "resets_at": 1999999999}}}')"
assert_eq "no --chain: nothing is printed to stdout" "$out" ""

# ============================================================================
# Never raises or exits non-zero: bad JSON, an unwritable directory, or a
# broken chained command are all swallowed so a broken usage probe can never
# break the pilot's terminal or a crew session's startup.
# ============================================================================
test_new_home
out="$(printf 'not json at all' | uv run --no-project --quiet "$SCRIPT"; echo "rc=$?")"
assert_contains "malformed stdin JSON never crashes (exit 0)" "$out" "rc=0"

test_new_home
out="$(run_statusline '{"session_id": "s-badchain", "rate_limits": {"five_hour": {"used_percentage": 5, "resets_at": 1999999999}}}' --chain /no/such/command/anywhere; echo "rc=$?")"
assert_contains "an unresolvable --chain command never crashes (exit 0)" "$out" "rc=0"
assert_true "the capture side effect still happens despite the broken chain" "[ -f '$WINGMAN_HOME/usage/s-badchain.json' ]"

# A payload with no session_id at all is a no-op regardless of rate_limits
# (the per-session filename has nothing to key on).
test_new_home
run_statusline '{"rate_limits": {"five_hour": {"used_percentage": 90, "resets_at": 1999999999}}}' >/dev/null
assert_false "no session_id: no usage directory is created at all" \
  "[ -d '$WINGMAN_HOME/usage' ]"

test_summary
