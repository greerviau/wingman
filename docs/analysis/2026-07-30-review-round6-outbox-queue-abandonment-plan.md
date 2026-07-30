# Plan review, round 6: outbox queue abandonment fix (issue #169)

**Date:** 2026-07-30
**Plan reviewed:** `docs/plans/2026-07-30-outbox-queue-abandonment-fix.md` (revised after rounds 1-5)
**Prior rounds:** `docs/analysis/2026-07-30-review-outbox-queue-abandonment-plan.md`,
`.../review-round2-...md`, `.../review-round3-...md`, `.../review-round4-...md`,
`.../review-round5-...md`
**Issue:** [greerviau/wingman#169](https://github.com/greerviau/wingman/issues/169)

**Verdict: request changes.** Two must-fix, four nice-to-have. No should-fix tier.

Both must-fix items are the **same mechanism** - the `done`-with-live-window limb
of the unified terminal predicate round 5 introduced - and both are one-sentence
specification edits. Nothing else in this plan is open. Every one of round 5's
six items is genuinely closed, four of them confirmed by execution rather than by
reading, and the adversarial pass over everything round 5 did *not* scope found
exactly one thing worth reporting (finding 1), plus one that reproduces under
execution (finding 2). This does not warrant a seventh full review round: apply
the two edits and the two matching test additions, and hand it to a developer.

---

## Method

Every experiment ran against an isolated scratch `WINGMAN_HOME` under this
session's scratchpad, exported per command and asserted not to be the live
`~/.wingman` before any call. The only reads against the live home were
`wm_state pref-get` and `wm_state crew-list --json`, both of which are pure
reads (see the `cmd_crew_list` note below); no `reconcile`, no mutation.

**Freshness.** The checkout is 2 commits behind `origin/main`.
`bin/watch-fleet`, `bin/lib/wm-state.py`, `bin/crew-list`, `bin/crew-prune`,
`bin/crew-standdown`, `bin/crew-say` and `bin/crew-ask` are byte-identical to
`origin/main` and are cited from the working tree. `bin/lib/common.sh` and
`bin/spawn-crew` differ and were read via `git show origin/main:<path>`.

**Executed, not read:**

- The plan's `resolve_notice_owner` and unified predicate, transcribed
  literally, over six parent-chain shapes with two different live-window sets.
- Two concurrent sweeps of one 40-message outbox, with and without the S-2
  exit-status gate on the payload move.
- `wm_state crew-get` vs. one fleet-wide `crew-list --all --json` vs. the
  fork-free glob emptiness test (10-100 samples each).
- `fire()`'s notice fold against a concurrent appender, plain vs. rename-aside,
  across all five distinct open/write/read interleavings.

---

## What round 5 raised, and where it stands

### M-1 (parent-chain predicate narrower than the sweep's): closed for all three reported shapes; a fourth shape the unification created is finding 2 below.

The two definitions are now genuinely one, not merely similar. The plan states
the predicate once ("a member, sender or ancestor, is terminal iff its roster
record is missing, or its status is `stood-down`/`died`, or its status is `done`
with no currently-live window"), and all three consumers - the sweep's step-2
sender check, `resolve_notice_owner`'s walk-up, and `crew-prune` pass 1 - are
written as testing membership in that one predicate rather than restating it.
The plan says so explicitly and names the drift as the reason. That is the right
shape of fix.

Transcribed literally and executed, all three shapes round 5 reported now
resolve correctly:

| chain shape | round 5 | round 6 |
|---|---|---|
| `W.parent=L`, `L` died (mass death) | `""` | `""` |
| `W.parent=L`, `L`'s record absent | `L` (orphaned) | **`""`** |
| `W.parent=L`, `L` is `done`, window dead | `L` (orphaned) | **`""`** |
| `A.parent=B`, `B.parent=A`, both died | `""` (guard cap) | `""` (guard cap) |
| `W.parent=L`, `L` alive and `working` | - | `L` (correct) |
| `W.parent=L`, `L` is `done`, **window live** | - | **`L` - see finding 2** |

The guard cap, the wingman floor, and the two-limb early return
(`rec missing or rec.parent == ""`) all behave as specified.

### M-2 (synchronous send in the sweep): closed. The direct-send path is genuinely gone, and the path replacing it is the pre-existing one.

- The plan's step 6 now has exactly **one** branch for a non-terminal sender:
  queue into that sender's own outbox. There is no conditional, no "try direct
  first," and no residual `wm_tmux_send_message` anywhere in the sweep's
  specification - the only mentions left are the `#214` accounting, the
  narrative of what was deleted, and test 17's regression guard asserting no
  such call ever originates from the sweep. That guard is the right instrument:
  it is what stops the deletion from being quietly re-added.
- The path it now uses is the existing redelivery mechanism - the one exercised
  by `tests/outbox-redelivery.test.sh` and hardened across rounds 1-4 (claim
  protocol, pointer stability, oldest-file selection, `PANE_STABLE` gating). It
  is not new surface.
- The deletion's three stated justifications check out against the code:
  `$BEATFILE` is touched exactly once per iteration (`bin/watch-fleet:807`),
  `GRACE` defaults to 30s (`:188`), `WM_SEND_LOCK_WAIT` defaults to 45s
  (`origin/main:bin/lib/common.sh:658` - the stale `:632` citation round 5
  caught is now correctly pinned), and all four existing send sites are inside
  the owner-scoped per-member loop.
- **Termination is handled.** The queued notice records its own sender as
  empty, so if the sender later goes terminal before delivery, the next sweep
  reads the sidecar as wingman and routes it to the wake channel rather than
  queueing it again. No notice-about-a-notice loop. The plan states this.

### S-1 (scan placement): closed. Placement is pinned exactly, and the blind-spot disclosure is accurate.

The placement - "near the top of the loop body, immediately after the beacon
touch, before the `wm_tmux has-session` block, and unconditionally on `$OWNER`"
- is unambiguous and coherent against the code: the beacon touch is
`bin/watch-fleet:807`, the tmux gate opens at `:838`, and `fire()`'s `exit 0` is
at `:802`. Nothing between the beacon and the gate can exit the process, so the
scan runs on every poll including a firing one. Test 18 pins it with an
assertion rather than prose.

**The tmux-server-death disclosure is an accurate and acceptable disclosure,
not a silent gap.** It appears twice (the design section and the risks list),
names the mechanism (`reconcile` is gated on a live tmux session in both
`bin/crew-list` and `bin/watch-fleet`), cites the existing analysis
(`docs/analysis/2026-07-30-tmux-server-death-and-reconcile-blind-spot.md`,
Defect 2), states that `crew-prune`'s pass 1 is blind for the identical reason,
and - the part that makes it honest rather than decorative - explicitly
qualifies the plan's own "robust backstop" language instead of leaving that
claim unconditional. It is out of scope to fix here and correctly identified as
a pre-existing defect that this plan inherits rather than introduces. Nothing
further is needed, except the one clause noted in finding 1 below.

### S-2 (concurrent sweeps double-notify): closed. Reproduced both ways.

Two concurrent processes over one 40-message outbox:

```
gated   (mv exit status): 40 log lines, 40 distinct messages,  0 duplicates
ungated (round 5's shape): 80 log lines, 40 distinct messages, 40 duplicates
```

The gate genuinely closes the reproduced race, and it closes it for the right
reason: `outbox/` and `outbox-abandoned/` are in the same tree, so `mv` is
`rename(2)`, and the loser gets `ENOENT` rather than a second success. The gate
also correctly covers the audit line and the notice, not just the move - step 5
is explicitly "for the winning process only."

### S-3 (per-directory `crew-get`): closed. The performance claim holds, and failing closed is the safe direction.

Measured on this host, same method as round 5:

| operation | cost |
|---|---|
| one `wm_state crew-get` | 140 ms |
| one `wm_state crew-list --all --json` | 135 ms, **constant in pending-directory count** |
| the fork-free glob emptiness test, 2 directories | **0.2 ms** |

So the shape is right: an idle fleet pays ~0.2 ms per poll and nothing else; a
fleet with anything pending pays one flat ~135 ms read regardless of how many
directories are pending, replacing N × 140 ms. At three pending directories that
is ~135 ms against round 5's measured 630 ms, and the gap widens with N. The
claim holds.

**Failing closed is genuinely the safe direction, and it does not drop
notices.** A failed roster read skips the scan *for that poll only*; the outbox
entry, its sidecar and its payload are all untouched and are re-examined on the
next poll five seconds later. Nothing is consumed, moved, or acknowledged, so
there is no state in which a notice is silently discarded. The only degradation
is deferral, and a permanently failing `wm_state` is the status quo this plan
exists to improve on, not a regression it introduces. The alternative - treating
"couldn't tell" as "terminal" - would move a live member's payload to
`outbox-abandoned/` and tell its sender the message was abandoned, which is
unrecoverable. The plan picked correctly.

**One thing worth stating because it is the exact hazard N-1 was about:**
`wm_state crew-list` is a pure read. `cmd_crew_list` (`bin/lib/wm-state.py:929`)
calls `load_roster()` and filters; it never reconciles and never writes. The
flip-stealing that produced N-1 comes from `bin/crew-list`'s own explicit
`reconcile` call, not from the `wm_state` subcommand the scan uses. Adding one
fleet-wide `crew-list --all --json` per poll to every watcher therefore cannot
steal a death flip from any other watcher. This was my main adversarial worry
about S-3's fix and it is clean.

### S-4 (`fire()`'s read-then-truncate): closed for the dominant loss mode; a narrow residual remains (nice-to-have 1).

Executed across all five distinct interleavings:

```
plain (cat; truncate)
  append opens BEFORE read, writes AFTER read  : LOST
  append opens AFTER read,  before truncate    : LOST
rename-aside (mv; cat; rm)
  append opens BEFORE mv, writes AFTER read    : LOST
  append opens BEFORE mv, writes BEFORE read   : SURVIVED (folded into the wake file)
  append opens AFTER mv                        : SURVIVED (fresh file, next poll)
```

The rename-aside eliminates the dominant mode - any appender that opens the file
at any point after the fold begins now creates a fresh file at the original path
and is picked up whole on the next poll's `-s` check. The reasoning in the plan
is exactly right. See nice-to-have 1 for the residual.

### Round 5's three nice-to-haves: all three addressed.

The `common.sh:632` citation is re-pinned to `origin/main:658`; the fork-free
glob replaces `ls | grep -v '^sent-'` and is reflected in the pseudocode; the
empty `## New events` section on a notice-only fire is called out.

---

## Must-fix

Both items are the same limb of the same predicate, and both are one-sentence
edits.

### 1. The scan has no data source for the "no live window" half of its own terminal predicate, and the natural fallback is fail-dangerous

The scan's pseudocode says, verbatim:

```sh
# ... derive _ostatus and window-liveness for $_oid from $_roster_json ...
```

**Window liveness is not in `$_roster_json` and cannot be.** A roster record
carries the tmux window *name*, not its state - confirmed by dumping
`crew-list --all --json` against a scratch roster: the fields are `id`,
`parent`, `status`, `type`, `window`. And status cannot stand in for it, because
`LIVE_STATES = ("working", "blocked", "review", "stalled")`
(`bin/lib/wm-state.py:127`) **excludes `done`** - so `cmd_reconcile` never flips
a `done` member to `died` when its window disappears, and a `done` member's
status is identical whether its window is alive or gone. The only source of
window liveness is a tmux query (`wm_tmux_windows_csv`,
`origin/main:bin/lib/common.sh:810`), and the plan's own S-1 fix deliberately
places the scan *before* the `wm_tmux has-session` gate.

This is not a hypothetical. The limb is load-bearing in two places, both
reachable:

- **The scan's own target test.** A `done` member with a live pane must **not**
  be swept - phase 1 explicitly adds a `done`-loop so its outbox is still
  serviced. A `done` member whose window died must be swept, and that is the
  entire reason the limb exists.
- **Step 2's sender check.** A `done` sender with a live pane can still be
  queued to; one with a dead window cannot, and must be routed to the wake
  channel instead.

Left as written, an implementer has two options and both are wrong. Dropping the
limb (the path of least resistance, since the named data source does not contain
it) sweeps a live `done` member's outbox and tells its sender the message was
abandoned while the target was alive and the `done`-loop would have delivered it
- the precise fail-dangerous direction S-3 was raised to close, re-entered
through a different door. Inventing a tmux call is the right answer but is
unspecified, and its behavior when the tmux server is dead is a real policy
choice, not an implementation detail.

**Fix (one sentence plus one clause):** state that the scan takes **one**
`wm_tmux_windows_csv` snapshot per poll alongside the single roster read, and
derives window liveness by matching each record's `window` field against it; and
state the tmux-dead policy explicitly - an unavailable tmux server yields an
empty window set, so every `done` member reads as having no live window. That
policy is defensible (no tmux server means no live panes), but it should be
chosen rather than fallen into, and it slightly refines the S-1 disclosure,
which currently says the scan "sees no terminal member at all and sweeps
nothing" in that scenario: that is true for the `died`/`stood-down` limbs, whose
statuses are frozen by the reconcile blind spot, but not for the `done` limb,
which would then read every `done` member as terminal. One clause fixes it.

Adopting finding 2's fix shrinks this item's surface by removing the walk from
the list of consumers that need window liveness at all.

### 2. The unified predicate answers the wrong question for the notice-owner walk, re-orphaning the notice in the *common* `done` shape

Round 5 was right that the walk's predicate was too narrow. Making it *identical*
to the sender check overshot: the two are genuinely different questions.

- The sender/target check asks **"can this member still be delivered to?"** A
  `done` member with a live pane can be - hence the window limb.
- The walk asks **"will this member's own watcher surface a notice?"** The
  notice file is keyed by the watcher's `--owner` scope
  (`bin/watch-fleet:155-170`), and a lead's own watcher is armed by that lead
  itself (`playbooks/common/lead.md:42`). A member that has reported `done` has
  finished its engagement, holds no work-in-progress and arms nothing; and
  wingman reaps it to `stood-down` - killing the window - in the same turn it
  sees the `done`. So `pending-notices-<done-lead>` has no reader, now or later.

Executed against a chain where the parent is `done` with a **live** window:

```
W4 (parent=LDLIVE, LDLIVE done, window live) -> 'LDLIVE'
```

That is M-1's failure mode exactly: a notice written to a file no live watcher
reads. And it is the **more common** `done` shape, not the rarer one. A member
that reports `done` keeps its window until it is reaped; "`done` with no live
window" is the unusual variant where the window died first. Round 5's own
reproduction could not see this, because its scratch environment had no live
tmux windows at all, which makes every `done` parent read as terminal.

The plan's own justification for the limb makes the point against itself: it
argues `done` must be treated as terminal because a `done` parent, "if wingman
itself is not currently running to reap it, can persist indefinitely." That
scenario is precisely the one where the window is still alive - nothing killed
it - and therefore precisely the one the predicate as written excludes.

Reachability is ordinary rather than exotic: at the end of an effort a lead
stands its workers down (`stood-down`, terminal) and then reports `done`. Any
message a stood-down worker had queued is swept, its sender is terminal, and the
walk lands on a `done`-with-live-window lead.

**Fix (one clause):** keep one shared predicate for delivery reachability - the
sender and target check, window limb intact - and give the walk the broader test
it actually needs: an ancestor is terminal for notice-routing purposes when its
record is missing, or its status is `stood-down`, `died`, **or `done`** - full
stop, no window qualifier. That is what M-1 needed all along (the walk was too
narrow on the `missing` and `done` limbs; the fix is to broaden it, not to make
it identical), it cannot drift back to being narrower than the delivery
predicate, and it removes the walk's dependence on window liveness entirely.

**Mitigation, stated for fairness:** in both findings the durable payload
(`outbox-abandoned/<id>/<stem>`) and the `outbox-abandoned.log` line are written
before any notice is composed, so what is at risk here is the *notification*,
not the message. That is the same mitigation that applied to M-1, which round 4
and round 5 both treated as blocking; I am applying the same bar.

---

## Nice-to-have

1. **S-4's rename-aside leaves one narrow residual.** An appender whose file
   descriptor was opened *before* the `mv` and whose write lands *after* the
   fold writes into the renamed-then-removed inode and is lost silently
   (reproduced above). The window is the appender's own open-to-write gap
   intersected with the fire's `mv`→`rm` span - genuinely small for a single
   builtin redirect, wider for anything that forks between the open and the
   write. Not blocking: the payload and the audit line are already durable, so
   this loses a wake announcement, not a message. If it is ever worth closing,
   the fully race-free form is no more complex - appenders write one file each
   into `pending-notices-<key>.d/`, and `fire()` folds and removes each file it
   finds; a file created at any instant is either folded now or found next poll.
   Worth one sentence softening the channel's "never loses it" claim either way.

2. **Step 7 contradicts step 3.** Step 3 claims the file by `mv`, so by step 7
   there is no original payload left; "remove the now-empty original file and
   sidecar" should read as sidecar removal plus the `rmdir`. As written it
   invites an implementer to make step 3 a copy and defer the delete to step 7,
   which would destroy the mv-as-claim property S-2 depends on.

3. **The `NOTICEFILE` name needs the same sanitization on both sides.** The
   lead branch derives its key as `tr -c 'A-Za-z0-9._-' '_'`
   (`bin/watch-fleet:155`). The sweep computes the same filename from a resolved
   owner id, and `bin/spawn-crew` slugifies only *generated* ids - an explicit
   `--id` is passed through unfiltered. One clause saying the writer applies the
   identical transform closes it by construction.

4. **Citation:** the `wm_tmux has-session` gate opens at `bin/watch-fleet:838`,
   not `:844`. Inherited from round 5.

---

## Testing strategy

Tests 1-19 are at the right level; 16-19 map cleanly onto round 5's four items,
and test 17's "assert no direct `wm_tmux_send_message` ever originates from the
sweep" is the right kind of regression guard for a deletion. Two additions, one
per must-fix:

20. **Finding 1:** a `done` target whose window is **live**, with a pending
    outbox message - assert the scan does **not** sweep it (the `done`-loop
    still owns it); and the same target with its window gone - assert it **is**
    swept. This is the assertion that makes the window limb's data source
    load-bearing in the test suite rather than in prose.
21. **Finding 2:** resolve the notice owner for a member whose parent is `done`
    with a **live** window - assert it floors to wingman rather than resolving
    to the `done` parent. Test 16 currently covers only the dead-window variant,
    which is the shape that already passes.

---

## Standing constraints

- **Phase 1 complete and independently mergeable:** yes, once the two edits
  land. Nothing in phase 1 depends on phase 2, and both edits are additive
  clauses rather than restructuring. As written, finding 2 leaves one common
  chain shape where a notice is written to a file nobody reads, and finding 1
  leaves the scan's central decision without a stated data source - the same
  "not a guarantee" condition rounds 4 and 5 blocked on.
- **Phase 2 stays a noted follow-up:** yes, unchanged and correctly sequenced -
  `wm_outbox_try_redeliver`'s extraction and the whole-fleet backstop remain
  out of phase 1, and round 4's duplicate-delivery pre-emption still holds.
- **Blast radius:** appropriate and still shrinking. Seven files in phase 1, no
  `bin/lib/wm-state.py` changes in either phase (verified: everything the scan
  needs - `crew-list --all --json`, `wm_tmux_windows_csv` - already exists).
- **`#214` overlap: accurately stated, and M-2's deletion did change the
  count.** Verified independently that `bin/watch-fleet`'s
  `wm_tmux_send_message` call sites are exactly four - `:924`, `:928`, `:974`,
  `:1077` (the three other matches are comments). The prior revision would have
  handed `#214`'s implementer **five** sites: those four plus one new,
  fleet-wide, `PANE_STABLE`-ungated send inside the sweep. It now hands over
  exactly the same **four** pre-existing sites, two of them rewritten in place
  and none added. The plan states this as "two rewritten, none added," which is
  correct, and the rebase caution on `:924`/`:928` remains the right note.
- **Testing strategy concrete:** yes - 19 named tests extending
  `tests/outbox-redelivery.test.sh`'s pattern, each tied to a specific finding,
  plus the two above.

## Open Questions

None from this review. The plan's own two open questions parse cleanly and both
recommendations remain correct; neither is affected by the findings above.
