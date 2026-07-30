# Plan review, round 5: outbox queue abandonment fix (issue #169)

**Date:** 2026-07-30
**Plan reviewed:** `docs/plans/2026-07-30-outbox-queue-abandonment-fix.md` (revised after rounds 1-4)
**Prior rounds:** `docs/analysis/2026-07-30-review-outbox-queue-abandonment-plan.md`,
`.../review-round2-...md`, `.../review-round3-...md`, `.../review-round4-...md`
**Issue:** [greerviau/wingman#169](https://github.com/greerviau/wingman/issues/169)

**Verdict: request changes.** Two must-fix, four should-fix, three nice-to-have.

**This does not need a sixth review round.** Every item below is a localized
specification edit with the exact replacement text or predicate named, and two
of them make phase 1 *smaller* rather than larger. The right next step is one
revision pass by the plan's author, then straight to a developer - not another
full adversarial review.

Round 4's four must-fix items (N-1 to N-4) and all five should-fix items are
addressed, and I confirmed N-1, N-2 and N-4 by execution rather than by
reading. What remains is confined to the same two mechanisms round 4 scoped
this round to - **which is itself the strongest evidence of convergence in this
plan's history**: nothing outside the sweep trigger and the notice channel
regressed, and the parts untouched this round (the claim protocol, pointer
stability, `crew-standdown`, `crew-prune`, the sidecars, the `#214` prose,
tests 1-11) all still hold. Round 4's scoping call was accurate.

---

## Method

Every experiment below ran against an isolated scratch `WINGMAN_HOME` under
this session's scratchpad, exported explicitly per command and asserted not to
be the live `~/.wingman` before any state-mutating call.

**Freshness.** The checkout is 2 commits behind `origin/main`.
`bin/watch-fleet`, `bin/crew-list`, `bin/crew-prune`, `bin/crew-standdown`,
`bin/crew-say`, `bin/crew-ask` and `bin/lib/wm-state.py` are byte-identical to
`origin/main`, so those citations are read from the working tree.
`bin/lib/common.sh` and `bin/spawn-crew` differ and were read via
`git show origin/main:<path>`.

**Executed, not read:**

- The plan's generic per-poll outbox scan, transcribed literally, run after a
  `crew-list`-shaped reconcile stole the flip.
- The plan's `resolve_notice_owner` pseudocode, transcribed literally, against
  four parent-chain shapes (simultaneous mass death, missing parent record,
  `done` parent, 2-cycle).
- `wm_state reconcile` against a sandbox roster in the `crew-list` shape and
  the `watch-fleet` shape.
- Two concurrent sweeps of one outbox directory, with and without an
  exit-status gate on the payload move.
- `fire()`'s notice-file read-then-truncate against a concurrent append, with
  and without a rename-aside.
- Timing of `wm_state crew-get` versus one fleet-wide roster read (10 samples
  each).
- `wm_state group-attention` on empty input (the `fire ""` path the plan
  introduces).

---

## What round 4 raised, and where it stands

### N-1 (sweep trigger): closed. The scan genuinely fires without the stolen signal.

Reproduced end to end. A `crew-list`-shaped reconcile (`--windows ""`, no
`--owner`, output discarded - exactly `bin/crew-list:27`) flipped `L`, `W`, `X`
to `died`; the watcher's own subsequent `reconcile --owner ""` returned an
empty `_reconcile_died`, confirming round 4's diagnosis is still live. The
plan's scan, transcribed literally and run against that state, produced:

```
SWEEP GONE reason=orphaned      # no roster record at all
SWEEP LIVE reason=died
SWEEP W    reason=died
```

It reads current roster status, never a flip list, so the stolen-flip failure
mode is structurally gone rather than narrowed. Dropping `_reconcile_died`
outright is the right call and does make phase 1 smaller.

Four caveats on *how* it is specified, not on whether the approach works:
see **M-2**, **S-1**, **S-2**, **S-3** below.

### N-2 (parent-keyed notice orphaned by a terminal parent): closed for the case round 4 found; two adjacent chain shapes still orphan. See **M-1**.

The mass-death case is genuinely fixed. Reproduced: after a simultaneous
lead+worker death, `W.parent` still points at the dead `L` (the re-adopt pass
at `bin/lib/wm-state.py:1001-1019` skips a worker whose own window is already
gone - round 4's diagnosis re-confirmed), and the plan's walk-up resolves `W`
to `""` (wingman). That is the correct floor and it is reached.

"Floored at wingman" is also a real terminating condition. Against a 2-cycle
(`A.parent=B`, `B.parent=A`, both `died`), the transcribed loop terminated on
the `guard < 5` cap and returned `""` - no infinite loop, no crash, exit 0. The
cap is doing real work and is correctly generous relative to the depth-2
architecture.

### N-3 (notice not surfaced by the owner's own watcher): closed. No double-surfacing.

Verified against the code rather than inferred:

- All five wingman-only exits are `[ -z "$OWNER" ]`-gated -
  `self_pane_check` (`bin/watch-fleet:327`), the outage block (`:1119`), the
  usage-limit block (`:1201`). A lead's cycle cannot reach any of them, so it
  reaches the `needs-attention` check at `:1334-1335` on every poll. The
  plan's "unconditional for a lead" claim is exact.
- For wingman, the at-most-one-further-poll deferral the plan documents is
  the correct characterization, and the deferral is genuinely bounded: the
  scratch file is only consumed inside `fire()`, so an earlier wingman-only
  exit cannot swallow it.
- **No double-surfacing.** `fire()` writes `$EXITFILE` and `exit 0`s, so a
  cycle fires at most once by construction; when both `$attention` and the
  notice are present they fold into one wake. The death event and the
  abandonment notice are complementary content in that one wake, not two
  announcements of the same thing.
- `fire ""` is safe: `wm_state group-attention` on empty input returns empty
  with rc 0, and the ack loop is guarded by `[ -n "$id" ]`. The plan's "print
  one extra stdout reason line" is load-bearing, not cosmetic - without it a
  notice-only fire emits *no* stdout at all, and stdout is the wake's trigger
  channel. Keep that clause explicit when this is implemented.

### N-4 (`set -u` crash on `$_key`): closed, and it matches the existing convention exactly.

Confirmed at `bin/watch-fleet:155-170`: `_key` is assigned only inside
`[ -n "$OWNER" ]`, and both branches already define
`PIDFILE`/`WAKEFILE`/`BEATFILE`/`EXITFILE`/`SPURCOUNTFILE`/`RUNFILE` for
precisely this reason. Adding `NOTICEFILE` to both branches is the same shape
as the six variables already there, and the bare-name-for-wingman /
`-$_key`-for-a-lead split matches the established convention. No read of
`$_key` survives outside that block. The writer computing the identical name
from the resolved owner value closes it by construction. Nothing further
needed.

### Round 4's five should-fix items: all five addressed.

- **S-1** (staleness below the send-lock ceiling): fixed correctly.
  `WM_SEND_LOCK_WAIT`'s 45s default is confirmed
  (`origin/main:bin/lib/common.sh:658`), the new default exceeds it, and the
  invariant is stated so it cannot be silently re-tuned back below. Test 4
  names the corrected threshold.
- **S-2** (prune ordering): fixed. Both sweep passes now run before
  `wm_state prune "$@"`, which is what keeps round 3's `--owner` scoping from
  being nullified. Confirmed the mechanism it protects against is real:
  `cmd_prune` (`bin/lib/wm-state.py:1188`) keeps out-of-scope records, so a
  post-prune pass 1 would indeed find nothing and fall through to the always
  fleet-wide pass 2.
- **S-3** (sidecar-first): fixed, with the correct rationale and all three
  writer sites named. `bin/spawn-crew:522-523` verified against `origin/main`.
- **S-4** (payload-move ordering stated once): fixed. Stated once,
  unambiguously, with the "nothing later ever touches either durable path"
  invariant, and step 7 reduced to deleting the leftover and `rmdir`. Test 15
  guards the regression.
- **S-5** (test gaps): tests 12-15 cover N-1, N-2, N-3 and the S-4 ordering.

### Round 4's four nice-to-haves: all four addressed.

Third mutator named; the `inflight-` seizure rationale stated; the no-tmux
window-check case confirmed; the `$id`/`$_id` inconsistency gone with the
deleted snippet.

---

## Must-fix

### M-1. The parent-chain walk's terminal predicate is narrower than the plan's own step-2 reachability predicate, and re-orphans the notice in two reachable chain shapes

The plan states two different definitions of "this member cannot receive
anything" in the same document:

- The sweep's step 2, for a **sender**: missing record, `stood-down`, `died`,
  **or `done` with no live window**.
- `resolve_notice_owner`, for an **ancestor**:
  `crew_get(parent).status in (stood-down, died)` - nothing else.

The narrower one re-creates exactly N-2's failure mode. Transcribed literally
and executed:

| chain shape | resolved key | correct? |
|---|---|---|
| `W.parent=L`, `L` died (simultaneous mass death) | `""` (wingman) | yes |
| `W.parent=L`, **`L`'s record absent** | **`L`** | **no - orphaned** |
| `W.parent=L`, **`L` is `done`** | **`L`** | **no - orphaned** |
| `A.parent=B`, `B.parent=A`, both died | `""` (guard cap) | yes |

Both bad rows write to `pending-notices-<L>`, which no live watcher reads -
identical to the defect N-2 was raised for.

**The missing-record row is reachable through a supported invocation.**
`cmd_prune` scopes by `parent_of(r) != owner` (`bin/lib/wm-state.py:1188`), so
`bin/crew-prune --owner ""` removes a closed top-level lead while keeping its
closed workers (whose parent is that lead, hence out of scope); the same
asymmetry arises from `--older-than-days`. Round 3's S-B fix exists precisely
to make scoped prunes usable, so this is a state the design invites.

**The `done` row is a real window too.** `done` is never re-adopted away
(`bin/lib/wm-state.py:1015` only re-parents from `("died", "stood-down")`), and
a `done` lead has finished its engagement and will not arm another watcher
cycle. Wingman normally reaps it to `stood-down` in the same turn, but the
notice can be written inside that window - and if wingman itself is not
running, `done` persists indefinitely.

**Fix (one predicate, no new machinery):** make the walk-up use the *same*
reachability predicate step 2 already defines - treat an ancestor as terminal
when its record is missing, or its status is `stood-down`/`died`, or it is
`done` with no live window - and keep walking to its own parent, still floored
at `""`. State it as one predicate used in both places, so the two cannot drift
apart again. Everything else about the walk (the guard cap, the wingman floor,
the reasoning for why wingman is the correct floor) is correct as written.

### M-2. The sweep's synchronous live-sender send sits inside the poll loop, starves the watcher's own liveness beacon, and is the first send site in `bin/watch-fleet` that acts outside its owner scope

Three problems, one deletion fixes all three.

**(a) Beacon starvation.** `bin/watch-fleet` touches `$BEATFILE` exactly once
per iteration, at the top of the loop (`:807`), and `cycle_live()` requires the
beacon to be fresher than `GRACE` (default **30s**, `:188`). Step 6's direct
`wm_tmux_send_message` to a live sender can occupy up to `WM_SEND_LOCK_WAIT` =
**45s** on a contended pane lock alone
(`origin/main:bin/lib/common.sh:658-671`), before any typing happens - and the
sweep does this **per abandoned message, serially, fleet-wide**, with no
per-poll bound. One contended send is already enough to exceed the grace.

Consequences, both of which this repo has an incident history for:

- A redundant arm landing in that window evaluates `cycle_live` as false,
  skips the `healthy` branch (`:631-643`), and **claims a second cycle for the
  same owner** (`:646`) - two watchers, two fleet-wide scans, and a `$PIDFILE`
  the first one deletes out from under the second when it eventually fires.
  Wingman arms a cycle at the end of every turn, so any pilot message during a
  blocked sweep triggers this.
- `--classify` on a live pid with a stale beacon returns
  `spurious ... hung-or-stale-pidfile` (`:407-410`) and increments the
  consecutive-failure budget - a manufactured watcher-failure incident. See
  `docs/analysis/2026-07-28-watch-fleet-spurious-deaths-and-dropped-wakes.md`
  for how that classification is read.

The hazard pre-exists at `:924`/`:928`, so this is an amplification rather than
a new class of bug - but the plan turns "one send per member per poll, inside
the owner-scoped loop, gated on `PANE_STABLE`" into "one send per abandoned
message, fleet-wide, ungated".

**(b) No stability gate.** The existing block's own comment states the
invariant: *"a pane mid-repaint is a member mid-turn, and typing into it both
risks interleaving with its own output and can't be confirmed anyway."* The
plan explicitly takes no new `PANE_STABLE`/`PANE_TEXT` capture in phase 1, so
the sweep's notify cannot honor that invariant - it is a blind send into a
live, working member's pane. (`#214`'s `C-c` exposure is disclosed; this
mid-turn interleaving is a separate consequence and is not.)

**(c) Out of scope.** All four existing `wm_tmux_send_message` sites
(`:924`, `:928`, `:974`, `:1077`) live inside the per-member loop that opens
`for _row in $(wm_state crew-list --owner "$OWNER" ...)` at `:867` and closes
at `:1105` - every keystroke `bin/watch-fleet` sends today is owner-scoped. The
scan is deliberately fleet-wide, so its notify would have a lead's watcher
typing into panes outside its own team, bypassing the team guardrail that
`bin/crew-say` enforces at the command layer.

**Fix - delete the direct send from the sweep.** Always queue the notice into
the live sender's own outbox (with its sidecar, sender recorded as empty),
which the plan **already specifies** as step 6's fallback, and let the existing
stability-gated, claim-protocol-governed redelivery path deliver it on the
sender's own owner's next poll. This:

- removes every blocking call from the scan, closing (a) outright;
- honors the `PANE_STABLE` invariant for free, closing (b);
- keeps the scan scope-neutral (writing a file, not keystrokes), closing (c);
- **removes a send site from `#214`'s inherited surface instead of adding
  one**, which simplifies the sequencing note the plan carries for `#214`;
- makes phase 1 smaller.

The only cost is notification latency of roughly one poll interval, against a
mechanism whose current worst case is "never".

---

## Should-fix

### S-1. Where the scan sits in the loop is unspecified, and `fire()` exits the process

`fire()` ends in `exit 0` (`bin/watch-fleet:803`), so **anything placed after
the attention check never runs on a firing poll** - and the poll that detects a
death is, by definition, a firing poll. Appending the scan next to the
`NOTICEFILE` change at `:1334` (the natural place, since that is the other
block being edited) therefore defers every death-path sweep to the next armed
cycle, which depends on the owning session being woken and taking a turn.

Placement also interacts with the `wm_tmux has-session` gate at `:844`. Put the
scan **outside** it: `bin/watch-fleet` keeps polling when the tmux server is
gone, and a scan inside the gate would be dead in exactly that scenario.

Given N-1 was itself "the plan names the hook but never says what triggers it",
leaving the placement to the implementer one round later is the same gap in a
different coat. Pin it: **near the top of the loop body, after the beacon
touch, before the `wm_tmux has-session` block, and unconditionally on
`$OWNER`.**

**Related limitation to state, not to fix here.** The scan keys on roster
status, and roster status is only updated by a reconcile that both
`bin/crew-list` and `bin/watch-fleet` gate on `tmux has-session`. Per
`docs/analysis/2026-07-30-tmux-server-death-and-reconcile-blind-spot.md`
(Defect 2, confirmed and unfixed on `main`), a whole-tmux-server death leaves
every member reading its last self-reported status - so the scan sees no
terminal member and sweeps nothing, and `crew-prune` pass 1 is blind for the
same reason. That is the largest possible mass abandonment, and it is exactly
the case the plan calls its highest-value scenario. Fixing the blind spot is
out of scope, but the plan currently asserts the scan is "the robust backstop
that does not depend on catching the exact right moment" without qualification.
One sentence naming this inherited limitation keeps that claim honest.

### S-2. Concurrent sweeps of the same outbox are ungated, so a message is announced twice

Making the scan unconditional in every watcher turns a single-sweeper
assumption into a multi-sweeper one. The plan gates the **claim** protocol on
"the rename's own exit status" but specifies no equivalent gate for the sweep;
its steps read as move (4), log (5), notify (6), with nothing keyed on whether
the move succeeded.

Reproduced with two concurrent processes running the plan's step sequence
against one outbox directory:

```
=== audit log ===
1785449134 abandoned W 1700000000-1.msg by=watcherA
1785449134 abandoned W 1700000000-1.msg by=watcherB
=== notices ===
NOTICE sent by watcherA for 1700000000-1.msg
NOTICE sent by watcherB for 1700000000-1.msg
```

Two notices to the same sender and two audit lines for one message - and the
audit log is the plan's own durable record of truth. Re-run with the payload
move performed first and **gated on its exit status**:

```
LOST RACE A
=== audit log ===
abandoned W 1700000000-1.msg by=B
=== notices ===
NOTICE by B
```

**Fix:** state that each file's sweep is claimed by its move to the durable
location and gated on that move's exit status, exactly as the claim protocol
already is - a lost race skips the file silently. This composes with S-4's
move-before-pointer rule rather than conflicting with it: both want the move
first.

### S-3. The scan's per-directory `crew-get` is the wrong shape - measurably, and it fails dangerously

Two problems in one line
(`_orec="$(wm_state crew-get --id "$_oid" 2>/dev/null)"`):

**Cost.** `wm_state` is `uv run --no-project --quiet …`. Measured on this host,
10 samples each:

| operation | cost |
|---|---|
| one `wm_state crew-get` | **140 ms** |
| one `crew-list --all --json` + parse (constant in outbox count) | **149 ms** |
| the plan's scan, 3 pending directories | **630 ms** (≈210 ms per pending dir) |

The plan's cost argument - *"a swept directory is empty on the next poll, so it
costs one directory listing and one `crew-get` and nothing else"* - is true only
for the transient terminal case. It never considers the state that actually
persists: a **live** member with an undeliverable pane, which is the very
condition that queues outbox messages in the first place. That directory is
never emptied by the scan, so its ~210 ms is paid every poll, in every watcher,
for as long as the member stays undeliverable. Four watchers × one stuck outbox
= ~0.84 s of process startup every 5 s, indefinitely, to re-derive "still
pending, still live". The per-directory form is already worse than a flat
fleet-wide read at a single pending directory.

**Fail-dangerous conflation.** `2>/dev/null` plus "empty status" makes a
*failed lookup* indistinguishable from *no record*, and the plan's `case` maps
empty to `sweep … orphaned`. A transient `wm_state` failure therefore sweeps a
**live** member's outbox and tells its sender the message was abandoned while
the target is alive and would have received it. (Roster reads themselves are
torn-read-safe - `write_json` is `mkstemp` + `os.replace` - so this is about
process-level failure, not JSON corruption.)

**Fix, one change for both:** take **one** fleet-wide roster read per poll,
only when the fork-free directory scan finds at least one pending directory,
and derive every id's status from it; if that read fails, skip the scan for the
poll rather than treating the fleet as terminal. `crew-list --all --json`
already exists, so the plan's "no `bin/lib/wm-state.py` changes required" claim
survives intact.

### S-4. `fire()`'s read-then-truncate of the notice file loses a concurrently appended notice

The plan specifies `fire()` as "fold any content into a new `## Abandoned
messages` section of `$WAKEFILE` … and truncate the file". Read literally
(`cat "$NOTICEFILE" >> "$WAKEFILE"; : > "$NOTICEFILE"`), any append landing
between the read and the truncate is destroyed with no trace. The appenders are
every watcher's scan; the reader is the one watcher owning that key. Reproduced:

```
wake file:   notice-1
notice file after fire: []          # notice-2 appended mid-window: gone
```

Rename-aside, same timing:

```
wake file:   notice-1
notice file left: [notice-2]        # preserved; the next poll's -s check fires on it
```

The window is small, but permanent silent loss of a queued message is the exact
failure this plan exists to eliminate, and the plan states the channel "never
los[es] it".

**Fix:** `mv "$NOTICEFILE" "$NOTICEFILE.reading"` first, fold in the renamed
copy, remove it. Appenders using `>>` either wrote to the renamed inode (read
anyway) or recreate the original path (picked up next poll). One line.

---

## Nice-to-have

- **Stale citation.** The plan cites `bin/lib/common.sh:632` for
  `WM_SEND_LOCK_WAIT`. That is the working tree's line number; on
  `origin/main` it is `:658`, which is what round 4 cited. `common.sh` is one
  of only two files that differ from `origin/main`, and the plan's own
  "Investigation performed" section notes the checkout is two commits behind -
  so this one citation should be re-pinned to `origin/main`.
- **Outbox directories accumulate forever.** The plan already notes that
  `sent-` entries are never removed, so `rmdir` rarely fires. Combined with
  the new per-poll scan, that means the scan's fixed cost grows monotonically
  with fleet history and never shrinks. `ls … | grep -v '^sent-'` is two forks
  per directory per poll per watcher; a shell-glob emptiness test is zero.
  Worth specifying the fork-free form since this is now a hot path.
- **A notice-only fire writes an empty `## New events` section.** Harmless, but
  worth one sentence so the first person to see that wake file does not read it
  as a bug.

---

## Testing strategy

Tests 1-15 are at the right level and cover the death, standdown, prune and
mass-death paths concretely. Four additions for the findings above:

16. **M-1:** resolve the notice owner for a member whose parent record is
    absent, and for one whose parent is `done` with no live window; assert both
    floor to wingman rather than to the unreachable id.
17. **M-2 / S-2:** two watcher processes sweeping one outbox concurrently -
    assert exactly one notice and exactly one `outbox-abandoned.log` line.
18. **S-1:** a poll on which the attention check fires *and* a terminal outbox
    exists - assert the sweep happened on that same poll (guards the placement
    against `fire()`'s `exit 0`).
19. **S-4:** append to the notice file while `fire()` is folding it into the
    wake file; assert the appended notice still surfaces on a later poll.

Test 12's N-1 assertion should also assert the scan runs with the tmux-session
gate absent, so the placement in S-1 stays pinned by a test rather than by
prose.

---

## Standing constraints

- **Phase 1 complete and independently mergeable:** yes once M-1 and M-2 are
  applied. As written, M-1 leaves two reachable paths where a notice is
  written to a file nobody reads, which is the same "not a guarantee"
  condition round 4 blocked on.
- **Phase 2 stays a noted follow-up:** yes. The backstop and the
  `wm_outbox_try_redeliver` extraction remain unimplemented and clearly
  sequenced, and S-1 (round 4) correctly pre-empts the duplicate-delivery bug
  phase 2 would otherwise introduce.
- **Blast radius:** appropriate. Seven files in phase 1, no
  `bin/lib/wm-state.py` changes, and both must-fix items shrink it further -
  M-2 by deleting a send site rather than adding one, M-1 by collapsing two
  liveness predicates into one.
- **`#214` overlap:** accurately stated. Verified again that
  `bin/watch-fleet`'s four `wm_tmux_send_message` sites are `:924`, `:928`,
  `:974`, `:1077`. Adopting M-2's fix removes the new phase-1 send site the
  plan currently hands to `#214`'s implementer, which is a strict simplification
  of that hand-off.

## Open Questions

None from this review. The plan's own two open questions parse cleanly and both
recommendations remain correct.
