#!/usr/bin/env bash
# E2E: issue #251 - cmd_reconcile's uncommitted-work auto-anchor. The moment a
# live member's window disappears and it flips to `died`, a dirty worktree
# (if it still has one) gets `git stash create` + `git update-ref
# refs/wip/<id> <sha>` run against it automatically - the exact by-hand
# salvage issue #198 needed during the 2026-08-04 fleet-loss incident
# (refs/wip/issue-198-fleet-loss-salvage), now unconditional.
#
# reconcile takes the live window list as a plain --windows CSV (not a real
# tmux query - see tests/reconcile-orphan-window.test.sh's own comment), so no
# tmux session is needed: a window is "live" simply by being named in
# --windows, "gone" by being omitted, which is what drives the death flip.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

field_of() {
  wm_state crew-get --id "$1" 2>/dev/null | uv run --no-project --quiet python -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit
v = d.get(sys.argv[1])
print("" if v is None else v)
' "$2"
}

new_worktree() {
  # new_worktree <path> - a real, minimal git checkout with one committed file,
  # ready for the caller to dirty (or not) before reconcile runs.
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email t@t.com
  git -C "$1" config user.name t
  echo committed > "$1/f.txt"
  git -C "$1" add f.txt
  git -C "$1" commit -q -m init
}

# --- a dirty (tracked, modified) worktree gets anchored on the death flip ----
test_new_home
WT1="$(wm_mktemp_dir)/wt1"
new_worktree "$WT1"
echo "uncommitted change" >> "$WT1/f.txt"
before_status="$(git -C "$WT1" status --porcelain)"
before_head="$(git -C "$WT1" rev-parse HEAD)"
wm_state crew-add --id a1 --type developer --objective x --repo /tmp --window wm-a1 --session-id sa1 --worktree "$WT1" >/dev/null
wm_state crew-set --id a1 --status working >/dev/null
wm_state reconcile --windows "" --owner "" >/dev/null

assert_eq "the member flips to died" "$(field_of a1 status)" "died"
wip_sha="$(field_of a1 wip_ref_sha)"
assert_true "wip_ref_sha is recorded on the roster" "[ -n '$wip_sha' ]"
ref_sha="$(git -C "$WT1" rev-parse --quiet --verify refs/wip/a1)"
assert_eq "refs/wip/a1 points at the recorded sha" "$ref_sha" "$wip_sha"

# Zero-disruption: HEAD never moved, and the working tree still shows the
# IDENTICAL uncommitted diff it had before reconcile ran (git stash create
# never touches either).
after_head="$(git -C "$WT1" rev-parse HEAD)"
after_status="$(git -C "$WT1" status --porcelain)"
assert_eq "HEAD is unchanged" "$after_head" "$before_head"
assert_eq "the working tree's dirty state is byte-identical after anchoring" "$after_status" "$before_status"
assert_contains "the anchored commit's diff carries the uncommitted change" \
  "$(git -C "$WT1" show "$wip_sha" -- f.txt)" "uncommitted change"

# --- a clean worktree: no ref, no wip_ref_sha (nothing to anchor) -----------
test_new_home
WT2="$(wm_mktemp_dir)/wt2"
new_worktree "$WT2"
wm_state crew-add --id a2 --type developer --objective x --repo /tmp --window wm-a2 --session-id sa2 --worktree "$WT2" >/dev/null
wm_state crew-set --id a2 --status working >/dev/null
wm_state reconcile --windows "" --owner "" >/dev/null

assert_eq "the member still flips to died" "$(field_of a2 status)" "died"
assert_eq "no wip_ref_sha is recorded for a clean worktree" "$(field_of a2 wip_ref_sha)" ""
assert_false "no refs/wip/a2 is created for a clean worktree" \
  "git -C '$WT2' rev-parse --quiet --verify refs/wip/a2"

# --- untracked-only changes: matches the #198 precedent exactly (plain `git
# stash create` never captures untracked files) - no ref, no wip_ref_sha -----
test_new_home
WT3="$(wm_mktemp_dir)/wt3"
new_worktree "$WT3"
echo "brand new file" > "$WT3/untracked.txt"
wm_state crew-add --id a3 --type developer --objective x --repo /tmp --window wm-a3 --session-id sa3 --worktree "$WT3" >/dev/null
wm_state crew-set --id a3 --status working >/dev/null
wm_state reconcile --windows "" --owner "" >/dev/null

assert_eq "the member still flips to died" "$(field_of a3 status)" "died"
assert_eq "no wip_ref_sha for untracked-only changes" "$(field_of a3 wip_ref_sha)" ""
assert_true "the untracked file itself is left alone on disk" "[ -f '$WT3/untracked.txt' ]"

# --- no worktree recorded at all (global-scope-style record): reconcile still
# completes cleanly, no crash, no ref ------------------------------------------
test_new_home
wm_state crew-add --id a4 --type developer --objective x --repo /tmp --window wm-a4 --session-id sa4 >/dev/null
wm_state crew-set --id a4 --status working >/dev/null
out4="$(wm_state reconcile --windows "" --owner "" 2>&1)"; rc4=$?
assert_eq "reconcile exits cleanly with no worktree on record" "$rc4" "0"
assert_eq "the member flips to died" "$(field_of a4 status)" "died"
assert_eq "no wip_ref_sha with no worktree" "$(field_of a4 wip_ref_sha)" ""

# --- a worktree path that no longer exists on disk (already torn down, a race
# with cleanup): reconcile still completes cleanly, no crash -----------------
test_new_home
wm_state crew-add --id a5 --type developer --objective x --repo /tmp --window wm-a5 --session-id sa5 \
  --worktree "$(wm_mktemp_dir)/never-created" >/dev/null
wm_state crew-set --id a5 --status working >/dev/null
out5="$(wm_state reconcile --windows "" --owner "" 2>&1)"; rc5=$?
assert_eq "reconcile exits cleanly with a missing worktree directory" "$rc5" "0"
assert_eq "the member still flips to died" "$(field_of a5 status)" "died"

# --- a re-death overwrites the ref with the LATEST anchored state, not a
# history of every death (by design - see _anchor_died_worktree's docstring) -
test_new_home
WT6="$(wm_mktemp_dir)/wt6"
new_worktree "$WT6"
echo "first crash" >> "$WT6/f.txt"
wm_state crew-add --id a6 --type developer --objective x --repo /tmp --window wm-a6 --session-id sa6 --worktree "$WT6" >/dev/null
wm_state crew-set --id a6 --status working >/dev/null
wm_state reconcile --windows "" --owner "" >/dev/null
first_sha="$(field_of a6 wip_ref_sha)"
assert_true "the first death anchors a sha" "[ -n '$first_sha' ]"

# Simulate a resume (back to working, window live again) then a second death
# with DIFFERENT uncommitted content.
wm_state crew-set --id a6 --status working >/dev/null
git -C "$WT6" checkout -q -- f.txt   # drop the first crash's uncommitted diff, as a real resume would see a clean base
echo "second crash" >> "$WT6/f.txt"
wm_state reconcile --windows "" --owner "" >/dev/null
second_sha="$(field_of a6 wip_ref_sha)"
assert_true "the second death anchors a different sha" "[ '$second_sha' != '$first_sha' ]"
ref_sha6="$(git -C "$WT6" rev-parse --quiet --verify refs/wip/a6)"
assert_eq "refs/wip/a6 now points at the SECOND death's sha, not the first" "$ref_sha6" "$second_sha"
assert_contains "the ref's content is the second crash's diff" \
  "$(git -C "$WT6" show "$second_sha" -- f.txt)" "second crash"

test_summary
