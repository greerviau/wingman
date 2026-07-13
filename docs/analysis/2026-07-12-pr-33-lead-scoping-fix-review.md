# Review: PR #33 - fix issue #17's lead-scoping gap

Reviewer: crew `review-pr-33-github-com-greervia-reviewer`.
Date: 2026-07-12.
Scope: `github.com/greerviau/wingman` PR #33 (`fix/issue-17-lead-scoping-gap`), reviewed against `docs/analysis/2026-07-12-pr-27-orchestration-impact-review.md` (finding 1), which is the review that surfaced this gap.

## Verdict: approve

Both bundled changes are correct, and the properties called out as needing verification rather than trust all hold up under direct testing (not just reading the diff or trusting the PR's own claims).

## What was verified directly (not taken on faith)

Checked out the branch (`fix/issue-17-lead-scoping-gap`, commit `9232fe9`) into an isolated worktree and ran the tests myself, rather than relying on the PR description's testing section.

**1. The user-level hook does not fire for the pilot's unrelated, non-wingman sessions.**
Traced the activation logic in `hooks/no-direct-edit-guard.sh`:

```
if [ "${WINGMAN_CREW_TYPE:-}" = "lead" ]; then
  :
elif [ -z "${WINGMAN_CREW_ID:-}" ] && wm_is_wingman_repo_session; then
  :
else
  exit 0
fi
```

`wm_is_wingman_repo_session` resolves `$CLAUDE_PROJECT_DIR` (via `cd ... && pwd -P`) and compares it against `$REPO`, which the script derives from its own physical location (`dirname` of `$0`, also `pwd -P`'d) - not from any env var an unrelated session could coincidentally share. An unrelated session has `WINGMAN_CREW_ID` unset (true for it, same as top-level wingman) but its `$CLAUDE_PROJECT_DIR` will not equal the wingman checkout path, so the `elif` is false and the hook exits 0 (allow). Ran this concretely: with `WINGMAN_CREW_ID`/`WINGMAN_CREW_TYPE` unset and `CLAUDE_PROJECT_DIR` pointed at a throwaway non-repo directory, both `Edit` and a `pytest` Bash call pass through untouched (`tests/no-direct-edit-guard.test.sh`, "top-level-shaped env outside this repo" cases) - confirmed by executing the test file, all pass. The same holds when `CLAUDE_PROJECT_DIR` is unset entirely (fails closed to "inactive," i.e. allows - correct, since an unrelated session should never be blocked by a missing signal).

**2. The lead branch fires unconditionally regardless of cwd.**
`WINGMAN_CREW_TYPE=lead` short-circuits before any cwd check at all. Verified with `WINGMAN_CREW_ID=lead1 WINGMAN_CREW_TYPE=lead` and `CLAUDE_PROJECT_DIR` pointed outside the wingman repo (and separately, unset entirely): `Edit` is denied in both cases ("lead: Edit is denied from outside this repo", "lead: Edit is denied with no CLAUDE_PROJECT_DIR at all") - this is the entire point of the fix and it holds.

**3. The path-based repo check gates the Edit/Write/NotebookEdit block correctly in both directions.**
`is_inside_git_repo()` walks up from the target's parent directory to the nearest existing directory, then asks `git -C <dir> rev-parse --is-inside-work-tree`. Verified both directions with real assertions, not just reading the fix's own claim:
- A `Write`/`Edit` targeting a path outside any git repo (a tmpdir with no `.git` anywhere above it, standing in for `~/.claude/projects/**/memory/*.md`) passes through with no output, for both the top-level-guarded and lead-guarded cases.
- A `Write`/`Edit` targeting a path inside a tracked repo (the default test fixture path, which resolves inside the actual wingman checkout used as the test repo) is still denied exactly as before.
Both directions have dedicated test assertions, and I ran them rather than trusting the PR's "manually verified end-to-end" claim.

**4. Hook installer: idempotent, additive, non-clobbering.**
Read and ran `tests/install-user-hook.test.sh` end to end (16/16 pass): fresh install, `--check` before/after, re-running does not duplicate the `PreToolUse` group, a pre-existing `settings.json` with an unrelated `theme` key and unrelated `Stop`/`PreToolUse` entries has all of it preserved with the guard's entry appended as a second `PreToolUse` group, and invalid existing JSON is refused rather than overwritten (file left byte-for-byte untouched). `bin/doctor`'s wiring is exercised through `WM_CLAUDE_USER_SETTINGS` so the test never touches a real machine's `~/.claude/settings.json` - confirmed by reading `bin/doctor`'s registration block, which reads that override before falling back to `$HOME/.claude/settings.json`.

**5. This repo's own project-level entry was actually removed, not left in place.**
Read `.claude/settings.json` on the branch directly: only the `Stop` hook remains; the `PreToolUse` block is gone entirely (not just its guard entry - the whole key), so there is no double-invocation risk for wingman's own top-level session.

**6. Docs/header comments match the new reality.**
The hook's header comment in `hooks/no-direct-edit-guard.sh` was rewritten to describe user-level registration, the cwd-gated top-level branch, the unconditional lead branch, and the git-repo path scoping - no leftover claims of "wired only here" or "unconditionally blocks every Edit/Write." `CLAUDE.md`'s onboarding step 1 mentions the new registration. Grepped for stale references elsewhere; found none.

**7. Full test suite run.**
Ran `tests/run.sh` myself rather than trusting the PR's summary. In this sandbox the full suite runs long enough that it exceeded a 550s timeout partway through `stall-check.test.sh` (a pre-existing characteristic of this environment's tmux-backed tests, unrelated to this PR - 14 of 21 test files completed before the cutoff, all with `0 failed`). Both files this PR actually touches or adds (`no-direct-edit-guard.test.sh`: 61/61, `install-user-hook.test.sh`: 16/16) ran to completion with no failures.

One discrepancy worth flagging: the PR description claims a pre-existing, unrelated failure in `crew-resume.test.sh` ("a failed resume reports the manual fallback" and two follow-ons). In my run that exact test passed (`26 run, 0 failed`). This is most likely environment/timing-dependent flakiness in that test file (it deals with tmux resume races) rather than a real regression, and it's unrelated to anything this PR changes - but the PR description's specific claim didn't reproduce here, so it shouldn't be read as a confirmed-stable baseline fact.

## Minor, non-blocking notes

- **Unquoted hook path in the generated settings entry.** `bin/lib/install-user-hook.py` stores the hook command as the literal `args.hook` string with no surrounding quotes, unlike the project-level entry it replaces (which quoted `"$CLAUDE_PROJECT_DIR/hooks/...`" for safe expansion). If a machine's wingman checkout path ever contains a space, the generated command would break when the shell that executes it splits on whitespace. Low likelihood in practice (dev checkout paths rarely have spaces), not worth blocking on, but a one-line fix (`json.dumps`-safe quoting or wrapping in `"..."` at write time) would close it for good.
- **Stale registration on repo relocation.** `is_registered()` matches by exact command string equality. If a wingman checkout is ever moved, doctor would add a second `PreToolUse` entry pointing at the new path rather than replacing the stale one pointing at the old (now-nonexistent) path. Harmless (the stale entry just becomes a no-op command that fails silently when Claude Code tries to run it, per PreToolUse hook error handling), but could be a future doctor idempotency edge case if it ever comes up.

Neither note affects the properties this PR set out to fix; both are opportunistic cleanup, not correctness gaps.

## Recommendation

Merge as-is. The two critical properties from issue #17/PR #27's gap (leads guarded regardless of spawn location; unrelated sessions never guarded) and the new false-positive fix (writes outside any git repo pass through) are all verified correct by direct test execution, not just by reading the diff or the PR's own description.
