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

test_summary
