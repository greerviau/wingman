# Seventh-pass review: wingman skills for robust operation (r7)

**Artifact reviewed:** `docs/plans/2026-07-13-wingman-skills-for-robust-operation.md` (revision r7)
**Prior passes:** r1 (`2026-07-13-review-...`), r2 (`...-rereview-...`), r3 (`...-third-review-...`), r4 (`...-fourth-review-...`), r5 (`...-fifth-review-...`), r6 (`...-sixth-review-...`) - all request-changes
**Date:** 2026-07-13
**Verdict:** **approve** - both sixth-pass findings are correctly closed, no new defect is introduced by either fix, and nothing must-fix remains. Two should-fix and two carried-over nits are listed below as text-level edits to fold in during implementation; none of them changes the design, and none is a reason to hold the plan.

## Summary

This is the first pass in which the design has survived unchanged and the fixes did not introduce a new defect of their own.

- **Sixth-pass must-fix (Files-touched check ordering): CLOSED, correctly.** The Files-touched bullet (plan line 373) now states the same four-step order as the design section, and adds the exact property whose absence caused the defect: *"a live cycle always means `healthy`, regardless of any leaked lock coexisting with it - checked before, never after, the lock check."* The design section's own wording was tightened in the same direction (line 245), and the direct regression test - a leaked `$PIDFILE.lock` coexisting with a genuinely live cycle must classify `healthy`, not `stale-claim-lock`/`spurious` - is added at line 362.
- **Sixth-pass should-fix (`/watch` cannot read the hint its remedy depends on): CLOSED, and by the cheaper of the two available routes.** `--classify` now prints the hint on its own outcome line (`spurious <hint>` / `spurious-repeated <hint>`, line 212), the remedy-selection prose is rewritten to parse that line rather than `watch-spurious.log` (lines 247, 296), `watch-spurious.log` is demoted to pure forensics with no reader dependency (line 252), `/watch`'s `allowed-tools` correctly needs no new grant (line 283), and a test asserting the hint reaches `/watch` with no file read is added (line 363).

Neither fix introduces a new failure path. I traced both against the code and against the interleavings the prior four passes used to break this design; details below.

---

## Verification of the two round-6 fixes

### Fix 1: check ordering (sixth-pass must-fix)

**Design section (lines 202-210, 245)** and **Files-touched (line 373)** now agree, and both are correct:

1. exit-record present → print its token, consume it, exit.
2. else `cycle_live` → `healthy`. *This is now stated in Files-touched as unconditional on any coexisting lock.*
3. only on the no-cycle-live path: `[ -d "$PIDFILE.lock" ]` → `stale-claim-lock`.
4. else the exhaustive `if`/`elif`/`else` pidfile-residue hints.

The failure the sixth pass traced - a redundant arm `SIGKILL`ed inside its ~0.2-0.5s claim window (`watch-fleet:278-303`) leaks the lock while cycle A is still live and supervising, and the Files-touched ordering then classifies that healthy cycle as `spurious` and drives a false `spurious-repeated` - is no longer reachable from any reading of the plan. Under the stated order, `cycle_live` is true, `--classify` prints `healthy`, nothing ticks, nothing logs, `/watch` does not re-arm. The lock check only fires once A genuinely dies, which is exactly when `stale-claim-lock` is the correct diagnosis.

`CLAIMLOCK="$PIDFILE.lock"` is confirmed against the code (`watch-fleet:271`), so the plan's `[ -d "$PIDFILE.lock" ]` names the real path.

**One residual race, already handled by the plan itself (not a finding).** A `--classify` that runs while a *legitimate* arm is mid-claim (lock held, `$PIDFILE` not yet written) would see no live cycle plus a lock present and report `stale-claim-lock` against a lock that is not stale. The window is sub-second, it requires a concurrent arm for the same owner (which `/watch`'s own body forbids within a turn - classify and arm are sequential, step 1 then step 2), the cost is one false budget tick, and the remedy text already guards the pilot against acting on it: *"remove it ... after confirming no genuine `watch-fleet` arm is concurrently in progress"* (line 249). Correctly anticipated; no change requested.

### Fix 2: the hint on `--classify`'s outcome line (sixth-pass should-fix)

The three problems the sixth pass raised are each structurally gone, not patched around:

- **No grant needed.** The hint arrives in the stdout of the `Bash(bin/watch-fleet:*)` call `/watch` already made. `allowed-tools` is unchanged and correct.
- **Guard-proof.** Still a bare `bin/watch-fleet --classify`, so it remains covered by `hooks/pilot-preferences-guard.sh`'s existing `watch-fleet` basename exemption during the pending-preferences window - the property r3 fought to establish is preserved by this fix rather than eroded by it.
- **No log parse.** "The most recent hint for this run of failures," which had no definition against an append-only, multi-owner log carrying `dropped-wake` lines, is gone entirely. `/watch` parses the second word of the line it just received.

The output contract is self-consistent: `healthy` / `fire` / `remote-control-dropped` stay bare single tokens (line 212), the two spurious outcomes carry exactly one extra field, and `/watch`'s stated parse ("the second word") matches both. `remote-control-dropped` is one hyphenated token, so first-word tokenization is unambiguous across all five outcomes.

---

## Findings

### Should-fix 1: `/watch`'s `spurious-repeated` report interpolates a count `<N>` it has no way to know

**Where:** plan line 239 (the message template: *"the watcher for `<owner>` has died `<N>` times in a row"*) and line 296 (`/watch`'s body: *"the watcher has died `WM_SPURIOUS_BUDGET_COUNT` (default 3) times in a row"*), against line 212 (the stdout contract, which carries the hint but **not** the count) and line 283 (`allowed-tools`).

`/watch` has exactly three sources of information: `bin/watch-fleet` stdout, `bin/crew-list`, and `Read(~/.wingman/wake)`. The count is in none of them.

- The stdout contract prints `spurious-repeated <hint>` - no count field.
- `WM_SPURIOUS_BUDGET_COUNT` is env-overridable by design (line 388), and the skill cannot read the environment (no grant, and no reason to add one).
- The count *file* is not a fallback either: rule 3 resets it to 0 in the same call that prints `spurious-repeated` (line 231), so by the time anything could read it, it reads 0.

**Concrete failure:** an operator sets `WM_SPURIOUS_BUDGET_COUNT=5` (the plan explicitly invites this as post-deployment tuning). The watcher dies five times in a row; `--classify` trips correctly and prints `spurious-repeated stale-claim-lock`; `/watch` reports *"the watcher has died 3 times in a row"* - a false number in a pilot-facing attention message, produced by a skill asserting something it cannot know. This is the same shape as the finding this fix was closing (the skill depending on a value it has no access to), just at lower stakes.

**Fix (one field, already recommended by the sixth pass and taken only halfway):** have `--classify` carry the count on the trip line - `spurious-repeated <count> <hint>` - and state the field order explicitly, updating `/watch`'s parse accordingly. If keeping a uniform two-field shape for both spurious outcomes is preferred, `spurious <count> <hint>` works equally well and makes the parse rule a single sentence. Alternatively, if the count is judged not worth a field, drop `<N>` from the message and say *"has died repeatedly, with no successful cycle in between"* - but do not leave the message interpolating a number the skill is guessing.

### Should-fix 2: the Files-touched bullet omits the new stdout contract, and the requested "design section governs" statement was not added

**Where:** plan line 373 (Files touched, `bin/watch-fleet`) and the absent normative statement.

The r7 fix's whole substance is a change to `--classify`'s **output contract** (the hint on the outcome line). That contract is stated in the design section (line 212) and asserted by a test (line 363), but the Files-touched bullet - the one section written *for the implementing developer* - describes `--classify`'s checks, hint vocabulary, and budget without ever saying it prints the hint. A developer working the Files-touched list would build a `--classify` that prints only the outcome word and be caught by the test, not by the spec.

This is the same seam that produced the must-fix in each of the last three passes (r5, r6, and r7 all found "Files touched" drifting from the design section). The sixth pass asked for two things here: the reorder (done) **and** *"a one-line normative statement that where 'Files touched' and the design sections differ, the design section governs"* (grep confirms no such statement exists anywhere in the plan). That statement is the cheap structural mitigation for a defect class that has now recurred three times; it is worth adding along with the missing contract line.

**Fix:** add `--classify`'s stdout contract to the Files-touched bullet (`prints \`<outcome>\` alone for `healthy`/`fire`/`remote-control-dropped`, and `<outcome> <hint>` for the two spurious outcomes`), and add the normative line at the top of the section.

### Carried-over nits from the sixth pass, neither addressed

1. **A missing/empty count file's arithmetic behavior is still unstated** (sixth-pass nit 1). Rule 1 says *"increment the count file, unconditionally"* and the file does not exist before the first spurious classification. `bin/watch-fleet` runs under `set -u` (`watch-fleet:60`). I tested both plausible implementations: `c=$(cat "$F" 2>/dev/null); echo $((c+1))` against a missing file yields `1` and exits 0 (an empty *value* is fine in arithmetic context), but `$((COUNT+1))` where `COUNT` was never assigned aborts with `unbound variable`. So the footgun is real for one of the two shapes a developer would naturally write. One sentence in the finding-2 fix section ("a missing or unreadable count file reads as 0") closes it.
2. **Line 222 still overstates how the claim lock leaks** (sixth-pass nit 2): *"a `SIGKILL`ed cycle leaks the claim-lock directory (its own `trap release_claim EXIT` cannot run under `SIGKILL`)"*. Confirmed against the code: a cycle in the blocking loop has **already** released the lock (`release_claim`, `watch-fleet:310`, before the loop starts), so killing it leaks nothing. The lock leaks only when a kill lands inside the sub-second claim window (`watch-fleet:278-303`) - which for a blocking cycle is a vanishingly small slice of its life, and which the *redundant arm* (finding 1 of the sixth pass) hits far more readily, since it spends most of its short life inside that window. The plan's own headline repro therefore depends on the narrower mechanism than the one it describes. This does not affect any test (test (b) at line 361 simply plants a lock directory), only the developer's mental model and issue #74's priority - but it is wrong as written and cheap to correct.

---

## Confirmed clean (no change requested)

- **The pure consecutive-count budget with reset-on-trip.** Untouched by r7 and still correct. Re-traced against both repros (never-claims and claims-then-dies); both count, neither has a gate to fall through, and the quiet-fleet self-heal holds.
- **The three-rule writer invariant** (line 226) and its regression test (e) - still the strongest test in the plan, still correctly specified to run against the real claim-time code path.
- **`--classify`'s dispatch point, argument-parser addition, `cycle_live` read-side check, exit-record write priority** (`fire`/`remote-control-dropped` unconditional, `healthy` non-clobbering), and the **loud claim-time drop**: all unchanged and all still correct.
- **`/watch`'s `allowed-tools`** is correct and, after the r7 fix, provably sufficient: nothing in the body now reads a path it does not grant.
- **The five-outcome vocabulary and `/watch`'s branch table** (lines 291-298) are complete and mutually exclusive, and the `spurious-repeated` branch correctly refuses to re-arm.
- **Line citations re-verified against the current `bin/watch-fleet`:** `set -u` `:60`, `cycle_live` `:218-223`, mode block `:225`, `CLAIMLOCK="$PIDFILE.lock"` `:271`, `release_claim` def `:275`, `mkdir` `:278`, `wm_die` `:290`, singleton guard `:302`, `release_claim` `:303`, fresh claim `:308`, `release_claim` `:310`, `INT TERM` trap `:311`. All accurate.
- **`/say` + `/ask`** and **`/prefs`**: unchanged across three passes now; still sound, and `/say`+`/ask` remains the right thing to build first and independently.

## Recommendation

**Approve.** The mechanism has been right since r5 and is now handed to the implementer consistently in both the design section and the Files-touched list. The four items above are one- or two-sentence edits with no design consequence; folding them in as part of the implementation change - rather than spending another review round on them - is the right call, and the plan's own test suite already catches the only one (should-fix 1's count) that has any pilot-visible effect.
