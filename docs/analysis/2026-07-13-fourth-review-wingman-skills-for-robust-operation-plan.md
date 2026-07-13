# Fourth-pass review: wingman skills for robust operation (r4)

**Artifact reviewed:** `docs/plans/2026-07-13-wingman-skills-for-robust-operation.md` (revision r4)
**Prior passes:** r1 (`.../2026-07-13-review-wingman-skills-for-robust-operation-plan.md`), r2 (`.../2026-07-13-rereview-...`), r3 (`.../2026-07-13-third-review-...`) - all request-changes
**Date:** 2026-07-13
**Verdict:** **request-changes**

## Summary

Of the three defects the third pass raised, **one is fully closed** (the dispatch point), **one is closed for the interleaving it named but rests on a false exhaustiveness claim** (the `cycle_live` check), and **the headline one is not closed at all** (the failure budget).

The failure budget was rewritten to be "immune to wingman's turn latency by construction." It is not. The consecutive *count* is indeed immune to the loop period, but the **cycle-lifetime qualifier that gates every increment is measured at classify time** (`now - watch-started`), so it carries wingman's model-turn latency inside it - the exact unbounded quantity the third pass rejected r3 for depending on. The resulting trip condition is **strictly tighter than the design it replaces**: r3 tripped when `L + W <= 30s`; r4 counts only when `L + W < 15s`. A persistent failure that r3's broken budget *would* have caught (a 5s death behind a 20s wingman turn) is silently missed by r4's.

Worse, the qualifier's other input - `watch-started`, written only on a **successful claim** - does not exist for any arm that dies *before* claiming. That includes the plan's own named reproduction (`watch-fleet:290`'s stuck-claim-lock death). For that failure the plan's own rules route every classification to "log only, do not count," so the budget **never trips** and the original silent livelock is reproduced verbatim, on the exact path finding 2 was written to close.

Two further defects in the exit-record design are reported below (both variants of "one record slot, more than one writer" - the same shape as the third pass's finding 2, in the directions its fix does not cover). No regression was found in anything the earlier passes had already cleared.

---

## Status of the third pass's findings

### Finding 1 (failure budget is a rate detector on an uncontrolled loop) - **NOT CLOSED.** See findings 1 and 2 below.

### Finding 2 (`--classify`'s state analysis is non-exhaustive) - **PARTIALLY CLOSED.**

The added `cycle_live` check (plan step 2, first bullet) does close the traced interleaving: record-absent-but-a-cycle-is-live now classifies `healthy`, with no log write and no budget tick. That is correct and is the right helper to reuse.

The plan's *justification* for the remaining two hint branches being exhaustive is false, and one reachable state is still unhandled - see finding 3. The record-clobber direction of the same "more writers than slots" mismatch is untouched - see finding 4.

### Finding 3 (dispatch point unstated) - **CLOSED.**

Plan line 174 now states it precisely: `--classify` joins the `case "$MODE"` block (`watch-fleet:225-245`), returns before the claim-lock acquisition at `watch-fleet:271`, never calls `mkdir "$CLAIMLOCK"`, never enters the blocking loop. The testing strategy carries the matching regression test. Correct, and the severity reasoning quoted into the plan is accurate.

### Finding 4 (`spurious-repeated` names no recovery action) - **CLOSED.** The pilot-facing message now carries its own remedy.

### Second-pass must-fix 1 (stdin denied by the preferences guard) - **STILL CLOSED.** Untouched by r4; the classify command remains a bare `bin/watch-fleet --classify`.

---

## Findings

### Finding 1 (must-fix): the budget's lifetime qualifier is measured at classify time, so wingman's turn latency is still inside the trip condition

**Where:** plan, "Finding 2 fix (r4 revision)", third bullet: *"compute the dead cycle's lifetime as `now - watch-started-<owner-key>`... If the lifetime is less than `WM_SPURIOUS_MIN_LIFETIME`... increment the count file."*

`--classify` runs inside a wingman turn, not at the moment of death. So `now` is not the death time - it is the death time plus `W`, wingman's own wake/model-turn latency (the harness must notice the background task's exit, re-invoke the session, the model must emit a `Skill` call, and the skill body must reach the `Bash` call). The value computed is therefore:

```
computed_lifetime = L + W        (L = the cycle's true lifetime, W = wingman's turn latency)
```

and the increment fires only when `L + W < WM_SPURIOUS_MIN_LIFETIME` (default `INTERVAL * 3` = **15s**).

Compare the two designs on the same failure:

| Design | Condition for the budget to engage |
| --- | --- |
| r3 (rejected by the third pass) | `L + W <= 30s` |
| r4 (this revision) | `L + W < 15s` |

**r4's condition is strictly stricter than the one it replaces.** A persistent failure with `L = 5s` (the plan's own claim-lock repro: 50 tries x `sleep 0.1`) behind a `W = 20s` wingman turn *would* have tripped r3's budget (`2P = 50 <= 60`) and is **silently missed by r4's** (`25 >= 15`), so the loop re-arms forever with supervision dead. The plan is arguing against itself here: its own text at line 189 rejects r3 on the grounds that 25s "is not a generous margin for a turn that must wake, emit a `Skill` call, classify, and re-arm, let alone report to the pilot first" - and then ships a design whose margin for that same turn is **10s**.

The claims at plan lines 32 and 312 ("immune to `P` by construction", "immune to wingman's turn latency by construction") are true of the *counter* and false of the *qualifier that gates every increment of it*. The composed detector is only as latency-independent as its weakest input.

**Recommended fix - measure the death, not the classify.** `bin/watch-fleet` already owns a death-time proxy: `$BEATFILE` is truncated at the top of **every** loop iteration (`watch-fleet:443`) and at claim time (`watch-fleet:309`), so its mtime is the cycle's last sign of life, within one `INTERVAL` of its death. Crucially, it survives every abnormal exit: the `INT TERM` trap (`watch-fleet:311`) removes only `$PIDFILE`, and `SIGKILL` runs nothing. So:

```
lifetime = mtime($BEATFILE) - watch-started      # latency-independent, ±INTERVAL
```

`beat_age()` (`watch-fleet:211-215`) already reads that mtime and is available to `--classify` in the mode block. Either use it, or - stronger, and worth considering because it also addresses finding 2 - have `watch-fleet` record its own lifetime at exit via a shell `EXIT` trap, since a process that can still run a trap knows exactly how long it lived and does not need `--classify` to infer it (see finding 2's recommendation).

**Testing implication (the same trap the third pass named, sprung again).** Test (a) in the r4 testing strategy - "three... classifications in a row, each spaced 40+ seconds apart" - spaces the *classify calls*, not the gap between each cycle's death and its classification. With `watch-started` re-stamped per cycle, that test passes under this defective design exactly as r3's rapid-`SIGKILL` test passed under r3's. A test that actually exercises this finding must **hold a delay between the cycle's death and the `--classify` call** (simulating `W`) and assert the count still increments.

### Finding 2 (must-fix): `watch-started` does not exist for any arm that dies before claiming - including the plan's own named reproduction - so the budget never trips for it

**Where:** plan, F3 fix point 1 (*"At claim time (right after `echo $$ > "$PIDFILE"`, `watch-fleet:308`, when a genuinely fresh cycle is won)... write the current epoch timestamp to `watch-started-<owner-key>`"*) and the finding-2 fix's lifetime rules.

`watch-started` is stamped **only by a process that wins the claim**. The failure class the budget exists to catch prominently includes deaths that happen *before* that point - and for those, the file either does not exist or belongs to some **earlier** cycle. The plan's own rules then refuse to count either case:

- **`watch-started` missing** → *"treat lifetime as unknown and do not count it toward the budget, only log it."*
- **`watch-started` stale (an earlier cycle's stamp)** → `now - watch-started` is large → *"an isolated, unremarkable reap... log it for forensics but leave the count file untouched."*

Traced against the plan's own named repro (`watch-fleet:290`, the stuck claim lock):

1. A cycle is `SIGKILL`ed while holding the claim lock (it is held across `mkdir` → `echo $$ > owner` → `sleep 0.1` → verify → `release_claim`, `watch-fleet:278-310`). `SIGKILL` cannot run the `trap release_claim EXIT` registered at `watch-fleet:283`, so `$PIDFILE.lock` is **leaked permanently**. (The comment at `watch-fleet:256-258` claims the next arm clears a stale lock once its 50 tries are exhausted; it does not - `wm_die` at `:290` prints and `exit 1`s, with no `rmdir`. The failure is therefore genuinely persistent, exactly as the third pass assumed. Worth its own issue independently of this plan.)
2. Every subsequent arm now spins 50 x `sleep 0.1` and dies at `watch-fleet:290`. It never reaches `echo $$ > "$PIDFILE"`, so it writes **no** exit-record (correct - absence is the spurious signal) and **no** `watch-started`.
3. `--classify`: record absent → `cycle_live` false (the pidfile names the `SIGKILL`ed pid) → genuinely spurious → hint `sigkill-suspected` → **lifetime = `now` - the dead cycle's old stamp**, which only grows, and is `>= 15s` from the very first classification onward → *"log it, leave the count file untouched."*
4. Count stays **0**. `spurious-repeated` never fires. `/watch` re-arms. Go to 2. **Forever, silently, with supervision fully dead.**

If no cycle for this owner ever claimed successfully (a leaked lock inherited from a previous wingman run), the `watch-started`-missing branch produces the identical outcome by a different rule.

This is the third pass's finding 2 verbatim - *"die → empty output → classified `spurious` → re-arm → die again → forever, silently, while supervision is fully dead"* - surviving intact through the fix written to close it. The root error is structural: **`watch-started` records when the last *successful claim* happened, not when the *arm that just exited* started.** Those are different processes in precisely the failure class the budget targets, so the qualifier is measuring the wrong cycle.

**Recommended fix.** Two options; the first is recommended because it also collapses finding 1 and makes the classifier stop inferring from absence.

1. **Let the dying process report itself.** Stamp the arm's own start at process entry (before the claim loop), and install a shell `EXIT` trap in `watch-fleet` that writes an exit-record for **every** exit it can observe - including `wm_die` - e.g. `died-early <lifetime-seconds>`. A process that can run a trap knows its own lifetime exactly, with no wall-clock inference and no cross-cycle slot confusion. `--classify` then only has to infer for the one case that genuinely cannot self-report (`SIGKILL` / harness reap), where `mtime($BEATFILE)` from finding 1 is the right proxy. Note the existing `trap release_claim EXIT` (`watch-fleet:283`) and the `trap - EXIT` at `:287` must be composed with this, not clobbered by it.
2. **Drop the lifetime qualifier entirely** and use the pure consecutive count the third pass offered as its option 1 (increment on `spurious`, reset on any non-spurious outcome, trip at N). The false positive it was added to prevent (three long-lived reaps with no intervening event) is rare, and the message it produces - "the watcher has died three times in a row with no event in between" - is *true* in that case, so the cost of the false positive is far smaller than the cost of the blind spot it currently creates.

Whichever is chosen, add the missing regression test: **with a stale `$PIDFILE.lock` directory in place, three consecutive arms that die at `watch-fleet:290` must reach `spurious-repeated`.** No test in the current strategy exercises a death that never claimed.

### Finding 3 (should-fix): the hint branches are still not exhaustive, and the plan's exhaustiveness argument is factually wrong

**Where:** plan, F3 fix, `--classify` step 2, second bullet: *"(The third theoretically-possible state, pidfile present and alive, is exactly what the `cycle_live` check above already routed to `healthy` - these two hint branches now cover everything that reaches this point.)"*

`cycle_live` is **not** "pidfile present and pid alive." It is (`watch-fleet:218-223`):

```
pidfile exists  AND  kill -0 <pid> succeeds  AND  beat_age() < GRACE      # GRACE defaults to 30s
```

So a **fourth** state reaches the hint logic and matches neither branch: **pidfile present, pid alive, beacon stale (> 30s).** It is reachable - a `watch-fleet` process wedged in a subprocess (a hung `tmux capture-pane`, a blocking stall probe) for longer than `GRACE`; a `SIGSTOP`ed cycle; or a stale pidfile whose pid has been recycled by an unrelated process, where `kill -0` succeeds against something that is not the watcher at all.

Neither specified branch fires (`pidfile present but pid no longer alive` is false; `pidfile absent` is false). An implementer who writes the `if/elif` the plan describes, with no `else`, produces an empty/unset hint - and under this script's `set -u` (`watch-fleet:60`) an unset expansion aborts `--classify` outright, leaving `/watch` with no result to branch on. The plan's parenthetical is what makes this easy to get wrong: it explicitly tells the implementer the two branches are exhaustive when they are not.

**Recommended fix.** State the hint logic against the actual state space, with an explicit terminal `else` (e.g. `pidfile present, pid alive, beacon stale` → `hung-or-stale-pidfile`, which is also a genuinely useful forensic value for the `watch-spurious.log` the plan is building this vocabulary for). Add the third case to the hint test.

### Finding 4 (should-fix): the single record slot lets a redundant arm's `healthy` overwrite a `fire`, permanently swallowing an already-acked crew event

**Where:** plan, F3 fix points 2 and 3 (the `healthy` write at the singleton early-exit; the `fire` write inside `fire()`).

The third pass's finding 2 covered one direction of the "one record slot, two live `watch-fleet` processes" mismatch (a wake with no record). The opposite direction is still open: **two records, one slot.**

1. Cycle A is live. Wingman places a redundant arm B (the ordinary case the `healthy` outcome exists to describe).
2. A fires. Per plan point 3 the record write goes *"before its existing `rm -f "$PIDFILE"; exit 0`"* - so A writes `fire`, and `fire()` has **already acked every surfaced event** (`watch-fleet:434-436`) before it gets to that `rm`.
3. In the window between A's record write and A's `rm -f "$PIDFILE"`, B evaluates the singleton guard (`watch-fleet:301`): A's pid is still alive and its beacon still fresh, so `cycle_live` is **true** → B writes **`healthy`, overwriting A's `fire`**, and exits.
4. Wingman classifies A's wake → reads `healthy` → **does nothing: no report, no re-arm.** The crew event is never surfaced.
5. Wingman classifies B's wake → record absent, no cycle live → `spurious` → re-arms C. Supervision recovers, but the swallowed event **does not**: `fire()` acked it at step 2, so C's top-of-loop `needs-attention` check (`watch-fleet:30-34`) deliberately suppresses it. The pilot never hears about that blocked/review/done member until its status changes again.

The window is narrow (the record write sits immediately before the `rm`), but the consequence is total and permanent, and it is F1's original failure class - a genuine crew event silently swallowed - re-entering through the record slot.

**Recommended fix (cheap).** Make the singleton `healthy` write **non-clobbering** (create-if-absent; e.g. `set -o noclobber`/`mkdir`-style, or simply skip the write when a record already exists). Losing a `healthy` record costs nothing, because the finding-2 `cycle_live` check already derives `healthy` from "record absent + a cycle is live" on its own - a `fire` record, by contrast, is the only trace of an event that has already been acked and can never be re-surfaced. Priority between the two writers must run `fire` > `remote-control-dropped` > `healthy`, never last-writer-wins.

### Finding 5 (should-fix): the claim-time "stale record clear" is not free - it destroys an unconsumed, already-acked `fire`

**Where:** plan, F3 fix point 1: *"clear any stale exit-record left over from a prior cycle... (defense in depth - under the documented one-arm-one-classify protocol this should never be needed, but it is cheap)."*

It is cheap only while the protocol holds perfectly. Because `--classify` already deletes the record it reads, the **only** way a record survives to a fresh claim is that a wake was never classified - i.e. exactly the case where the record is the last remaining trace of an event that `fire()` has already acked. Clearing it then converts a recoverable ordering slip into a permanently swallowed event, with the same end state as finding 4.

It is reachable through the plan's own skill body, which gates classification on *"If invoked in response to a `watch-fleet` background task's completion"* (step 1) - so a `/watch` invoked for any other reason (the pilot re-arming supervision by hand after a `spurious-repeated`, which the plan's own recovery message tells them to do) skips step 1 entirely, arms, and **clears whatever record was pending**.

**Recommended fix.** Keep the defense-in-depth clear, but make it loud rather than silent: if a record exists at claim time, append it to `watch-spurious.log` (or a `dropped-wake` line) *before* clearing, so a lost wake leaves forensic evidence rather than vanishing. Separately, tighten the skill body so the "arm without classifying" path cannot be entered while a record is pending.

### Nits

- **The argument parser must also learn `--classify`.** `watch-fleet:82-90` accepts only `--owner|--status|--stop|--start|arm|__loop` and `wm_die`s on anything else (`*) wm_die "unknown arg: $1"`). The plan cites the `case "$MODE"` block (`:225-245`) precisely but never the parser, which is the one place a `--classify` invocation would die today. Given how line-precise the rest of the plan is, this omission is worth closing.
- **"never touch `$PIDFILE`/`$BEATFILE`" (plan line 174) contradicts the mandated `cycle_live` check**, which reads `$PIDFILE` and stats `$BEATFILE` (and, under finding 1's recommendation, would read that mtime deliberately). The testing strategy has it right ("neither creates the claim-lock directory nor **mutates** `$PIDFILE`/`$BEATFILE`"). Say *mutates* in the design section too.
- **No lifecycle for the new state files.** `watch-started-<owner-key>` and `watch-spurious-count-<owner-key>` are created but never cleaned up (not on `--stop`, not on stand-down of a lead whose owner key they carry). Minor, but the plan enumerates every other file's write points exactly.

---

## Confirmed clean (no change requested)

- **`--classify`'s dispatch point** (third pass finding 3): closed, with the correct severity reasoning and a matching regression test.
- **The `cycle_live` check for the record-absent-but-live race** (third pass finding 2's traced interleaving): correct, and reusing `cycle_live` is the right call - the classifier's notion of "a cycle is up" then agrees with the singleton guard's by construction.
- **`spurious-repeated`'s recovery instruction** (third pass finding 4): closed.
- **Stdin/guard fix** (second pass must-fix 1): still closed; `bin/watch-fleet --classify` remains a bare invocation and still passes the guard's own resolver.
- **The `remote-control-dropped` exit-record** (second pass should-fix): still structurally closed and still tested as its own case.
- **F5** (explicit `timeout` dropped as inert), **`/prefs`** (narrow `Skill`-branch guard extension, with the `tool_input` field correctly flagged as unconfirmed), and **`/say` + `/ask`** (unchanged, sound, and still the right thing to build first): all unchanged and still correct.
- **Line citations spot-checked and accurate**: `cycle_live` at 218-223, mode block at 225-245, claim loop at 276-292, `wm_die` at 290, singleton at 301-305, fresh claim at 308-309, `INT TERM` trap at 311, `fire()` at 399-439 (acks at 434-436), `remote-control-dropped` at 451-461, beacon truncation at 443. `GRACE` defaults to 30s (`:109`), `INTERVAL` to 5s (`:105`).

## What would make this approvable

Findings 1 and 2 are the same defect in two inputs to one comparison, and both are fixable in the same edit: **stop deriving the budget's evidence from `now` and from the last successful claim.** Have the dying process record its own lifetime where it can (an `EXIT` trap covers everything except `SIGKILL`), fall back to `mtime($BEATFILE)` where it cannot, and treat an arm that never claimed as the strongest possible quick death rather than as an uncountable unknown - or drop the lifetime qualifier and take the pure consecutive count. Then fix the hint's fourth state (finding 3), make the `healthy` record write non-clobbering (finding 4), and log-before-clearing the stale record (finding 5).

The testing strategy needs one structural change in the same spirit as the third pass's: **its budget regression test must put the delay between each cycle's death and its classification** (that is where `W` lives), not merely between the classify calls, and it must cover a death that never won a claim. As written, test (a) passes under the design this review is rejecting - the same way r3's test passed under r3's.
