# Third-pass review: wingman skills for robust operation (r3)

**Artifact reviewed:** `docs/plans/2026-07-13-wingman-skills-for-robust-operation.md` (revision r3)
**Prior passes:** `docs/analysis/2026-07-13-review-wingman-skills-for-robust-operation-plan.md` (r1 → request-changes), `docs/analysis/2026-07-13-rereview-wingman-skills-for-robust-operation-plan.md` (r2 → request-changes)
**Date:** 2026-07-13
**Verdict:** **request-changes**

## Summary

The first of the second pass's two must-fix items is **fully and correctly closed**, verified by running the guard's own resolver rather than by reading the prose. The second is **only partially closed**: the failure budget as specified is a *rate* detector whose trip condition depends on wingman's own model-turn latency, an unbounded quantity the design does not control. A persistent failure that recurs more slowly than once per 30 seconds never trips it and reproduces the original silent livelock exactly.

Two further defects were found in the new r3 exit-record design, both reachable through the ordinary redundant-arm path that the `healthy` outcome exists to describe.

Everything else in r3 verified clean, including the should-fix item (`remote-control-dropped`), which the exit-record redesign closes structurally as claimed.

## Verification of the second pass's must-fix items

### Must-fix 1 (stdin / `--classify` denied by the preferences guard) - CLOSED

r3 drops stdin entirely in favour of a `watch-fleet`-written exit-record file, making the classify command a bare `bin/watch-fleet --classify`. Verified by running `hooks/lib/cmd_match.py`'s real `command_segments` + `resolve_command` against each shape and checking the result against the guard's actual Bash allowlist branch (`hooks/pilot-preferences-guard.sh:254`, `if b in ("crew-list", "watch-fleet"): continue`):

| Command | Resolved segment basenames | Guard verdict |
| --- | --- | --- |
| `bin/watch-fleet --classify` | `watch-fleet` | allow |
| `bin/watch-fleet --classify --owner lead-1` | `watch-fleet` | allow |
| `bin/watch-fleet` (arming) | `watch-fleet` | allow |
| `printf %s "$OUT" \| bin/watch-fleet --classify` (r2's shape) | `printf`, `watch-fleet` | **deny** |

Both r3 shapes pass. The r2 shape is confirmed denied, as the second pass found. The consequential claims r3 draws from this are also correct: the spurious-log write needs no new tool grant (it happens inside a command that *begins with* `bin/watch-fleet`), and the `/watch`-half of F4 is genuinely closed - arming and classifying are now both bare `watch-fleet` invocations, so the single raw-command instruction retained for the gate-pending window really does cover the whole cycle.

### Must-fix 2 (spurious branch re-arms with no backoff) - PARTIALLY CLOSED, see finding 1

The failure budget is the right idea and does close the *specific reproduction* the second pass named (the stuck claim lock, which dies in ~5s). It does not close the *class* the finding described. See finding 1.

### Should-fix (`remote-control-dropped` emits no `--` separator, untested) - CLOSED

Structurally resolved, exactly as r3 claims. The path at `bin/watch-fleet:447-460` writes its wake file, echoes its reason line, `rm -f "$PIDFILE"`, `exit 0` - and now gets an explicit exit-record write before that exit, so there is no text to scan and no separator to miss. The testing strategy names it as its own case. Correct.

---

## Findings

### Finding 1 (must-fix): the failure budget is a rate detector on a loop whose rate the design does not control

**Where:** plan, "Finding 2 fix (r3): a failure budget on the `spurious` path", and the `--classify` step 2 in the F3 fix section.

**What the plan specifies:** before returning `spurious`, `--classify` counts how many `watch-spurious.log` lines for this owner fall within the last 60 seconds (including the one just appended); at 3, it returns `spurious-repeated` instead and `/watch` stops re-arming.

**Why it does not close the finding.** Those log lines are timestamped *at classify time*, not at death time. Classify runs inside a wingman turn, so the spacing between consecutive entries is the whole loop period `P`:

```
P = (time watch-fleet takes to die) + (wingman's model-turn latency to wake, classify, and re-arm)
```

With entries at `t`, `t+P`, `t+2P`, the third classify's 60-second window is `[t+2P-60, t+2P]`. The first entry is inside it only if `2P <= 60`, i.e. **the budget trips only when `P <= 30s`**. For any persistent failure with `P > 30s`, the oldest entry has always aged out, the count never exceeds 2, and the loop runs forever - silently, with supervision fully dead. That is the original finding, verbatim, on the same path.

`P > 30s` is not a corner case:

- `watch-fleet:290`'s `wm_die` on a stuck claim lock takes ~5s (50 tries x `sleep 0.1`, `watch-fleet:276-291`). That leaves a budget of 25s for a wingman turn that must wake, emit a `Skill` call, classify, and re-arm. A busy orchestrator turn that also reports to the pilot, or one under model load, exceeds that routinely. The fix's correctness is a coin flip on latency the design never measures.
- Nothing bounds the *death* half either. The claim lock is the one persistent failure the second pass happened to name; a future or different persistent failure that dies 20-30s in (an OOM during a `crew-list` subprocess, a hung `tmux` call inside the poll loop) pushes `P` past 30s on its own, with no wingman-latency help needed at all.

The plan's own justification for the window design is *"`--classify` already owns `$WINGMAN_HOME/watch-spurious.log` for this owner, so it can use it as the failure-budget's own state, with no separate counter file needed."* That convenience is precisely what introduces the coupling: it forces a wall-clock rate test where the property actually being detected ("this watcher cannot stay up") has nothing to do with wall-clock rate.

**Recommended fix.** Make the budget independent of loop period. In increasing order of fidelity:

1. **Consecutive count (minimum sufficient).** Keep an owner-keyed counter (`$WINGMAN_HOME/watch-spurious-<owner>.count`), increment on `spurious`, and **reset to zero on any non-spurious outcome** (`healthy`, `fire`, `remote-control-dropped`). Trip at N (default 3). Immune to `P` entirely and no more complex than the window arithmetic it replaces. It also fixes the window design's other wart: because the 3 log entries survive a `spurious-repeated`, the current design re-trips on the *first* spurious after the pilot fixes the cause and re-arms, unless something else resets it.
2. **Consecutive count qualified by cycle lifetime (recommended).** A pure consecutive count can false-positive on genuinely isolated deaths in a quiet fleet (three separate reaps days apart, with no fire in between to reset). The signal that actually separates "cannot stay up" from "was up for an hour and got reaped" is **how long the cycle survived after arming** - which is the real distinction the `spurious` path exists to absorb. `watch-fleet` already stamps `$PIDFILE` and `$BEATFILE` at fresh-claim time (`watch-fleet:308-309`), so the arm timestamp is available; count only consecutive spurious exits whose cycle lived less than a small multiple of the poll interval.

Either way, the thresholds should be env-overridable, which the plan already recommends in "Open questions" (`WM_SPURIOUS_BUDGET_COUNT`/`WM_SPURIOUS_BUDGET_WINDOW`) but does not carry into the design section, the "Files touched" list, or the testing strategy (which tests a hardcoded 3-within-60s). Fold that through.

**Testing implication.** The plan's regression test for this (case (d): "force three spurious classifications in quick succession... repeatedly `SIGKILL` a cycle immediately after each re-arm") passes under the defective design, because it deliberately drives `P` to near zero. A test that actually exercises the finding must space the deaths past the window (e.g. 3 spurious exits ~40s apart) and assert the budget still trips.

### Finding 2 (must-fix): `--classify`'s state analysis is non-exhaustive, and the missing state is reachable and mis-scored

**Where:** plan, F3 fix, `--classify` step 2: *"`$PIDFILE` present but its pid no longer alive → `sigkill-suspected`; `$PIDFILE` absent → `clean-exit-or-sigterm`."*

These two branches are not exhaustive. The third state - **`$PIDFILE` present and its pid alive** - is omitted, and it is exactly the state that proves supervision is *fine*. It is reachable through the ordinary redundant-arm path:

The exit-record is a single owner-keyed slot (`$WINGMAN_HOME/watch-exit-<owner-key>`), but **two `watch-fleet` processes can be in flight for one owner at once** - and that is not an edge case, it is the situation the `healthy` outcome exists to describe. `CLAUDE.md` explicitly tells wingman a redundant arm can land on a live cycle, and the plan's own F2 fix section documents it. Both are harness-tracked background tasks, so both produce a wake, but there is only one record slot:

1. Cycle A is armed and blocking (fresh claim; per plan point 1, it cleared the record).
2. A redundant arm B acquires the claim *lock*, hits the singleton guard (`watch-fleet:297-305`), writes `healthy` to the record, releases, exits. It never reaches `echo $$ > "$PIDFILE"`, so it correctly does not clear the record - good.
3. Before wingman gets a turn to classify, cycle A fires: it writes `fire` to the **same** record, overwriting `healthy`, and exits.
4. Wingman classifies one wake → reads `fire` → reports the roster and arms cycle C. Correct.
5. Wingman classifies the *other* wake → the record is gone (consumed in step 4) and C has not exited → **classified `spurious`**.

That step-5 classification is a false spurious. It writes a bogus forensic line into `watch-spurious.log` - the very log the plan positions as the mechanism that will eventually turn "one of four hypotheses" into a confirmed root cause ("What remains open") - and it **feeds the failure budget**, so a run of these can produce a false `spurious-repeated`, in which wingman stops arming and tells the pilot fleet supervision is broken when a healthy cycle (C) is running the whole time. It also asks the hint logic to score a pidfile that is present with a *live* pid, which neither specified branch covers.

**Recommended fix (two lines, using a helper that already exists).** In `--classify`, on record-absent, check `cycle_live` (`watch-fleet:218-223`) first:

- **Record absent AND a cycle is live** → print `healthy`. A cycle is up; supervision is intact; this wake belongs to a redundant arm or a crossed record. No log write, no budget tick, no re-arm.
- **Record absent AND no cycle is live** → genuinely spurious; proceed to the existing hint logic (whose two branches are now exhaustive, since "present and alive" has been consumed above) and the failure budget.

This is strictly stronger than the current design and closes the whole "more wakes than records" mismatch, not just this one interleaving.

### Finding 3 (should-fix): the plan never says `--classify` must dispatch before the claim lock

**Where:** plan, F3 fix ("`bin/watch-fleet --classify [--owner <id>]` (new subcommand, no stdin)") and the "Files touched" entry for `bin/watch-fleet`.

The plan enumerates the four change points in `bin/watch-fleet` with precise line citations, but never states where `--classify` itself is dispatched. It must go in the existing `case "$MODE"` block (`watch-fleet:225-245`, alongside `--status`/`--stop`), which returns **before** the claim-lock acquisition at `watch-fleet:271`, and it must not acquire the claim lock or touch `$PIDFILE`/`$BEATFILE`.

If a developer instead lets `--classify` fall through to the arm path, the failure is silent and severe: with a cycle live, the classify invocation would hit the singleton guard and - under this very plan - **write `healthy` to the exit record and exit 0**, so every classify returns `healthy`, no wake is ever acted on, and every genuine crew event is swallowed. That is F1's original failure mode restored through a new door. It is also a 5-second hang per classify whenever the claim lock is contended.

State the dispatch point explicitly and add a test asserting `--classify` neither creates a claim-lock directory nor mutates `$PIDFILE`.

### Finding 4 (nit): `spurious-repeated` names no recovery action

The `/watch` body says *"stop; do not re-arm until the underlying cause is understood"*, and the report to the pilot names the log to read. Neither states how supervision resumes once the cause is cleared (re-invoke `/watch`, or arm `bin/watch-fleet` directly). Since this branch deliberately leaves the fleet unsupervised, the message should carry its own remedy, the way every other attention event in `CLAUDE.md` does.

---

## Confirmed clean (no change requested)

- **F1** (classify by scanning for a reason prefix): moot and superseded. The exit-record design removes the text scan entirely, which is strictly more robust than r2's fix. `fire()` (`watch-fleet:399-437`) does emit its `--` separator, and `wm_ok` does write to stdout, so r2's analysis was sound - it is simply no longer load-bearing.
- **F2 `healthy` path**: still correct. The singleton guard's early exit (`watch-fleet:297-305`) is a distinct, explicitly handled outcome that ends the turn with no re-arm.
- **F5**: correctly resolved and dropped (the 700s test past an explicit 600000ms timeout is a clean disproof of the "defensive floor" rationale).
- **F4 `/prefs` half**: unchanged from r2 and previously accepted. The guard genuinely has no `Skill` branch, so the narrow `Skill`-name allowance is the right fix, and the plan correctly flags the `tool_input` field name as unconfirmed rather than asserting it.
- **`/say` + `/ask`**: reconfirmed. The permission-parity gap is real (neither `bin/crew-say` nor `bin/crew-ask` appears in any `allowed-tools` or settings allowlist), the wrappers are faithful, and the F6 `--answer-file` follow-up read plus its `Read(~/.wingman/ask/*.json)` grant are correct.
- **Line citations**: spot-checked and accurate (`wm_die` at 290, singleton at 297-305, fresh claim at 308, `wm_ok "armed"` at 312, `fire()` at 399-437, `remote-control-dropped` at 447-460).

## What would make this approvable

Findings 1 and 2 are both cheap and both narrow. Replace the wall-clock window budget with a consecutive-count budget that resets on any non-spurious outcome (ideally qualified by cycle lifetime), have `--classify` return `healthy` when the record is absent but a cycle is live, state `--classify`'s dispatch point, and update the testing strategy so its budget regression test spaces the failures past the old window rather than driving them to zero period. Nothing else in r3 is blocking.
