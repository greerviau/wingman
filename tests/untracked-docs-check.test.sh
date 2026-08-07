#!/usr/bin/env bash
# E2E: bin/lib/untracked-docs-check.sh, the stand-down-time backstop warning
# for issue #205's related exposure - untracked docs/ content one `git clean
# -fd` from gone. Mirrors tests/git-freshness-check.test.sh's real-git-fixture
# shape rather than mocking git.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SCRIPT="$TEST_REPO/bin/lib/untracked-docs-check.sh"
FIXDIR="$(wm_mktemp_dir)"

# --- clean docs/: tracked file only, nothing untracked -------------------------
CLEAN_REPO="$FIXDIR/clean-repo"
mkdir -p "$CLEAN_REPO/docs"
(
  cd "$CLEAN_REPO"
  git init -q
  git config user.email a@b.com
  git config user.name tester
  echo "tracked" > docs/plan.md
  git add docs/plan.md
  git commit -qm init
)
out="$("$SCRIPT" "$CLEAN_REPO")"; rc=$?
assert_eq "clean docs/ exits 0" "$rc" "0"
assert_eq "clean docs/ prints nothing on stdout" "$out" ""
err="$("$SCRIPT" "$CLEAN_REPO" 2>&1 1>/dev/null)"
assert_eq "clean docs/ prints nothing on stderr" "$err" ""

# --- untracked docs/ files: exits 1, warning on stderr only --------------------
UNTRACKED_REPO="$FIXDIR/untracked-repo"
mkdir -p "$UNTRACKED_REPO/docs/analysis"
(
  cd "$UNTRACKED_REPO"
  git init -q
  git config user.email a@b.com
  git config user.name tester
  echo "x" > README.md
  git add README.md
  git commit -qm init
  echo "stray plan" > docs/analysis/one.md
  echo "stray notes" > docs/analysis/two.md
)
out="$("$SCRIPT" "$UNTRACKED_REPO" 2>/dev/null)"; rc=$?
assert_eq "untracked docs/ files: nothing on stdout" "$out" ""
err="$("$SCRIPT" "$UNTRACKED_REPO" 2>&1 1>/dev/null)"; rc=$?
assert_eq "untracked docs/ files exits 1" "$rc" "1"
assert_contains "the warning names the count" "$err" "warning: 2 untracked file(s) under docs/"
assert_contains "the warning names one path" "$err" "docs/analysis/one.md"
assert_contains "the warning names the other path" "$err" "docs/analysis/two.md"
assert_contains "the warning explains why it matters" "$err" "git clean -fd"

# --- untracked files elsewhere in the repo (not under docs/) don't trigger it --
OUTSIDE_DOCS_REPO="$FIXDIR/outside-docs-repo"
mkdir -p "$OUTSIDE_DOCS_REPO/docs"
(
  cd "$OUTSIDE_DOCS_REPO"
  git init -q
  git config user.email a@b.com
  git config user.name tester
  echo "tracked" > docs/plan.md
  git add docs/plan.md
  git commit -qm init
  echo "stray, not under docs/" > scratch.txt
)
out="$("$SCRIPT" "$OUTSIDE_DOCS_REPO")"; rc=$?
assert_eq "an untracked file outside docs/ does not trigger the check" "$rc" "0"

# --- more than 10 untracked files: truncates the listing, names the remainder --
MANY_REPO="$FIXDIR/many-repo"
mkdir -p "$MANY_REPO/docs"
(
  cd "$MANY_REPO"
  git init -q
  git config user.email a@b.com
  git config user.name tester
  echo "x" > README.md
  git add README.md
  git commit -qm init
  i=0
  while [ "$i" -lt 12 ]; do
    echo "stray $i" > "docs/file-$i.md"
    i=$((i + 1))
  done
)
err="$("$SCRIPT" "$MANY_REPO" 2>&1 1>/dev/null)"; rc=$?
assert_eq "12 untracked docs/ files exits 1" "$rc" "1"
assert_contains "the warning names the true count (12)" "$err" "warning: 12 untracked file(s) under docs/"
assert_contains "the warning names the truncation remainder" "$err" "... and 2 more"

# --- no docs/ directory at all: exits 0, nothing printed -----------------------
NO_DOCS_REPO="$FIXDIR/no-docs-repo"
mkdir -p "$NO_DOCS_REPO"
(
  cd "$NO_DOCS_REPO"
  git init -q
  git config user.email a@b.com
  git config user.name tester
  echo "x" > README.md
  git add README.md
  git commit -qm init
)
out="$("$SCRIPT" "$NO_DOCS_REPO")"; rc=$?
assert_eq "no docs/ directory exits 0" "$rc" "0"
assert_eq "no docs/ directory prints nothing" "$out" ""

# --- not a git repo at all: exits 0, nothing printed (documented ambiguity) ----
NOT_A_REPO="$FIXDIR/not-a-repo"
mkdir -p "$NOT_A_REPO/docs"
echo "untracked, but no git repo here at all" > "$NOT_A_REPO/docs/orphan.md"
out="$("$SCRIPT" "$NOT_A_REPO")"; rc=$?
assert_eq "a non-git-repo directory exits 0" "$rc" "0"
assert_eq "a non-git-repo directory prints nothing" "$out" ""

# --- usage error -----------------------------------------------------------------
out="$("$SCRIPT" 2>&1)"; rc=$?
assert_eq "no argument is a usage error" "$rc" "2"
assert_contains "the usage error names itself" "$out" "usage: untracked-docs-check.sh"

rm -rf "$FIXDIR"
test_summary
