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
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
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
# Crew session WITH the grant recorded (allow_merge: true): every path above
# is now permitted.
# ============================================================================
wm_state crew-add --id dev1 --type developer --repo "$TEST_REPO" \
  --window w1 --session-id s1 --allow-merge >/dev/null

out="$(run_hook "gh pr merge 46")"
assert_eq "crew, GRANTED: gh pr merge 46 is allowed (no output)" "$out" ""

out="$(run_hook "gh pr merge --auto")"
assert_eq "crew, GRANTED: gh pr merge --auto is allowed (no output)" "$out" ""

out="$(run_hook "gh api -X PUT repos/owner/repo/pulls/46/merge")"
assert_eq "crew, GRANTED: gh api -X PUT .../merge is allowed (no output)" "$out" ""

out="$(run_hook "git push origin main" "$CLONE")"
assert_eq "crew, GRANTED: git push origin main is allowed (no output)" "$out" ""

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

test_summary
