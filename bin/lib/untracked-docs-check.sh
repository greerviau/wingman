#!/usr/bin/env bash
# untracked-docs-check.sh <repo> - reports untracked files under <repo>/docs/, the
# concrete data-loss exposure from issue #205: a plan or review-findings file left
# untracked in a working tree is one `git clean -fd` from gone, and nothing before
# this surfaced it automatically. Writes its warning directly to STDERR (never
# stdout) and exits 1 when untracked docs/ files are found. Exits 0, printing
# nothing, when docs/ is clean OR <repo> is not a git repo at all - the two are
# deliberately indistinguishable here: this is a best-effort backstop warning,
# not a repo-validity check, so a caller just does
# `untracked-docs-check.sh "$REPO" || true` with no output capture needed.
# Usage: untracked-docs-check.sh <repo>
set -u
REPO="${1:-}"
[ -n "$REPO" ] || { echo "usage: untracked-docs-check.sh <repo>" >&2; exit 2; }
UNTRACKED="$(git -C "$REPO" status --porcelain --untracked-files=all -- :/docs 2>/dev/null | grep '^??' || true)"
[ -n "$UNTRACKED" ] || exit 0
N=$(printf '%s\n' "$UNTRACKED" | wc -l | tr -d ' ')
{
  echo "warning: $N untracked file(s) under docs/ in $REPO - not durable (a stray 'git clean -fd' erases them):"
  printf '%s\n' "$UNTRACKED" | sed 's/^?? /  /' | head -10
  [ "$N" -gt 10 ] && echo "  ... and $((N - 10)) more (git status --porcelain -- docs)"
} >&2
exit 1
