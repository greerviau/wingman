# Review (round 2): onboarding-preferences hook enforcement plan

**Artifact reviewed:** `docs/plans/2026-07-13-onboarding-preferences-hook-enforcement.md` (revision claiming to resolve all round-1 findings)
**Prior review:** `docs/analysis/2026-07-13-onboarding-preferences-hook-enforcement-plan-review.md`
**Verdict:** All nine round-1 findings are genuinely resolved - each fix was verified against the actual code, not just the plan's claims.
Three new should-fix findings surfaced (one enforcement gap shared with the contract itself, one deployment-channel choice, one allowlist omission), plus minors.
None undermines the architecture; the plan is implementable once these are addressed or explicitly accepted.

## Verification of the claimed round-1 fixes

Each fix was checked against the code it depends on, not taken on the plan's word.

1. **Bare `crew-set --status review` (finding 1): resolved.**
   The guard now fires on any `crew-set` containing `--status review` and falls back to the member's `$WINGMAN_HOME/crew/<id>.json` `artifact` field.
   Verified that field exists and is kept current: `cmd_crew_set` writes `artifact` into the live status file (`bin/lib/wm-state.py:343`) and mirrors it into the roster (`wm-state.py:370-372`).
   The test list covers both call shapes, including the stale-revision re-entry with no `--artifact`.
2. **Tokenizer vs. the real `$WINGMAN_STATE` shape (finding 2): resolved for the shape that matters.**
   The gap is real as described (`no-direct-edit-guard.sh:150-151` recurses on `tokens[2:]` and lands on `--no-project`), and the fix - skip leading `-` tokens after `uv run` - correctly handles the literal `WM_UV` form (`uv run --no-project --quiet`, `bin/lib/common.sh:30`), which is fixed and value-flag-free.
   The test mandate to use the literal flag-bearing string closes the round-1 test-blindness concern.
   A residual edge with value-taking flags remains - see minor finding 6.
3. **`publish-failed` marker (finding 3): resolved.**
   A failed or refused `Artifact` call now records an escapable state, the guard allows a current-content `publish-failed` record, and the deny reason names three resolutions.
   The old "optimistic record" open question is correctly retired.
   One record-shape underspecification remains - see minor finding 7.
4. **`bin/crew-resume` environment (finding 4): resolved.**
   Verified `crew-resume`'s launch script (`bin/crew-resume:147-151`) exports exactly the five variables the plan says, missing `WINGMAN_RUN_ID` and `WINGMAN_CREW_TYPE`; verified the crew record persists `type` (`wm-state.py:281`) so reading it is free as claimed; verified `spawn-crew` exports both (`bin/spawn-crew:169,173`) so the fix mirrors an existing pattern.
   The "resuming session's run id" semantics choice is well argued, and the orphaned-marker consequence is now documented as safe degradation.
5. **Self-answer gap (finding 5): resolved.**
   The `pilot-preferences-ask-tracker.sh` `PostToolUse` marker gates `pref-set` on a completed `AskUserQuestion`, and the residual "asked *something*, not necessarily the right thing" gap is explicitly accepted in Open Questions with sound reasoning (transcript-content inspection would reintroduce the fragility section 6 rejects).
6. **Stop-guard interaction (finding 6): resolved, one command short.**
   The allowlist deliberately names `bin/crew-list`, `bin/watch-fleet` arming, and reading `$WINGMAN_HOME/wake`, with the supervision-vs-directive rationale stated.
   But it misses one command stop-guard also mandates - see should-fix finding 3 below.
7. **Unset `artifact_linking` (finding 7): resolved.**
   The split is now internally consistent: no-run-id/unreadable defaults to local without asking; set-run-id-but-unset asks the fallback.
   The "structurally rare" claim is slightly incomplete - see minor finding 8.
8. **Donor files in scope (finding 8): resolved.** `hooks/no-direct-edit-guard.sh` and its test are listed as modified files, with the refactor-regression check stated.
9. **`install-user-hook.py` idempotency (finding 9): resolved.**
   Verified `is_registered()` hardcodes `PreToolUse` at `install-user-hook.py:40` and the write path at lines 76-77; the plan names both the check and the write path, and the test extension asserts non-default-event idempotency.

## New findings

### Should fix

#### 1. A terminal `--status done --artifact` delivery bypasses the section 6 gate entirely - and reviewer-type members deliver exactly that way

`artifact-link-guard.sh` fires only on `crew-set` commands containing `--status review`.
But the `reviewer` playbook's delivery shape is terminal: it carries the report path as `artifact` and goes straight to `done`, never passing through `review` ("once they are delivered your engagement is over - that is your terminal condition, so you go `done`", `playbooks/software-development/reviewer.md:27`).
So every reviewer's markdown findings report - the same rendering-sensitive deliverable class as the analyst incident that motivated section 6 - skips the publish enforcement completely.

The contract prose shares the gap: `playbooks/_status-contract.md:143` scopes the publish check to "a `review`-state `--artifact` deliverable," so the plan's hook faithfully enforces a contract that already excludes terminal deliveries.
That makes this a joint contract-text and hook-logic decision, not a hook bug - but the plan is already rewriting that exact contract section (section 5), so this is the moment to resolve it.

**Fix:** either extend both the contract text and the guard to any `crew-set` carrying a resolvable markdown artifact with `--status review` **or** `--status done` (the delivery statuses), or state the terminal-delivery exclusion as a deliberate acceptance in the plan and the contract.
Extending is recommended: the pilot's underlying intent (markdown deliverables render well when remote) applies at least as strongly to a report whose author is about to disappear.
Note `--status done --artifact <path>` in one call is the common reviewer shape, and a bare `--status done` after an earlier `--artifact` is also possible - the same two call shapes finding 1 already handles for `review` apply here unchanged.

#### 2. The onboarding trio's enforcement is gated behind the consent-gated `bin/doctor` registration the plan itself documents as observably not happening

The plan registers all five hooks user-level via `bin/doctor`, "styled after the existing delegation-guard block."
Its own Open Questions section then notes that `hooks/no-direct-edit-guard.sh` is *not currently registered* on the very machine this investigation ran on, because doctor's registration is consent-gated and evidently never ran - "a mechanism can be correct and still never get turned on."
Shipping the plan's central mechanism through the same demonstrably-failing install channel reproduces, at the install layer, the exact silent-skip failure class the plan exists to close.

For the onboarding trio this is avoidable: `pilot-preferences-guard.sh`, `pilot-preferences-nudge.sh`, and `pilot-preferences-ask-tracker.sh` activate only when `$CLAUDE_PROJECT_DIR` is this wingman checkout and `WINGMAN_CREW_ID` is unset - precisely the sessions for which this repo's project-level `.claude/settings.json` already loads.
`hooks/stop-guard.sh` is registered exactly that way today (`.claude/settings.json`, `Stop` entry), so the pattern is proven; project-level registration ships with `git pull`, needs no consent prompt, and cannot silently be "off."

**Fix:** register the onboarding trio in this repo's `.claude/settings.json` (project level) instead of user level.
Only section 6's pair (`artifact-publish-tracker.sh`, `artifact-link-guard.sh`) genuinely needs user-level doctor registration, because crew sessions run with project roots in other repos - the plan's reasoning is correct for that pair and only that pair.

#### 3. The onboarding guard's allowlist misses `bin/crew-ask await` - the one stop-guard directive left denied

`hooks/stop-guard.sh` has three block reasons, each naming the commands the session must run.
The plan's allowlist covers reason 1 (`Read $WM_HOME/wake`, `bin/crew-list`) and reason 3 (`bin/watch-fleet` arming), but not reason 2: a pending ask with no live waiter, where stop-guard directs "Arm 'bin/crew-ask await --id <req>' as a harness-tracked background task" (`hooks/stop-guard.sh:154`).
A wingman restart mid-run with a pending `crew-ask` therefore hits the exact conflict shape finding 6 was about, one command over: stop-guard mandates a command the preferences guard denies.
The turn still terminates (two-pass design), so it is a supervision gap, not a wedge - the same class and severity as the watch-fleet case the plan chose to allowlist, and the same rationale ("keeping existing commitments alive") applies: an unwaited ask means the answer can never wake wingman.

**Fix:** add `bin/crew-ask await` to the allowlist and to the guard test's exemption cases.
(`bin/crew-say` for relaying an answer to a blocked member is a weaker candidate - it is arguably "acting," the pilot is necessarily present at that moment, and deferring it one turn costs little - reasonable to leave off, but the plan should say so rather than leave the stop-guard reason-1 mention of `crew-say` unaddressed.)

### Minor

#### 4. The section 6 deny reason's three resolutions all assume the `Artifact` tool can complete a call

If the `Artifact` tool is entirely unavailable in a crew session (not exposed by the harness/auth, so no call ever completes and no `PostToolUse` fires), no marker of any kind can appear, and the only escape from a denied `review` report is reporting `blocked` - which the deny reason does not name.
Round 1's finding 3 explicitly asked for the `blocked`/local-only escape to be named; the revision closed the failed-call case with `publish-failed` but dropped the last-ditch mention.
One clause in the deny reason ("if the Artifact tool is unavailable to you, report `blocked` instead") closes it.

#### 5. The `publish-failed` record shape omits the `sha256` its own staleness check requires

The guard allows a `publish-failed` record only "for the file's *current* contents (same staleness check as `published`)," but the record shape is given as `{"status": "publish-failed", "reason": ...}` with no `sha256` field.
The implementer can infer it; the spec should state it.

#### 6. "Skip every leading token starting with `-`" mishandles value-taking `uv run` flags

`uv run -p 3.12 pytest` skips `-p`, then treats `3.12` as the command - a false negative in the delegation guard's test-runner detection (deny direction).
This is not a regression (the current `tokens[2:]` code fails on all flag forms), and in the allowlist direction misparsing can only over-deny non-standard shapes while the mandated `WM_UV` form works - the safe direction.
But the plan's claim that "future `uv run` flags need no update here" is overstated, and round 1's fix wording ("skip option tokens (`--*` and their values where applicable)") was dropped in the retelling.
Worth one sentence acknowledging the value-flag limitation, or handling the small set of value-taking `uv run` flags.

#### 7. Section 5's "two remaining ways" to hit set-run-id-but-unset is missing the most common third

A wingman restart mid-run mints a fresh `WINGMAN_RUN_ID` and its first `pref-set` replaces `preferences.json` wholesale - so every crew member spawned before the restart still carries the *old* run id, whose `pref-get` now exits 1.
For all pre-restart in-flight crew, `artifact-link-guard.sh` then takes its "preference isn't `artifact`" skip permanently (their run id never regains answers), and condition B falls back to the crew-side prose ask.
This degrades to exactly today's behavior rather than deadlocking, so no mechanism change is required - but the plan's rarity claim ("the two remaining ways to hit it are a resumed crew member and manual interference") is wrong, and the implementer and contract text should name restart-with-in-flight-crew as the expected third case.

#### 8. Nits

- Section 1 says "a `pref-get`/`pref-list`" once where every other mention is `prefs-list` - one subcommand name, pick it everywhere.
- The guard resolves `--artifact <path>` and the crew record's `artifact` against markers keyed by `realpath(tool_input.file_path)`, but never says what a *relative* artifact path resolves against; specify the hook input's `cwd` (both values are commonly repo-relative while `Artifact` calls often use absolute paths).
- `artifact-publish-tracker.sh` activates "whenever `$WM_HOME` resolves," which with `common.sh`'s `~/.wingman` default is every session on the machine - marker files will accumulate for non-crew sessions that publish Artifacts, and the marker-cleanup follow-up only covers crew stand-down. Harmless; worth one line in the cleanup note.

## What holds up well

- Every round-1 must-fix and should-fix is genuinely closed, with the fixes specified at the right level of detail and each one verified here against the code it touches (`wm-state.py`'s crew record and mirroring, `crew-resume`'s launch script, `spawn-crew`'s exports, `install-user-hook.py`'s hardcoded event key, the tokenizer's `uv` case).
- The `publish-failed` marker design is a clean close of the deadlock: both outcomes of an `Artifact` attempt now leave an escapable recorded state, and the plan correctly downgrades the unverified-`tool_response` open question's stakes as a result.
- The ask-tracker reuses section 6's own marker pattern rather than inventing a second mechanism, and the residual accepted gap is stated honestly with a correct cost argument against closing it.
- Section 7's run-id semantics argument (a resume belongs to the resuming sit-down) is the right call and is consistent with the preferences store's whole-file-per-run replacement behavior.
- The revision's habit of naming which round-1 finding each change closes makes the delta auditable - this review would have been slower and less certain without it.
