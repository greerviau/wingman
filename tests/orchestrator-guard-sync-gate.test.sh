#!/usr/bin/env bash
# E2E: hooks/orchestrator-guard-sync-gate.sh (claude PreToolUse) and hooks/
# session-init.sh (claude SessionStart) - the two claude entry points into
# the shared orchestrator bootstrap routine (docs/analysis/2026-08-18-
# remove-bin-wingman-launcher-spec.md, §4.5, §8 step 7). bin/wingman's own
# two-gate ordering (continuity BEFORE guard-transport, refusing outright on
# a missing continuity transport) is retired along with the launcher itself
# - §4.6 replaces that refusal with a one-time, non-blocking notice, so
# there is only ONE gate left to prove here: the guard-transport reconcile+
# self-test, fail-closed via the PreToolUse hook.
#
# Proves:
#   (a) a healthy repo: the first tool call bootstraps successfully and is
#       allowed (silence); the cache means a second call costs nothing.
#   (b) a broken repo (missing hook script): every tool call is denied,
#       naming the remedy, EXCEPT the two allowlisted retry commands
#       (a direct orchestrator-bootstrap.sh invocation, and bin/doctor -y).
#   (c) session-init.sh cannot literally block a session (it has no deny
#       mechanism), but surfaces the same failure as additionalContext.
#   (d) the continuity-transport notice (§4.6): a stubbed adapter with no
#       continuity transport gets a one-time notice via session-init.sh's
#       additionalContext, consumed once (a second SessionStart-shaped call
#       never repeats it).
#
# Every refusal happens before any real work: the guard hook mirrors, not a
# copy of the real checkout's own hooks/ (which other tests running
# concurrently may depend on).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mk_mirror() {
  # mk_mirror <target_dir> [<hook_script_relpath> missing]
  _mm_dir="$1"; _mm_missing="${2:-}"
  mkdir -p "$_mm_dir"
  ln -s "$TEST_REPO/bin" "$_mm_dir/bin"
  mkdir -p "$_mm_dir/hooks"
  ln -s "$TEST_REPO/hooks/lib" "$_mm_dir/hooks/lib"
  for f in "$TEST_REPO"/hooks/*; do
    [ -f "$f" ] || continue
    _mm_base="$(basename "$f")"
    [ "hooks/$_mm_base" = "$_mm_missing" ] && continue
    ln -s "$f" "$_mm_dir/hooks/$_mm_base"
  done
}

GATE="$TEST_REPO/hooks/orchestrator-guard-sync-gate.sh"
SI="$TEST_REPO/hooks/session-init.sh"

# =============================================================================
# (a) a healthy repo: allowed, and the second call is a cheap cache hit
# =============================================================================
test_new_home
MIRROR_A="$(wm_mktemp_dir)/mirror-healthy"
mk_mirror "$MIRROR_A"

out_a1="$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  CLAUDE_PROJECT_DIR="$MIRROR_A" WINGMAN_RUN_ID="gate-a" bash "$MIRROR_A/hooks/orchestrator-guard-sync-gate.sh")"
assert_eq "healthy repo: the first tool call is allowed (silence)" "$out_a1" ""

STATUS_FILE_A="$WINGMAN_HOME/orchestrator-bootstrap/gate-a.outcome"
assert_true "healthy repo: a pass outcome was cached" "grep -q pass '$STATUS_FILE_A'"

# Second call: same identity, cached - prove it's cheap by asserting no NEW
# guard-transport reconcile ran (the settings file's own mtime is unchanged).
_mtime_before="$(stat -c %Y "$WM_CLAUDE_USER_SETTINGS" 2>/dev/null || stat -f %m "$WM_CLAUDE_USER_SETTINGS" 2>/dev/null)"
sleep 1.1
out_a2="$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  CLAUDE_PROJECT_DIR="$MIRROR_A" WINGMAN_RUN_ID="gate-a" bash "$MIRROR_A/hooks/orchestrator-guard-sync-gate.sh")"
_mtime_after="$(stat -c %Y "$WM_CLAUDE_USER_SETTINGS" 2>/dev/null || stat -f %m "$WM_CLAUDE_USER_SETTINGS" 2>/dev/null)"
assert_eq "healthy repo: the second tool call is also allowed" "$out_a2" ""
assert_eq "healthy repo: the settings file was NOT rewritten on the cached call (fast path, no reconcile)" \
  "$_mtime_before" "$_mtime_after"

# =============================================================================
# (b) a broken repo: every ordinary tool call is denied, but both retry
# shapes are allowed through regardless
# =============================================================================
test_new_home
MIRROR_B="$(wm_mktemp_dir)/mirror-bad"
mk_mirror "$MIRROR_B" "hooks/no-direct-edit-guard.sh"

out_b1="$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | \
  CLAUDE_PROJECT_DIR="$MIRROR_B" WINGMAN_RUN_ID="gate-b" bash "$MIRROR_B/hooks/orchestrator-guard-sync-gate.sh")"
assert_contains "broken repo: an ordinary tool call is denied" "$out_b1" '"permissionDecision": "deny"'
assert_contains "broken repo: the denial names the remedy" "$out_b1" "bin/doctor -y"

out_b_retry1="$(echo '{"tool_name":"Bash","tool_input":{"command":"bin/lib/orchestrator-bootstrap.sh --agent claude"}}' | \
  CLAUDE_PROJECT_DIR="$MIRROR_B" WINGMAN_RUN_ID="gate-b" bash "$MIRROR_B/hooks/orchestrator-guard-sync-gate.sh")"
assert_eq "broken repo: a direct orchestrator-bootstrap.sh retry is allowed through" "$out_b_retry1" ""

out_b_retry2="$(echo '{"tool_name":"Bash","tool_input":{"command":"bin/doctor -y"}}' | \
  CLAUDE_PROJECT_DIR="$MIRROR_B" WINGMAN_RUN_ID="gate-b" bash "$MIRROR_B/hooks/orchestrator-guard-sync-gate.sh")"
assert_eq "broken repo: a bin/doctor -y retry is allowed through" "$out_b_retry2" ""

out_b_chained="$(echo '{"tool_name":"Bash","tool_input":{"command":"bin/doctor -y && rm -rf /tmp/nonexistent"}}' | \
  CLAUDE_PROJECT_DIR="$MIRROR_B" WINGMAN_RUN_ID="gate-b" bash "$MIRROR_B/hooks/orchestrator-guard-sync-gate.sh")"
assert_contains "broken repo: chaining a retry with anything else does NOT qualify" "$out_b_chained" '"permissionDecision": "deny"'

out_b2="$(echo '{"tool_name":"Edit","tool_input":{"file_path":"x.py"}}' | \
  CLAUDE_PROJECT_DIR="$MIRROR_B" WINGMAN_RUN_ID="gate-b" bash "$MIRROR_B/hooks/orchestrator-guard-sync-gate.sh")"
assert_contains "broken repo: a non-Bash tool call is denied too (no escape hatch for it)" "$out_b2" '"permissionDecision": "deny"'

# =============================================================================
# (c) session-init.sh cannot block, but surfaces the identical failure
# =============================================================================
test_new_home
MIRROR_C="$(wm_mktemp_dir)/mirror-bad-si"
mk_mirror "$MIRROR_C" "hooks/no-direct-edit-guard.sh"
out_c="$(echo '{}' | CLAUDE_PROJECT_DIR="$MIRROR_C" WINGMAN_RUN_ID="gate-c" bash "$MIRROR_C/hooks/session-init.sh")"; rc_c=$?
assert_eq "session-init.sh itself still exits 0 (SessionStart cannot block)" "$rc_c" "0"
assert_contains "session-init.sh reports the bootstrap failure as additionalContext" "$out_c" "guard-hook bootstrap FAILED"
assert_contains "session-init.sh's context names the same remedy" "$out_c" "no-direct-edit-guard.sh"

# =============================================================================
# (d) the fleet-continuity notice (§4.6): a stubbed adapter with no
# continuity transport gets a one-time notice, consumed exactly once
# =============================================================================
# bin/lib/orchestrator-bootstrap.sh always runs the full bootstrap when
# invoked directly (it has no internal caching of its own - see its own
# header comment); the lazy, once-per-identity gating is the CALLER's job.
# claude's own real descriptor already has a wired continuity transport, so
# a stub with none is used here to prove the notice fires at all.
STUB_DESC="$TEST_REPO/bin/lib/agents/__test-gate-no-continuity-stub.sh"
cat > "$STUB_DESC" <<'EOF'
WM_AGENT_BIN="claude"
WM_AGENT_DISPLAY_NAME="Test Gate No-Continuity Stub"
WM_AGENT_GUARD_TRANSPORT=claude-json
WM_AGENT_CONTINUITY_TRANSPORT=""
WM_AGENT_REMOTE_CONTROL_FLAG=""
EOF

test_new_home
MIRROR_D="$(wm_mktemp_dir)/mirror-notice"
mk_mirror "$MIRROR_D"
out_d1="$(WINGMAN_RUN_ID="gate-d" "$MIRROR_D/bin/lib/orchestrator-bootstrap.sh" --agent __test-gate-no-continuity-stub --repo "$MIRROR_D" 2>&1)"; rc_d1=$?
assert_eq "no-continuity stub: the bootstrap still passes (guard transport is fine)" "$rc_d1" "0"
NOTICE_FILE_D="$WINGMAN_HOME/orchestrator-bootstrap/gate-d.notice"
assert_true "no-continuity stub: a notice was written" "[ -f '$NOTICE_FILE_D' ]"
assert_contains "the notice names the gap honestly (not built, not impossible)" \
  "$(cat "$NOTICE_FILE_D" 2>/dev/null)" "has not been built"
rm -f "$STUB_DESC"

# The notice-CONSUMPTION contract - write once, a reader deletes it, a
# CACHED (not re-bootstrapped) call never sees it regenerated - is a
# property of the real CALLER-side caching, not of bin/lib/orchestrator-
# bootstrap.sh itself (which has none). hooks/lib/guard_dispatch.py's own
# _orchestrator_bootstrap_gate is that caller for the four non-Claude
# dialects, and every real descriptor among them already has an empty
# continuity transport - no stub needed. opencode is used here (not
# codex/pi) specifically because its own reconcile needs no real binary on
# PATH at all (bin/lib/guard-transport.sh's own _wm_gt_sync_opencode never
# checks `wm_have`) - this section runs unconditionally, on every machine
# including CI, rather than SKIPping wherever the real CLI happens to be
# absent (review round 1: a codex-gated version of this section SKIPped in
# CI and never actually ran there).
test_new_home
MIRROR_E="$(wm_mktemp_dir)/mirror-notice-real"
mk_mirror "$MIRROR_E"
unset WM_AGENT_BIN_OVERRIDE
GUARDS_E="$(uv run --no-project --quiet "$TEST_REPO/bin/lib/hook_manifest.py" --print-guards opencode --repo "$MIRROR_E")"
payload_e='{"tool":"bash","args":{"command":"ls"},"cwd":"'"$MIRROR_E"'"}'
HOME_E="$(wm_mktemp_dir)"

out_e1="$(printf '%s' "$payload_e" | \
  HOME="$HOME_E" WINGMAN_RUN_ID="gate-e" WINGMAN_CREW_ID="" \
  uv run --no-project --quiet "$MIRROR_E/hooks/lib/guard_dispatch.py" --dialect opencode --guards "$GUARDS_E" 2>&1)"; rc_e1=$?
assert_true "opencode orchestrator: the first tool call is denied ONCE, as the notice" "[ $rc_e1 -eq 2 ]"
assert_contains "the notice text names the continuity gap" "$out_e1" "has not been built"

out_e2="$(printf '%s' "$payload_e" | \
  HOME="$HOME_E" WINGMAN_RUN_ID="gate-e" WINGMAN_CREW_ID="" \
  uv run --no-project --quiet "$MIRROR_E/hooks/lib/guard_dispatch.py" --dialect opencode --guards "$GUARDS_E" 2>&1)"; rc_e2=$?
assert_true "opencode orchestrator: reissuing the identical command now proceeds (notice consumed)" "[ $rc_e2 -eq 0 ]"
assert_eq "the reissued call's own output carries the explicit allow verdict (opencode has no silent-allow contract)" "$out_e2" '{"decision": "allow"}'

# Regression test for the cwd-CONTAINMENT fix (round-1 review, live-
# reproduced): _is_orchestrator_session used to compare cwd to the repo root
# by exact equality, so a tool call whose cwd was a repo SUBDIRECTORY (an
# entirely ordinary thing mid-session) never triggered the bootstrap gate at
# all. $MIRROR_F/hooks is a genuine, non-symlinked subdirectory of the
# mirror (mk_mirror mkdir's it directly; only the files inside are
# symlinked), so this exercises real containment, not equality-by-accident.
test_new_home
MIRROR_F="$(wm_mktemp_dir)/mirror-notice-subdir"
mk_mirror "$MIRROR_F"
unset WM_AGENT_BIN_OVERRIDE
GUARDS_F="$(uv run --no-project --quiet "$TEST_REPO/bin/lib/hook_manifest.py" --print-guards opencode --repo "$MIRROR_F")"
payload_f='{"tool":"bash","args":{"command":"ls"},"cwd":"'"$MIRROR_F/hooks"'"}'
HOME_F="$(wm_mktemp_dir)"

out_f1="$(printf '%s' "$payload_f" | \
  HOME="$HOME_F" WINGMAN_RUN_ID="gate-f" WINGMAN_CREW_ID="" \
  uv run --no-project --quiet "$MIRROR_F/hooks/lib/guard_dispatch.py" --dialect opencode --guards "$GUARDS_F" 2>&1)"; rc_f1=$?
assert_true "opencode orchestrator from a repo SUBDIRECTORY: still denied ONCE, as the notice" "[ $rc_f1 -eq 2 ]"
assert_contains "the notice text names the continuity gap" "$out_f1" "has not been built"
assert_true "the bootstrap actually ran from a subdirectory cwd (the cache file exists)" \
  "[ -f '$WINGMAN_HOME/orchestrator-bootstrap/gate-f.outcome' ]"

out_f2="$(printf '%s' "$payload_f" | \
  HOME="$HOME_F" WINGMAN_RUN_ID="gate-f" WINGMAN_CREW_ID="" \
  uv run --no-project --quiet "$MIRROR_F/hooks/lib/guard_dispatch.py" --dialect opencode --guards "$GUARDS_F" 2>&1)"; rc_f2=$?
assert_true "reissuing from the same subdirectory cwd now proceeds (notice consumed)" "[ $rc_f2 -eq 0 ]"
assert_eq "the reissued call's own output carries the explicit allow verdict" "$out_f2" '{"decision": "allow"}'

test_summary
