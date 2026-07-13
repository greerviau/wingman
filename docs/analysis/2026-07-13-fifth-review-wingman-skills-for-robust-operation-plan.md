# Fifth-pass review: wingman skills for robust operation (r5)

**Artifact reviewed:** `docs/plans/2026-07-13-wingman-skills-for-robust-operation.md` (revision r5)
**Prior passes:** r1 (`.../2026-07-13-review-...`), r2 (`.../2026-07-13-rereview-...`), r3 (`.../2026-07-13-third-review-...`), r4 (`.../2026-07-13-fourth-review-...`) - all request-changes
**Date:** 2026-07-13
**Verdict:** **request-changes**

## Summary

**The headline defect is genuinely fixed in the design.** The recurring failure - a claim that never succeeds, silently livelocking supervision - is closed at the root, not patched again.
r5 removes the lifetime qualifier and the `watch-started` file entirely; the budget is now a pure consecutive count of spurious classifications with no wall-clock term and no dependency on a successful claim anywhere in the trip condition.
Traced line by line against the plan's own stuck-claim-lock repro, it trips on the third arm (trace below).
This is the structurally different mechanism the fourth pass asked for, and it is the right one: the two obvious cheaper alternatives (reset on a successful claim; reset on a successful loop entry) both re-open the *observed* failure - an arm that claims and is then killed externally - so the pure count is not merely acceptable here, it is the only one of the three that catches both classes.

**But the plan does not ship that design.** Its "Files touched" section instructs the implementing developer to also reset the count file **at fresh-claim time inside `bin/watch-fleet`** - a rule that appears nowhere in the design section, contradicts it, and, if implemented as written, reverts the fix for every failure that claims before dying (finding 1). That single clause is worth the whole revision.

A second must-fix: the budget's claimed self-healing property (plan line 213) does not hold on a quiet fleet, because the only thing that resets the count is a *classification*, and a healthy watcher on an idle fleet never produces one. Once a trip has ever occurred, the count stays at or above the threshold indefinitely, and the very next isolated spurious death - the ordinary case `/watch` exists to absorb silently - halts supervision and reports a message that is false (finding 2).

All three of the fourth pass's should-fixes and all three of its nits are closed. Two smaller findings and one nit are reported below.

---

## Status of the fourth pass's findings

| Fourth-pass finding | Status |
| --- | --- |
| 1 (must-fix): lifetime qualifier measured at classify time, carries `W` | **CLOSED** - qualifier removed entirely; no `now` anywhere in the trip condition |
| 2 (must-fix): `watch-started` absent for any arm that dies before claiming | **CLOSED** - file removed; a never-claimed death counts exactly like any other spurious death |
| 3 (should-fix): hint branches non-exhaustive, `set -u` abort risk | **CLOSED** - three-way check, `hung-or-stale-pidfile` added (see nit 1 on wording) |
| 4 (should-fix): a racing `healthy` write clobbers an acked `fire` | **CLOSED** - `healthy` non-clobbering, `fire`/`remote-control-dropped` unconditional; the priority rule is stated and tested |
| 5 (should-fix): silent claim-time clear destroys an unconsumed `fire` | **CLOSED** - the clear is now log-then-clear (`dropped-wake` in `watch-spurious.log`); declining the "classify before every arm" half is argued, not overlooked (see nit 2) |
| Nit: parser must learn `--classify` | **CLOSED** - F3 fix point 1, plus its own regression test |
| Nit: "never touch" → "never mutate" `$PIDFILE`/`$BEATFILE` | **CLOSED** - plan line 186 |
| Nit: no lifecycle for the new state files | **CLOSED** - named in Open questions as a pre-existing gap, with the two new files explicitly included in whatever closes it |

The testing strategy also absorbed the fourth pass's structural criticism correctly: budget test (a) now holds a delay **between the cycle's death and its classification** (where `W` lives), not merely between classify calls, and test (b) drives the never-claimed repro directly. Both are the right tests, and neither would pass under r3's or r4's designs.

### The repro, traced against r5

Stale `$PIDFILE.lock` in place (leaked by a `SIGKILL` inside the claim window - `trap release_claim EXIT` at `watch-fleet:283` cannot run):

1. Arm spins 50 x `sleep 0.1`, `mkdir` fails every time, dies at `watch-fleet:290`. No exit-record written (correct - absence is the spurious signal). No claim, and in r5 there is nothing else it needed to write.
2. `--classify`: record absent → `cycle_live` false (`$PIDFILE` names the dead pid) → genuinely spurious → hint written to `watch-spurious.log` → **count incremented, unconditionally, with no lifetime gate to fall through.**
3. Repeat. On the third, count reaches `WM_SPURIOUS_BUDGET_COUNT` → `spurious-repeated` → `/watch` reports to the pilot and does **not** re-arm.

The silent livelock is gone. Every prior revision failed at step 2 for a different reason; r5 has no step-2 gate left to fail at. Confirmed against the real code: `beat_age()` (`watch-fleet:211-215`) returns `999999` when `$BEATFILE` is missing, so `cycle_live` is genuinely false here, and the parser (`watch-fleet:82-90`) does still `wm_die` on `--classify` today, exactly as the plan's own nit fix says.

---

## Findings

### Finding 1 (must-fix): "Files touched" tells the developer to reset the count at claim time, which reverts the fix for every failure that claims before dying

**Where:** plan line 334 (Files touched): *"`bin/watch-fleet` (extend: ... a loud (log-then-clear) stale-record handling **and `watch-spurious-count` reset at fresh-claim time**; ...)"*

The design section is unambiguous and correct: the count file has exactly two mutation rules (finding-2 fix, plan lines 212-214) - **increment** on every spurious classification, **reset** on any non-spurious *classification* outcome (`healthy`/`fire`/`remote-control-dropped`). No claim-time reset appears anywhere in it. The claim-time write point (F3 fix, point 2, plan line 179) describes only the exit-record's log-then-clear, and explicitly notes that r4's `watch-started` write at that point is **removed**.

Line 334 nevertheless instructs the implementer to reset `watch-spurious-count` inside `bin/watch-fleet` at fresh-claim time. This is not a harmless duplication; it is a third mutation rule that changes the detector's behavior:

1. The harness reaps `/watch`'s background task shortly after it arms (the plan's own F9 compaction hypothesis - the mechanism it considers most likely, recurring "on an ordinary cadence").
2. Each arm **wins the claim** (`echo $$ > "$PIDFILE"`, `watch-fleet:308`) → under line 334, **the count resets to 0** → the cycle enters the loop → it is reaped → death.
3. `--classify`: record absent, `cycle_live` false → spurious → count increments 0 → 1.
4. `/watch` re-arms → claim wins → **count resets to 0 again.** Go to 2.

The count never exceeds 1. `spurious-repeated` never fires. Supervision is dead, silently, forever - the exact failure this revision exists to close, restored on the path that matches the *originally observed incident* (a `watch-fleet` background process killed externally twice, each needing manual recovery). Note the stuck-claim-lock repro would still trip (it never claims, so it never hits the reset), which is what makes this so dangerous: the plan's own headline regression test **passes** while the more common failure class silently regresses. That is the same trap the third and fourth passes each caught in a different form - a test that only exercises the regime where the defect is invisible.

For completeness, a claim-time reset is not a defensible design choice that merely needs promoting into the design section. It is the "reset on a successful claim" variant, and it is wrong on its own terms: winning a claim proves only that the lock was free, not that the cycle can stay up, so it cannot distinguish a healthy watcher from one being reaped seconds after every arm. The design section's rule (reset only on a *classified* non-spurious outcome) is the correct one.

**Fix:** delete `"and \`watch-spurious-count\` reset at fresh-claim time"` from the Files-touched bullet. `bin/watch-fleet`'s claim-time code touches the exit-record only; the count file is written **exclusively** by `--classify`. Say that explicitly in the finding-2 fix section ("the count file has exactly two writers, both inside `--classify`") so the invariant survives the next edit, and add it to the testing strategy: **an arm that successfully claims must not alter the count file** - the direct regression test for this finding.

### Finding 2 (must-fix): the budget never self-heals on a quiet fleet, so after any trip a single isolated death permanently halts supervision

**Where:** plan line 213: *"reset the count file to 0 ... This is what makes the budget self-healing once a cycle actually stays up again"*, and line 214: *"The count file is *not* reset on this transition [reaching the budget]."*

The reset fires on a non-spurious **classification** - and a classification only happens when a wake is processed. A watcher that "actually stays up" produces **no wake at all**: it blocks. On a quiet or parked fleet (members in `review`, nothing transitioning - the plan's own cost-discipline section notes a large *idle* fleet is normal and expected), a perfectly healthy cycle can run for hours or days and never emit `fire`, never be redundantly armed into a `healthy`, and therefore never reset anything. The count is not reset by health; it is reset only by *evidence of health that happens to arrive as a wake*, which is a different and much rarer thing.

Composed with the deliberate non-reset on trip, the result is a sticky, permanently degraded state:

1. Three consecutive spurious deaths → count = 3 → `spurious-repeated` → `/watch` stops re-arming, pilot is told.
2. The pilot diagnoses the cause, fixes it, and resumes supervision the way the plan's own recovery message tells them to (`/watch` again, or arming `bin/watch-fleet` directly). **The count is still 3** - and the manual path skips step 1 of `/watch`'s body entirely (it is not "invoked in response to a background task's completion"), so nothing classifies and nothing resets.
3. The fresh cycle is healthy. The fleet is quiet. No wake, no classification, no reset. The count sits at 3 indefinitely.
4. Weeks later, one isolated, unrelated reap (precisely the case `spurious` exists to absorb silently, and which the plan's own leading hypothesis says recurs on an ordinary cadence) → `--classify` → spurious → count 4 → `>= 3` → **`spurious-repeated`** → `/watch` refuses to re-arm and reports *"the watcher has died 3 times in a row with no successful cycle in between"*.

That message is **false** (the intervening cycle stayed up for weeks), and the action taken on it is **wrong** (a silent re-arm was the correct response). From the first trip onward, the ordinary spurious-recovery path is gone: every subsequent single death is an attention event requiring manual resumption, until some unrelated crew event happens to fire a cycle and reset the counter. The plan's stated tradeoff - "three isolated unrelated reaps would now trip it too" - understates this: after one trip, **one** isolated reap trips it, forever.

**Fix (one rule, no new state, no wall clock):** **reset the count to 0 when `spurious-repeated` is emitted** - the trip consumes the budget. The property line 214 is protecting ("a problem that was flagged and never actually fixed must be re-noticed immediately, not after three fresh failures") survives almost intact: in a genuinely persistent failure each arm dies in seconds, so a pilot who resumes without fixing the cause re-trips within three quick cycles rather than one, and `/watch` does not re-arm after a trip anyway, so no silent loop can hide in that gap. In exchange, the sticky false positive above disappears entirely. Add the matching test: **after a `spurious-repeated`, a single subsequent spurious classification must report `spurious`, not `spurious-repeated`** - and correct line 213's self-healing claim, which as written will be read as a guarantee the design does not provide.

### Finding 3 (should-fix): the forensic hint actively misdirects for the plan's own headline repro, and the recovery instruction cannot recover from it

**Where:** plan, F3 fix, `--classify` step 2 (the three-way hint) and the finding-2 fix's `spurious-repeated` message.

`spurious-repeated`'s entire purpose is to send the pilot to `watch-spurious.log` to find the cause. For the stuck-claim-lock repro - the one failure this whole budget was rebuilt to catch - the log tells them the wrong thing:

- The arm that just died died at `watch-fleet:290`, because `mkdir "$CLAIMLOCK"` failed 50 times. It **knows** exactly why it died; it prints so on stderr.
- `--classify` never learns this. It derives its hint purely from `$PIDFILE` residue left behind by an entirely **different, earlier** process: pidfile present with a dead pid → `sigkill-suspected`; pidfile absent (the `SIGKILL` landed before `watch-fleet:308`) → `clean-exit-or-sigterm`. Both are statements about the long-dead original cycle, not about the arm whose death is being classified, and neither mentions the lock.
- So the pilot, correctly triggered by `spurious-repeated`, reads a log full of `sigkill-suspected` and goes hunting for whatever is killing their watcher - while the actual cause, a leaked `~/.wingman/watch.pid.lock` directory, is sitting on disk and is nowhere named.

The recovery instruction compounds this: *"once the cause is understood, resume it by running `/watch` again or arming `bin/watch-fleet` directly"* is a **no-op for this failure** - the lock is still leaked, so the fresh arm spins 50 tries and dies at `:290` exactly like its predecessors. The only remedy is `rmdir` on the lock directory, which appears nowhere in the plan.

Confirmed against the code, and note the codebase's own comment is wrong here: `watch-fleet:255-258` claims *"a stale lock directory left by a killed process is cleared by the next arm once its 50 tries are exhausted"*. It is not - `:290` is a bare `wm_die` with no `rmdir`. The fourth pass flagged this as *"worth its own issue independently of this plan"*; r5 records the leak in its trace but does not file it, fix it, or correct the false comment.

**Fix (cheap, no new state, no wall-clock term):**
1. In `--classify`'s hint logic, check `[ -d "$PIDFILE.lock" ]` **first** and emit `stale-claim-lock` when it is present - the one hint that is about the arm that actually just died. Add it to the hint test.
2. Give `spurious-repeated`'s pilot-facing message a conditional remedy for that hint (clear the stale lock directory), since "arm it again" demonstrably does not work for it.
3. File the `:290` stale-lock-never-cleared bug as its own issue (with the incorrect comment at `:255-258`), as the fourth pass asked, and reference it from Open questions - the budget now *detects* this failure, but nothing in this plan makes it *recoverable*.

### Nits

1. **Say `else`, not a third condition.** Plan line 193 promises "an explicit, exhaustive three-way check with a terminal `else`", then specifies branch three as a *condition* (`beat_age()` at or beyond `$GRACE`). Written literally as `if / elif / elif` with no `else`, that is the shape the fourth pass rejected. It happens to be safe today - `beat_age()` echoes `999999` when `$BEATFILE` is missing (`watch-fleet:212`), so the third condition is total over `cycle_live == false` - but that is an accident of an unrelated helper, not a property the design should lean on under `set -u`. Write branch three as the `else` arm.
2. **A `dropped-wake` line is forensics, not a save.** The finding-5 fix makes an overwritten wake *traceable*, but if the dropped record was a `fire`, the crew event is still permanently swallowed (`fire()` acked it at `watch-fleet:434-436`), and `watch-spurious.log` has no reader unless a `spurious-repeated` happens to send someone there. The plan's phrasing ("nothing is ever silently lost, only ever loudly dropped") is optimistic for a log file nobody is told to read. Declining the mandatory classify-before-arm alternative is well argued and I would keep that call - but name the residual in Open questions: a dropped `fire` is a lost crew event, recoverable only when that member's status next changes.

---

## Confirmed clean (no change requested)

- **The pure consecutive-count budget** is the correct mechanism, and its accepted false-positive tradeoff is real and correctly priced (subject to finding 2, which makes that tradeoff far worse than the plan believes). Both cheaper-looking alternatives - reset on claim, reset on loop entry - re-open the observed external-kill class; this design is the only one of the three that catches both it and the never-claimed class.
- **Exit-record write priority** (`fire` = `remote-control-dropped` > `healthy`, non-clobbering `healthy`), and the reasoning that a lost `healthy` costs nothing because the read-side `cycle_live` check re-derives it: sound.
- **`--classify`'s dispatch point** (before claim-lock acquisition, in the `case "$MODE"` block), its **argument-parser** addition, and the **`cycle_live`** read-side check: all still correct and all now tested.
- **Testing strategy**: the budget tests finally test the right thing (delay between death and classification; a death that never claims). Findings 1 and 2 each need one more test, named above.
- **`/say` + `/ask`**: unchanged, sound, still the right thing to build first and still independently shippable.
- **`/prefs`**: unchanged; the narrow `Skill`-branch guard extension and the flagged-unconfirmed `tool_input` field are both still correct.
- **F5** (explicit `timeout` dropped as inert) and the **`remote-control-dropped`** record: unchanged and correct.
- **Line citations spot-checked against the current file and accurate**: parser `82-90`, `beat_age` `211-215`, `cycle_live` `218-223`, mode block `225-245`, claim loop `276-292`, `wm_die` `290`, singleton `301-305`, fresh claim `308-309`, `INT TERM` trap `311`, arm line `312`. `GRACE` 30s (`:109`), `INTERVAL` 5s (`:105`).

## What would make this approvable

Three edits, none of them a redesign:

1. **Delete the claim-time count reset from "Files touched"** (finding 1) and state the invariant that `--classify` is the count file's only writer. This is the difference between shipping the fix and shipping its inverse.
2. **Reset the count on trip** (finding 2), and correct the "self-healing" claim to match what the design actually does.
3. **Add the `stale-claim-lock` hint and a remedy that works for it** (finding 3), and file the leaked-lock bug separately.

The detection mechanism itself is finally right. What is left is making sure the implementation instructions describe the mechanism the design section actually specifies, and that the pilot who receives its alert can act on it.
