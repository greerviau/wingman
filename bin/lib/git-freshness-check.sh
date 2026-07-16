#!/usr/bin/env bash
# git-freshness-check.sh - advisory preflight for issue #143: a repo-scoped
# crew session that reads a file directly (a software-analyst, reviewer, or
# architect - every role except developer, which already isolates into a
# fresh worktree every run) has no guarantee its checkout is caught up with
# origin/<default-branch>. This script makes that check cheap and consistent
# instead of an ad hoc `git log`/`git status` improvisation redone slightly
# differently - and slightly wrong - each time. See
# playbooks/_status-contract.md, "Your checkout is a claim, not verified
# freshness," for the convention this backs.
#
# Usage:
#   git-freshness-check.sh [<path>...]
# Run from inside the target repo, or set REPO_DIR to point elsewhere.
#
# Prints one or more verdict lines to stdout:
#   fresh:HEAD already contains origin/<default-branch>
#   stale:N commit(s) behind origin/<default-branch>
#     <one-line log of the missing commits, indented>
#   path-same:<path>          - for each <path> argument, independent of the
#   path-diff:<path>            overall verdict above
#   error:<reason>
# Exit codes: 0 fresh, 1 stale (advisory, not fatal), 2 couldn't determine
# (usage/environment error - not a git repo, no origin remote, or the
# default branch could not be resolved).
#
# Never mutates HEAD, the index, or the working tree - the only two things
# this script runs against the checkout are `git fetch` and `git remote
# set-head`, both of which touch only refs/remotes/origin/*. This is exactly
# as safe to run against a checkout a human or another live session may also
# be using as the developer playbook's own pre-worktree fetch.
# bash-3.2-safe.
set -u
. "$(dirname "$0")/common.sh"

REPO_DIR="${REPO_DIR:-.}"

_gfc_err() { echo "error:$1"; exit 2; }

git -C "$REPO_DIR" rev-parse --show-toplevel >/dev/null 2>&1 \
  || _gfc_err "not a git repo: $REPO_DIR"
git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1 \
  || _gfc_err "no origin remote"

git -C "$REPO_DIR" fetch origin --quiet 2>/dev/null \
  || _gfc_err "git fetch origin failed"

# Resolve the default branch: origin/HEAD symref first, refreshed once via
# `git remote set-head origin -a` (also read-only against the working tree -
# it only rewrites the origin/HEAD symref) if unset, then `gh repo view` as a
# soft best-effort fallback if gh happens to be available, then a last-resort
# main/master probe.
DEFAULT_BRANCH="$(git -C "$REPO_DIR" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"

if [ -z "$DEFAULT_BRANCH" ]; then
  git -C "$REPO_DIR" remote set-head origin -a >/dev/null 2>&1
  DEFAULT_BRANCH="$(git -C "$REPO_DIR" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
fi

if [ -z "$DEFAULT_BRANCH" ] && wm_have gh; then
  DEFAULT_BRANCH="$(cd "$REPO_DIR" && gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)"
fi

if [ -z "$DEFAULT_BRANCH" ]; then
  for _gfc_candidate in main master; do
    if git -C "$REPO_DIR" rev-parse -q --verify "refs/remotes/origin/$_gfc_candidate" >/dev/null 2>&1; then
      DEFAULT_BRANCH="$_gfc_candidate"
      break
    fi
  done
fi

[ -n "$DEFAULT_BRANCH" ] || _gfc_err "could not resolve origin's default branch"

_gfc_count="$(git -C "$REPO_DIR" rev-list --count HEAD.."origin/$DEFAULT_BRANCH" 2>/dev/null)"
case "$_gfc_count" in
  ''|*[!0-9]*) _gfc_err "could not compare HEAD to origin/$DEFAULT_BRANCH" ;;
esac

if [ "$_gfc_count" -eq 0 ]; then
  _gfc_exit=0
  echo "fresh:HEAD already contains origin/$DEFAULT_BRANCH"
else
  _gfc_exit=1
  echo "stale:$_gfc_count commit(s) behind origin/$DEFAULT_BRANCH"
  git -C "$REPO_DIR" log --oneline "HEAD..origin/$DEFAULT_BRANCH" 2>/dev/null | sed 's/^/  /'
fi

for _gfc_path in "$@"; do
  if git -C "$REPO_DIR" diff --quiet HEAD "origin/$DEFAULT_BRANCH" -- "$_gfc_path" 2>/dev/null; then
    echo "path-same:$_gfc_path"
  else
    echo "path-diff:$_gfc_path"
  fi
done

exit "$_gfc_exit"
