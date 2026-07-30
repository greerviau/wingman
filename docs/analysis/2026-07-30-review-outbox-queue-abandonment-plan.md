# Plan review: outbox queue abandonment fix (issue #169)

**Date:** 2026-07-30
**Plan reviewed:** `docs/plans/2026-07-30-outbox-queue-abandonment-fix.md`
**Issue:** [greerviau/wingman#169](https://github.com/greerviau/wingman/issues/169)
**Verdict:** **Request changes.** Five must-fix items; the shape of the fix is right.

---

## Summary

The plan's core architecture is correct and I independently confirmed its central
diagnosis. Once a member reaches `stood-down`/`died` its tmux window is already
gone, so no amount of widening the watcher's status filter can help - sweep-and-
surface at end-of-life really is the only correct remedy for that half of the
problem, and the plan is right to lead with it. The `#214` reasoning is sound and
its line-level correction of that issue's own report is accurate (verified below).
The death-path call site is well chosen and race-free.

What it gets wrong is concentrated in the *mechanics* of the two new primitives.
As specified, the plan would:

- deliver its own metadata sidecars into crew panes as if they were messages
  (certain, on every queue that ever redelivers successfully);
- corrupt the shared pane-stability baseline that gates freeze detection, stall
  nudges, Remote Control drop detection **and** the outbox send itself, across
  two independent processes with no locking;
- have no working delivery path for abandonment notices whose sender is the
  orchestrator itself - which is the single most important sender in the issue's
  own impact statement;
- not actually close the double-delivery race it claims to close;
- make `crew-prune --dry-run` destructive.

Separately, the plan's headline empirical premise ("zero redeliveries have ever
succeeded") is **false as of the day the plan was written**, and I have the file
on disk to prove it. The correction happens to strengthen the plan's conclusion,
but the plan asserts it as verified fact and builds a large speculative argument
on top of it.

---

## Verification performed

Read directly against the checkout (see finding 9 on freshness):
`bin/watch-fleet:855-1010` (population filter, outbox block at `:912-933`, the
`review|stalled` continue at `:992`, RC block, send sites at `:924`/`:928`/`:974`/
`:1077`), `bin/lib/common.sh:359-367` (`wm_pane_snapshot`) and `:709-711`
(`wm_tmux_windows`), `bin/crew-say:83-96`, `bin/crew-ask:299-308`,
`bin/spawn-crew:513-524`, `bin/crew-standdown` (`AFFECTED` at `:25`, `kill-window`
at `:73`), `bin/crew-prune` (all 30 lines), `bin/lib/wm-state.py`'s `cmd_prune`,
`cmd_reconcile`, `cmd_crew_get`, and `tests/outbox-redelivery.test.sh`.
Also inspected live `$WINGMAN_HOME/outbox/` and correlated file mtimes against the
issue's creation timestamp.

**Confirmed true in the plan:** the population filter is
`{working, blocked, review, stalled}` ∩ owner scope ∩ live window; `crew-standdown`
does kill the window (`:73`), so no pane survives the status flip; neither
`bin/crew-prune` nor `wm-state.py` references `outbox` anywhere; the multi-line
branch renames before sending and the single-line branch sends before renaming;
`_reconcile_died` is available at the point the plan wants to hook it, and
`cmd_reconcile`'s death flip iterates the **whole roster** (owner only gates the
re-adopt pass), so exactly one cycle observes each death - the death-path call
site needs no cross-cycle coordination. Good call.

**Also confirmed:** the `review|stalled` early-`continue` sits at `:992`, *after*
the outbox block, so `review`/`stalled` members do get serviced today. Neither the
issue nor the plan claims otherwise, but it was worth ruling out as a hidden cause.

---

## Must-fix

### 1. The `.from` sidecars will be delivered to crew panes as messages

`bin/watch-fleet:914` selects the next queued file with:

```sh
_obfile="$(ls "$_obdir" 2>/dev/null | grep -v '^sent-' | sort | head -1)"
```

The only exclusion is the `sent-` prefix. The plan drops `<queued-file>.from`
sidecars into that same directory and never changes the selector, and
`wm_outbox_try_redeliver` is described as a straight refactor of this block plus
the claim tightening.

Concrete failure, guaranteed rather than racy. Queue one message:

```
outbox/dev-1/1785289400-3171542.msg          <- the message
outbox/dev-1/1785289400-3171542.msg.from     <- the new sidecar
```

Poll N: `sort` puts `.msg` before `.msg.from` (prefix sorts first), so the real
message is delivered and renamed to `sent-1785289400-3171542.msg`. Poll N+1: the
only remaining non-`sent-` file is the **sidecar**. It is two lines, so it takes
the multi-line branch, gets renamed to `sent-…msg.from`, and the member's pane
receives:

> Queued message for you: read `…/sent-1785289400-3171542.msg.from` and act on it
> now - it is a direct message to you, not background material.

The member then reads a file containing a crew id and the word `say`. Every
successful redelivery is followed by exactly one garbage delivery.

The same defect exists in `wm_outbox_sweep_abandoned`, whose step 1 says "for every
non-`sent-` file under `outbox/<id>/`" - that set includes the sidecars, so each one
becomes its own bogus abandonment notice and its own audit-log line.

**Fix:** both functions must select only message files and treat `*.from` as
metadata (e.g. `grep -v '^sent-' | grep -v '\.from$'`, or better, put sidecars in a
subdirectory so no future selector can trip over them). The redelivery path must
also delete or move the sidecar alongside its message, or the sidecars accumulate
forever.

### 2. The backstop corrupts the shared `PANE_STABLE` baseline for every diagnostic that uses it

The plan says taking the capture in-house costs "a second `capture-pane` per id per
poll … an acceptable, explicit tradeoff." That understates it materially.
`wm_pane_snapshot` (`bin/lib/common.sh:359-367`) is not a pure read - it persists
state:

```sh
_hashfile="$WM_HOME/pane-<id>.hash"
_prev="$(cat "$_hashfile" 2>/dev/null)"
printf '%s\n' "$_hash" > "$_hashfile"
if [ -n "$_prev" ] && [ "$_hash" = "$_prev" ]; then PANE_STABLE=1; else PANE_STABLE=0; fi
```

There is one hash file per member, unlocked, and `PANE_STABLE` means "identical on
two *consecutive polls*" - roughly a 5-second interval. Today exactly one cycle
ever calls this for a given id, because owner scope partitions the fleet by parent.
The backstop breaks that invariant two ways:

- **Within the top-level process.** For every direct report, the owner-scoped loop
  snapshots first and the backstop snapshots again moments later in the same poll.
  The backstop's own `PANE_STABLE` is therefore computed over a **millisecond**
  interval, not two polls - so it reads `1` almost unconditionally, including for a
  pane that is mid-turn with no new output yet. That is precisely the state the
  block's own comment says the gate exists to prevent ("a pane mid-repaint is a
  member mid-turn, and typing into it both risks interleaving with its own output
  and can't be confirmed anyway"), and it is the same "busy but quiet" state #214 is
  about. The backstop would type into busy panes far more aggressively than any
  existing caller.
- **Across processes.** For a lead's worker, the lead's `watch-fleet` and the
  top-level `watch-fleet` now both write `pane-<worker>.hash` on interleaved,
  unsynchronised schedules. The lead's freeze detection, stall-check nudge, and RC
  drop detection all gate on `PANE_STABLE` computed from a baseline the other
  process keeps overwriting. This regresses fleet machinery that works today, for
  members the backstop is not even trying to help.

This is the "new race" the review brief asks about, and it is the most serious
finding here.

**Fix:** give the backstop its own hash namespace (e.g.
`pane-backstop-<id>.hash`) so each caller keeps independent two-poll semantics, or
have `wm_outbox_try_redeliver` accept the caller's already-computed
`PANE_STABLE`/`PANE_TEXT` instead of re-capturing. The plan explicitly rejects the
latter for decoupling reasons; a separate namespace gets the decoupling without the
shared-state corruption and is the smaller change.

### 3. An abandonment notice whose sender is wingman itself has nowhere to go

The plan records the sender as `${WINGMAN_CREW_ID:-'-'}`, with `-` meaning
"wingman's own top-level session," and then delivers the notice by
(a) `wm_tmux_send_message` to the sender, falling back to (b) queuing it into
*the sender's own outbox*.

Neither works for `-`. The orchestrator session is not a roster member, has no
`wm-<id>` window, and `outbox/-/` is serviced by nothing: the owner-scoped loop
iterates roster ids, and the backstop iterates live `wm-*` windows. The notice
lands in a directory no code path will ever read, which is a bit-for-bit
reproduction of the defect this plan exists to close.

This is not an edge case. The issue's own impact statement names "the channel that
carries the human's answers to blocked crew" as the primary casualty, and `CLAUDE.md`
routes exactly that through `bin/crew-say` **from the orchestrator**. A pilot answer
relayed to a member that then stands down is the single most likely message this fix
will ever have to salvage, and it is the one case with no delivery path.

**Fix:** the orchestrator already has a working wake channel -
`bin/watch-fleet`'s wake file plus a fire reason (the same mechanism
`remote-control-dropped`, the outage machine, and the correlated-death batch all
use). Route `-`-sender notices through it so wingman is woken and reports the
abandonment to the pilot on its next turn. Anything less means the headline case is
covered only by an append-only log file nobody reads.

(Minor, same area: `${WINGMAN_CREW_ID:-'-'}` as literally written expands to the
three-character string `'-'`, not `-`. The quotes are inside the expansion.)

### 4. Claim-before-send, as specified, does not close the double-delivery race

The plan asserts the loser of the `mv` race "sees the source already gone and moves
on with no further action." Nothing in the current code does that, and the plan does
not say to add it. `bin/watch-fleet:920-925`:

```sh
mv "$_obpath" "$_obsent" 2>/dev/null          # exit status discarded
_obmsg="Queued message for you: read $_obsent …"
wm_tmux_send_message "$(wm_tmux_win_target "$_win")" "$_obmsg" \
  || mv "$_obsent" "$_obpath" 2>/dev/null
```

The `mv`'s exit status is thrown away and the send proceeds regardless. Generalising
this pattern to both branches, as written, gives the loser this behaviour:

1. Loser's `mv` fails (source already claimed by the winner) - unnoticed.
2. Loser sends the pointer anyway, naming `sent-…` which now exists → the member
   receives the message a second time.
3. If the loser's send fails, its `|| mv "$_obsent" "$_obpath"` **un-claims the
   winner's already-delivered file**, putting it back in the queue for a third
   delivery on a later poll.

**Fix:** state explicitly that the send is gated on the claim's exit status
(`if mv … 2>/dev/null; then … fi`) and that the revert path is reachable only by the
process that owns the claim. This is a one-line change but the plan currently
describes the desired behaviour without specifying the mechanism, and the mechanism
that exists today does the opposite.

### 5. `crew-prune`'s sweep passes break `--dry-run` and ignore `--owner`

The plan specifies both passes "run unconditionally on every invocation." But
`bin/crew-prune` documents and implements `--dry-run` as "show what would be
removed, change nothing," and branches on it at `:23-29`. Under the plan,
`crew-prune --dry-run` would delete outbox files, send abandonment notices to live
panes, and append to the audit log - the one invocation a user runs precisely
*because* it is inert.

Second, `wm_state prune` honours `--owner` (`cmd_prune`, `bin/lib/wm-state.py:1182-1190`),
so a lead pruning its own scope would sweep outboxes fleet-wide, including for
members it does not own.

**Fix:** skip both passes entirely under `--dry-run` (or report what they *would*
sweep, without acting), and scope pass 1 to `--owner` when it is given.

---

## Should-fix

### 6. The "zero redeliveries ever" premise is false, and the plan states it as verified fact

The plan repeats the issue's observation as its own finding: "zero files anywhere
under `outbox/*/sent-*` across the entire history of that state directory - the
redelivery path has apparently never once completed a delivery." Live state
contradicts this:

```
/home/greer/.wingman/outbox/implement-the-approved-plan-at-d-developer/sent-1785289400-3171542.msg
mtime: 2026-07-29 01:43:20
```

Issue #169 was filed `2026-07-27T02:08:24Z`. The successful redelivery is dated
**two days after the issue**, and one day before the plan. It went through the
multi-line branch, which reverts the rename on a non-zero send - so this is a
`wm_tmux_send_message` success against a real Claude Code pane, not a stub.

Two consequences:

- **The conclusion survives and gets stronger.** This is direct production evidence
  that `PANE_STABLE` does reach `1` against a real TUI and that the redelivery
  mechanism works end-to-end outside the test harness. That matters, because as
  written the plan rules out a mechanical `PANE_STABLE` defect on the strength of a
  bash TUI stub (`tests/outbox-redelivery.test.sh`'s stub is byte-stable by
  construction, which is exactly the property under question for a real pane) plus
  a control repro using that same stub. The stub evidence does not support the
  conclusion at the confidence the plan claims; the `sent-` file does. Re-ground
  piece 3 on it and most of the speculative structural argument - particularly the
  "watcher not continuously running" strand - becomes unnecessary.
- **Something deleted pending messages with no `sent-` marker.** The six pending
  messages the issue reported are gone. Both surviving outbox directories hold zero
  pending files, and
  `outbox/ground-and-plan-a-fix-for-atrium-software-analyst-5/` is empty with an
  mtime of Jul 28 14:59 - a message was queued there and then removed without ever
  becoming `sent-`. I could not determine what removed it. If some path already
  deletes pending outbox files, that is an additional silent-loss vector this plan
  does not model, and the `crew-prune` section's justification ("this is what drains
  the six messages already stranded in production today") is stale.

Re-verify against live state and correct the plan. A plan whose stated empirical
foundation is falsifiable in one `ls` invites a reader to distrust the parts that
are right.

### 7. Claim-before-send creates a new silent-loss window and the plan widens it

A cycle killed between the claim `mv` and the send (or between a failed send and its
revert) leaves the message named `sent-*` - permanently invisible, because
`grep -v '^sent-'` excludes it and nothing ever reconciles a stale claim. This hole
exists today in the multi-line branch only; the plan extends it to every message and
adds a second process that can be killed independently. The repo's own
`docs/analysis/2026-07-28-watch-fleet-spurious-deaths-and-dropped-wakes.md` documents
cycles dying to out-of-band signals, so this is not hypothetical.

Trading a double-delivery risk for a silent-loss risk is a bad trade in a fix whose
entire purpose is eliminating silent loss. Use a distinct in-flight prefix
(`claiming-`/`inflight-`) rather than `sent-`, and have the sweep (or the next poll)
reclaim a claim older than some small multiple of the poll interval. At minimum, name
the exposure and justify accepting it.

### 8. The backstop can resurrect an orphan immediately after the standdown sweep

Piece 1 and piece 2 race at end-of-life:

1. The backstop claims `outbox/X/msg` (renames it to `sent-…`) and begins a send.
2. `bin/crew-standdown X` kills the window, then sweeps `outbox/X/` - which now
   contains no non-`sent-` file, so the sweep finds nothing and reports nothing.
3. The backstop's send fails (the window just died) and reverts `sent-…` back to
   `msg`.

The queue is now non-empty again for a member that is `stood-down`, and the sweep
that would have surfaced it has already run. It is orphaned until the next
`crew-prune`, and never surfaced to the sender. The `died` path has the same shape.

This is another argument for sequencing (finding 10) and for the stale-claim design
in finding 7 - a sweep that also reclaims in-flight claims closes it.

### 9. The freshness claim in "Investigation performed" is inaccurate

The plan states the checkout was two commits behind `origin/main`, "both confined to
`docs/analysis/*.md` and a `bin/spawn-crew` CLAUDE.md-exclusion tweak, neither
touching any file cited here." Commit `51fd782` adds a 26-line `wm_claude_md_excludes`
function to **`bin/lib/common.sh`** and edits **`bin/spawn-crew`** - two of the seven
files this plan modifies.

The conclusions survive: both additions are orthogonal to the outbox path. But the
line cites shift - `bin/spawn-crew`'s queue site is `:521-525` on `origin/main`, not
`:520-524` - and the assertion as written is wrong. Given that the status contract
requires this check precisely so stale reads do not become findings, it should be
corrected rather than left as an unforced error in an otherwise well-grounded
section.

### 10. Piece 1 carries nearly all the risk and none of the benefit for the reported incident

The plan itself concedes piece 1 "does not explain the specific six-message
production observation." Every must-fix above except 1 and 5 - the shared-hash
corruption, the double-delivery race, the new silent-loss window, the
sweep-vs-backstop hole - exists *only because of piece 1*. Piece 2 plus the prune
passes fully closes the defect the issue reports, touches four files, and introduces
no concurrency.

Land piece 2 + prune as its own change, and piece 1 as a separate follow-up with the
concurrency design worked out properly. That also removes the merge-ordering
entanglement with #214 the plan flags at the end, since the collision is entirely in
piece 1's territory.

Related, on #214 scope: the plan's line-level correction is **accurate** - I verified
that `bin/watch-fleet:924` and `:928` are the two outbox-redelivery sends, and that
`docs/analysis/2026-07-30-tmux-clear-key-interrupt-and-silent-denial.md` mislabels
them (as "the `/remote-control` reconnect retry" at `:84` and "the overdue-blocker
message" at `:145`), while `:974` and `:1077` are correctly identified. Good catch,
and the contributing-but-distinct verdict on #214 is correctly reasoned.

But the plan misses one interaction in its own direction: the backstop is a **new
fifth send site**, typing into panes selected by a stability gate the plan
inadvertently defeats (finding 2). #214's accepted fix ("on busy, skip and retry next
poll") will have to cover it too. Flag it in the sequencing note so whoever implements
#214 does not enumerate four sites against a file that now has five.

### 11. `done` members are ambiguously handled by `crew-prune` pass 1

Pass 1 says "for every id with a `working`/`blocked`/`review`/`stalled` roster status,
skip. For every other existing id (`stood-down`/`died`) … sweep." `done` is in neither
set. By the stated rule it gets swept; by the parenthetical it does not. A `done`
member still has a live window and is reaped in the same turn per `CLAUDE.md`, so its
queue is still deliverable - sweeping it as abandoned discards a message that would
otherwise arrive. Add `done` to the skip list explicitly.

### 12. Testing strategy: right shape, four gaps and one flake

The strategy correctly targets the death/standdown/prune paths through real
`watch-fleet` cycles rather than unit-testing shell functions, and reusing
`tests/outbox-redelivery.test.sh`'s isolation harness is the right call. Gaps:

- **No test for the `-` (wingman) sender path** - finding 3's case, and the most
  important one. It should assert the notice reaches a channel that actually exists,
  not that a file appears under `outbox/-/`.
- **No test that a `.from` sidecar is never itself delivered** - finding 1. The
  natural assertion is that after a successful redelivery, a further poll types
  nothing into the pane.
- **No test that `crew-prune --dry-run` changes nothing** - finding 5.
- **No test for stale-claim recovery** - finding 7. Simulate a kill between claim and
  send (leave a file named with the in-flight prefix) and assert it is recovered
  rather than stranded.
- **Test 6 is a flake as written.** "Arm both cycles simultaneously … assert exactly
  one delivery" passes by luck whenever the two polls happen not to overlap, which
  will be most runs. It tests the scheduler, not the claim. Drive
  `wm_outbox_try_redeliver` directly from two concurrent shells against one queued
  file with a synchronisation point, and assert on the claim's outcome. Given the
  standing bar on test flakiness, a probabilistic concurrency test is worse than none.

---

## Nice-to-have

- `${WINGMAN_CREW_ID:-'-'}` expands to `'-'` (with quotes), not `-`.
- The plan cites `:1076` for the stall-check nudge in one place; it is `:1077`
  (correctly cited elsewhere in the same paragraph).
- The audit-log open question is fine as posed, and the recommended answers (always
  log, append-only) are the right ones - but note that under finding 3 the log is
  currently the *only* channel for orchestrator-sent notices, which makes "always
  log" load-bearing rather than belt-and-braces. Fixing 3 restores it to belt-and-
  braces.

---

## Answers to the review questions

1. **Does it close the silent-loss defect?** For crew-to-crew messages, yes, once
   findings 1, 4, 7 and 8 are addressed. For orchestrator-sent messages - the issue's
   headline case - **no**, as specified: finding 3 leaves them in an unserviced
   directory. `crew-prune` no longer orphans a pending outbox, subject to finding 5.
2. **Is the top-level backstop correctly scoped?** The `[ -z "$OWNER" ]` gate and the
   "live window, no status filter" population are right, and match the file's existing
   precedent. But it does create new races: the shared `pane-<id>.hash` corruption
   (finding 2), the un-gated claim (finding 4), and the sweep collision (finding 8).
   Not correct as specified.
3. **Does it regress what works today?** Redelivery to a live, in-scope member does
   work today - I have the production `sent-` file and the passing test suite. The
   refactor preserves it, but finding 2 regresses the freeze/stall/RC diagnostics for
   lead-owned members, and finding 1 adds a spurious delivery after every successful
   one.
4. **Is the #214 relationship right?** Yes. Contributing-but-distinct is correctly
   reasoned, the root-cause independence argument holds, and the line-cite correction
   is accurate and useful. The plan stays out of #214's territory in intent; finding 2
   means it lands in it in effect, and it adds a fifth send site #214's fix must cover.
5. **Is the testing strategy executable?** Yes, and at the right level. Four gaps and
   one probabilistic test - finding 12.
6. **Blast radius?** Seven files is defensible for the full scope, but findings 10's
   split would cut the risky change down to `bin/lib/common.sh`, `bin/crew-standdown`,
   `bin/crew-prune`, `bin/watch-fleet` (death hook only) and the three sidecar
   one-liners, deferring the `watch-fleet` refactor and the new backstop block.
