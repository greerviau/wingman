#!/usr/bin/env bash
# E2E: all three of wingman's session-creation choke points - bin/wingman,
# bin/spawn-crew, bin/crew-resume - reconcile user-scope guard hooks (via
# bin/lib/sync-user-hooks.py) immediately before a Claude Code session
# starts, and refuse to create that session at all if the reconcile fails
# (issue #241). bin/crew-resume is not an edge case here: it writes its own
# launcher and opens its own tmux window rather than going through
# bin/spawn-crew, so it needs the identical wiring proven separately.
#
# The unit-level reconciler behavior (fresh/idempotent/partial/--check/fail-
# closed/concurrency) is covered in tests/sync-user-hooks.test.sh; this file
# only proves each entry point actually calls it, in the right place, with
# the right fail-closed consequence.
#
# A "repo mirror" is used to force a sync failure at each choke point without
# ever touching the real checkout's own hooks/ scripts (which other tests
# running concurrently may depend on): bin/ is symlinked in whole (so every
# script's own logic, including the real sync-user-hooks.py, is exercised
# unmodified), while hooks/ is a real directory of individually symlinked
# scripts with exactly one broken. The mirror is deliberately not a git repo,
# so bin/wingman's checkout-freshness advisory (step 6) fails fast
# ("not a git repo") instead of attempting a real network fetch.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

WINGMAN="$TEST_REPO/bin/wingman"
SPAWN="$TEST_REPO/bin/spawn-crew"
CRESUME="$TEST_REPO/bin/crew-resume"

export WM_SPAWN_DELAY=0 WM_SUBMIT_DELAY=0 WM_READY_TRIES=4 WM_READY_POLL=0 \
  WM_SUBMIT_POLL=0.2 WM_SUBMIT_TRIES=1 WM_PLAYBOOKS="$TEST_REPO/playbooks"

# mk_mirror <target_dir> [<hook_script_relpath> [missing|noexec]]
# A mirror of $TEST_REPO's bin/ (whole-directory symlink, so every script's
# own real logic runs) plus a hooks/ directory of individually symlinked
# scripts. With no third argument, every hook is present and executable
# (a "healthy" mirror); with one, that one script is broken.
mk_mirror() {
  _mm_dir="$1"; _mm_script="${2:-}"; _mm_mode="${3:-}"
  mkdir -p "$_mm_dir"
  ln -s "$TEST_REPO/bin" "$_mm_dir/bin"
  mkdir -p "$_mm_dir/hooks"
  for f in "$TEST_REPO"/hooks/*; do
    [ -f "$f" ] || continue
    _mm_base="$(basename "$f")"
    if [ -n "$_mm_script" ] && [ "hooks/$_mm_base" = "$_mm_script" ]; then
      case "$_mm_mode" in
        missing) continue ;;
        noexec)
          cp "$f" "$_mm_dir/hooks/$_mm_base"
          chmod -x "$_mm_dir/hooks/$_mm_base"
          continue
          ;;
      esac
    fi
    ln -s "$f" "$_mm_dir/hooks/$_mm_base"
  done
}

registered_count() {
  # Count of registered hook commands across every event in a settings file.
  uv run --no-project --quiet python -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(0); sys.exit(0)
n = 0
for groups in (d.get('hooks') or {}).values():
    for g in groups:
        n += len(g.get('hooks', []))
print(n)
" "$1"
}

MANIFEST_COUNT="$(uv run --no-project --quiet python -c "
import json
d = json.load(open('$TEST_REPO/bin/lib/user-hooks.json'))
print(sum(len(g['hooks']) for g in d['groups']))
")"

# =============================================================================
# test 11: all three choke points reconcile before the session is created
# =============================================================================

# --- bin/wingman -------------------------------------------------------------
test_new_home
MIRROR_OK1="$(wm_mktemp_dir)/mirror-ok"
mk_mirror "$MIRROR_OK1"
STUBDIR1="$(wm_mktemp_dir)"
CLAUDE_MARKER1="$STUBDIR1/invoked"
cat > "$STUBDIR1/claude" <<EOF
#!/usr/bin/env bash
printf 'STUB_CLAUDE_INVOKED %s\n' "\$*" > "$CLAUDE_MARKER1"
exit 0
EOF
chmod +x "$STUBDIR1/claude"
out11a="$(PATH="$STUBDIR1:$PATH" "$MIRROR_OK1/bin/wingman" 2>&1)"; rc11a=$?
wm_stop_guardian
assert_eq "bin/wingman: a healthy repo exits 0" "$rc11a" "0"
assert_true "bin/wingman: claude was execed (session created)" "[ -f '$CLAUDE_MARKER1' ]"
assert_eq "bin/wingman: every manifest hook is registered before exec" \
  "$(registered_count "$WM_CLAUDE_USER_SETTINGS")" "$MANIFEST_COUNT"
assert_false "bin/wingman: the failure sink is absent after a clean launch" \
  "[ -f '$WINGMAN_HOME/last-launch-failure' ]"

# --- bin/spawn-crew ------------------------------------------------------------
test_new_home
MIRROR_OK2="$(wm_mktemp_dir)/mirror-ok"
mk_mirror "$MIRROR_OK2"
TARGET_REPO2="$(wm_mktemp_dir)/target-repo"
mkdir -p "$TARGET_REPO2"
git -C "$TARGET_REPO2" init -q
wm_trust_repo "$TARGET_REPO2"
STUB2="$(wm_mktemp_dir)/stub.sh"
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$STUB2"; chmod +x "$STUB2"
GID11B="wiring-spawn-ok"
out11b="$(WM_AGENT="$STUB2" "$MIRROR_OK2/bin/spawn-crew" --type software-analyst --repo "$TARGET_REPO2" --id "$GID11B" --objective "wiring reconciles" 2>&1)"
rc11b=$?
assert_eq "bin/spawn-crew: a healthy repo exits 0" "$rc11b" "0"
assert_true "bin/spawn-crew: the roster record was created" "wm_state crew-get --id '$GID11B' >/dev/null 2>&1"
assert_eq "bin/spawn-crew: every manifest hook is registered before the window opens" \
  "$(registered_count "$WM_CLAUDE_USER_SETTINGS")" "$MANIFEST_COUNT"

# --- bin/crew-resume -----------------------------------------------------------
test_new_home
MIRROR_OK3="$(wm_mktemp_dir)/mirror-ok"
mk_mirror "$MIRROR_OK3"
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id wiring-resume-ok --type developer --objective x --repo /tmp --window wm-wiring-resume-ok --session-id sess-wro >/dev/null
wm_state crew-set --id wiring-resume-ok --status died >/dev/null
STUB3="$(wm_mktemp_dir)/stub.sh"
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$STUB3"; chmod +x "$STUB3"
out11c="$(WM_AGENT="$STUB3" "$MIRROR_OK3/bin/crew-resume" wiring-resume-ok 2>&1)"
assert_contains "bin/crew-resume: a healthy repo resumes the member" "$out11c" "1 resumed"
assert_eq "bin/crew-resume: every manifest hook is registered before the window opens" \
  "$(registered_count "$WM_CLAUDE_USER_SETTINGS")" "$MANIFEST_COUNT"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# =============================================================================
# test 12: all three refuse outright on a sync failure - nothing half-created
# =============================================================================

# --- bin/wingman -------------------------------------------------------------
test_new_home
MIRROR_BAD1="$(wm_mktemp_dir)/mirror-bad"
mk_mirror "$MIRROR_BAD1" "hooks/no-direct-edit-guard.sh" missing
STUBDIR4="$(wm_mktemp_dir)"
CLAUDE_MARKER4="$STUBDIR4/invoked"
cat > "$STUBDIR4/claude" <<EOF
#!/usr/bin/env bash
printf 'STUB_CLAUDE_INVOKED %s\n' "\$*" > "$CLAUDE_MARKER4"
exit 0
EOF
chmod +x "$STUBDIR4/claude"
out12a="$(PATH="$STUBDIR4:$PATH" "$MIRROR_BAD1/bin/wingman" 2>&1)"; rc12a=$?
wm_stop_guardian
assert_true "bin/wingman: a broken repo exits non-zero" "[ $rc12a -ne 0 ]"
assert_false "bin/wingman: claude was never execed" "[ -f '$CLAUDE_MARKER4' ]"
assert_contains "bin/wingman: the refusal names the remedy" "$out12a" "bin/doctor -y"

# --- bin/spawn-crew ------------------------------------------------------------
test_new_home
MIRROR_BAD2="$(wm_mktemp_dir)/mirror-bad"
mk_mirror "$MIRROR_BAD2" "hooks/no-direct-edit-guard.sh" missing
TARGET_REPO3="$(wm_mktemp_dir)/target-repo"
mkdir -p "$TARGET_REPO3"
git -C "$TARGET_REPO3" init -q
wm_trust_repo "$TARGET_REPO3"
GID12B="wiring-spawn-bad"
out12b="$(WM_AGENT="$STUB2" "$MIRROR_BAD2/bin/spawn-crew" --type software-analyst --repo "$TARGET_REPO3" --id "$GID12B" --objective "wiring refuses" 2>&1)"
rc12b=$?
assert_true "bin/spawn-crew: a broken repo exits non-zero" "[ $rc12b -ne 0 ]"
assert_false "bin/spawn-crew: no roster record was created" "wm_state crew-get --id '$GID12B' >/dev/null 2>&1"
assert_false "bin/spawn-crew: no tmux window was created" \
  "tmux list-windows -t '=$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx 'wm-$GID12B'"

# --- bin/crew-resume -----------------------------------------------------------
test_new_home
MIRROR_BAD3="$(wm_mktemp_dir)/mirror-bad"
mk_mirror "$MIRROR_BAD3" "hooks/no-direct-edit-guard.sh" missing
tmux new-session -d -s "$WM_TMUX_SESSION" -n _wm_idle
wm_state crew-add --id wiring-resume-bad --type developer --objective x --repo /tmp --window wm-wiring-resume-bad --session-id sess-wrb >/dev/null
wm_state crew-set --id wiring-resume-bad --status died >/dev/null
out12c="$(WM_AGENT="$STUB3" "$MIRROR_BAD3/bin/crew-resume" wiring-resume-bad 2>&1)"; rc12c=$?
assert_true "bin/crew-resume: a broken repo exits non-zero" "[ $rc12c -ne 0 ]"
assert_eq "bin/crew-resume: the member stays died" \
  "$(wm_state crew-get --id wiring-resume-bad | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("status"))')" "died"
assert_false "bin/crew-resume: no window was created" \
  "tmux list-windows -t '=$WM_TMUX_SESSION' -F '#{window_name}' 2>/dev/null | grep -qx wm-wiring-resume-bad"
assert_false "bin/crew-resume: no .resume.sh launcher was written" \
  "[ -f '$WINGMAN_HOME/crew/wiring-resume-bad.resume.sh' ]"

# --all-died refuses the whole batch, not a partial one (step 5's requirement:
# hoisted once per invocation, so one bad reconcile blocks every member).
wm_state crew-add --id wiring-resume-bad2 --type developer --objective y --repo /tmp --window wm-wiring-resume-bad2 --session-id sess-wrb2 >/dev/null
wm_state crew-set --id wiring-resume-bad2 --status died >/dev/null
out12d="$(WM_AGENT="$STUB3" "$MIRROR_BAD3/bin/crew-resume" --all-died 2>&1)"; rc12d=$?
assert_true "bin/crew-resume --all-died: a broken repo exits non-zero" "[ $rc12d -ne 0 ]"
assert_eq "bin/crew-resume --all-died: first member stays died" \
  "$(wm_state crew-get --id wiring-resume-bad | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("status"))')" "died"
assert_eq "bin/crew-resume --all-died: second member also stays died (not a partial recovery)" \
  "$(wm_state crew-get --id wiring-resume-bad2 | uv run --no-project --quiet python -c 'import sys,json;print(json.load(sys.stdin).get("status"))')" "died"
tmux kill-session -t "$WM_TMUX_SESSION" 2>/dev/null

# =============================================================================
# test 13: the failure sink is written and cleared (MF-2)
# =============================================================================
test_new_home
MIRROR_BAD4="$(wm_mktemp_dir)/mirror-bad"
mk_mirror "$MIRROR_BAD4" "hooks/no-direct-edit-guard.sh" missing
STUBDIR5="$(wm_mktemp_dir)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR5/claude"; chmod +x "$STUBDIR5/claude"
PATH="$STUBDIR5:$PATH" "$MIRROR_BAD4/bin/wingman" >/dev/null 2>&1
wm_stop_guardian
assert_true "the failure sink is written on a forced sync failure" "[ -f '$WINGMAN_HOME/last-launch-failure' ]"
sink_content="$(cat "$WINGMAN_HOME/last-launch-failure" 2>/dev/null)"
assert_contains "the sink names the guard-hook-sync component" "$sink_content" "guard-hook sync"
assert_contains "the sink names the missing script's path" "$sink_content" "no-direct-edit-guard.sh"
ts_line="$(sed -n 1p "$WINGMAN_HOME/last-launch-failure")"
case "$ts_line" in
  *T*Z*guard-hook*) ok "the sink's first line carries a timestamp and the component" ;;
  *) fail "the sink's first line carries a timestamp and the component" ;;
esac

# doctor surfaces it near the top of its own output while it is present.
doctor_out="$("$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_contains "bin/doctor surfaces the recorded launch failure" "$doctor_out" "the most recent session launch refused to start"
assert_contains "bin/doctor's surfaced message names the component" "$doctor_out" "guard-hook sync"

# A subsequent successful launch clears it.
MIRROR_OK4="$(wm_mktemp_dir)/mirror-ok"
mk_mirror "$MIRROR_OK4"
PATH="$STUBDIR5:$PATH" "$MIRROR_OK4/bin/wingman" >/dev/null 2>&1
wm_stop_guardian
assert_false "a successful launch clears the failure sink" "[ -f '$WINGMAN_HOME/last-launch-failure' ]"

# doctor no longer surfaces anything once it is cleared.
doctor_out2="$("$TEST_REPO/bin/doctor" -y < /dev/null 2>&1)"
assert_false "bin/doctor no longer mentions a launch failure once cleared" \
  "printf '%s' '$doctor_out2' | grep -q 'the most recent session launch refused to start'"

test_summary
