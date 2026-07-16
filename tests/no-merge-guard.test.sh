#!/usr/bin/env bash
# E2E: hooks/no-merge-guard.sh (issue #46). Denies gh pr merge, a gh api call
# hitting the REST merge endpoint (PUT only - a GET stays allowed), a graphql
# mergePullRequest mutation, and a direct push to the repository's default
# branch, from a crew session by default - and lifts the deny once the
# member's own crew record carries allow_merge: true. Also covers the
# --allow-merge grant guard itself: never settable by a crew member on its
# own id, settable by a lead onto one of its own workers, always settable by
# wingman's own top-level session (no WINGMAN_CREW_ID at all).
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$TEST_REPO/hooks/no-merge-guard.sh"

run_hook() {
  # run_hook <command> [cwd]
  uv run --no-project --quiet python -c '
import json, sys
data = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}
print(json.dumps(data))
' "$1" "${2:-$TEST_REPO}" | bash "$HOOK"
}

test_new_home

# --- scratch repo with a real origin/HEAD, so default-branch resolution is
# exercised against real git state rather than the fallback guess -----------
SCRATCH="$(wm_mktemp_dir)"
BARE="$SCRATCH/origin.git"
git init -q --bare "$BARE"
CLONE="$SCRATCH/work"
git clone -q "$BARE" "$CLONE"
(
  cd "$CLONE"
  git checkout -q -b main
  echo hi > a.txt
  git -c user.email=a@a -c user.name=a add a.txt
  git -c user.email=a@a -c user.name=a commit -q -m init
  git push -q origin main
  git remote set-head origin main
  git checkout -q -b feature/foo
)

# ============================================================================
# Merge-path detection: not a crew session at all (no WINGMAN_CREW_ID) - the
# pilot's own session is unaffected by this guard (issue #46, requirement 4).
# ============================================================================
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

out="$(run_hook "gh pr merge 46")"
assert_eq "non-crew: gh pr merge is allowed (no output)" "$out" ""

out="$(run_hook "git push origin main" "$CLONE")"
assert_eq "non-crew: git push origin main is allowed (no output)" "$out" ""

# ============================================================================
# Crew session, no grant: every merge-equivalent path is denied
# ============================================================================
export WINGMAN_CREW_ID=dev1
export WINGMAN_CREW_TYPE=developer

out="$(run_hook "gh pr merge 46")"
assert_contains "crew, no grant: gh pr merge 46 is denied" "$out" '"permissionDecision": "deny"'
assert_contains "crew, no grant: denial cites issue #46" "$out" "issue #46"
assert_contains "crew, no grant: denial tells the member to leave it for the pilot" "$out" "let the pilot merge it"

out="$(run_hook "gh pr merge")"
assert_contains "crew, no grant: bare gh pr merge is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "gh pr merge --auto")"
assert_contains "crew, no grant: gh pr merge --auto is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "gh pr merge 46 --squash --delete-branch")"
assert_contains "crew, no grant: gh pr merge with flags is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "gh api -X PUT repos/owner/repo/pulls/46/merge")"
assert_contains "crew, no grant: gh api -X PUT .../merge is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "gh api --method put /repos/owner/repo/pulls/46/merge")"
assert_contains "crew, no grant: gh api --method put (lowercase) is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "gh api repos/owner/repo/pulls/46/merge")"
assert_eq "crew, no grant: gh api .../merge with NO method (defaults GET, read-only) is allowed" "$out" ""

out="$(run_hook 'gh api graphql -f query='"'"'mutation{mergePullRequest(input:{pullRequestId:"PR_kwABC"}){clientMutationId}}'"'"'')"
assert_contains "crew, no grant: gh api graphql mergePullRequest mutation is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook 'gh api graphql -f query='"'"'query{viewer{login}}'"'"'')"
assert_eq "crew, no grant: an unrelated graphql query is allowed (no output)" "$out" ""

# --- direct push to the default branch ---------------------------------
out="$(run_hook "git push origin main" "$CLONE")"
assert_contains "crew, no grant: git push origin main is denied" "$out" '"permissionDecision": "deny"'
assert_contains "crew, no grant: push denial names the branch" "$out" "main"

out="$(run_hook "git push --force origin main" "$CLONE")"
assert_contains "crew, no grant: git push --force origin main is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "git push origin HEAD:main" "$CLONE")"
assert_contains "crew, no grant: git push origin HEAD:main is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "git push origin fix:refs/heads/main" "$CLONE")"
assert_contains "crew, no grant: git push origin fix:refs/heads/main is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "git push origin feature/foo" "$CLONE")"
assert_eq "crew, no grant: pushing a feature branch is allowed (no output)" "$out" ""

# bare `git push` resolves the destination from the current branch
( cd "$CLONE" && git checkout -q main )
out="$(run_hook "git push" "$CLONE")"
assert_contains "crew, no grant: bare git push while on main is denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "git push origin" "$CLONE")"
assert_contains "crew, no grant: git push origin (remote only, no refspec) while on main is denied" "$out" '"permissionDecision": "deny"'

( cd "$CLONE" && git checkout -q feature/foo )
out="$(run_hook "git push" "$CLONE")"
assert_eq "crew, no grant: bare git push while on a feature branch is allowed (no output)" "$out" ""

# A command chained with something else - the merge segment must still be caught.
out="$(run_hook "cd /tmp && gh pr merge 46")"
assert_contains "crew, no grant: gh pr merge mid-chain is still denied" "$out" '"permissionDecision": "deny"'

# ============================================================================
# issue #117: a `git push` whose enclosing command starts with `cd <path>`
# must resolve the destination against the directory the git invocation
# actually executes in - not the hook payload's own cwd, which may be an
# unrelated checkout of the very same repo (a worktree: multiple checkouts,
# each potentially on a different branch).
# ============================================================================
export WINGMAN_CREW_ID=dev-worktree
export WINGMAN_CREW_TYPE=developer

WORKTREE="$SCRATCH/worktree-feature"
( cd "$CLONE" && git worktree add -q -b feat/worktree-thing "$WORKTREE" origin/main )
( cd "$CLONE" && git checkout -q main )   # primary checkout sits on main - the reported precondition

# Payload cwd is the PRIMARY checkout (on main); the command's own `cd` moves
# into the worktree (on feat/worktree-thing) before the bare push - must be
# ALLOWED, where before this fix it was wrongly denied.
out="$(run_hook "cd $WORKTREE && git push" "$CLONE")"
assert_eq "issue #117: bare git push after cd into a worktree on a feature branch is allowed (no output)" "$out" ""

# Same shape, but the command's own cd lands on a checkout that IS on main -
# still correctly DENIED (proves the fix tracks the real destination, it
# doesn't just make any cd-prefixed push allowed).
out="$(run_hook "cd $CLONE && git push" "$SCRATCH")"
assert_contains "issue #117: bare git push after cd onto a checkout on main is still denied" "$out" '"permissionDecision": "deny"'

# `;` and a real newline as the separator - not just `&&` - resolve identically.
out="$(run_hook "cd $WORKTREE; git push" "$CLONE")"
assert_eq "issue #117: cd ; git push (semicolon separator) is allowed (no output)" "$out" ""

NEWLINE_CMD="$(printf 'cd %s\ngit push' "$WORKTREE")"
out="$(run_hook "$NEWLINE_CMD" "$CLONE")"
assert_eq "issue #117: cd <newline> git push is allowed (no output)" "$out" ""

# Multiple cd's in the same chain - the LAST one is the one that counts.
out="$(run_hook "cd $CLONE && cd $WORKTREE && git push" "$SCRATCH")"
assert_eq "issue #117: the last of multiple cd's in a chain wins (allowed, no output)" "$out" ""

out="$(run_hook "cd $WORKTREE && cd $CLONE && git push" "$SCRATCH")"
assert_contains "issue #117: ...and reversing the order correctly denies instead" "$out" '"permissionDecision": "deny"'

# A relative cd resolves against the payload cwd (SCRATCH is the worktree's parent).
out="$(run_hook "cd worktree-feature && git push" "$SCRATCH")"
assert_eq "issue #117: a relative cd into the worktree is allowed (no output)" "$out" ""

# A relative `cd ..`-style hop from INSIDE the worktree onto a sibling checkout
# that IS on main - proves relative resolution denies correctly too, not just
# the descend-into-worktree case above.
out="$(run_hook "cd ../work && git push" "$WORKTREE")"
assert_contains "issue #117: a relative cd (..) onto a sibling checkout on main is denied" "$out" '"permissionDecision": "deny"'

# An unresolvable cd target (an unexpanded shell variable) leaves the tracked
# directory wherever it already was - here, the untouched payload cwd (the
# primary checkout, on main), so this DENIES. This is the payload-cwd's own
# branch showing through, not a guarantee: see the edge-case table's "not
# uniformly conservative" note - the same fallback would instead ALLOW if the
# payload cwd (or a prior resolved cd/-C) were on a non-default branch.
out="$(run_hook 'cd "$SOME_UNEXPANDED_VAR" && git push' "$CLONE")"
assert_contains "issue #117: an unresolvable cd (unexpanded var) inherits the payload cwd's branch (main) and denies" "$out" '"permissionDecision": "deny"'

# ---- git -C <dir> push: the related deny-bypass folded into this change ----

# `git -C <worktree> push` (no cd at all) resolves against the -C directory,
# not the payload cwd - allowed, same as the cd-prefixed case above.
out="$(run_hook "git -C $WORKTREE push" "$CLONE")"
assert_eq "issue #117: git -C <worktree> push (no cd) is allowed (no output)" "$out" ""

# `git -C <primary-checkout> push` - the actual bypass this section closes:
# before this fix, argv[1] == "-C" meant this was never even inspected.
out="$(run_hook "git -C $CLONE push" "$SCRATCH")"
assert_contains "issue #117: git -C <checkout-on-main> push is now denied (was a silent bypass before this fix)" "$out" '"permissionDecision": "deny"'

# `-C` composes with a preceding `cd` - the LAST directory-changing token
# (cd or -C) before push wins, matching git's own "-C overrides cwd" rule.
out="$(run_hook "cd $CLONE && git -C $WORKTREE push" "$SCRATCH")"
assert_eq "issue #117: cd onto main, then git -C onto the worktree, is allowed (the -C wins)" "$out" ""

out="$(run_hook "cd $WORKTREE && git -C $CLONE push" "$SCRATCH")"
assert_contains "issue #117: cd onto the worktree, then git -C onto main, is denied (the -C wins)" "$out" '"permissionDecision": "deny"'

# An unresolvable -C argument (unexpanded var) falls back to exec_cwd exactly
# like an unresolvable cd does.
out="$(run_hook 'git -C "$SOME_UNEXPANDED_VAR" push' "$CLONE")"
assert_contains "issue #117: an unresolvable -C argument falls back to exec_cwd (payload cwd, main) and denies" "$out" '"permissionDecision": "deny"'

# Multiple -C flags in one invocation compound relative to the PRECEDING -C,
# matching real git semantics, not the original exec_cwd - a relative second
# -C from $SCRATCH ("worktree-feature") composed onto the first -C's already-
# absolute $WORKTREE would double up incorrectly if resolved against exec_cwd
# instead; resolving against the running target_dir keeps it correct. Here
# the first -C lands on the worktree (feature branch), and the relative
# second -C hops from there back out to the sibling checkout on main.
out="$(run_hook "git -C $WORKTREE -C ../work push" "$SCRATCH")"
assert_contains "issue #117: multiple -C flags compound relative to the preceding -C and correctly deny" "$out" '"permissionDecision": "deny"'

# ---- destination-unresolvable-therefore-deny: closes a bypass found in review ----
#
# resolve_cd_target()/git_push_target_dir() accept ANY syntactically valid
# cd/-C argument as a real, resolved directory - they never check it is an
# actual, accessible git checkout. If the resulting target_dir is NOT a git
# checkout, current_branch(target_dir) fails and returns None; for a bare
# push, `if dest:` being false previously meant the destination check was
# SKIPPED entirely - an allow, not a deny - even though the payload cwd
# ($CLONE) genuinely sits on main. A crew session could bypass the guard on
# any bare push just by cd'ing (or git -C'ing) into an ordinary, real,
# non-git directory first - no adversarial intent required. An unresolvable
# destination on a bare/HEAD push must now deny instead of silently
# skipping the check.
out="$(run_hook "cd /tmp && git push" "$CLONE")"
assert_contains "issue #117: cd into a non-git directory (/tmp) no longer bypasses the guard - denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "git -C /tmp push" "$CLONE")"
assert_contains "issue #117: git -C into a non-git directory (/tmp) no longer bypasses the guard - denied" "$out" '"permissionDecision": "deny"'

out="$(run_hook "cd /this/dir/does/not/exist/nowhere && git push" "$CLONE")"
assert_contains "issue #117: cd into a nonexistent directory no longer bypasses the guard - denied" "$out" '"permissionDecision": "deny"'

# An explicit-refspec push is unaffected by this: its destination comes
# directly from the command text, never from a git call that can be steered
# onto a bogus directory and made to fail - so it still denies/allows on the
# refspec itself, unchanged by the fix above.
out="$(run_hook "cd /tmp && git push origin feature/foo" "$CLONE")"
assert_eq "issue #117: an explicit-refspec push after cd into a non-git dir is still evaluated on the refspec (allowed, no output)" "$out" ""

( cd "$CLONE" && git checkout -q feature/foo )
git worktree remove -q "$WORKTREE" 2>/dev/null || true

# Restore the ambient crew identity the FOLLOWING section depends on - do NOT
# `unset` here. The existing "Crew session WITH the grant recorded" section
# right after this insertion point never re-exports WINGMAN_CREW_ID itself;
# it relies on `dev1`/`developer` still being ambient from the file's own
# earlier "Crew session, no grant" section. An `unset` here would make its
# four "crew, GRANTED: ... allowed (no output)" assertions pass vacuously via
# check_merge_paths()'s own `if not crew_id: return` early-out (a non-crew
# session is allowed regardless of any grant) instead of genuinely exercising
# the grant-lifts-deny path - the suite would stay green while that coverage
# silently went vacuous.
export WINGMAN_CREW_ID=dev1
export WINGMAN_CREW_TYPE=developer

# ============================================================================
# Crew session WITH the grant recorded (allow_merge: true, review_gate_waived:
# true): every path above is now permitted. review_gate_waived is granted
# alongside allow_merge here deliberately - this section is only testing that
# a grant lifts the deny across every merge-equivalent shape (issue #46's
# original coverage), unchanged by issue #132. The review-evidence gate ITSELF
# (allow_merge granted, waiver NOT granted) gets its own dedicated coverage
# further below, against a fake `gh`.
# ============================================================================
wm_state crew-add --id dev1 --type developer --repo "$TEST_REPO" \
  --window w1 --session-id s1 --allow-merge --waive-review-gate >/dev/null

out="$(run_hook "gh pr merge 46")"
assert_eq "crew, GRANTED (+waived): gh pr merge 46 is allowed (no output)" "$out" ""

out="$(run_hook "gh pr merge --auto")"
assert_eq "crew, GRANTED (+waived): gh pr merge --auto is allowed (no output)" "$out" ""

out="$(run_hook "gh api -X PUT repos/owner/repo/pulls/46/merge")"
assert_eq "crew, GRANTED (+waived): gh api -X PUT .../merge is allowed (no output)" "$out" ""

out="$(run_hook "git push origin main" "$CLONE")"
assert_eq "crew, GRANTED (+waived): git push origin main is allowed (no output)" "$out" ""

# A grant recorded for a DIFFERENT crew id must not leak to this one.
unset WINGMAN_CREW_ID; export WINGMAN_CREW_ID=dev2
out="$(run_hook "gh pr merge 46")"
assert_contains "a different crew id without its own grant is still denied" "$out" '"permissionDecision": "deny"'
export WINGMAN_CREW_ID=dev1

# ============================================================================
# The --allow-merge grant guard itself: who may set it
# ============================================================================
unset WINGMAN_CREW_TYPE

# A crew member granting itself autonomy - denied, regardless of type.
out="$(run_hook '$WINGMAN_STATE crew-set --id dev1 --allow-merge true')"
assert_contains "a developer cannot grant itself merge autonomy" "$out" '"permissionDecision": "deny"'
assert_contains "self-grant denial cites issue #46" "$out" "issue #46"

# A plain (non-lead) crew member granting autonomy to some OTHER id - denied too.
out="$(run_hook '$WINGMAN_STATE crew-set --id someone-else --allow-merge true')"
assert_contains "a non-lead crew member cannot grant merge autonomy to anyone" "$out" '"permissionDecision": "deny"'

# A lead granting one of its OWN workers autonomy - allowed.
export WINGMAN_CREW_ID=lead1
export WINGMAN_CREW_TYPE=lead
out="$(run_hook '$WINGMAN_STATE crew-set --id dev1 --allow-merge true')"
assert_eq "a lead granting a worker merge autonomy is allowed (no output)" "$out" ""

# A lead granting itself autonomy - still denied (self-grant applies to leads too).
out="$(run_hook '$WINGMAN_STATE crew-set --id lead1 --allow-merge true')"
assert_contains "a lead cannot grant itself merge autonomy" "$out" '"permissionDecision": "deny"'

# wingman's own top-level session (no WINGMAN_CREW_ID at all) - always allowed.
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE
out="$(run_hook '$WINGMAN_STATE crew-set --id dev1 --allow-merge true')"
assert_eq "wingman's own top-level session can grant merge autonomy (no output)" "$out" ""

# A crew-set call that is NOT about --allow-merge is untouched by this guard.
export WINGMAN_CREW_ID=dev1
out="$(run_hook '$WINGMAN_STATE crew-set --id dev1 --status working --summary "on it"')"
assert_eq "an ordinary crew-set (no --allow-merge) is allowed (no output)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# cmd_match.py fails CLOSED on a command it cannot fully lex (issue #56) -
# this hook must deny on that, and must NOT false-deny legitimate multi-line
# shapes (a crew-set continuation, a multi-line commit message, a heredoc
# used to build up a PR body, including one nested inside a substitution).
# ============================================================================
export WINGMAN_CREW_ID=dev1
export WINGMAN_CREW_TYPE=developer

CONTINUATION="$(printf '$WINGMAN_STATE crew-set --id dev1 --status working \\\n  --summary "on it"')"
out="$(run_hook "$CONTINUATION")"
assert_eq "the documented multi-line crew-set continuation is allowed (no output)" "$out" ""

COMMIT_MSG="$(printf 'git commit -m "First line\nSecond line with an apostrophe: don'"'"'t worry"')"
out="$(run_hook "$COMMIT_MSG")"
assert_eq "a multi-line git commit -m message is allowed (no output)" "$out" ""

BARE_HEREDOC="$(printf 'cat <<EOF\nThis doesn'"'"'t push to main.\nEOF\n')"
out="$(run_hook "$BARE_HEREDOC")"
assert_eq "a bare heredoc body with an apostrophe is allowed (no output)" "$out" ""

GUARDED_MENTION="$(printf "cat <<'EOF'\nDon't run gh pr merge 123 --squash directly.\nEOF\n")"
out="$(run_hook "$GUARDED_MENTION")"
assert_eq "a quoted-delimiter heredoc merely documenting gh pr merge is allowed (no output)" "$out" ""

# The r4 idiom: a heredoc nested inside a substitution, body containing both
# an apostrophe and an unbalanced paren, in all three substitution forms -
# must stay allowed in every one, and specifically must not trip
# merge_reason()'s own deny text.
NESTED_BODY="This doesn't (have both."
for form in double-quoted unquoted backtick; do
  case "$form" in
    double-quoted)
      cmd="$(printf 'gh pr create --body "$(cat <<'"'"'EOF'"'"'\n%s\nEOF\n)"' "$NESTED_BODY")" ;;
    unquoted)
      cmd="$(printf 'gh pr create --body $(cat <<'"'"'EOF'"'"'\n%s\nEOF\n)' "$NESTED_BODY")" ;;
    backtick)
      cmd="$(printf 'gh pr create --body `cat <<'"'"'EOF'"'"'\n%s\nEOF\n`' "$NESTED_BODY")" ;;
  esac
  out="$(run_hook "$cmd")"
  assert_eq "nested heredoc in a $form substitution (apostrophe+paren body) is allowed (no output)" "$out" ""
done

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ---- fail closed: a malformed command that also matches the pre-gate -------
export WINGMAN_CREW_ID=dev1
export WINGMAN_CREW_TYPE=developer
out="$(run_hook "merge 'oops")"
assert_contains "an unresolvable command mentioning a trigger word is denied" \
  "$out" '"permissionDecision": "deny"'
assert_contains "the parse-failure denial names the heredoc-quoting remedy verbatim" \
  "$out" "<<'EOF'"

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ---- an unrelated malformed command never even reaches command_segments ---
# (the cheap substring pre-gate exits 0 before any Python/parsing runs at all)
export WINGMAN_CREW_ID=dev1
export WINGMAN_CREW_TYPE=developer
out="$(run_hook "echo 'oops")"
assert_eq "an unresolvable command mentioning no trigger word is allowed (pre-gate skips it)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# PR #72 review, finding 1 (must-fix): a here-string (<<<) is not a heredoc
# and must never swallow a following command as an opaque "body" - that
# would hide a real gh pr merge from this exact guard.
# ============================================================================
# A fresh crew id, never granted --allow-merge (dev1 was granted earlier in
# this file and stays granted for the rest of the run - reusing it here would
# test the grant bypass, not the here-string fix).
export WINGMAN_CREW_ID=dev-herestring
export WINGMAN_CREW_TYPE=developer

HERESTRING_HIDDEN_MERGE="$(printf 'grep x <<<foo\ngh pr merge 5 --squash\n<foo')"
out="$(run_hook "$HERESTRING_HIDDEN_MERGE")"
assert_contains "a merge hidden behind a here-string is still denied (no heredoc misparse)" \
  "$out" '"permissionDecision": "deny"'

# A plain here-string with nothing further must stay allowed, not hard-deny
# (the same misparse's other symptom: reading "<<<" as an unterminated
# heredoc delimiter).
out="$(run_hook 'grep foo <<< "$var"')"
assert_eq "a plain here-string with a variable is allowed (no output)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# issue #132: the review-evidence gate itself. allow_merge is granted but the
# waiver is NOT, so every gh pr merge attempt below must resolve a real PR
# (via a fake `gh` answering `gh pr view ... --json reviews,number,url`) and
# find genuine, verifiable review evidence before it is allowed through.
# ============================================================================
mkdir -p "$SCRATCH/bin"
GH_REVIEWS_JSON="$SCRATCH/reviews.json"
GH_NODE_JSON="$SCRATCH/node.json"
GH_LOG="$SCRATCH/gh.log"
: > "$GH_LOG"
# issue #138: the PR's current head commit, used throughout this section's
# fixtures as `headRefOid` (and, for a genuine APPROVED review meant to be
# fresh, that same review's own `commit.oid`) so shape-1/shape-2's new
# staleness checks see a matching, non-stale head unless a fixture
# deliberately diverges it to exercise staleness.
HEAD_SHA_FRESH="deadbeef00000000000000000000000000000001"
cat > "$SCRATCH/bin/gh" <<SH
#!/usr/bin/env bash
echo "\$@" >> "$GH_LOG"
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  cat "$GH_REVIEWS_JSON"
  exit 0
fi
# The graphql node(id:\$id){...on PullRequest{...}} resolution call (issue
# #132's GraphQL merge path): identified by the "\$id:ID!" fragment the
# hook's own NODE_TO_PR_QUERY always embeds, so it never collides with the
# mergePullRequest mutation itself (which this fake gh never has to answer -
# the hook only ever inspects that command's own text, it never runs it).
case "\$*" in
  *'\$id:ID!'*) cat "$GH_NODE_JSON"; exit 0 ;;
esac
exit 1
SH
chmod +x "$SCRATCH/bin/gh"
export PATH="$SCRATCH/bin:$PATH"

export WINGMAN_CREW_ID=devA
export WINGMAN_CREW_TYPE=developer
wm_state crew-add --id devA --type developer --repo "$TEST_REPO" \
  --window wA --session-id sA --allow-merge >/dev/null

# --- no reviews at all: denied, and NOT with the old merge_reason() text ---
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": []}
JSON
out="$(run_hook "gh pr merge 46")"
assert_contains "review gate: no reviews at all is denied" "$out" '"permissionDecision": "deny"'
assert_contains "review gate: denial cites issue #132" "$out" "issue #132"
assert_not_contains "review gate: denial is the NEW reason, not the old merge_reason()" \
  "$out" "let the pilot merge it"

# --- a COMMENTED review carrying the requester's OWN crew id's marker + ----
# VERDICT: approve - self-approval, denied.
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:devA --> VERDICT: approve - looks fine"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_contains "review gate: own-crew-id VERDICT: approve is denied (self-approval)" \
  "$out" '"permissionDecision": "deny"'
assert_contains "review gate: self-approval denial names it" "$out" "self-approval"

# --- a COMMENTED review from a DIFFERENT crew id + VERDICT: approve, but no -
# matching type:reviewer roster record at all - unrecognized id, denied.
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:ghost-reviewer --> VERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_contains "review gate: an unrecognized reviewer crew id is denied" \
  "$out" '"permissionDecision": "deny"'
assert_contains "review gate: denial names the unrecognized id" "$out" "no matching roster record"

# --- a real, independently-spawned reviewer whose delivery matches this PR -
# allowed.
wm_state crew-add --id rev1 --type reviewer --repo "$TEST_REPO" \
  --window wr1 --session-id sr1 >/dev/null
wm_state crew-set --id rev1 --delivery "https://github.com/acme/widgets/pull/46" >/dev/null
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev1 --> VERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_eq "review gate: a genuine reviewer's comment-fallback approve is allowed (no output)" "$out" ""

# --- same reviewer record, but its delivery points at a DIFFERENT PR -------
# mismatched delivery, denied.
wm_state crew-set --id rev1 --delivery "https://github.com/acme/widgets/pull/999" >/dev/null
out="$(run_hook "gh pr merge 46")"
assert_contains "review gate: a reviewer's delivery pointing elsewhere is denied" \
  "$out" '"permissionDecision": "deny"'
assert_contains "review gate: denial names the delivery mismatch" "$out" "does not name this PR"
wm_state crew-set --id rev1 --delivery "https://github.com/acme/widgets/pull/46" >/dev/null

# --- the reviewer id resolves, but its roster record is not type:reviewer --
wm_state crew-add --id rev-imposter --type developer --repo "$TEST_REPO" \
  --window wri --session-id sri >/dev/null
wm_state crew-set --id rev-imposter --delivery "https://github.com/acme/widgets/pull/46" >/dev/null
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-imposter --> VERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_contains "review gate: a non-reviewer-type crew id's approve is denied" \
  "$out" '"permissionDecision": "deny"'
assert_contains "review gate: denial names the wrong type" "$out" "not \`reviewer\`"

# --- a real APPROVED review state (any author) - allowed, no marker needed -
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "APPROVED", "author": {"login": "a-real-human"}, "body": "looks good to me", "commit": {"oid": "$HEAD_SHA_FRESH"}}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_eq "review gate: a real APPROVED review state is allowed regardless of marker (no output)" "$out" ""

# --- a stale request-changes verdict from an old round can't be shadowed by -
# an earlier approve still counting as live: latest per crew id wins.
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev1 --> VERDICT: approve - lgtm"},
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev1 --> VERDICT: request changes - actually no"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_contains "review gate: a later request-changes shadows an earlier approve from the same reviewer" \
  "$out" '"permissionDecision": "deny"'

# --- ...and the reverse: a later approve supersedes an earlier request-changes
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev1 --> VERDICT: request changes - fix X"},
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev1 --> VERDICT: approve - fixed, lgtm now"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_eq "review gate: a later approve from the same reviewer supersedes an earlier request-changes (no output)" "$out" ""

# --- a reviewer already stood down and pruned into crew-archive.jsonl is ----
# still recognized (the roster cross-check falls back to the archive).
wm_state crew-add --id rev-archived --type reviewer --repo "$TEST_REPO" \
  --window wra --session-id sra >/dev/null
wm_state crew-set --id rev-archived --delivery "https://github.com/acme/widgets/pull/46" --status done >/dev/null
wm_state standdown --id rev-archived >/dev/null
wm_state prune >/dev/null
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-archived --> VERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_eq "review gate: an archived (stood-down, pruned) reviewer record is still recognized (no output)" "$out" ""

# --- allow_merge + review_gate_waived: true, no reviews at all - allowed ---
# (the waiver is honored - unchanged post-grant behavior).
wm_state crew-set --id devA --review-gate-waived true >/dev/null
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": []}
JSON
out="$(run_hook "gh pr merge 46")"
assert_eq "review gate: review_gate_waived honored with no reviews at all (no output)" "$out" ""
wm_state crew-set --id devA --review-gate-waived false >/dev/null

# --- the REST merge endpoint shape (gh api -X PUT .../merge) goes through ---
# the identical evidence check, resolving owner/repo/number straight out of
# the REST path itself (no gh call needed to resolve the PR).
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": []}
JSON
out="$(run_hook "gh api -X PUT repos/acme/widgets/pulls/46/merge")"
assert_contains "review gate: REST merge endpoint with no reviews is denied" \
  "$out" '"permissionDecision": "deny"'
assert_contains "review gate: REST merge denial cites issue #132" "$out" "issue #132"

cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "APPROVED", "author": {"login": "a-real-human"}, "body": "looks good", "commit": {"oid": "$HEAD_SHA_FRESH"}}
]}
JSON
out="$(run_hook "gh api -X PUT repos/acme/widgets/pulls/46/merge")"
assert_eq "review gate: REST merge endpoint with a real APPROVED review is allowed (no output)" "$out" ""

# --- the graphql mergePullRequest mutation shape (issue #132's decided-in- --
# scope GraphQL path): the pullRequestId node id is resolved to owner/repo/
# number via one extra `gh api graphql` call before the same evidence check
# runs.
cat > "$GH_NODE_JSON" <<'JSON'
{"data": {"node": {"number": 46, "repository": {"owner": {"login": "acme"}, "name": "widgets"}}}}
JSON
GRAPHQL_MERGE='gh api graphql -f query='"'"'mutation{mergePullRequest(input:{pullRequestId:"PR_kwABC"}){clientMutationId}}'"'"''

cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": []}
JSON
out="$(run_hook "$GRAPHQL_MERGE")"
assert_contains "review gate: graphql mergePullRequest with no reviews is denied" \
  "$out" '"permissionDecision": "deny"'
assert_contains "review gate: graphql merge denial cites issue #132" "$out" "issue #132"

cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "APPROVED", "author": {"login": "a-real-human"}, "body": "looks good", "commit": {"oid": "$HEAD_SHA_FRESH"}}
]}
JSON
out="$(run_hook "$GRAPHQL_MERGE")"
assert_eq "review gate: graphql mergePullRequest resolves the node id and allows with a real APPROVED review (no output)" "$out" ""

# A node id the fake gh cannot resolve (simulated resolution failure) - fails
# CLOSED (denied), not allowed unchecked.
rm -f "$GH_NODE_JSON"
out="$(run_hook "$GRAPHQL_MERGE")"
assert_contains "review gate: an unresolvable graphql node id fails closed (denied)" \
  "$out" '"permissionDecision": "deny"'
assert_contains "review gate: node-resolution-failure denial cites issue #132" "$out" "issue #132"
cat > "$GH_NODE_JSON" <<'JSON'
{"data": {"node": {"number": 46, "repository": {"owner": {"login": "acme"}, "name": "widgets"}}}}
JSON

# --- git push straight to the default branch with allow_merge granted and --
# no waiver - denied (no PR to point review evidence against).
out="$(run_hook "git push origin main" "$CLONE")"
assert_contains "review gate: a direct default-branch push with no waiver is denied (no PR to check)" \
  "$out" '"permissionDecision": "deny"'
assert_contains "review gate: push-with-no-PR denial names the reason" "$out" "no PR to point review evidence"

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# issue #132: --review-gate-waived is gated by the identical self-grant
# restriction --allow-merge already carries.
# ============================================================================
export WINGMAN_CREW_ID=devA
export WINGMAN_CREW_TYPE=developer

out="$(run_hook '$WINGMAN_STATE crew-set --id devA --review-gate-waived true')"
assert_contains "a developer cannot waive its own review gate" "$out" '"permissionDecision": "deny"'
assert_contains "review-gate self-grant denial cites issue #132" "$out" "issue #132"

out="$(run_hook '$WINGMAN_STATE crew-set --id someone-else --review-gate-waived true')"
assert_contains "a non-lead crew member cannot waive the review gate for anyone" \
  "$out" '"permissionDecision": "deny"'

export WINGMAN_CREW_ID=lead1
export WINGMAN_CREW_TYPE=lead
out="$(run_hook '$WINGMAN_STATE crew-set --id devA --review-gate-waived true')"
assert_eq "a lead waiving a worker's review gate is allowed (no output)" "$out" ""

out="$(run_hook '$WINGMAN_STATE crew-set --id lead1 --review-gate-waived true')"
assert_contains "a lead cannot waive its own review gate" "$out" '"permissionDecision": "deny"'

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE
out="$(run_hook '$WINGMAN_STATE crew-set --id devA --review-gate-waived true')"
assert_eq "wingman's own top-level session can waive the review gate (no output)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# PR #134 review, findings 1+2: the roster writes the review-evidence gate
# ITSELF trusts (crew-add, crew-set --delivery) must be as tightly gated as
# allow_merge/review_gate_waived - otherwise a policed session can just write
# its way past the gate instead of getting a genuine review.
# ============================================================================
export WINGMAN_CREW_ID=devA
export WINGMAN_CREW_TYPE=developer

# --- finding 1: self-waive via crew-add (re-adding one's own record) -------
out="$(run_hook '$WINGMAN_STATE crew-add --id devA --type developer --repo /tmp --window w --session-id s --allow-merge --waive-review-gate')"
assert_contains "a developer cannot re-add its own record via crew-add" "$out" '"permissionDecision": "deny"'
assert_contains "self-add denial cites issue #132" "$out" "issue #132"
assert_contains "self-add denial names crew-add specifically" "$out" "crew-add"

# The identical attempt via the documented self-report idiom
# (--id "$WINGMAN_CREW_ID", unexpanded at this hook) must be denied the same
# way - a literal-string-only comparison would have missed this spelling.
out="$(run_hook '$WINGMAN_STATE crew-add --id "$WINGMAN_CREW_ID" --type developer --repo /tmp --window w --session-id s --allow-merge')"
assert_contains "self-add via the \$WINGMAN_CREW_ID idiom is denied identically" "$out" '"permissionDecision": "deny"'

# --- finding 2: minting a sockpuppet reviewer via crew-add ------------------
out="$(run_hook '$WINGMAN_STATE crew-add --id fake-reviewer --type reviewer --repo /tmp --window w2 --session-id s2')"
assert_contains "a developer cannot mint a NEW crew-add record at all" "$out" '"permissionDecision": "deny"'
assert_contains "sockpuppet-mint denial cites issue #132" "$out" "issue #132"

# --- finding 2, other half: repointing an EXISTING id's delivery -----------
wm_state crew-add --id rev-real --type reviewer --repo "$TEST_REPO" \
  --window wrr --session-id srr >/dev/null
out="$(run_hook '$WINGMAN_STATE crew-set --id rev-real --delivery https://github.com/acme/widgets/pull/999')"
assert_contains "a developer cannot repoint another id's --delivery" "$out" '"permissionDecision": "deny"'
assert_contains "delivery-repoint denial cites issue #132" "$out" "issue #132"

# --- ordinary self-report of one's OWN delivery is unaffected --------------
out="$(run_hook '$WINGMAN_STATE crew-set --id devA --delivery https://github.com/acme/widgets/pull/46')"
assert_eq "a developer setting --delivery on ITS OWN literal id is allowed (no output)" "$out" ""

# The documented idiom (--id "$WINGMAN_CREW_ID") must be recognized as self
# too, not just a literal id string match.
out="$(run_hook '$WINGMAN_STATE crew-set --id "$WINGMAN_CREW_ID" --delivery https://github.com/acme/widgets/pull/46')"
assert_eq "a developer self-reporting via the \$WINGMAN_CREW_ID idiom is allowed (no output)" "$out" ""

# A crew-set call with no --delivery at all is untouched by this restriction.
out="$(run_hook '$WINGMAN_STATE crew-set --id someone-else --status working --summary "hi"')"
assert_eq "a crew-set with no --delivery is unaffected regardless of --id (no output)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# --- a lead spawning one of its own NEW workers via crew-add is unaffected -
export WINGMAN_CREW_ID=lead1
export WINGMAN_CREW_TYPE=lead
out="$(run_hook '$WINGMAN_STATE crew-add --id new-worker-1 --type developer --repo /tmp --window w3 --session-id s3')"
assert_eq "a lead creating a NEW worker via crew-add is allowed (no output)" "$out" ""

# ...but a lead can never crew-add ITSELF, literally or via the idiom.
out="$(run_hook '$WINGMAN_STATE crew-add --id lead1 --type lead --repo /tmp --window w4 --session-id s4 --allow-merge')"
assert_contains "a lead cannot re-add its own record via crew-add" "$out" '"permissionDecision": "deny"'

out="$(run_hook '$WINGMAN_STATE crew-add --id "$WINGMAN_CREW_ID" --type lead --repo /tmp --window w4 --session-id s4 --allow-merge')"
assert_contains "...nor via the \$WINGMAN_CREW_ID idiom" "$out" '"permissionDecision": "deny"'

# ...nor repoint its OWN delivery onto anyone else, or vice versa.
out="$(run_hook '$WINGMAN_STATE crew-set --id new-worker-1 --delivery https://github.com/acme/widgets/pull/46')"
assert_contains "a lead repointing a worker's delivery is still denied (delivery is self-report-only)" \
  "$out" '"permissionDecision": "deny"'

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# --- wingman's own top-level session (no WINGMAN_CREW_ID) is exempt from ---
# both new restrictions, exactly like every other actor-restriction in this
# file.
out="$(run_hook '$WINGMAN_STATE crew-add --id admin-added --type reviewer --repo /tmp --window w5 --session-id s5')"
assert_eq "wingman's own top-level session can crew-add anything (no output)" "$out" ""

out="$(run_hook '$WINGMAN_STATE crew-set --id admin-added --delivery https://github.com/acme/widgets/pull/46')"
assert_eq "wingman's own top-level session can set delivery on any id (no output)" "$out" ""

# ============================================================================
# issue #136: crew-set --type gets the identical self/wingman restriction
# already applied to --delivery (not crew-add's lead-non-self carve-out -
# there is no legitimate flow that changes an existing id's type after
# crew-add time).
# ============================================================================
export WINGMAN_CREW_ID=devA
export WINGMAN_CREW_TYPE=developer

# --- repointing an EXISTING other id's --type is denied ---------------------
wm_state crew-add --id rev-real2 --type reviewer --repo "$TEST_REPO" \
  --window wrr2 --session-id srr2 >/dev/null
out="$(run_hook '$WINGMAN_STATE crew-set --id rev-real2 --type developer')"
assert_contains "a developer cannot repoint another id's --type" "$out" '"permissionDecision": "deny"'
assert_contains "type-repoint denial cites issue #136" "$out" "issue #136"

# --- ordinary self-report of one's OWN type is unaffected -------------------
out="$(run_hook '$WINGMAN_STATE crew-set --id devA --type developer')"
assert_eq "a developer setting --type on ITS OWN literal id is allowed (no output)" "$out" ""

out="$(run_hook '$WINGMAN_STATE crew-set --id "$WINGMAN_CREW_ID" --type developer')"
assert_eq "a developer self-reporting via the \$WINGMAN_CREW_ID idiom is allowed (no output)" "$out" ""

# A crew-set call with no --type at all is untouched by this restriction.
out="$(run_hook '$WINGMAN_STATE crew-set --id someone-else --status working --summary "hi"')"
assert_eq "a crew-set with no --type is unaffected regardless of --id (no output)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# --- a lead cannot repoint a worker's --type either (type is self-report- ---
# only, unlike crew-add's lead-non-self carve-out) --------------------------
export WINGMAN_CREW_ID=lead1
export WINGMAN_CREW_TYPE=lead
out="$(run_hook '$WINGMAN_STATE crew-set --id new-worker-1 --type reviewer')"
assert_contains "a lead repointing a worker's type is still denied (type is self-report-only)" \
  "$out" '"permissionDecision": "deny"'
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# --- wingman's own top-level session is exempt ------------------------------
out="$(run_hook '$WINGMAN_STATE crew-set --id admin-added --type reviewer')"
assert_eq "wingman's own top-level session can set type on any id (no output)" "$out" ""

# --- the narrowed pre-gate leaves unrelated, non-crew-set commands alone ----
# (paralleling the existing "an unrelated malformed command never even
# reaches command_segments" test at lines 386-391): a command that mentions
# --type but never mentions crew-set, and that the lexer cannot fully parse,
# must still be allowed - the pre-gate should exit 0 before any Python/
# parsing runs, exactly as it does today for an unrelated malformed command
# with no trigger word at all. This is the regression this fix's own review
# flagged against a bare `*--type*` pre-gate alternative.
export WINGMAN_CREW_ID=dev1
export WINGMAN_CREW_TYPE=developer
out="$(run_hook "kubectl create secret generic foo --type=Opaque --from-literal=key='oops")"
assert_eq "an unrelated, unparseable --type command with no crew-set is allowed (pre-gate skips it)" "$out" ""
unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# PR #134 review, minor finding 1: shape-1 (a real APPROVED review, any
# author) must respect latest-verdict-per-author ordering exactly like
# shape-2 already does - a stale APPROVED must not outlive a later
# CHANGES_REQUESTED from that SAME (necessarily distinct) account.
# ============================================================================
export WINGMAN_CREW_ID=devA
export WINGMAN_CREW_TYPE=developer

cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "APPROVED", "author": {"login": "real-human"}, "body": "lgtm", "commit": {"oid": "$HEAD_SHA_FRESH"}},
  {"state": "CHANGES_REQUESTED", "author": {"login": "real-human"}, "body": "actually no"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_contains "shape-1: a later CHANGES_REQUESTED from the SAME real reviewer supersedes an earlier APPROVED" \
  "$out" '"permissionDecision": "deny"'

cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "CHANGES_REQUESTED", "author": {"login": "real-human"}, "body": "fix X"},
  {"state": "APPROVED", "author": {"login": "real-human"}, "body": "fixed, lgtm now", "commit": {"oid": "$HEAD_SHA_FRESH"}}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_eq "shape-1: ...and the reverse - a later APPROVED from the same reviewer is allowed (no output)" "$out" ""

# A different real reviewer's still-live APPROVED is unaffected by an
# unrelated reviewer's own CHANGES_REQUESTED.
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$HEAD_SHA_FRESH", "reviews": [
  {"state": "CHANGES_REQUESTED", "author": {"login": "reviewer-one"}, "body": "fix X"},
  {"state": "APPROVED", "author": {"login": "reviewer-two"}, "body": "lgtm from me", "commit": {"oid": "$HEAD_SHA_FRESH"}}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_eq "shape-1: a DIFFERENT reviewer's live APPROVED still counts on its own (no output)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# PR #134 review, minor finding 2: `gh pr merge`'s own ref parsing must skip
# a value-taking flag's argument (e.g. --body/--subject) rather than misread
# it as the positional PR ref - proven by observing which `gh pr view`
# invocation actually ran, not just the allow/deny outcome (which failed
# closed either way and so could not distinguish the two).
# ============================================================================
export WINGMAN_CREW_ID=devA
export WINGMAN_CREW_TYPE=developer
# devA picked up review_gate_waived: true from an earlier section in this
# file (lead1 granted it) - reset directly (test setup, not through the
# hook) so the evidence check actually runs and calls `gh pr view` for this
# section to observe, rather than short-circuiting on the waiver.
wm_state crew-set --id devA --review-gate-waived false >/dev/null

: > "$GH_LOG"
run_hook 'gh pr merge --body "merge it" --squash' >/dev/null
assert_contains "a --body value is never misread as the PR ref (falls through to current-branch resolution)" \
  "$(cat "$GH_LOG")" "pr view --json number -q .number"
assert_not_contains "...and specifically never queries a PR literally named \"merge it\"" \
  "$(cat "$GH_LOG")" "pr view merge it"

: > "$GH_LOG"
run_hook 'gh pr merge 46 --subject "release notes" --squash' >/dev/null
assert_contains "an explicit ref is still read correctly alongside a --subject value" \
  "$(cat "$GH_LOG")" "pr view 46"
assert_not_contains "...and the --subject value itself is never queried as if it were the ref" \
  "$(cat "$GH_LOG")" "pr view release notes"

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# issue #135: spawn-time per-verdict hash commitments close the marker-
# impersonation gap latent in shape 2's comment-fallback evidence (the PR
# #134 round-2 residual, item 1). A `type: reviewer` record minted with
# --review-token carries a review_commit_approve/review_commit_request_
# changes commitment; a VERDICT: approve reusing its marker is now only
# trusted alongside a matching wingman-review-proof marker whose preimage
# hashes to the recorded commitment. A record with NO commitment on file
# (test 1, above - the existing "genuine reviewer's comment-fallback
# approve" case using untokened rev1) falls straight through to the
# pre-issue-#135 marker-only acceptance, unchanged.
# ============================================================================
export WINGMAN_CREW_ID=dev-tok
export WINGMAN_CREW_TYPE=developer
wm_state crew-add --id dev-tok --type developer --repo "$TEST_REPO" \
  --window wdt --session-id sdt --allow-merge >/dev/null

REVIEW_TOKEN1="$(uv run --no-project --quiet python -c 'import secrets;print(secrets.token_hex(32))')"
wm_state crew-add --id rev-tok1 --type reviewer --repo "$TEST_REPO" \
  --window wrt1 --session-id srt1 --review-token "$REVIEW_TOKEN1" >/dev/null
wm_state crew-set --id rev-tok1 --delivery "https://github.com/acme/widgets/pull/46" >/dev/null

PROOF_APPROVE1="$(WM_REVIEW_TOKEN="$REVIEW_TOKEN1" WINGMAN_CREW_ID=rev-tok1 wm_state review-sign --verdict approve)"

# --- test 2: tokened reviewer, valid proof, genuine approve is allowed -----
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok1 -->\n<!-- wingman-review-proof:$PROOF_APPROVE1 -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_eq "issue #135: a tokened reviewer's genuine approve with a valid proof is allowed (no output)" "$out" ""

# --- test 3: tokened reviewer, forged approve with NO proof marker at all --
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok1 --> VERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_contains "issue #135: a forged approve with no proof marker is denied" "$out" '"permissionDecision": "deny"'
assert_contains "issue #135: denial names the missing-proof case" "$out" "no wingman-review-proof marker"

# --- test 4: tokened reviewer, forged approve with a garbage/mismatched proof
GARBAGE_PROOF="$(printf '0%.0s' $(seq 1 64))"
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok1 -->\n<!-- wingman-review-proof:$GARBAGE_PROOF -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_contains "issue #135: a forged approve with a mismatched proof is denied" "$out" '"permissionDecision": "deny"'
assert_contains "issue #135: denial names the mismatch" "$out" "does not match the commitment"

# --- test 5: a reviewer's own genuine request-changes preimage cannot be ---
# repurposed as a forged approve proof (verifies the "independent
# commitments" soundness claim directly, not just by reasoning).
PROOF_RC1="$(WM_REVIEW_TOKEN="$REVIEW_TOKEN1" WINGMAN_CREW_ID=rev-tok1 wm_state review-sign --verdict "request changes")"
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok1 -->\n<!-- wingman-review-proof:$PROOF_RC1 -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_contains "issue #135: a genuine request-changes preimage cannot be repurposed as an approve proof" \
  "$out" '"permissionDecision": "deny"'

# --- test 6: the exact PR #134 round-2 repro, now closed -------------------
# genuine reviewer (tokened) posts request changes with its own valid proof;
# a different crew id (the merging developer) posts a LATER COMMENTED
# comment reusing the reviewer's marker and VERDICT: approve but with no
# matching proof (it doesn't hold the reviewer's token) - denied where
# before issue #135 it was allowed (latest-marker-wins had no binding at
# all).
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok1 -->\n<!-- wingman-review-proof:$PROOF_RC1 -->\nVERDICT: request changes - fix X"},
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok1 --> VERDICT: approve - looks fine now"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_contains "issue #135: the exact PR #134 round-2 repro (forged marker-reuse approve) is now denied" \
  "$out" '"permissionDecision": "deny"'

# --- test 7: cross-PR replay via a live delivery change is denied (round 1) -
REVIEW_TOKEN3="$(uv run --no-project --quiet python -c 'import secrets;print(secrets.token_hex(32))')"
wm_state crew-add --id rev-tok3 --type reviewer --repo "$TEST_REPO" \
  --window wrt3 --session-id srt3 --review-token "$REVIEW_TOKEN3" >/dev/null
wm_state crew-set --id rev-tok3 --delivery "https://github.com/acme/widgets/pull/300" >/dev/null
PROOF_X="$(WM_REVIEW_TOKEN="$REVIEW_TOKEN3" WINGMAN_CREW_ID=rev-tok3 wm_state review-sign --verdict approve)"
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 300, "url": "https://github.com/acme/widgets/pull/300", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok3 -->\n<!-- wingman-review-proof:$PROOF_X -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 300")"
assert_eq "issue #135 (round 1 setup): a genuine proof is allowed against the PR it was rendered for (no output)" "$out" ""

wm_state crew-set --id rev-tok3 --delivery "https://github.com/acme/widgets/pull/301" >/dev/null
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 301, "url": "https://github.com/acme/widgets/pull/301", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok3 -->\n<!-- wingman-review-proof:$PROOF_X -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 301")"
assert_contains "issue #135 (round 1 regression): a genuine PR-X proof no longer validates on PR-Y after a live delivery repoint" \
  "$out" '"permissionDecision": "deny"'

# --- test 7a: cross-PR replay via a clear-then-reset is denied (round 2) ---
# the two-step variant that defeated round 1's first fix (an intervening
# `--delivery ""` clear must not reset review_delivery_bound).
REVIEW_TOKEN3B="$(uv run --no-project --quiet python -c 'import secrets;print(secrets.token_hex(32))')"
wm_state crew-add --id rev-tok3b --type reviewer --repo "$TEST_REPO" \
  --window wrt3b --session-id srt3b --review-token "$REVIEW_TOKEN3B" >/dev/null
wm_state crew-set --id rev-tok3b --delivery "https://github.com/acme/widgets/pull/310" >/dev/null
PROOF_X2="$(WM_REVIEW_TOKEN="$REVIEW_TOKEN3B" WINGMAN_CREW_ID=rev-tok3b wm_state review-sign --verdict approve)"
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 310, "url": "https://github.com/acme/widgets/pull/310", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok3b -->\n<!-- wingman-review-proof:$PROOF_X2 -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 310")"
assert_eq "issue #135 (round 2 setup): a genuine proof is allowed on PR-X before the clear-then-reset (no output)" "$out" ""

wm_state crew-set --id rev-tok3b --delivery "" >/dev/null
wm_state crew-set --id rev-tok3b --delivery "https://github.com/acme/widgets/pull/311" >/dev/null
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 311, "url": "https://github.com/acme/widgets/pull/311", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok3b -->\n<!-- wingman-review-proof:$PROOF_X2 -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 311")"
assert_contains "issue #135 (round 2 regression): a clear-then-reset still triggers regeneration - old proof denied on PR-Y" \
  "$out" '"permissionDecision": "deny"'

# --- test 8: crew-add --review-token is still fully blocked for every ------
# crew session (confirms check_crew_add_restriction()'s existing blanket
# denial already covers this - the overlap isn't accidental).
out="$(run_hook '$WINGMAN_STATE crew-add --id fake-reviewer-tok --type reviewer --repo /tmp --window w9 --session-id s9 --review-token deadbeef')"
assert_contains "issue #135: crew-add --review-token is still blocked by the existing crew-add restriction" \
  "$out" '"permissionDecision": "deny"'
assert_contains "...denial cites issue #132 (the existing blanket crew-add denial)" "$out" "issue #132"

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# issue #135: crew-set --regenerate-review-token self-grant restriction,
# mirroring --allow-merge/--review-gate-waived exactly (reuses
# _check_no_self_grant).
# ============================================================================
export WINGMAN_CREW_ID=dev-tok
export WINGMAN_CREW_TYPE=developer

out="$(run_hook '$WINGMAN_STATE crew-set --id dev-tok --regenerate-review-token deadbeef')"
assert_contains "a developer cannot regenerate its own review token" "$out" '"permissionDecision": "deny"'
assert_contains "self-grant denial cites issue #135" "$out" "issue #135"

out="$(run_hook '$WINGMAN_STATE crew-set --id "$WINGMAN_CREW_ID" --regenerate-review-token deadbeef')"
assert_contains "self-grant via the \$WINGMAN_CREW_ID idiom is denied identically" "$out" '"permissionDecision": "deny"'

out="$(run_hook '$WINGMAN_STATE crew-set --id someone-else-tok --regenerate-review-token deadbeef')"
assert_contains "a non-lead crew member cannot regenerate anyone's review token" "$out" '"permissionDecision": "deny"'

export WINGMAN_CREW_ID=lead1
export WINGMAN_CREW_TYPE=lead
out="$(run_hook '$WINGMAN_STATE crew-set --id rev-tok1 --regenerate-review-token deadbeef')"
assert_eq "a lead regenerating a worker's review token is allowed (no output)" "$out" ""

out="$(run_hook '$WINGMAN_STATE crew-set --id lead1 --regenerate-review-token deadbeef')"
assert_contains "a lead cannot regenerate its own review token" "$out" '"permissionDecision": "deny"'

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE
out="$(run_hook '$WINGMAN_STATE crew-set --id rev-tok1 --regenerate-review-token deadbeef')"
assert_eq "wingman's own top-level session can regenerate a review token (no output)" "$out" ""

export WINGMAN_CREW_ID=dev-tok
export WINGMAN_CREW_TYPE=developer
out="$(run_hook '$WINGMAN_STATE crew-set --id dev-tok --status working --summary "on it"')"
assert_eq "an ordinary crew-set (no --regenerate-review-token) is allowed (no output)" "$out" ""

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# issue #135, round 3/round 4 (round-4 should-fix 2): the end-to-end half of
# the resume-backfill regression, paired with tests/wm-state-review-gate.
# test.sh's state-engine assertions the same way tests 7/7a above are paired
# with that file's own tests 14/15. A LEGACY (no-token) reviewer already
# carrying a real `delivery` when it crashes must have review_delivery_bound
# correctly BACKFILLED (not left None) the moment bin/crew-resume
# regenerates its first-ever commitment - otherwise the next delivery change
# misreads as a "first-ever" assignment and skips regeneration, reopening
# the cross-PR replay this whole section exists to close. This proves the
# resumed reviewer's stale PR-X evidence is actually rejected by the real
# merge gate on PR-Y, not just that the roster field looks right.
# ============================================================================
export WINGMAN_CREW_ID=dev-tok
export WINGMAN_CREW_TYPE=developer

wm_state crew-add --id rev-legacy-resume --type reviewer --repo "$TEST_REPO" \
  --window wrlr --session-id srlr >/dev/null
wm_state crew-set --id rev-legacy-resume --delivery "https://github.com/acme/widgets/pull/400" >/dev/null

# Simulate bin/crew-resume's regeneration of a died, previously-untokened
# reviewer: its very first commitment, minted post-resume.
RESUME_TOKEN="$(uv run --no-project --quiet python -c 'import secrets;print(secrets.token_hex(32))')"
wm_state crew-set --id rev-legacy-resume --regenerate-review-token "$RESUME_TOKEN" >/dev/null

PROOF_RESUME="$(WM_REVIEW_TOKEN="$RESUME_TOKEN" WINGMAN_CREW_ID=rev-legacy-resume wm_state review-sign --verdict approve)"
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 400, "url": "https://github.com/acme/widgets/pull/400", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-legacy-resume -->\n<!-- wingman-review-proof:$PROOF_RESUME -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 400")"
assert_eq "issue #135 round 3: a resumed reviewer's fresh proof is valid on PR-X (no output)" "$out" ""

# Delivery changes to a DIFFERENT PR - must regenerate (the backfill made
# review_delivery_bound correctly non-None going into this change, rather
# than misreading it as a first-ever assignment).
wm_state crew-set --id rev-legacy-resume --delivery "https://github.com/acme/widgets/pull/401" >/dev/null
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 401, "url": "https://github.com/acme/widgets/pull/401", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-legacy-resume -->\n<!-- wingman-review-proof:$PROOF_RESUME -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 401")"
assert_contains "issue #135 round 3 regression: a resumed reviewer's stale PR-X proof is denied on PR-Y (backfill closed the gap)" \
  "$out" '"permissionDecision": "deny"'

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

# ============================================================================
# issue #138: review evidence must be bound to the PR's CURRENT head commit,
# not merely genuine at some point in the past. See
# docs/analysis/2026-07-16-issue-138-review-evidence-commit-binding-plan.md.
# Uses a fresh reviewer (rev138) and a fresh PR number (500) to stay isolated
# from the mutable roster state the earlier sections in this file left
# behind.
# ============================================================================
export WINGMAN_CREW_ID=dev-tok
export WINGMAN_CREW_TYPE=developer

REVIEW_TOKEN138="$(uv run --no-project --quiet python -c 'import secrets;print(secrets.token_hex(32))')"
wm_state crew-add --id rev138 --type reviewer --repo "$TEST_REPO" \
  --window wr138 --session-id sr138 --review-token "$REVIEW_TOKEN138" >/dev/null
wm_state crew-set --id rev138 --delivery "https://github.com/acme/widgets/pull/500" >/dev/null

SHA_A="1111111111111111111111111111111111111a"
SHA_B="2222222222222222222222222222222222222b"

# --- test 1: shape 1, a fresh APPROVED review (commit.oid == headRefOid) is
# allowed - the explicit matching case, distinct from the incidental coverage
# the fixture updates earlier in this file already give it.
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 500, "url": "https://github.com/acme/widgets/pull/500", "headRefOid": "$SHA_A", "reviews": [
  {"state": "APPROVED", "author": {"login": "a-real-human"}, "body": "lgtm", "commit": {"oid": "$SHA_A"}}
]}
JSON
out="$(run_hook "gh pr merge 500")"
assert_eq "issue #138: shape 1, a fresh APPROVED review (matching commit.oid) is allowed (no output)" "$out" ""

# --- test 2: shape 1, a STALE APPROVED review (commit.oid differs from the
# PR's current headRefOid - new commits landed after the approval) is denied.
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 500, "url": "https://github.com/acme/widgets/pull/500", "headRefOid": "$SHA_B", "reviews": [
  {"state": "APPROVED", "author": {"login": "a-real-human"}, "body": "lgtm", "commit": {"oid": "$SHA_A"}}
]}
JSON
out="$(run_hook "gh pr merge 500")"
assert_contains "issue #138: shape 1, a stale APPROVED review is denied" \
  "$out" '"permissionDecision": "deny"'
assert_contains "issue #138: shape-1 stale denial names stale evidence / issue #138" \
  "$out" "stale evidence (issue #138)"

# --- test 3: shape 1, an APPROVED review with NO commit field at all is
# denied - defensive; absence is never treated as license to skip the check.
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 500, "url": "https://github.com/acme/widgets/pull/500", "headRefOid": "$SHA_A", "reviews": [
  {"state": "APPROVED", "author": {"login": "a-real-human"}, "body": "lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 500")"
assert_contains "issue #138: shape 1, an APPROVED review with no commit field is denied" \
  "$out" '"permissionDecision": "deny"'

# --- test 4: shape 2, a freshly commit-bound approve (review-sign --commit
# matching the fixture's headRefOid) is allowed - the full Tier 2 path.
PROOF138_A="$(WM_REVIEW_TOKEN="$REVIEW_TOKEN138" WINGMAN_CREW_ID=rev138 wm_state review-sign --verdict approve --commit "$SHA_A")"
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 500, "url": "https://github.com/acme/widgets/pull/500", "headRefOid": "$SHA_A", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev138 -->\n<!-- wingman-review-proof:$PROOF138_A -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 500")"
assert_eq "issue #138: shape 2, a freshly commit-bound approve matching the current head is allowed (no output)" "$out" ""

# --- test 5: the exact issue #138 replay repro, now closed - a byte-for-byte
# repost of the round-1 comment (same marker, same proof, VERDICT: approve)
# after the head has moved on to commit B is denied.
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 500, "url": "https://github.com/acme/widgets/pull/500", "headRefOid": "$SHA_B", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev138 -->\n<!-- wingman-review-proof:$PROOF138_A -->\nVERDICT: approve - lgtm"},
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev138 -->\n<!-- wingman-review-proof:$PROOF138_A -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 500")"
assert_contains "issue #138: the exact replay repro (byte-for-byte repost of an old genuine approve) is denied" \
  "$out" '"permissionDecision": "deny"'
assert_contains "issue #138: replay denial names stale evidence" \
  "$out" "stale evidence"

# --- test 6: shape 2, a genuine re-sign for the new head after a push is
# allowed - confirms the fix does not block genuine re-approval, only stale
# replay.
PROOF138_B="$(WM_REVIEW_TOKEN="$REVIEW_TOKEN138" WINGMAN_CREW_ID=rev138 wm_state review-sign --verdict approve --commit "$SHA_B")"
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 500, "url": "https://github.com/acme/widgets/pull/500", "headRefOid": "$SHA_B", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev138 -->\n<!-- wingman-review-proof:$PROOF138_A -->\nVERDICT: approve - lgtm"},
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev138 -->\n<!-- wingman-review-proof:$PROOF138_B -->\nVERDICT: approve - re-reviewed after the push, still lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 500")"
assert_eq "issue #138: a genuine re-sign for the new head after a push is allowed (no output)" "$out" ""

# --- test 7: shape 2, Tier 1 backward compatibility still holds - a reviewer
# that never called review-sign --commit (review_commit_approve_sha still
# None) is still allowed even though the fixture now also carries a
# headRefOid the record's review_commit_approve_sha is never compared
# against. Reuses rev-tok1/PROOF_APPROVE1 from the issue #135 section above.
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 46, "url": "https://github.com/acme/widgets/pull/46", "headRefOid": "$SHA_A", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev-tok1 -->\n<!-- wingman-review-proof:$PROOF_APPROVE1 -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 46")"
assert_eq "issue #138: Tier 1 backward compat - a never-commit-bound reviewer's proof is still allowed (no output)" "$out" ""

# --- test 8: a missing/empty headRefOid in the gh pr view response fails
# CLOSED - a fixture that would otherwise be a fresh, valid Tier-2 approve,
# but with headRefOid omitted entirely from the top-level JSON.
cat > "$GH_REVIEWS_JSON" <<JSON
{"number": 500, "url": "https://github.com/acme/widgets/pull/500", "reviews": [
  {"state": "COMMENTED", "body": "<!-- wingman-crew:rev138 -->\n<!-- wingman-review-proof:$PROOF138_B -->\nVERDICT: approve - lgtm"}
]}
JSON
out="$(run_hook "gh pr merge 500")"
assert_contains "issue #138: a missing headRefOid fails closed (denied), not allowed unchecked" \
  "$out" '"permissionDecision": "deny"'

unset WINGMAN_CREW_ID WINGMAN_CREW_TYPE

test_summary
