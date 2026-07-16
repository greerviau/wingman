#!/usr/bin/env bash
# E2E: bin/lib/git-freshness-check.sh, the advisory stale-checkout preflight
# (issue #143). Builds real git fixtures (a bare "origin" plus clones) rather
# than mocking git, matching this repo's existing E2E bash test convention
# (tests/artifact-scan.test.sh). Exercises fresh/stale/path-diff/path-same/
# error/default-branch-fallback verdicts, plus the non-mutation safety
# guarantee the whole design leans on to justify running this against a
# checkout a human or another live session may be using.
#
# Fixture branch is deliberately named "trunk", not "main"/"master": a raw
# `git push origin HEAD:main` from a crew session trips
# hooks/no-merge-guard.sh's default-branch-push guard (issue #46) even
# against a disposable /tmp fixture unrelated to this repo, since the guard's
# fallback candidate set is {main, master} whenever origin/HEAD isn't yet
# cached locally - which is exactly this fixture's state immediately after
# `git init --bare`.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SCRIPT="$TEST_REPO/bin/lib/git-freshness-check.sh"
FIXDIR="$(wm_mktemp_dir)"

# --- shared fixture: a bare "origin" and a first clone ("clone1") tracking it,
# one commit touching both file-a and file-b, default branch "trunk" --------
ORIGIN="$FIXDIR/origin.git"
CLONE1="$FIXDIR/clone1"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$CLONE1" 2>/dev/null
(
  cd "$CLONE1"
  git config user.email a@b.com
  git config user.name tester
  git checkout -q -b trunk
  echo "a" > file-a
  echo "b" > file-b
  git add file-a file-b
  git commit -qm init
  git push -q origin HEAD:trunk -u
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/trunk
  git remote set-head origin -a >/dev/null 2>&1
)

# --- fresh case: HEAD matches origin/trunk exactly -----------------------------
out="$(REPO_DIR="$CLONE1" "$SCRIPT")"; rc=$?
assert_eq "a checkout matching origin/trunk exits 0" "$rc" "0"
case "$out" in
  fresh:*) ok "the verdict starts with fresh:" ;;
  *) fail "the verdict starts with fresh:"; printf '         got [%s]\n' "$out" ;;
esac

# --- advance the bare repo via a second clone, touching only file-a -----------
CLONE2="$FIXDIR/clone2"
git clone -q "$ORIGIN" "$CLONE2" 2>/dev/null
(
  cd "$CLONE2"
  git config user.email a@b.com
  git config user.name tester
  git checkout -q trunk
  echo "a2" >> file-a
  git add file-a
  git commit -qm "touch file-a"
  git push -q origin HEAD:trunk
)
NEW_SHA="$(git -C "$CLONE2" rev-parse --short HEAD)"

# --- stale case: clone1's HEAD never advanced ----------------------------------
out="$(REPO_DIR="$CLONE1" "$SCRIPT" file-a file-b)"; rc=$?
assert_eq "a checkout one commit behind origin/trunk exits 1" "$rc" "1"
first_line="$(printf '%s\n' "$out" | head -1)"
case "$first_line" in
  stale:1\ commit\(s\)\ behind*) ok "the verdict starts with stale:1 commit(s) behind" ;;
  *) fail "the verdict starts with stale:1 commit(s) behind"; printf '         got [%s]\n' "$first_line" ;;
esac
assert_contains "the following line names the new commit" "$out" "$NEW_SHA"

# --- path-diff / path-same, independent of the overall stale verdict ----------
assert_contains "file-a (touched by the new commit) is path-diff" "$out" "path-diff:file-a"
assert_contains "file-b (untouched) is path-same" "$out" "path-same:file-b"

# --- default-branch fallback: origin/HEAD deliberately unset ------------------
# Cloned, then one more commit lands upstream, so this checkout is stale too -
# the fallback path is exercised on a real stale/fresh distinction, not just
# on whether it resolves a name at all.
CLONE3="$FIXDIR/clone3"
git clone -q "$ORIGIN" "$CLONE3" 2>/dev/null
(cd "$CLONE3" && git checkout -q trunk && git symbolic-ref --delete refs/remotes/origin/HEAD)
(
  cd "$CLONE2"
  echo "a3" >> file-a
  git add file-a
  git commit -qm "touch file-a again"
  git push -q origin HEAD:trunk
)
out="$(REPO_DIR="$CLONE3" "$SCRIPT")"; rc=$?
assert_eq "the fallback (git remote set-head origin -a) still resolves the default branch" "$rc" "1"
case "$out" in
  stale:1\ commit\(s\)\ behind\ origin/trunk*) ok "the resolved default branch is still trunk" ;;
  *) fail "the resolved default branch is still trunk"; printf '         got [%s]\n' "$out" ;;
esac

# --- no-origin error -------------------------------------------------------------
NOORIGIN="$FIXDIR/no-origin"
mkdir -p "$NOORIGIN"
(cd "$NOORIGIN" && git init -q)
out="$(REPO_DIR="$NOORIGIN" "$SCRIPT")"; rc=$?
assert_eq "a repo with no origin remote exits 2" "$rc" "2"
assert_contains "the reason names the missing origin remote" "$out" "error:no origin remote"

# --- not-a-repo error -------------------------------------------------------------
NOTREPO="$FIXDIR/not-a-repo"
mkdir -p "$NOTREPO"
out="$(REPO_DIR="$NOTREPO" "$SCRIPT")"; rc=$?
assert_eq "a plain non-repo directory exits 2" "$rc" "2"

# --- non-mutation: the safety guarantee the whole design leans on -------------
# A stale checkout with BOTH a staged and an unstaged local change present -
# the harder case, not a clean tree - snapshotted before and after a run that
# also exercises the per-path diff branch (path arguments passed).
(
  cd "$CLONE1"
  echo "staged-change" >> file-a
  git add file-a
  echo "unstaged-change" >> file-b
)
before_head="$(git -C "$CLONE1" rev-parse HEAD)"
before_status="$(git -C "$CLONE1" status --porcelain)"
REPO_DIR="$CLONE1" "$SCRIPT" file-a file-b >/dev/null
after_head="$(git -C "$CLONE1" rev-parse HEAD)"
after_status="$(git -C "$CLONE1" status --porcelain)"
assert_eq "HEAD is byte-identical before and after a run against a dirty stale checkout" "$before_head" "$after_head"
assert_eq "git status --porcelain is byte-identical before and after (staged + unstaged changes both preserved)" "$before_status" "$after_status"

rm -rf "$FIXDIR"
test_summary
