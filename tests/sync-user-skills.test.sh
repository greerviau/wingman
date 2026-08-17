#!/usr/bin/env bash
# E2E: bin/lib/sync-user-skills.py, the reconciler that installs the
# portable crew command vocabulary (.agents/skills/wingman-<verb>) into an
# agent CLI's own user-level skills directory (called from codex's and
# grok's own WM_AGENT_PREFLIGHT functions). Never touches a real developer
# machine's actual ~/.agents/skills, ~/.grok/skills, or
# ~/.config/opencode/skills - every --target here is a throwaway tmp dir.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SYNC="$TEST_REPO/bin/lib/sync-user-skills.py"
run_sync() { uv run --no-project --quiet "$SYNC" "$@"; }

WORK="$(wm_mktemp_dir)"

VERBS="ask blocked prune say status takeover watch"
VERB_COUNT=7

count_wingman_entries() {
  # $1 = target dir. Counts every wingman-<verb> name present, regardless
  # of whether it is a symlink or a real (copy-mode) directory.
  [ -d "$1" ] || { echo 0; return; }
  find "$1" -maxdepth 1 -name 'wingman-*' | wc -l | tr -d ' '
}

# --- test 1: fresh install (symlink mode, the default) -----------------------
TARGET1="$WORK/fresh/skills"
run_sync --target "$TARGET1" --repo "$TEST_REPO"
rc1=$?
assert_eq "fresh install: sync exits 0" "$rc1" "0"
assert_eq "fresh install: all seven verbs are installed" "$(count_wingman_entries "$TARGET1")" "$VERB_COUNT"
for v in $VERBS; do
  assert_true "fresh install: wingman-$v is a symlink" "[ -L '$TARGET1/wingman-$v' ]"
  resolved="$(uv run --no-project --quiet python -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$TARGET1/wingman-$v")"
  assert_eq "fresh install: wingman-$v resolves to the repo's own canonical skill" "$resolved" "$TEST_REPO/.agents/skills/wingman-$v"
  assert_true "fresh install: the symlink target's SKILL.md is readable through it" "[ -r '$TARGET1/wingman-$v/SKILL.md' ]"
done

# --- test 2: idempotence - a second run touches nothing -----------------------
before_mtime="$(stat -c %Y "$TARGET1/wingman-status" 2>/dev/null || stat -f %m "$TARGET1/wingman-status")"
sleep 1.1
out2="$(run_sync --target "$TARGET1" --repo "$TEST_REPO" 2>&1)"
rc2=$?
assert_eq "idempotent re-run: sync exits 0" "$rc2" "0"
assert_eq "idempotent re-run: no stderr output at all (nothing changed)" "$out2" ""
after_mtime="$(stat -c %Y "$TARGET1/wingman-status" 2>/dev/null || stat -f %m "$TARGET1/wingman-status")"
assert_eq "idempotent re-run: the symlink's mtime is unchanged (not recreated)" "$after_mtime" "$before_mtime"
assert_eq "idempotent re-run: still exactly seven entries" "$(count_wingman_entries "$TARGET1")" "$VERB_COUNT"

# --- test 3: --check is read-only, --report lists what's missing -------------
TARGET3="$WORK/check-only/skills"
if run_sync --target "$TARGET3" --repo "$TEST_REPO" --check >/dev/null 2>&1; then
  fail "--check against an absent target reports fully installed"
else
  ok "--check against an absent target reports something missing"
fi
assert_false "--check never creates the target directory" "[ -d '$TARGET3' ]"
report3="$(run_sync --target "$TARGET3" --repo "$TEST_REPO" --check --report 2>/dev/null)"
report3_lines="$(printf '%s\n' "$report3" | grep -c '^install:')"
assert_eq "--report lists all seven verbs as needing install" "$report3_lines" "$VERB_COUNT"
assert_contains "--report names wingman-status specifically" "$report3" "install: wingman-status"

# --- test 4: a moved repository re-points the links ---------------------------
# Build a second, independent copy of just the canonical skills tree (not the
# whole repo - sync-user-skills.py's --repo only ever reads .agents/skills/
# under it) to stand in for "the same repo, relocated".
MOVED_REPO="$WORK/moved-repo"
mkdir -p "$MOVED_REPO/.agents/skills"
cp -r "$TEST_REPO/.agents/skills/." "$MOVED_REPO/.agents/skills/"
TARGET4="$WORK/moved/skills"
run_sync --target "$TARGET4" --repo "$TEST_REPO" >/dev/null
resolved_before="$(uv run --no-project --quiet python -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$TARGET4/wingman-status")"
assert_eq "moved-repo test: starts out pointed at the original repo" "$resolved_before" "$TEST_REPO/.agents/skills/wingman-status"
out4="$(run_sync --target "$TARGET4" --repo "$MOVED_REPO" 2>&1)"
assert_contains "moved-repo test: the stale link is reported as installed (relinked)" "$out4" "installed:"
resolved_after="$(uv run --no-project --quiet python -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$TARGET4/wingman-status")"
assert_eq "moved-repo test: now points at the moved repo's own canonical skill" "$resolved_after" "$MOVED_REPO/.agents/skills/wingman-status"
assert_eq "moved-repo test: still exactly seven entries after the move" "$(count_wingman_entries "$TARGET4")" "$VERB_COUNT"

# --- test 5: a real directory at a wingman-* name is reported and skipped,
#             never clobbered --------------------------------------------------
TARGET5="$WORK/human-placed/skills"
mkdir -p "$TARGET5/wingman-status"
printf 'a human put this here, not the installer\n' > "$TARGET5/wingman-status/NOTE.txt"
out5="$(run_sync --target "$TARGET5" --repo "$TEST_REPO" 2>&1)"
rc5=$?
assert_eq "human-placed dir: sync still exits 0 (a skip is not a failure)" "$rc5" "0"
assert_contains "human-placed dir: a warning names wingman-status" "$out5" "warning: wingman-status:"
assert_contains "human-placed dir: the warning explains it is not managed by this installer" "$out5" "not managed by this installer"
assert_true "human-placed dir: still a real directory, not replaced with a symlink" "[ -d '$TARGET5/wingman-status' ] && [ ! -L '$TARGET5/wingman-status' ]"
assert_true "human-placed dir: the human's own file survives untouched" "[ -f '$TARGET5/wingman-status/NOTE.txt' ]"
assert_eq "human-placed dir: the human's file content is byte-identical" "$(cat "$TARGET5/wingman-status/NOTE.txt")" "a human put this here, not the installer"
# Every OTHER verb still installs normally - one blocked entry does not stop
# the rest from being reconciled.
assert_true "human-placed dir: every other verb still installed as a symlink" "[ -L '$TARGET5/wingman-ask' ]"
assert_eq "human-placed dir: six of seven verbs are managed symlinks, the seventh is the untouched real directory" \
  "$(count_wingman_entries "$TARGET5")" "$VERB_COUNT"
# A second run warns again (every run re-evaluates current state) but still
# never touches it.
out5b="$(run_sync --target "$TARGET5" --repo "$TEST_REPO" 2>&1)"
assert_contains "human-placed dir: re-run warns again" "$out5b" "warning: wingman-status:"
warn_count5b="$(printf '%s\n' "$out5b" | grep -c 'warning: wingman-status:')"
assert_eq "human-placed dir: the warning is printed exactly once per run, not duplicated" "$warn_count5b" "1"
assert_true "human-placed dir: NOTE.txt still survives the second run" "[ -f '$TARGET5/wingman-status/NOTE.txt' ]"

# --- test 6: a removed verb's link is cleaned up -------------------------------
# A repo copy missing one verb entirely, to prove the installer removes a
# managed link whose verb no longer exists upstream.
TRIMMED_REPO="$WORK/trimmed-repo"
mkdir -p "$TRIMMED_REPO/.agents/skills"
cp -r "$TEST_REPO/.agents/skills/." "$TRIMMED_REPO/.agents/skills/"
rm -rf "$TRIMMED_REPO/.agents/skills/wingman-watch"
TARGET6="$WORK/removed-verb/skills"
run_sync --target "$TARGET6" --repo "$TEST_REPO" >/dev/null
assert_true "removed-verb test: wingman-watch starts out installed" "[ -L '$TARGET6/wingman-watch' ]"
out6="$(run_sync --target "$TARGET6" --repo "$TRIMMED_REPO" 2>&1)"
assert_contains "removed-verb test: the removal is reported" "$out6" "removed:"
assert_false "removed-verb test: wingman-watch is gone" "[ -e '$TARGET6/wingman-watch' ]"
assert_eq "removed-verb test: exactly six entries remain" "$(count_wingman_entries "$TARGET6")" "$((VERB_COUNT - 1))"
# Syncing back against the full repo restores it.
run_sync --target "$TARGET6" --repo "$TEST_REPO" >/dev/null
assert_true "removed-verb test: syncing against the full repo again restores wingman-watch" "[ -L '$TARGET6/wingman-watch' ]"
assert_eq "removed-verb test: back to seven entries" "$(count_wingman_entries "$TARGET6")" "$VERB_COUNT"

# --- test 7: a non-wingman-* neighbour is never touched, read, or considered --
TARGET7="$WORK/neighbour/skills"
mkdir -p "$TARGET7/some-other-skill"
printf 'name: some-other-skill\ndescription: unrelated\n' > "$TARGET7/some-other-skill/SKILL.md"
run_sync --target "$TARGET7" --repo "$TEST_REPO" >/dev/null
assert_true "unrelated neighbour: some-other-skill/ survives untouched" "[ -d '$TARGET7/some-other-skill' ]"
assert_eq "unrelated neighbour: its SKILL.md is byte-identical" \
  "$(cat "$TARGET7/some-other-skill/SKILL.md")" "$(printf 'name: some-other-skill\ndescription: unrelated\n')"
assert_eq "unrelated neighbour: all seven wingman verbs installed alongside it" "$(count_wingman_entries "$TARGET7")" "$VERB_COUNT"

# --- test 8: copy mode - fresh install, idempotence, and drift repair --------
TARGET8="$WORK/copy-mode/skills"
run_sync --target "$TARGET8" --repo "$TEST_REPO" --mode copy >/dev/null
assert_false "copy mode: wingman-status is NOT a symlink" "[ -L '$TARGET8/wingman-status' ]"
assert_true "copy mode: wingman-status is a real directory with a real SKILL.md" "[ -f '$TARGET8/wingman-status/SKILL.md' ]"
assert_true "copy mode: a .wm-sync-hash marker is written" "[ -f '$TARGET8/wingman-status/.wm-sync-hash' ]"
assert_eq "copy mode: the copied content is byte-identical to the source" \
  "$(cat "$TARGET8/wingman-status/SKILL.md")" "$(cat "$TEST_REPO/.agents/skills/wingman-status/SKILL.md")"
out8_idem="$(run_sync --target "$TARGET8" --repo "$TEST_REPO" --mode copy 2>&1)"
assert_eq "copy mode: idempotent re-run produces no output" "$out8_idem" ""

# Drift: the copy is modified in place, and a re-sync must repair it back to
# match the repo's own (unmodified) source.
printf 'CORRUPTED\n' >> "$TARGET8/wingman-status/SKILL.md"
out8_drift="$(run_sync --target "$TARGET8" --repo "$TEST_REPO" --mode copy 2>&1)"
assert_contains "copy mode: drift is detected and repaired" "$out8_drift" "installed:"
assert_not_contains "copy mode: the corruption is gone after reconcile" "$(cat "$TARGET8/wingman-status/SKILL.md")" "CORRUPTED"
assert_eq "copy mode: repaired content matches the repo's source again" \
  "$(cat "$TARGET8/wingman-status/SKILL.md")" "$(cat "$TEST_REPO/.agents/skills/wingman-status/SKILL.md")"

# --- test 8b: mode switches actually change the on-disk SHAPE, not just
#              content - test 8 above only ever installs copy mode into an
#              empty target, which never exercises the entry-already-exists
#              path either direction; a content-only check here would pass
#              vacuously the same way the real bug did (content compared
#              through the symlink resolves identical to the source, so a
#              switch to copy mode read as "already correct" and silently
#              never became a real copy) --------------------------------------
TARGET8B="$WORK/mode-switch/skills"
run_sync --target "$TARGET8B" --repo "$TEST_REPO" --mode symlink >/dev/null
assert_true "mode switch: starts out a symlink" "[ -L '$TARGET8B/wingman-status' ]"

out8b_to_copy="$(run_sync --target "$TARGET8B" --repo "$TEST_REPO" --mode copy 2>&1)"
assert_contains "mode switch: symlink -> copy is reported as an install, not silently skipped" "$out8b_to_copy" "installed:"
assert_false "mode switch: wingman-status is no longer a symlink after switching to copy" "[ -L '$TARGET8B/wingman-status' ]"
assert_true "mode switch: wingman-status is now a real directory" "[ -d '$TARGET8B/wingman-status' ]"
assert_true "mode switch: the real directory holds a real SKILL.md" "[ -f '$TARGET8B/wingman-status/SKILL.md' ]"
assert_eq "mode switch: --check in copy mode reports clean immediately after the switch (no residual drift)" \
  "$(run_sync --target "$TARGET8B" --repo "$TEST_REPO" --mode copy --check >/dev/null 2>&1; echo $?)" "0"

out8b_to_symlink="$(run_sync --target "$TARGET8B" --repo "$TEST_REPO" --mode symlink 2>&1)"
assert_contains "mode switch: copy -> symlink is reported as an install too" "$out8b_to_symlink" "installed:"
assert_true "mode switch: wingman-status is a symlink again" "[ -L '$TARGET8B/wingman-status' ]"
assert_false "mode switch: the old copy directory is gone, not left alongside the new symlink" "[ -d '$TARGET8B/wingman-status' ] && [ ! -L '$TARGET8B/wingman-status' ]"

# --- test 9: concurrency - N reconcilers racing one fresh target --------------
TARGET9="$WORK/concurrent/skills"
_pids=""
for _i in $(seq 1 8); do
  run_sync --target "$TARGET9" --repo "$TEST_REPO" >/dev/null 2>&1 &
  _pids="$_pids $!"
  wm_track "$!"
done
for _p in $_pids; do wait "$_p"; done
assert_eq "concurrent runs: exactly seven entries, none duplicated or lost" "$(count_wingman_entries "$TARGET9")" "$VERB_COUNT"
for v in $VERBS; do
  assert_true "concurrent runs: wingman-$v is a valid, readable symlink" "[ -r '$TARGET9/wingman-$v/SKILL.md' ]"
done

test_summary
