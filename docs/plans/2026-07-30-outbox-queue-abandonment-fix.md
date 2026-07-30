# Fix: queued crew messages are silently abandoned when the target member ends

**Date:** 2026-07-30 (revised after five review rounds)
**Issue:** [greerviau/wingman#169](https://github.com/greerviau/wingman/issues/169)
**Mode:** plan (no developer handoff yet - awaiting disposition)
**Revision note:** reviewed five times
(`docs/analysis/2026-07-30-review-outbox-queue-abandonment-plan.md`,
`.../review-round2-...md`, `.../review-round3-...md`, `.../review-round4-...md`,
`.../review-round5-...md`). Round 4's four must-fix items (the sweep trigger,
the parent-chain keying, the notice-as-fire-condition, the `set -u` crash) are
now confirmed closed - three by direct execution, not reading. Round 5 found
two further must-fix items (both spec-level, both make phase 1 smaller rather
than larger) and four should-fix items, all addressed below. Round 5's own
assessment: this plan does not need a sixth full adversarial round - the
remaining items are localized specification edits, and the fact that nothing
outside the two mechanisms round 4 scoped this round to (the sweep trigger,
the notice channel) regressed is itself evidence of convergence. The
architecture has been independently confirmed correct across all five rounds.

## Problem

`bin/crew-say`, `bin/crew-ask`, and `bin/spawn-crew` each queue a message under
`$WINGMAN_HOME/outbox/<id>/` when `wm_tmux_send_message` cannot confirm delivery
(a dialog-shaped pane, an unconfirmed submit, or a contended send lock), and each
tells the caller, verbatim, that "the watcher will retry it automatically." The
only code that ever retries a queued message is `bin/watch-fleet`'s per-member
pane loop, which only considers members that are (a) inside the polling cycle's
own `--owner` scope, and (b) currently in status `working`, `blocked`, `review`,
or `stalled`. Once a member reaches `done`, `stood-down`, or `died`, its outbox
becomes permanently unreachable: no code path ever services it again, nothing
expires it, nothing surfaces it, and neither `bin/crew-standdown` nor
`bin/crew-prune` touches `outbox/<id>/` at all. The sender is never told the
promised retry did not happen.

## Investigation performed

Carried forward and re-confirmed across all five rounds: the checkout is two
commits behind `origin/main`, orthogonal to the outbox path; live `outbox/`
holds exactly one `sent-` file (a confirmed production redelivery) and one
empty, orphaned, unexplained directory, not "zero ever" as the issue itself
claims; the isolated reproduction proving a message queued to a member that
ends before a stable poll is never serviced and is orphaned by `crew-prune`;
the control case proving the underlying mechanism is sound.

## Diagnosis of the three suggested pieces

Unchanged, confirmed correct across all five rounds: piece 3 (why redelivery
so rarely succeeds) is a structural, architectural gap, not a mechanical bug
in `PANE_STABLE`/oldest-file selection; piece 2 (surface and clean up at
end-of-life) is the direct, necessary fix; piece 1 (a top-level backstop) is
real hardening, sequenced as phase 2.

## Relationship to related issues (informational - not in scope to fix here)

**#188** (whole-pane checksum false-positives on a busy pane): unchanged,
genuinely adjacent, not fixed here.

**#214** (a blind `C-c` clear-keystroke aborts a target's in-flight tool
call): contributing-but-distinct at the root-cause level; confirmed accurate
and specific by round 4 (`bin/watch-fleet`'s four `wm_tmux_send_message`
sites are exactly `:924`, `:928`, `:974`, `:1077`, matching `#214`'s own
enumeration; `:924`/`:928` are the two sends inside the outbox block phase 1
restructures). **Round 5, finding M-2, simplifies this further and removes a
hand-off item rather than adding one:** the prior revision's sweep design
called for a direct, synchronous `wm_tmux_send_message` to a live sender as
part of `wm_outbox_sweep_abandoned`, which would have been a genuinely new,
phase-1 send site outside the four above - and, per M-2 below, one of the
more exposed ones (fleet-wide, ungated on `PANE_STABLE`, outside any owner
scope). That direct send is deleted outright (M-2, below): the sweep now
always queues into a live sender's own outbox and lets the existing,
stability-gated redelivery path deliver it. Phase 1 therefore hands `#214`'s
implementer exactly the same four pre-existing sites it always did - two
rewritten, none added - which is a strict simplification of the sequencing
note this plan has carried since round 3.

## Design

### Metadata sidecars live in a separate tree, never inside `outbox/<id>/`

Unchanged. `$WM_HOME/outbox-meta/<id>/` mirrors `outbox/<id>/` by base
filename; `bin/crew-say`, `bin/crew-ask`, `bin/spawn-crew` write the sidecar
**before** the payload (round 4's S-3, confirmed correct by round 5) - the
sender's crew id, or empty for wingman.

### `wm_outbox_basename` - recovering the stable stem across claim-protocol prefixes

Unchanged; confirmed correct by direct execution in round 3.

### The claim protocol

Unchanged in shape. **Round 4's S-1 fix (stale threshold derived from
`WM_SEND_LOCK_WAIT + INTERVAL * 3`, not just `INTERVAL * 3`) confirmed correct
by round 5**, including the citation: `WM_SEND_LOCK_WAIT`'s 45-second default
lives at `bin/lib/common.sh:658` on `origin/main` (round 5 caught that an
earlier revision cited the *working tree's* line number, `:632` - the
checkout is two commits behind and `common.sh` is one of the two files that
differ; every citation to this constant is now pinned to `origin/main`).

### Pointer stability, for both the sweep and redelivery

Unchanged; `outbox-abandoned/<id>/<stem>` (the sweep) and
`outbox-delivered/<id>/<stem>` (redelivery) are each written once, before any
pointer naming them is composed or sent, and never touched again. **Round 5
confirms this is unaffected by M-2 below**: M-2 removes the sweep's *notify*
step's direct send, not the payload-move step that creates
`outbox-abandoned/<id>/<stem>` - the two are independent, and the pointer-
stability invariant (move first, always) is unchanged and now additionally
gates the sweep's own claim (S-2, below).

### `bin/watch-fleet`'s existing outbox block: phase-1 hardening, applied in place

Unchanged: no new `PANE_STABLE`/`PANE_TEXT` capture in the main per-member
loop; the claim protocol applied entirely in place.

### `done`-status members get outbox servicing in phase 1

Unchanged from round 3/4.

### The generic per-poll outbox scan, replacing the `_reconcile_died`-driven hook (round 4's N-1; round 5 confirmed the approach and specified three corrections to it)

**Round 5 confirmed by direct execution that dropping the `_reconcile_died`
dependency and scanning `$WM_HOME/outbox/*/` directly genuinely closes the
stolen-flip failure mode** - reproduced against a `crew-list`-shaped
reconcile call (exactly `bin/crew-list:27`'s shape: no `--owner`, output
discarded) that flipped three members while the watcher's own subsequent
`_reconcile_died` read empty; the scan, driven off current roster status
rather than a flip list, swept all three correctly regardless. The approach
is confirmed right; round 5 found three corrections to *how* it reads roster
state and *where* it sits in the loop - none change the approach itself.

**Round 5, finding S-3: a per-directory `wm_state crew-get` is both measurably
the wrong shape and fails dangerously.** Measured directly (10 samples each,
this host): one `crew-get` costs **140ms**; one fleet-wide
`crew-list --all --json` read costs **149ms**, constant regardless of outbox
count; the scan as specified, against 3 pending directories, cost **630ms**
(~210ms per pending directory). The plan's own cost argument - "a swept
directory is empty on the next poll, so this costs one listing and one
`crew-get` and nothing else" - covers only the *transient* terminal case. It
never accounted for the state that actually persists: a **live** member with
an undeliverable pane, which is precisely the condition that puts a message
in the outbox in the first place. That directory is never emptied by the
scan, so its ~210ms is paid every poll, in every watcher, for as long as the
member stays undeliverable - already worse than one flat fleet-wide read at a
single pending directory, and it only gets worse with more. Separately,
`2>/dev/null` on a failed lookup is indistinguishable from "no record" in the
prior design, and the `case` mapped both to `sweep ... orphaned` - so a
transient `wm_state` process failure would sweep a **live** member's outbox
and tell its sender the message was abandoned while the target is alive and
would have received it.

**Fixed, one change closes both:** the directory listing itself (a plain
shell glob, no subprocess) stays the first, cheap check; only if it finds at
least one pending directory does the scan take **one** fleet-wide
`wm_state crew-list --all --json` read for the whole poll, deriving every
pending id's status from that single payload rather than one `crew-get` per
directory. If that one read fails, the scan **skips entirely for this poll**
rather than treating the failure as "no record" - failing closed (defer to
the next poll) rather than failing dangerous (sweep a live member). This
keeps the "no `bin/lib/wm-state.py` changes required" property intact, since
`crew-list --all --json` already exists.

**Round 5, finding S-1: where the scan sits in the loop was unspecified, and
`fire()` itself exits the process.** `fire()` ends in `exit 0`
(`bin/watch-fleet:803`), so anything placed *after* the `needs-attention`
check never runs on a poll that fires - and the poll that detects a death is,
by construction, exactly such a poll. Appending the scan next to the
`NOTICEFILE` change (the natural place, since that block is also being
edited) would defer every death-path sweep to the *next* armed cycle, which
itself depends on the owning session being woken and taking a turn - the same
shape of gap N-1 was raised to close, one placement decision later. Also,
placement inside the `wm_tmux has-session` gate (`:844`) would go dead
exactly when the whole tmux server is unavailable. **Fixed:** the scan sits
**near the top of the loop body, immediately after the beacon touch, before
the `wm_tmux has-session` block, and unconditionally on `$OWNER`** - so it
runs on every poll, in every watcher, before anything else in that poll can
exit the process.

```sh
: > "$BEATFILE" || true

# The generic outbox-directory scan (replaces any dependence on
# _reconcile_died - see "the generic per-poll outbox scan" in the plan).
# Cheap check first (plain glob, no subprocess); only pays for a fleet-wide
# roster read if something is actually pending.
_any_pending=0
for _od in "$WM_HOME"/outbox/*/; do
  [ -d "$_od" ] || continue
  for _of in "$_od"*; do
    case "$_of" in *"/sent-"*) continue ;; esac
    [ -e "$_of" ] && { _any_pending=1; break 2; }
  done
done
if [ "$_any_pending" = 1 ]; then
  if _roster_json="$(wm_state crew-list --all --json 2>/dev/null)"; then
    for _od in "$WM_HOME"/outbox/*/; do
      [ -d "$_od" ] || continue
      _oid="$(basename "$_od")"
      # ... derive _ostatus and window-liveness for $_oid from $_roster_json ...
      # ... apply the unified terminal predicate (see below) and sweep if terminal ...
    done
  fi
  # a failed roster read skips the scan for this poll - fail closed, never
  # dangerous - rather than treating "couldn't tell" as "terminal"
fi
```

**Related limitation, stated rather than left as an unqualified claim (round
5, should-fix, part of S-1): the scan inherits a pre-existing blind spot and
the plan should say so.** The scan keys entirely on roster status, and roster
status is updated only by a `reconcile` call that both `bin/crew-list` and
`bin/watch-fleet` themselves gate on a live tmux server
(`wm_tmux has-session`). Per `docs/analysis/2026-07-30-tmux-server-death-and-
reconcile-blind-spot.md` (Defect 2, confirmed and unfixed on `main`), a
whole-tmux-server death leaves every member reading its last self-reported
status indefinitely - so in that scenario the scan (and `crew-prune`'s own
pass 1, for the identical reason) sees no terminal member at all and sweeps
nothing. That is the largest possible mass-abandonment scenario, and it is
exactly the case this plan calls its highest-value one. Fixing that blind
spot is out of scope here (it is a separate, already-documented defect); this
plan's own "robust backstop" language for the scan is qualified with this
inherited limitation rather than stated unconditionally.

**Nice-to-have (round 5): a fork-free emptiness test**, since this scan is
now a hot path (an `outbox/<id>/` directory persists indefinitely once
created - `sent-`/durable-copy entries are never removed, so a directory with
any successful-delivery history never goes away - meaning the scan's fixed
cost only grows with fleet history, never shrinks). The pseudocode above
already reflects this: a plain shell glob loop with a `case` match, zero
subprocess forks, rather than `ls ... | grep -v '^sent-'`'s two forks per
directory per poll per watcher.

### The unified reachability predicate (round 5, finding M-1 - collapses two definitions that had drifted apart back into one)

The plan previously stated two different definitions of "this member cannot
receive anything": the sweep's own sender-liveness check (missing record,
`stood-down`, `died`, or `done` with no live window) and the parent-chain
walk's own terminal test (`status in (stood-down, died)` only - narrower,
missing both the "record missing" and the "`done`, no window" cases). Round 5
reproduced both narrow gaps re-creating exactly N-2's original failure shape:
a parent whose record is absent (reachable through a supported
`crew-prune --owner ""`/`--older-than-days` invocation, which keep an
out-of-scope descendant's own record while removing the ancestor's) or a
parent that is `done` (never re-adopted away - the re-adopt pass only fires
from `died`/`stood-down` - and, if wingman itself is not currently running to
reap it, can persist indefinitely) both resolved the walk to the unreachable
dead id instead of continuing past it.

**Fixed: one predicate, named once, used in both places.** A member (sender
or ancestor) is **terminal** iff its roster record is missing, or its status
is `stood-down`/`died`, or its status is `done` with no currently-live
window. Both the sweep's step-2 sender check and `resolve_notice_owner`'s
walk-up test membership in this exact predicate - stated as one shared
definition specifically so the two cannot drift apart again, which is what
produced this finding in the first place.

```
resolve_notice_owner(id):
  guard = 0
  while guard < 5:
    rec = crew_get(id)
    if rec missing or rec.parent == "": return ""      # floor: wingman
    parent = rec.parent
    if is_terminal(parent):     # the unified predicate, above
      id = parent; guard += 1; continue
    return parent               # first non-terminal ancestor
  return ""                      # safety fallback
```

The guard cap, the wingman floor, and the reasoning for why wingman is the
correct floor (the one process guaranteed to outlive a tmux-server loss) are
all confirmed correct by round 5's own 2-cycle reproduction (`A.parent=B`,
`B.parent=A`, both terminal - the loop terminates on the cap, returns `""`, no
crash, no infinite loop) and carried forward unchanged.

### `wm_outbox_sweep_abandoned <id> <reason> <notify-mode>` (piece 2)

For every file under `outbox/<id>/` that is not `sent-`:

1. Look up the `outbox-meta/<id>/` sidecar via `wm_outbox_basename`. Sender is
   the sidecar's content (empty = wingman), or `unknown` (no sidecar).
2. Test the sender against the **unified terminal predicate** (above). If
   terminal, treat as unreachable and route through `<notify-mode>` (below)
   instead of that sender's own outbox.
3. **Round 5, finding S-2: the payload move is now the sweep's own atomic
   claim, exactly like the redelivery claim protocol, closing a genuine
   double-notify race.** Making the generic scan unconditional in every
   watcher (the fix above) turns a single-sweeper assumption the rest of the
   design never stated into a multi-sweeper reality - reproduced directly:
   two concurrent processes running the (previously unGated) step sequence
   against one outbox directory each independently composed a notice and each
   appended its own audit-log line for the *same* message. **Fixed:** the
   move to `outbox-abandoned/<id>/<stem>` is gated on its own `mv`'s exit
   status - `if mv "$src" "$WM_HOME/outbox-abandoned/$id/$stem" 2>/dev/null;
   then ...compose, log, notify...; fi` - so only the process whose `mv`
   succeeds proceeds to do anything further for that file; a losing process
   (source already gone) does nothing - no notice, no log line, silently
   correct, exactly mirroring how the redelivery claim already resolves the
   analogous race. This composes directly with the existing "move before any
   pointer is composed or sent" rule rather than conflicting with it - both
   already wanted the move to happen first; this just adds the gate on its
   outcome.
4. Compose the notice: target id, sweep reason, when originally queued, the
   content (inline if short, else a pointer to the now-durably-moved payload).
5. **Always** (for the winning process only, per the gate above), append one
   line to `$WM_HOME/outbox-abandoned.log`.
6. Notify:
   - **A sender that passed step 2's check:** **round 5, finding M-2 - always
     queue, never send directly.** The prior design attempted a direct,
     synchronous `wm_tmux_send_message` to a live sender before falling back
     to queueing. Round 5 found this creates three compounding problems, one
     deletion fixes all three:
     - **Beacon starvation.** `bin/watch-fleet` touches `$BEATFILE` once per
       iteration, at the top of the loop, and `cycle_live()` requires it
       fresher than `GRACE` (default 30s). A single contended send can block
       up to `WM_SEND_LOCK_WAIT` (45s) - already past `GRACE` on its own -
       and the sweep would do this *per abandoned message, serially,
       fleet-wide*, with no per-poll bound. A redundant arm landing in that
       window reads `cycle_live` as false and claims a second cycle for the
       same owner; `--classify` on the still-live-but-stale-beacon pid
       reports a manufactured `spurious ... hung-or-stale-pidfile` failure,
       incrementing the consecutive-failure budget for no real reason.
     - **No stability gate.** Phase 1 takes no new `PANE_STABLE` capture (by
       design), so a direct send from the sweep cannot honor the existing
       block's own documented invariant - "a pane mid-repaint is a member
       mid-turn, and typing into it both risks interleaving with its own
       output and can't be confirmed anyway" - making it a blind send into a
       potentially busy, live member's pane.
     - **Out of scope.** All four of `bin/watch-fleet`'s existing send sites
       live inside the owner-scoped per-member loop; the generic scan is
       deliberately fleet-wide, so a direct send from it would have a lead's
       watcher typing into panes outside its own team, bypassing the team
       guardrail `bin/crew-say` enforces at the command layer.

     **Fixed by deletion:** always queue the notice into the live sender's
     own outbox (with its own sidecar, sender recorded as empty), which the
     design already specified as the *fallback* - now the only path. The
     existing, stability-gated, claim-protocol-governed redelivery mechanism
     delivers it on that sender's own owner's next poll. This removes every
     blocking call from the scan (closing beacon starvation outright), honors
     `PANE_STABLE` for free (the redelivery path already does), keeps the
     scan scope-neutral (writing a file, never keystrokes), and - per the
     `#214` section above - removes a send site from that issue's inherited
     surface rather than adding one. The only cost is a notification latency
     of roughly one poll interval, against a mechanism whose prior worst case
     was "never."
   - **Wingman, `unknown`, or a sender that failed step 2:** route through
     `<notify-mode>` - `stdout` (`bin/crew-standdown`/`bin/crew-prune`) or
     `wake` (the generic scan, redesigned below for the notice channel's own
     three fixes).
7. Remove the now-empty original file and sidecar (for the winning process
   only); `rmdir` if empty.

### The `wake`-mode channel

Round 4's parent-chain keying and six-exit-consolidation are unchanged;
round 5 confirmed both by direct code inspection (all five wingman-only
exits are `[ -z "$OWNER" ]`-gated, so a lead's cycle reaches the
`needs-attention` check unconditionally on every poll; `fire()` exits by
construction, so no double-surfacing is possible when both a genuine
attention event and a pending notice coincide) and found one defect in the
mechanism itself:

**Round 5, finding S-4: `fire()`'s read-then-truncate of the notice file can
lose a concurrently-appended notice.** Read literally
(`cat "$NOTICEFILE" >> "$WAKEFILE"; : > "$NOTICEFILE"`), any append landing
between the read and the truncate is destroyed with no trace - reproduced
directly. **Fixed, one line:** rename-aside first -
`mv "$NOTICEFILE" "$NOTICEFILE.reading" 2>/dev/null` - then fold in the
*renamed* copy and remove it. An appender using `>>` either already wrote to
the renamed inode (read anyway, since the rename happens before the fold) or
finds the original path gone and recreates a fresh file there (picked up
whole on the next poll's `-s` check, never partially lost).

**Nice-to-have (round 5): a notice-only fire writes an empty `## New events`
section in the wake file.** Harmless (the `## Abandoned messages` section
still carries the actual content), but worth one sentence in the
implementation so the first reader of that wake file does not mistake the
empty section for a bug. Separately confirmed by round 5: `fire ""` (the
call shape a notice-only fire takes, with no genuine `$attention`) is safe -
`wm_state group-attention` on empty input returns empty with rc 0, and the
ack loop is already guarded by `[ -n "$id" ]` - and the plan's "print one
extra stdout reason line" is load-bearing, not cosmetic: without it, a
notice-only fire would emit *no* stdout at all, and stdout is the wake's own
trigger channel.

### `bin/crew-standdown`

Unchanged.

### `bin/crew-prune`

Unchanged: both sweep passes run before `wm_state prune` removes any record
(round 4's S-2, confirmed correct by round 5 - `cmd_prune` keeps out-of-scope
records, so a post-prune pass 1 would find nothing and fall through to the
always-fleet-wide pass 2, nullifying `--owner` scoping); flag parsing for
`--owner`/`--owner=value`/`--dry-run`; the `done`-plus-live-window skip
condition. `crew-prune` pass 1 now uses the same unified terminal predicate
(above) as the sweep and the parent-chain walk, rather than a fourth,
separately-stated version of the same test.

### `bin/watch-fleet`'s top-level whole-fleet backstop (piece 1, phase 2 only)

Unchanged.

## Phased delivery

**Phase 1**, smaller again this round (M-2 deletes a send site rather than
adding one; M-1 collapses two liveness predicates into one; S-3 replaces N
per-poll `crew-get` calls with at most one fleet-wide read): `bin/lib/common.sh`
(`wm_outbox_basename`, `wm_outbox_sweep_abandoned`, and the shared unified
terminal-predicate check), `bin/crew-say`/`bin/crew-ask`/`bin/spawn-crew`
(sidecar-then-payload write order; the updated "watcher will retry"
message), `bin/crew-standdown` (cascade sweep), `bin/watch-fleet` (claim
protocol applied in place; the `done`-loop; the generic per-poll outbox scan
- placed per S-1, reading via one fleet-wide `crew-list --all --json` per
S-3; the `NOTICEFILE`/`fire()` extension with the S-4 rename-aside fix),
`bin/crew-prune` (flag parsing; both sweep passes, run before
`wm_state prune`, using the unified predicate). No `bin/lib/wm-state.py`
changes required in either phase.

**Phase 2:** extract `wm_outbox_try_redeliver` into `bin/lib/common.sh` with
the namespaced `PANE_STABLE` capture; add the whole-fleet backstop block to
`bin/watch-fleet`.

Round 5's own assessment: phase 1 is independently mergeable once M-1 and M-2
land - as specified before this revision, M-1 left two reachable chain shapes
where a notice is written to a file nobody reads (the same "not a guarantee"
condition round 4 blocked on), and M-2's direct send was a real, if latent,
risk to the watcher's own liveness bookkeeping. With both applied, phase 1
stands on its own; phase 2 remains a correctly-sequenced, separate follow-up.

## Files touched

**Phase 1:** `bin/lib/common.sh` (new: `wm_outbox_basename`,
`wm_outbox_sweep_abandoned`, the unified terminal-predicate helper),
`bin/crew-say`, `bin/crew-ask`, `bin/spawn-crew`, `bin/crew-standdown`,
`bin/watch-fleet` (in-place claim protocol hardening, `done`-loop, the
generic outbox scan, `NOTICEFILE` in both owner branches, the `fire()`
rename-aside fix), `bin/crew-prune`. No `bin/lib/wm-state.py` changes
required in either phase.

**Phase 2:** `bin/lib/common.sh` (`wm_outbox_try_redeliver` extraction,
`wm_pane_snapshot` namespace argument), `bin/watch-fleet` (backstop block).

## Testing strategy

Extends `tests/`, following `tests/outbox-redelivery.test.sh`'s pattern.
Tests 1-15 (carried forward from rounds 1-4, covering the claim protocol,
pointer stability, standdown/prune/death sweeps, the mass-death parent-chain
case, and the ordering regression) are unchanged and confirmed at the right
level by round 5. Four additions:

16. **M-1:** resolve the notice owner for a member whose parent's record is
    absent, and separately for one whose parent is `done` with no live
    window; assert both floor to wingman rather than resolving to the
    unreachable ancestor id.
17. **M-2 / S-2:** two watcher processes sweeping one outbox concurrently;
    assert exactly one notice is ever queued and exactly one
    `outbox-abandoned.log` line is ever written for that message - and
    assert no direct `wm_tmux_send_message` call ever originates from the
    sweep (a regression guard for M-2's deletion).
18. **S-1:** a poll on which the `needs-attention` check fires *and* a
    terminal member's outbox is pending in the same poll; assert the sweep
    happens on that same poll, not deferred to a later one (guards the scan's
    placement against `fire()`'s `exit 0`). Extends test 12's existing
    scenario to also run with the `wm_tmux has-session` gate absent, so
    placement stays pinned by an assertion rather than by prose alone.
19. **S-4:** append to the notice file at the exact moment `fire()` is
    folding its (previously-existing) content into the wake file; assert the
    concurrently-appended notice still survives and surfaces on the next
    poll rather than being silently destroyed by the read-then-truncate
    window.

**Phase 2:** unchanged - top-level backstop reaches an indirect descendant;
`PANE_STABLE` namespace isolation; direct two-shell concurrency test.

## Open Questions

Unchanged; all five review rounds confirmed the block parses cleanly and
both recommendations remain correct.

```wingman-questions
{
  "questions": [
    {
      "id": "audit-log",
      "type": "choice",
      "question": "Should every abandoned outbox message always be appended to a durable audit log ($WM_HOME/outbox-abandoned.log), in addition to the sender/wake notification described above?",
      "options": [
        { "label": "Yes, always log", "recommended": true,
          "detail": "Belt-and-braces now that the sender-notification paths (including the corrected parent-chain-keyed wake channel and the now-gated sweep claim) are fixed: guarantees a durable record even if a notify step fails for an unrelated reason, matching crew-archive.jsonl's own precedent." },
        { "label": "No, rely on notify + terminal output only",
          "detail": "Slightly less code, but re-introduces exactly the kind of unanswerable-after-the-fact question this investigation hit when trying to explain the empty orphaned outbox directory in live state." }
      ],
      "free_text": true
    },
    {
      "id": "audit-log-retention",
      "type": "choice",
      "question": "Should outbox-abandoned.log (and outbox-abandoned/<id>/, outbox-delivered/<id>/, the two durable-payload directories) get their own time-based retention sweep, or stay unbounded?",
      "options": [
        { "label": "No retention", "recommended": true,
          "detail": "Matches crew-archive.jsonl's own existing precedent; all three are low-volume (bounded by how often messages are ever abandoned, or redelivered as a multi-line pointer, in the first place)." },
        { "label": "Add a time-based sweep in crew-prune",
          "detail": "Consistent with the ask-record precedent, but adds retention knobs across three separate locations for a volume this low - not clearly worth the extra surface." }
      ],
      "free_text": true
    }
  ]
}
```

## Risks and follow-ups

- The whole-fleet backstop's extra `capture-pane` per live window per
  top-level poll (phase 2 only) is cheap but not free; no evidence it matters
  at any fleet size this project has run at.
- This plan does not touch `wm_tmux_pane_ready`, the dialog-shape detector, or
  the whole-pane checksum confirmation logic (#188's territory).
- Sequencing with `#214`: simplified by M-2 - phase 1 now rewrites exactly
  the same two of `#214`'s four enumerated `watch-fleet` send sites it always
  did, and introduces none of its own. Confirm before merging either fix that
  the other's changes to `:924`/`:928` are rebased onto, not silently
  overwritten by, this one.
- **The generic outbox scan inherits an existing, documented blind spot
  (round 5, S-1):** a whole-tmux-server death leaves reconcile unable to run
  at all (both `bin/crew-list` and `bin/watch-fleet` gate it on a live tmux
  session), so roster status never updates and the scan - like
  `crew-prune`'s own pass 1 - sees nothing to sweep. Documented in
  `docs/analysis/2026-07-30-tmux-server-death-and-reconcile-blind-spot.md`
  (Defect 2), out of scope to fix here; this plan's "robust backstop"
  framing for the scan is stated with this qualifier rather than
  unconditionally.
- Delivery is now **at-least-once**, not at-most-once (a documented
  consequence of the earlier pointer-stability fix, not a defect) - a crash
  between a confirmed send and the `sent-` rename produces a duplicate
  delivery on the next poll, never a silent loss.
- `outbox-abandoned/<id>/` and `outbox-delivered/<id>/` have no retention
  policy specified, matching the audit log's own reasoning.
- `sent-`/`outbox-delivered/<id>/` entries are never removed, so a directory
  with any successful-delivery history persists indefinitely - the `rmdir`
  cleanup rarely fires for such a member (cosmetic, not correctness), and the
  scan's own fixed cost per poll only grows with fleet history, never
  shrinks (mitigated by S-3's fork-free emptiness test and single fleet-wide
  read, not eliminated).
- Caller-facing messages (`bin/crew-say`, `bin/crew-ask`, `bin/spawn-crew`)
  gain one clause noting that end-of-life abandonment is now handled rather
  than silently promised-and-dropped.
- `tests/dialog-delivery-refusal.test.sh`'s existing selector assertions
  remain correct after this change but should gain the `inflight-` exclusion
  anyway so they keep asserting what they say they assert.
- The unexplained empty outbox directory found in live state remains
  genuinely unresolved; any future occurrence should leave a trace in
  `outbox-abandoned.log` if it goes through the sweep - a recurrence with no
  matching log entry would itself be strong evidence of a still-undiscovered
  deletion path outside this codebase's own `bin/`/`hooks/` trees.
