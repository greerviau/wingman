# Review: "A Categorized Playbook Library" implementation plan

Date: 2026-07-11
Reviewed artifact: `docs/plans/2026-07-11-categorized-playbook-library-implementation.md`
Reviewer: reviewer crew member (plan review, no code written)

## Verdict

The resolver design in Phase 1/3 is fundamentally sound and bash-3.2-safe, and it would work correctly for the plan's shipped v1 role/category set.
No bug was found that would "misroute every crew spawn" under realistic use.
However, the plan's own grounding is less thorough than it claims: one explicit factual claim about file contents is verified false, and several real prose references to the `analyst` bare name are missing from the doc-update phase and would ship stale.
There are also a few real (if narrow) resolver edge cases and a test-isolation gap worth fixing before merge, none individually blocking, but collectively enough that this should not go in as-is without incorporating the fixes below.
Recommend: address the "must fix" items, then proceed with the plan's own two-PR split.

## Must-fix findings

### 1. The plan's claim that `reviewer.md` doesn't reference `analyst` is false

Plan section 3 (Phase 3) states:

> None of `playbooks/common/research.md`, `playbooks/software-development/architect.md`, `playbooks/software-development/developer.md`, or `playbooks/software-development/reviewer.md` reference the bare `analyst` name in their own prose (confirmed by reading each), so no in-file edits are needed beyond the move itself...

This is incorrect. `playbook/reviewer.md` line 9 reads:

> - **A plan** (an analyst's spec or an architect's implementation plan): does it hold together? ...

This is the literal bare role name, used exactly the way the plan already treats as needing a rename elsewhere (e.g. `lead.md`'s "Spawn an `analyst`" prose).
Because PR2 (Phases 5-7, per the plan's own split) only adds *new* playbook files and does not revisit existing `software-development/*.md` files, this line would ship in PR1 as "an analyst's spec" immediately after `analyst` stops being a valid type name anywhere else in the codebase - a real, self-inflicted inconsistency in the exact file the plan already re-touches for the `analyst`->`software-analyst` rename.
Fix: add `playbooks/software-development/reviewer.md` line 9 ("an analyst's spec" -> "a software-analyst's spec") to the Phase 3 git-mv/edit step, and correct the "confirmed by reading each" claim.

### 2. The Phase 6 doc sweep misses real `analyst` prose in files it's already editing (or should be)

Section 1 ("Grounding beyond the scoping doc") presents itself as a from-scratch verification pass that "turned up two more real references the doc's list missed" (`bin/doctor`, `docs/architecture.md`).
Re-grepping every file for `analyst` line-by-line and cross-checking against the plan's Phase 6 edit lists turns up three more real misses that same pass should have caught:

- **`CLAUDE.md` line 48**: `"Delegating that to an analyst crew member." is the whole announcement; then act.` - this is a worked example using the bare role name, in the same file whose lines 62, 64, 126, 129, 134-138, 191, 193-196, 200 the plan *does* edit for exactly this reason. Not in the plan's CLAUDE.md edit list.
- **`CLAUDE.md` line 57**: `Does the effort need a **third role beyond the standard analyst→developer pair**...` - same category of miss, same file.
- **`.claude/commands/lead.md` line 9**: `A lead runs its own crew (analyst → architect → developers → reviewer), sequences...` - this file isn't mentioned anywhere in the plan (not in section 1's grounding, not in Phase 6). It's a live slash-command definition (`/lead`) that names the pipeline the exact same way `CLAUDE.md`'s own "Appointing a lead" section does (which the plan *does* fix at line 200) - it will read as stale/wrong the moment `analyst` is renamed, with nothing in the plan ever touching it.

None of these are caught by the automated test suite (`tests/playbook-resolution.test.sh` only asserts against `sysprompt.md` content and `--list-types` output, not against README/CLAUDE.md/command-file prose), so they'd ship silently wrong and stay that way until someone notices by inspection.
Fix: add these three to Phase 6's edit list. While at it, worth a final `grep -rn '\banalyst\b' --include='*.md' .` (excluding `docs/plans/`, `docs/analysis/`, and the moved/renamed playbook files themselves) as a closing check for the phase, since two separate read-throughs (the plan's own, and this review's) each missed something the other caught.

(Minor, not actionable: `bin/crew-standdown` line 38 has a code comment "e.g. an analyst" - purely illustrative, not a path or type reference, cosmetic only.)

### 3. `WM_PLAYBOOKS` should be overridable, so the new test doesn't have to mutate the live repo tree

The plan's Phase 1 constant is:

```bash
WM_PLAYBOOKS="$WM_REPO/playbook"
export WM_PLAYBOOKS
```

This is an unconditional assignment - unlike `WM_HOME="${WINGMAN_HOME:-$HOME/.wingman}"` two lines above it in the same file, which is deliberately override-friendly so tests can isolate state via `test_new_home`'s `WINGMAN_HOME="$(mktemp -d)/wm"`.
Because `WM_PLAYBOOKS` has no such override hook, `tests/playbook-resolution.test.sh` (section 4) has no way to point the resolver at an isolated fixture directory, and instead writes its `.local.md` override and cross-category-collision fixtures directly into `$TEST_REPO/playbooks/...` - i.e., the real `playbooks/` directory of whichever wingman checkout is running the suite.
This is a real deviation from the pattern `tests/spawn-scope.test.sh` established (an isolated `mktemp`-based fixture repo for `repoA`/`repoB`), which the new test's own header comment claims to follow "exactly." It doesn't, for exactly the part that touches the shared library tree.
The risk is bounded (the fixtures are `trap`-cleaned, and `tests/run.sh` runs suites sequentially, not in parallel) but not zero: the suite's own `wm_timeout` helper elsewhere SIGKILLs hung commands, and a SIGKILL skips `trap ... EXIT` cleanup, which could leave stray fixture files in a developer's real working tree.
Fix: change the constant to `WM_PLAYBOOKS="${WM_PLAYBOOKS:-$WM_REPO/playbooks}"` (one-line change, same pattern as `WM_HOME`), and have the new test export an isolated `WM_PLAYBOOKS` pointing at a `mktemp` fixture tree seeded with a minimal `common/lead.md`, `software-development/developer.md`, etc., exactly as it already does for `WINGMAN_HOME`. This removes the live-tree mutation risk entirely rather than merely bounding it.

## Should-fix findings (resolver robustness)

### 4. The "matches existing style" justification for unquoted `set -- $DIRS` doesn't hold up

The plan defends the unquoted word-split with:

> ... matches the codebase's existing style (e.g. the unquoted `GLOBAL_REPO_DIRS` handling a few lines up).

This comparison is inaccurate. `GLOBAL_REPO_DIRS` is iterated with a newline-delimited `read` loop:

```bash
printf '%s\n' "$GLOBAL_REPO_DIRS" | while IFS= read -r _d; do
  [ -n "$_d" ] && printf ' --add-dir %s' "$(quote "$_d")"
done
```

which is safe for directory paths containing spaces (each line is one whole path, IFS splitting doesn't apply within a line).
The new resolver's `DIRS="$DIRS $d"` + `set -- $DIRS` is a *different, weaker* technique: it space-joins paths and then word-splits on whitespace, so any category or role directory whose path contains a space (e.g. wingman cloned under `~/My Drive/wingman` or any parent folder with a space in its name - common on macOS/Windows) silently miscounts directories.
Depending on the exact path, this could produce a false "ambiguous" collision error, or worse, silently resolve to the wrong `PLAYBOOK` file with no error at all (if the split happens to still produce exactly one distinct fragment matched against `$d`'s prefix comparisons).
This doesn't bite with today's fixed role/category set (none of the shipped names contain spaces), but it's an unnecessary and easily-avoided fragility, given the safer newline-delimited idiom already exists two sections up in the very same file.
Recommend: build `DIRS` newline-delimited (or dedupe/count without ever restuffing it through `set --`) instead of space-joining it.

### 5. `find -name "$TYPE.md"` treats `$TYPE` as a glob pattern, not a literal string

`find "$WM_PLAYBOOKS" -type f \( -name "$TYPE.md" -o -name "$TYPE.local.md" \)` passes `$TYPE` straight into a `-name` pattern, which `find` matches as shell-style glob syntax, not literal text.
A `--type` value containing `*`, `?`, or `[...]` (e.g., `--type '*'`, or a malformed type string assembled upstream by a lead/wingman session) would match every `.md`/`.local.md` file under whatever directories happen to contain one, rather than being cleanly rejected as "no playbook for crew type."
This undermines the exact-name-match invariant the whole collision-detection design is built on ("a bare name... is searched across every category - role names are kept unique across categories").
Low likelihood given today's simple slug-style type names, but worth a one-line guard (reject or escape glob metacharacters in `$TYPE` before it reaches `-name`) given this is precisely the kind of resolver whose entire job is correct exact-name resolution.

### 6. Repurposing the script's own `$1`/`$@`/`$#` via `set -- $DIRS` is an unscoped, undocumented-in-code invariant

The plan's own justification is correct as verified against the live file: nothing after the "resolve the playbook" section in `bin/spawn-crew` reads the script's outer positional parameters again (checked every later section: PERM_MODE, MODEL, `slugify`/ID derivation, WORKTREE, SID, sysprompt composition, launch script, tmux launch, roster record, opening message - none touch `$1/$@/$#` at the script's top level).
So this isn't a bug today. But the safety depends entirely on that invariant continuing to hold across future edits, and nothing in the code enforces or documents it beyond a comment.
Wrapping the resolver in a plain shell function (bash 3.2 supports `local` and gives every function its own positional-parameter scope) would make the `set --` reuse strictly scoped and safe against a future edit reintroducing a read of the script's own argv after this point - essentially free, given the logic is already self-contained.

## Minor / informational

### 7. Collision-test fixtures aren't gitignored, unlike the local-override fixture next to them

In `tests/playbook-resolution.test.sh`, the local-override fixture (`developer.local.md`) is gitignored by `*.local.md`, and the plan's own notes lean on that fact for safety.
The cross-category-collision fixtures a few lines later (`playbooks/software-development/zzz-collision-fixture.md`, `playbooks/common/zzz-collision-fixture.md`) are plain `.md` files - not covered by that gitignore rule at all.
If cleanup is skipped by an abnormal kill (see finding 3), these would show up as ordinary untracked files in `git status`, capable of being swept into a later `git add -A`/`git add .`.
Cheap fix: name them `zzz-collision-fixture.local.md` instead - the resolver's `-name "$TYPE.local.md"` branch already matches that suffix, so the test's behavior is unaffected, and any leftover stays gitignored.

### 8. Occurrence-count citations in Phase 6 (CLAUDE.md) are slightly off

The plan says "Lines 134-138 ... (three occurrences)" - actual count of the bare word `analyst` on those lines is four (134, 136, 137, 138, one each).
It says "Lines 193-196 ... (four occurrences)" - actual count is three (193, 195, 196).
Neither miscount changes what needs to happen (the instruction is "throughout," which a real find/replace plus a closing grep would catch regardless of the stated count), but it's a reminder - consistent with why this review was asked to verify citations rather than trust them - that the plan's specific numbers should not be taken as ground truth during implementation; grep, don't count.

### 9. Phase 2's "only one test is Phase-3-dependent" framing understates the actual dependency

Section 3 (Phase 2) says the resolution test is written to pass both before and after Phase 3, with only the "bare name resolves to the correct category file" assertion being inherently Phase-3-dependent.
In practice, nearly every other assertion in the test (`common/lead` qualified resolution, the `.local.md` override, both collision-fixture paths, and every `--list-types` assertion) also hardcodes `playbooks/<category>/...` paths that simply don't exist until Phase 3's `git mv`s land - running the test in isolation against Phase 1's still-flat `playbook/` tree would fail on essentially all of its assertions, not just the one named.
This doesn't change the recommendation - the plan already (correctly) suggests landing Phases 2 and 3 as sequential commits in the same PR so the test is only ever evaluated against its final target state - it's only the stated rationale that's imprecise.

## Confirmed correct (no issue found)

Spelled out since the assignment specifically asked whether the resolver "would actually work in bash 3.2":

- Process substitution (`< <(...)`) is a core bash feature, not bash-4+; safe on 3.2.
- `set --` word-splitting, `local`, and the `case`/glob patterns used throughout are all bash-3.2-safe.
- The dedup check `case " $DIRS " in *" $d "*)` is safe against prefix/substring false-positives for directory paths (the surrounding-space delimiters correctly prevent one directory's path from matching as a false substring of a deeper nested one, e.g. `scientific-research` vs. `scientific-research/biological-research`), *given* no path contains a literal space (tracked separately as finding 4).
- A type name that is an exact substring of another (e.g. `review` vs. `reviewer`) is not mishandled: `find -name "$TYPE.md"` requires an exact full-filename match, not a substring match, so this case resolves correctly (assuming no glob metacharacters in `$TYPE`; see finding 5 for that separate, narrower concern).
- An empty or missing `$WM_PLAYBOOKS` directory is handled correctly: `find`'s stderr is suppressed, the read loop simply doesn't execute, `$#` is `0`, and `wm_die` fires with the expected message - no crash under `set -u`.
- No role name in the v1 shipped set (section 2's target layout) collides with any other across categories - verified by listing every planned basename; the plan's own section 10 risk note about this being a "library invariant going forward" is accurate and appropriately flagged as a follow-up rather than a build blocker.
- `wm_crew_types()`'s dedup of a `.md`/`.local.md` pair down to one identical `category/role` line before `sort -u` is correct (both strip to the same basename).
- The claim that nothing in Phase 1 changes runtime behavior for the existing six flat playbooks (still resolving to the same files, just via `find` instead of a glob) checks out against the live files.
- `bin/spawn-crew` line 6, line 142, and every cited `bin/doctor` (lines 72-73) and `docs/architecture.md`/`README.md` line number were verified against the live files and are accurate.

## On the PR-split recommendation (plan section 9)

The two-PR split (mechanical resolver + reorg in PR1, new content + docs in PR2) is sound in principle: it isolates the one part of this effort with real blast radius (a resolver bug misrouting spawns) from purely subjective content review, and there's no code dependency forcing a finer or coarser split.
The one thing worth calling out: as scoped, this split creates a gap for finding 1 above.
`playbooks/software-development/reviewer.md`'s stale "analyst" reference is introduced by PR1 (the move/rename phase) but PR2 never revisits existing `software-development/*` files (it only adds new category content and touches README/CLAUDE.md/architecture.md), so nothing in the plan's own phase structure would ever catch or fix it once split this way.
Recommend folding the `reviewer.md` fix into Phase 3 (PR1) directly, alongside the `lead.md` prose fixes the plan already scopes there, rather than leaving it to be caught ad hoc in review.
