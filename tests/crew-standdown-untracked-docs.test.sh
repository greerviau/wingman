#!/usr/bin/env bash
# E2E: bin/crew-standdown surfaces untracked docs/ content left behind by a
# lead working directly in a shared repo checkout (issue #205) - a mechanical
# backstop for the exposure named in the incident: nothing before this looked
# at a stood-down lead's own checkout at all. Warning-only (never gates the
# standdown), scoped to type=lead (never a cascaded worker under it), and
# only fires when no worktree of the member's own is on record (a
# developer's own worktree-removal fallback is a separate, already-covered
# path).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

STANDDOWN="$TEST_REPO/bin/crew-standdown"

make_repo_with_untracked_docs() {
  # make_repo_with_untracked_docs <dir>
  mkdir -p "$1/docs"
  (
    cd "$1"
    git init -q
    git config user.email a@b.com
    git config user.name tester
    echo "x" > README.md
    git add README.md
    git commit -qm init
    echo "stray analysis" > docs/analysis-note.md
  )
}

make_repo_with_clean_docs() {
  # make_repo_with_clean_docs <dir>
  mkdir -p "$1/docs"
  (
    cd "$1"
    git init -q
    git config user.email a@b.com
    git config user.name tester
    echo "tracked" > docs/plan.md
    git add docs/plan.md
    git commit -qm init
  )
}

# --- a stood-down lead with untracked docs/: the warning appears -------------
test_new_home
DIRTY_REPO="$(wm_mktemp_dir)"
make_repo_with_untracked_docs "$DIRTY_REPO"
wm_state crew-add --id lead1 --type lead --objective x --repo "$DIRTY_REPO" --window wm-lead1 --session-id slead1 >/dev/null
wm_state crew-set --id lead1 --status done --summary "finished" >/dev/null
out="$("$STANDDOWN" lead1 2>&1)"
assert_contains "the standdown still reports success" "$out" "stood down lead1"
assert_contains "the untracked-docs warning appears" "$out" "untracked file(s) under docs/"
assert_contains "the warning names the stray file" "$out" "docs/analysis-note.md"

# --- a stood-down lead with clean docs/: no warning ---------------------------
test_new_home
CLEAN_REPO="$(wm_mktemp_dir)"
make_repo_with_clean_docs "$CLEAN_REPO"
wm_state crew-add --id lead2 --type lead --objective x --repo "$CLEAN_REPO" --window wm-lead2 --session-id slead2 >/dev/null
wm_state crew-set --id lead2 --status done --summary "finished" >/dev/null
out="$("$STANDDOWN" lead2 2>&1)"
assert_contains "the standdown still reports success" "$out" "stood down lead2"
assert_not_contains "no warning for a clean checkout" "$out" "untracked file(s) under docs/"

# --- a non-lead (e.g. software-analyst) with the same untracked docs/: no
# warning - the TY = lead gate, not a cid/$ID one -----------------------------
test_new_home
ANALYST_REPO="$(wm_mktemp_dir)"
make_repo_with_untracked_docs "$ANALYST_REPO"
wm_state crew-add --id analyst1 --type software-analyst --objective x --repo "$ANALYST_REPO" --window wm-analyst1 --session-id sanalyst1 >/dev/null
wm_state crew-set --id analyst1 --status done --summary "finished" >/dev/null
out="$("$STANDDOWN" analyst1 2>&1)"
assert_contains "the standdown still reports success" "$out" "stood down analyst1"
assert_not_contains "no warning for a non-lead type, even with untracked docs/" "$out" "untracked file(s) under docs/"

# --- a lead reaped as a descendant of a cascaded standdown is still checked
# (the check is not gated on cid = $ID) ----------------------------------------
test_new_home
CASCADE_REPO="$(wm_mktemp_dir)"
make_repo_with_untracked_docs "$CASCADE_REPO"
wm_state crew-add --id owner1 --type lead --objective x --repo /tmp --window wm-owner1 --session-id sowner1 >/dev/null
wm_state crew-add --id lead3 --type lead --objective x --repo "$CASCADE_REPO" --window wm-lead3 --session-id slead3 --parent owner1 >/dev/null
wm_state crew-set --id owner1 --status done --summary "finished" >/dev/null
wm_state crew-set --id lead3 --status done --summary "finished" >/dev/null
out="$("$STANDDOWN" owner1 2>&1)"
assert_contains "the cascade reports success" "$out" "stood down owner1"
assert_contains "the cascaded lead's own untracked docs/ is still surfaced" "$out" "untracked file(s) under docs/"

# --- a lead whose worktree IS on record and exists: the developer-shaped
# worktree-removal path applies instead, so the untracked-docs check does not
# fire (this test doubles as documentation of that boundary; a lead never
# actually creates a worktree in practice, but the guard is keyed on the
# recorded field, not on crew type alone) --------------------------------------
test_new_home
WT_REPO="$(wm_mktemp_dir)"
make_repo_with_untracked_docs "$WT_REPO"
(cd "$WT_REPO" && git worktree add -q --detach "$WT_REPO-wt" >/dev/null 2>&1)
wm_state crew-add --id lead4 --type lead --objective x --repo "$WT_REPO" --worktree "$WT_REPO-wt" --window wm-lead4 --session-id slead4 >/dev/null
wm_state crew-set --id lead4 --status done --summary "finished" >/dev/null
out="$("$STANDDOWN" lead4 2>&1)"
assert_contains "the standdown still reports success" "$out" "stood down lead4"
assert_not_contains "no untracked-docs warning when a worktree of its own is on record" "$out" "untracked file(s) under docs/"

test_summary
