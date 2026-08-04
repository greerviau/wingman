#!/usr/bin/env bash
# E2E: issue #251 - cmd_reconcile's uncommitted-work auto-anchor. The moment a
# live member's window disappears and it flips to `died`, a dirty worktree
# (if it still has one) gets snapshotted - tracked, staged, AND untracked
# files alike - via a scratch git index (GIT_INDEX_FILE points read-tree/
# add/write-tree at a throwaway file, never the real .git/index) and pointed
# at by refs/wip/<id> automatically. Generalizes the by-hand salvage issue
# #198 needed during the 2026-08-04 fleet-loss incident (refs/wip/issue-198-
# fleet-loss-salvage).
#
# Review round 1 found the original `git stash create` implementation
# silently dropped any never-`git add`ed file while the notification text
# claimed full coverage (MF-1) and that a genuine anchor failure was
# indistinguishable from "the tree was clean" (MF-4) - most of this file's
# new cases exist to pin those two fixes down directly, not just re-assert
# the original zero-disruption property.
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
# IDENTICAL uncommitted diff it had before reconcile ran (the scratch-index
# build touches neither the real index nor the working tree).
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

# --- untracked-only changes ARE anchored (review round 1, MF-1: the original
# `git stash create` implementation silently dropped these; the rewrite
# captures them via `git add -A` into the scratch index) - the untracked file
# itself is left completely alone on disk, exactly like a1's tracked case ---
test_new_home
WT3="$(wm_mktemp_dir)/wt3"
new_worktree "$WT3"
echo "brand new file" > "$WT3/untracked.txt"
wm_state crew-add --id a3 --type developer --objective x --repo /tmp --window wm-a3 --session-id sa3 --worktree "$WT3" >/dev/null
wm_state crew-set --id a3 --status working >/dev/null
wm_state reconcile --windows "" --owner "" >/dev/null

assert_eq "the member still flips to died" "$(field_of a3 status)" "died"
wip_sha3="$(field_of a3 wip_ref_sha)"
assert_true "an untracked-only change IS anchored (MF-1 fix)" "[ -n '$wip_sha3' ]"
assert_true "the untracked file itself is left alone on disk" "[ -f '$WT3/untracked.txt' ]"
assert_contains "the anchored commit contains the untracked file's content" \
  "$(git -C "$WT3" show "$wip_sha3:untracked.txt" 2>/dev/null)" "brand new file"

# --- MF-1 regression guard: a modified TRACKED file and a brand-new
# UNTRACKED file both survive in the SAME anchor commit - this is the
# review's own end-to-end reproduction of the original bug (the notification
# claimed full coverage while only the tracked half actually anchored) -----
test_new_home
WT7="$(wm_mktemp_dir)/wt7"
new_worktree "$WT7"
echo "tracked edit" >> "$WT7/f.txt"
echo "untracked content" > "$WT7/new_module.py"
before_status7="$(git -C "$WT7" status --porcelain)"
wm_state crew-add --id a7 --type developer --objective x --repo /tmp --window wm-a7 --session-id sa7 --worktree "$WT7" >/dev/null
wm_state crew-set --id a7 --status working >/dev/null
wm_state reconcile --windows "" --owner "" >/dev/null

wip_sha7="$(field_of a7 wip_ref_sha)"
assert_true "the mixed dirty state is anchored" "[ -n '$wip_sha7' ]"
assert_contains "the anchor captures the tracked edit" \
  "$(git -C "$WT7" show "$wip_sha7" -- f.txt)" "tracked edit"
assert_contains "the anchor ALSO captures the untracked new file (this is exactly what MF-1 fixed)" \
  "$(git -C "$WT7" show "$wip_sha7:new_module.py" 2>/dev/null)" "untracked content"
after_status7="$(git -C "$WT7" status --porcelain)"
assert_eq "the working tree is still byte-identical after anchoring the mixed state" "$after_status7" "$before_status7"

# --- a gitignored-only file is NOT captured - matches ordinary `git add -A`
# behavior exactly (an ignored build artifact is not "uncommitted work") ---
test_new_home
WT8="$(wm_mktemp_dir)/wt8"
new_worktree "$WT8"
echo "*.ignored" > "$WT8/.gitignore"
git -C "$WT8" add .gitignore
git -C "$WT8" commit -q -m "add gitignore"
echo "should not be anchored" > "$WT8/build.ignored"
wm_state crew-add --id a8 --type developer --objective x --repo /tmp --window wm-a8 --session-id sa8 --worktree "$WT8" >/dev/null
wm_state crew-set --id a8 --status working >/dev/null
wm_state reconcile --windows "" --owner "" >/dev/null
assert_eq "a worktree with only an ignored file anchors nothing (matches ordinary git add -A)" \
  "$(field_of a8 wip_ref_sha)" ""

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

# --- a genuine anchor FAILURE (review round 1, MF-4) is recorded distinctly
# from "the tree was clean" - a worktree directory that exists on disk but
# was never actually a git checkout (its own .git was lost, or never
# created - a plausible shape for a race with teardown) fails at the very
# first git call inside _anchor_died_worktree ---------------------------------
test_new_home
WT9="$(wm_mktemp_dir)/wt9-not-a-repo"
mkdir -p "$WT9"
echo "some file" > "$WT9/f.txt"
wm_state crew-add --id a9 --type developer --objective x --repo /tmp --window wm-a9 --session-id sa9 --worktree "$WT9" >/dev/null
wm_state crew-set --id a9 --status working >/dev/null
out9="$(wm_state reconcile --windows "" --owner "" 2>&1)"; rc9=$?
assert_eq "reconcile still exits cleanly despite the anchor failure" "$rc9" "0"
assert_eq "the member still flips to died" "$(field_of a9 status)" "died"
assert_eq "no wip_ref_sha when the anchor genuinely failed" "$(field_of a9 wip_ref_sha)" ""
wip_error9="$(field_of a9 wip_anchor_error)"
# Not assert_true/eval here: the real error text embeds single quotes
# (Python's own repr of the failed argv), which would break out of assert_true's
# single-quoted eval string if interpolated directly - a plain conditional
# expands the variable safely instead.
if [ -n "$wip_error9" ]; then ok "wip_anchor_error IS recorded, distinguishing failure from a clean tree"
else fail "wip_anchor_error IS recorded, distinguishing failure from a clean tree"; fi

# --- the scratch-index rewrite is immune to a stale .git/index.lock - the
# reviewer's own verified failure mode for the ORIGINAL `git stash create`
# implementation, which operated against the real index. GIT_INDEX_FILE
# points every index-touching call here at a throwaway file instead, so a
# lock on .git/index cannot block it - a genuine improvement, not a side
# effect: the likeliest real-world crash (killed mid-git-operation) is
# exactly what leaves this lock behind ---------------------------------------
test_new_home
WT10="$(wm_mktemp_dir)/wt10"
new_worktree "$WT10"
echo "dirty despite the lock" >> "$WT10/f.txt"
touch "$WT10/.git/index.lock"
wm_state crew-add --id a10 --type developer --objective x --repo /tmp --window wm-a10 --session-id sa10 --worktree "$WT10" >/dev/null
wm_state crew-set --id a10 --status working >/dev/null
wm_state reconcile --windows "" --owner "" >/dev/null
wip_sha10="$(field_of a10 wip_ref_sha)"
assert_true "a stale .git/index.lock does NOT block the scratch-index anchor" "[ -n '$wip_sha10' ]"
rm -f "$WT10/.git/index.lock"

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

# --- the REAL production topology: a LINKED worktree of `repo`, not an
# unrelated standalone git directory (review round 1, nice-to-have 8). In
# production `worktree` is always `git worktree add`-linked to `repo` - the
# anchor writes the ref from INSIDE the linked worktree, while
# bin/crew-takeover reads it back via `git -C <repo>`; this is the one
# cross-boundary step nothing else in this file exercises, and it depends on
# refs/wip/ being a SHARED ref (linked worktrees share one object store) ---
test_new_home
BASE="$(wm_mktemp_dir)/base-repo"
new_worktree "$BASE"
LINKED="$(wm_mktemp_dir)/linked-worktree"
git -C "$BASE" worktree add -q "$LINKED" -b linked-branch >/dev/null
echo "uncommitted in the linked worktree" >> "$LINKED/f.txt"
wm_state crew-add --id lw1 --type developer --objective x --repo "$BASE" --window wm-lw1 --session-id slw1 --worktree "$LINKED" >/dev/null
wm_state crew-set --id lw1 --status working >/dev/null
wm_state reconcile --windows "" --owner "" >/dev/null

assert_eq "the member flips to died" "$(field_of lw1 status)" "died"
wip_sha_lw="$(field_of lw1 wip_ref_sha)"
assert_true "the linked worktree's dirty state is anchored" "[ -n '$wip_sha_lw' ]"
ref_from_base="$(git -C "$BASE" rev-parse --quiet --verify refs/wip/lw1)"
assert_eq "the ref is visible from the BASE repo (the shared object store), not only the linked worktree - exactly how bin/crew-takeover reads it back" \
  "$ref_from_base" "$wip_sha_lw"
assert_contains "the anchored commit carries the linked worktree's own uncommitted change" \
  "$(git -C "$BASE" show "$wip_sha_lw" -- f.txt)" "uncommitted in the linked worktree"
git -C "$BASE" worktree remove "$LINKED" --force 2>/dev/null

test_summary
