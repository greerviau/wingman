# Sixth-pass review: wingman skills for robust operation (r6)

**Artifact reviewed:** `docs/plans/2026-07-13-wingman-skills-for-robust-operation.md` (revision r6)
**Prior passes:** r1 (`.../2026-07-13-review-...`), r2 (`.../2026-07-13-rereview-...`), r3 (`.../2026-07-13-third-review-...`), r4 (`.../2026-07-13-fourth-review-...`), r5 (`.../2026-07-13-fifth-review-...`) - all request-changes
**Date:** 2026-07-13
**Verdict:** **request-changes** (one must-fix, one should-fix, two nits - all narrow edits; no redesign, and the detection mechanism is untouched)

## Summary

**All three of the fifth pass's findings are correctly closed.** The claim-time count reset is deleted from "Files touched" and inverted into an explicit prohibition, with the three-rule writer invariant now stated in the design section and a direct regression test added. Reset-on-trip (rule 3) is added, and the self-heal path now genuinely holds on a quiet fleet - traced below. The `stale-claim-lock` hint and its conditional remedy are added, and the underlying leaked-lock bug is filed as issue #74 (confirmed OPEN on GitHub) and referenced from Open questions. Both nits are closed.

**The budget mechanism itself remains correct and I would not change it.** Nothing in this pass touches the pure consecutive count.

Two new defects, both introduced by r6's own fixes, both narrow:

1. **(Must-fix.)** The "Files touched" bullet orders `--classify`'s steps as *"its `stale-claim-lock` check, its `cycle_live` check, its exhaustive hint logic"* - the lock check **before** `cycle_live`. The design section nests the lock check *inside* the already-spurious branch, after `cycle_live` has ruled out a live cycle. Implemented in the Files-touched order, a leaked lock that coexists with a **live, healthy cycle** (a reachable state, traced below) misclassifies that healthy cycle as `spurious`, ticks the budget, and drives a false `spurious-repeated` while supervision is running fine the whole time. This is the same shape of defect as the fifth pass's must-fix 1 - the Files-touched list drifting from the design section - recurring in the same bullet one revision later.
2. **(Should-fix.)** `/watch` cannot actually obtain the forensic hint its new conditional remedy depends on. `--classify`'s stated stdout contract prints only the outcome word; the hint goes solely to `watch-spurious.log`. Reading that log is not in `/watch`'s `allowed-tools` (plan line 272), is denied outright by `hooks/pilot-preferences-guard.sh`'s `Read` branch (which allows exactly `$WM_HOME/wake` and nothing else), and "the most recent hint for this run of failures" is undefined against an append-only, multi-owner log that also carries `dropped-wake` lines.

---

## Status of the fifth pass's findings

| Fifth-pass finding | Status |
| --- | --- |
| 1 (must-fix): Files-touched claim-time count reset reverts the fix | **CLOSED** - clause deleted and inverted into an explicit prohibition (plan line 361); the three-rule writer invariant is stated in the design section (line 219); regression test (e) added (line 350), and it is correctly specified to run against the real claim-time code path, not `--classify` in isolation |
| 2 (must-fix): budget never self-heals on a quiet fleet | **CLOSED** - rule 3 (reset-on-trip) added (line 224) with its rationale (line 228); `/watch`'s body updated (line 285); regression test (d) added; the false "self-healing" claim is corrected rather than restated |
| 3 (should-fix): hint misdirects for the plan's own repro | **CLOSED as designed** - `stale-claim-lock` hint added and checked first among the hints (line 200); conditional remedy specified (lines 238-241); issue #74 filed (verified OPEN) and referenced from Open questions (line 379); tests added (line 351). Subject to new should-fix 2 below, which is a defect in the *delivery* of the hint, not a failure to close this finding |
| Nit 1: say `else`, not a third condition | **CLOSED** - line 200 now specifies an explicit `if`/`elif`/`else` and states why the `beat_age()` accident is not something to lean on |
| Nit 2: a `dropped-wake` line is forensics, not a save | **CLOSED** - residual stated precisely at line 259 and carried into Open questions (line 378) |

### The self-heal path, traced against a quiet fleet after a trip (the fifth pass's must-fix 2)

1. Three consecutive spurious classifications → count reaches 3 → `--classify` prints `spurious-repeated` **and resets the count to 0 in the same call** (rule 3). `/watch` reports to the pilot and does not re-arm.
2. The pilot clears the cause and resumes supervision the way the recovery message says - `/watch` again, or a raw `bin/watch-fleet` arm. Neither path classifies anything, so neither touches the count. Under r5 the count would still read 3 here; under r6 it reads **0**. This is the step where the old design was already lost.
3. The fresh cycle blocks healthily for days. The fleet is quiet: no wake, so no classification, so rule 2 never fires. The count stays at 0 - which is now the *correct* resting value, and is exactly why rule 3 is load-bearing rather than a convenience: rule 2 provably cannot run in this window.
4. Weeks later, one isolated, unrelated reap → `--classify` → spurious → count 0 → 1 → below threshold → prints `spurious` → `/watch` re-arms silently.

No false trip, no false "died three times in a row" message, no wrongly-withheld re-arm. The sticky-forever state is gone, and the property r5's non-reset rule was protecting survives: a pilot who resumes without fixing a genuinely persistent cause re-trips within three quick cycles, and `/watch` never re-arms after a trip, so no silent loop can hide in the gap. The plan states this tradeoff explicitly (line 228) rather than implying it away.

---

## Findings

### Finding 1 (must-fix): "Files touched" orders the `stale-claim-lock` check *before* `cycle_live`, contradicting the design section - a healthy live cycle is then classified spurious

**Where:** plan line 361 (Files touched): *"the new `--classify [--owner <id>]` subcommand ... with, **in order**, its `stale-claim-lock` check, its `cycle_live` check, its exhaustive hint logic ..."*
**Against:** plan lines 198-205 (the design section), where the lock check is explicitly *inside* the `cycle_live`-is-false branch: *"If absent, check `cycle_live` ... before concluding anything: ... **No cycle is live** → genuinely spurious. Determine the forensic hint. **Checked first, before anything else**: `[ -d "$PIDFILE.lock" ]`."*

The design section is correct: "checked first" there means *first among the hints*, on a path where spuriousness has already been established. The Files-touched line hoists it out of that branch and puts it ahead of `cycle_live` in the top-level sequence. A developer implementing the Files-touched list literally writes:

```sh
# --classify
if [ -f "$EXITREC" ]; then ... ; fi
if [ -d "$PIDFILE.lock" ]; then hint=stale-claim-lock; <spurious path>   # WRONG: before cycle_live
elif cycle_live; then <healthy>
else <hint logic>; <spurious path>
fi
```

**Why this is reachable, and what it costs.** A leaked claim-lock directory can coexist with a live, healthy cycle. Confirmed against the code: the lock is held from `mkdir "$CLAIMLOCK"` (`watch-fleet:278`) until `release_claim`, and a **redundant** arm - one that finds a live cycle and exits via the singleton guard - holds it across `watch-fleet:278-303`. If that redundant arm is `SIGKILL`ed inside that window (its `trap release_claim EXIT` cannot run), the lock is leaked **while cycle A is still live and supervising normally**. This is the same reap mechanism the plan's own leading hypothesis (F9, harness-side reap) says recurs on an ordinary cadence, and the redundant arm is the most frequently-armed process in the whole loop.

From that state, under the Files-touched ordering:

1. Any subsequent wake → `--classify` → record absent → lock present → **`stale-claim-lock`, classified spurious** - while cycle A is alive, beacon fresh, doing its job.
2. Budget ticks. Log fills with a hint about a cycle that is not dead.
3. `/watch` re-arms (spurious → arm one fresh cycle). That arm spins 50 tries against the leaked lock and dies at `watch-fleet:290`, 5 seconds later - a wake that produces another `spurious`.
4. Three of these → `spurious-repeated` → `/watch` stops re-arming and tells the pilot supervision is not being maintained. **It is being maintained** - cycle A never stopped.

Under the design-section ordering, none of this happens: `cycle_live` is true, so `--classify` prints `healthy`, ticks nothing, logs nothing, and `/watch` does not re-arm (which is also the correct action - there is nothing to fix while A is up). When A eventually does die, the lock check then correctly produces `stale-claim-lock` on a genuinely spurious path. The design section is right and complete; only the Files-touched line is wrong.

**Fix:** reword line 361 to match the design section - *"its `cycle_live` check first; then, only on the genuinely-spurious path, its hint logic (the `stale-claim-lock` check first among the hints, then the exhaustive `clean-exit-or-sigterm` / `sigkill-suspected` / `hung-or-stale-pidfile` `if`/`elif`/`else`)"* - and add a one-line normative statement that where "Files touched" and the design sections differ, the design section governs. Add the regression test: **a live, healthy cycle with a leaked `$PIDFILE.lock` present must classify `healthy`, not `stale-claim-lock`/`spurious`** - the direct test for this ordering, and one the existing hint test (which sets up a lock with no live cycle) does not cover.

### Finding 2 (should-fix): `/watch` has no way to read the hint its new conditional remedy is conditioned on

**Where:** plan line 238 (*"the remedy clause is conditional on the **most recent** hint recorded in `watch-spurious.log`"*), line 285 (`/watch`'s body: *"with the remedy conditioned on the most recent forensic hint in `watch-spurious.log`"*), against line 272 (`/watch`'s `allowed-tools`) and lines 197-205 (`--classify`'s output contract).

`--classify`'s stated stdout contract prints **only the outcome word**: step 1 says *"read its one-word contents, print it (`healthy`, `fire`, or `remote-control-dropped`)"*, and step 2's spurious path says *"Append one line to `$WINGMAN_HOME/watch-spurious.log` (timestamp, owner, hint)"* then print `spurious` / `spurious-repeated`. **The hint is never printed.** So `/watch` must go read the log. Three problems, in ascending order of hardness:

- **No grant.** `/watch`'s `allowed-tools` is `Bash(bin/watch-fleet:*), Bash(bin/crew-list:*), Read(~/.wingman/wake)` - no `watch-spurious.log`. Reading it prompts, in wingman's own session, at exactly the moment supervision has just failed. This is the same class of defect the plan itself fixed for `/ask` (F6, where `Read(~/.wingman/ask/*.json)` was added precisely so the follow-up read never prompts), and the same parity gap the whole `/say`+`/ask` half of this spec exists to close.
- **Denied by the guard.** `hooks/pilot-preferences-guard.sh:232-235` allows `Read` for **exactly** `$WM_HOME/wake` and nothing else, falling through to `deny()` otherwise. During the pending-preferences window the read is a hard denial, not a prompt.
- **Undefined parse.** "The most recent hint for this run of failures" has no definition against an append-only log that is shared across owners and also carries `dropped-wake` lines from the finding-5 fix. Asking skill prose to pick the right line out of that is exactly the "branching logic in skill prose, guaranteed to drift" shape this plan's own "existing convention" section argues against, and which the `--classify` verb exists to eliminate.

**Fix (cheap, no new grant, no log parsing, keeps the bare-command property intact):** have `--classify` print the hint on its outcome line - e.g. `spurious stale-claim-lock` / `spurious-repeated 3 stale-claim-lock`. It already computes the hint; emitting it costs one field. `/watch` then branches on stdout it already receives from a command it is already granted, `watch-spurious.log` reverts to being pure forensics with no reader dependency, and the count in the message (which the skill likewise has no way to know today - `WM_SPURIOUS_BUDGET_COUNT` is env-overridable and the skill cannot read it) comes along for free. Update the `/watch` body (line 285) and the finding-3 remedy (lines 238-241) to condition on the classifier's own output rather than the log, and the test at line 351 to assert the hint appears on stdout.

### Nits

1. **State that a missing or empty count file reads as 0.** Rule 1 says "increment the count file, unconditionally," and the file does not exist before the first spurious classification. `bin/watch-fleet` runs under `set -u` (`watch-fleet:60`); a `$(( $(cat "$COUNTFILE") + 1 ))` against a missing file yields an arithmetic error, not 0. This is the same `set -u` foot-gun the fifth pass's nit 1 caught in the hint logic; one sentence in the finding-2 fix section closes it.
2. **Line 215 overstates how a leaked lock arises, which distorts the repro's priority.** It says *"a `SIGKILL`ed cycle leaks the claim-lock directory (its own `trap release_claim EXIT` cannot run under `SIGKILL`)"*. A cycle in the blocking loop has **already** released the lock (`release_claim` at `watch-fleet:310`, before the loop starts) - killing it leaks nothing. The lock leaks only when a kill lands inside the ~0.2-0.5s claim window (`watch-fleet:278-303`), which for a *blocking* cycle is a vanishingly small slice of its lifetime, and which the plan's own headline repro therefore depends on. (The redundant-arm variant in finding 1 above is the genuinely likely way to hit it, since a redundant arm spends *most* of its short life inside that window.) Worth correcting so the implementing developer builds the right mental model, and so issue #74's priority is judged against how it actually occurs.

---

## Confirmed clean (no change requested)

- **The pure consecutive-count budget with reset-on-trip.** Traced against both the never-claims repro and the claims-then-dies repro; both count, neither has a gate to fall through, and the quiet-fleet self-heal now holds. The stated false-positive tradeoff is real, correctly priced, and narrowed by rule 3.
- **The three-rule writer invariant** and its regression test (e) - the strongest test in the plan, and correctly specified to run against the real claim-time code, not `--classify` in isolation.
- **`--classify`'s dispatch point, argument-parser addition, `cycle_live` read-side check, exit-record write priority** (`fire`/`remote-control-dropped` unconditional, `healthy` non-clobbering), and the **loud claim-time drop**: all unchanged from r5 and all still correct.
- **Issue #74** exists, is OPEN, and its title matches the bug as described. The decision to file rather than fold the fix into this plan is right.
- **`/say` + `/ask`**: unchanged, sound, still the right thing to build first and still independently shippable ahead of everything above.
- **`/prefs`**: unchanged; the narrow `Skill`-branch guard extension and the flagged-unconfirmed `tool_input` field remain correct.
- **Line citations re-verified against the current file**: parser `82-90` (`--owner` at `:84`), `cycle_live` `:218`, mode block `:225`, `CLAIMLOCK="$PIDFILE.lock"` `:271` (so the plan's `[ -d "$PIDFILE.lock" ]` names the real path), `release_claim` `:275`, `mkdir` `:278`, `wm_die` `:290`, singleton `:302`, `release_claim` `:303`, fresh claim `:308`, `release_claim` `:310`, `INT TERM` trap `:311`. All accurate.

## What would make this approvable

Two edits, neither a redesign:

1. **Reorder the Files-touched bullet so `cycle_live` precedes the `stale-claim-lock` check** (finding 1), state that the design section governs on any conflict, and add the live-cycle-with-leaked-lock test. This is the third consecutive revision in which "Files touched" has diverged from the design section; the normative statement is what stops a fourth.
2. **Have `--classify` print the hint (and the count) on its outcome line** (finding 2), and condition `/watch`'s remedy on that rather than on parsing `watch-spurious.log`.

The mechanism is right and has been right since r5. What r6 got wrong is, again, only in how the design is handed to the implementer - and both remaining defects are in that same seam.
