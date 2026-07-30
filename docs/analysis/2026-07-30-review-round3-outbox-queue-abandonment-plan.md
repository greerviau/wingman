# Plan review, round 3: outbox queue abandonment fix (issue #169)

**Date:** 2026-07-30
**Plan reviewed:** `docs/plans/2026-07-30-outbox-queue-abandonment-fix.md` (revised after rounds 1 and 2)
**Prior rounds:** `docs/analysis/2026-07-30-review-outbox-queue-abandonment-plan.md`,
`docs/analysis/2026-07-30-review-round2-outbox-queue-abandonment-plan.md`
**Issue:** [greerviau/wingman#169](https://github.com/greerviau/wingman/issues/169)
**Verdict:** **Request changes.** Four must-fix, five should-fix. Round 2's
five must-fix items are all genuinely closed - three of them verified by direct
reproduction, not by reading. What remains is new: three defects the round-2
fixes themselves introduced or left unspecified, plus one incorrect claim about
the `#214` overlap that this review was explicitly asked to confirm and cannot.

---

## Summary

This is a substantially better plan than round 2's. Every one of round 2's five
must-fix items is closed by the right mechanism, and I verified the three
mechanical ones by building the protocol the plan specifies and running it
rather than reasoning about it:

- **M2 (selector must exclude `inflight-`): closed.** Reproduced - with
  `grep -v '^sent-' | grep -v '^inflight-'` a live in-flight file is invisible
  to the selector and only the plain pending file is claimed.
- **M3 (staleness keyed on `mv`-preserved mtime): closed, and by the better of
  the two options round 2 offered.** I re-confirmed `mv` preserves mtime
  (back-dated a file to 600s old, `mv`'d it, mtime unchanged), then ran the
  plan's reclaim against an `inflight-<old-epoch>-...` file *whose mtime was
  back-dated to the original queuing time*: it reclaimed on the embedded epoch
  and the misleading mtime was never read. A crashed claimant's file is
  correctly reverted to plain and re-selected on the same poll. Embedding the
  epoch in the name makes `mv`'s mtime behaviour genuinely irrelevant.
- **`wm_outbox_basename`: correct, including the subtlety it exists for.**
  `${1#inflight-*-}` is a *shortest*-match strip, so with a digits-only
  `date +%s` epoch it removes exactly `inflight-<epoch>-` and stops at the first
  `-` after it. Verified in both `bash` and POSIX `sh` against the real filename
  shape (`<epoch>-<pid>.msg`, from `bin/crew-say:90`, `bin/crew-ask:306`,
  `bin/spawn-crew:522`). All three queueing sites, and no others, are covered -
  I grepped the whole of `bin/`, `hooks/`, and `playbooks/`; there are exactly
  three writers and one reader of `outbox/`.
- **M5 (round 1's shared-`PANE_STABLE` corruption leaking into phase 1):
  closed, genuinely.** Phase 1 takes **no** new capture: the claim protocol is
  applied in place using the loop's existing `:887` snapshot, so the four later
  consumers of those globals (`:942`, `:963`, `:995`, `:1049`) are untouched.
  The one new capture anywhere in phase 1 is the `done`-loop's, and the
  disjointness argument holds - `LIVE_STATES` is `("working", "blocked",
  "review", "stalled")` and `done` is in `TERMINAL_STATES`
  (`bin/lib/wm-state.py:127`/`:131`), so the main loop can never iterate a
  `done` id.
- **M4 (notice pointed at a file the sweep deletes): closed for the sweep
  path.** Moving rather than deleting is right, and no step deletes anything an
  earlier pointer names - within the sweep. It is **not** closed for the
  redelivery path, which now has the same defect for a different reason (M-A
  below).
- **The should-fix items** (S1 cascade coverage, S2 `done`, S4 `died`
  recoverability rationale, S5 second-level sweep stated once, S6 corrected
  test, S7 `crew-ask` records untouched, S8 flag parsing) are all addressed in
  the text. S2's fix is incomplete (S-A below) and S8's is under-specified
  (S-B); the rest are fine.

Empirically I re-confirmed the plan's own corrections: live
`$WINGMAN_HOME/outbox/` holds exactly one `sent-` file and one empty orphaned
directory, and the checkout is 2 commits behind `origin/main` (`51fd782`,
`00afb82`), so every citation below is read from `git show origin/main:<path>`.

What is left:

1. **The multi-line redelivery pointer dangles under the new three-state
   protocol** - M4's defect, reproduced, in the path M4 did not look at.
2. **The `wake`-mode channel is still not a guaranteed delivery** - a single
   global scratch file feeding per-owner wake files, surfaced by only one of
   the six code paths that write a wake file, and specifically not by the one
   that runs on a correlated mass death.
3. **The sweep queues its own notice into an outbox that is itself already
   abandoned**, in the plan's primary scenario (a lead cascade standdown).
4. **The `#214` claim this review was asked to confirm does not hold** in
   either of the two directions the plan asserts it.

---

## Verification performed

Read from `origin/main`, not the working tree: `bin/watch-fleet` (`:355-440`
`--classify`, `:758-803` `fire()`, `:806-846` loop head and the reconcile/
death-flip call site, `:867-883` population filter, `:887` the single snapshot,
`:898-933` the outbox block, `:912-931` selector and the two send branches,
`:1105-1200` the outage exits, `:1334` `needs-attention`); `bin/lib/common.sh`
(`wm_pane_snapshot`, `wm_tmux_pane_text`); `bin/lib/wm-state.py`
(`LIVE_STATES`/`TERMINAL_STATES`/`ATTENTION_STATES` at `:127`/`:131`/`:136`,
`cmd_crew_list:929-952`, `cmd_reconcile:959+`, `cmd_needs_attention:1557+`,
`cmd_crew_set`'s `announced` gate at `:744`); `bin/crew-say:55-96`;
`bin/crew-ask:140-175`, `:280-310`; `bin/spawn-crew:505-530`;
`bin/crew-standdown` (all 101 lines); `bin/crew-prune` (all 30 lines);
`tests/dialog-delivery-refusal.test.sh`.

Executed directly:

- `mv`/mtime: back-dated mtime 600s, `mv` within a directory, re-stat - mtime
  unchanged. Round 2's finding re-confirmed independently.
- `wm_outbox_basename` as written in the plan, in `bash` and POSIX `sh`,
  against plain / `sent-` / `inflight-<epoch>-` / doubly-prefixed names.
- A literal implementation of the plan's phase-1 claim protocol (selector,
  embedded-epoch reclaim, claim-gated-on-`mv`, resolve-to-`sent-`) run against
  a scratch outbox in three cases: a crashed claimant's stale file, a live
  in-flight file alongside a plain one, and a multi-line payload. The first two
  behave exactly as the plan says. The third is M-A below.
- Live `$WINGMAN_HOME/outbox/` and `bin/crew-list --tree`.

---

## Must-fix

### M-A. The multi-line redelivery pointer dangles under the three-state protocol (M4's defect, in the path M4 did not cover)

Today's code makes the multi-line pointer valid by *construction*: it renames
the file to its final resting name **before** composing the pointer, and the
pointer names that final path (`bin/watch-fleet:917-925`):

```sh
_obsent="$_obdir/sent-$_obfile"
mv "$_obpath" "$_obsent" 2>/dev/null
_obmsg="Queued message for you: read $_obsent and act on it now - ..."
wm_tmux_send_message ... "$_obmsg" || mv "$_obsent" "$_obpath" 2>/dev/null
```

The rename-to-`sent-` *is* the claim in the current design. The plan splits
that single rename into two (`plain -> inflight-<epoch>- -> sent-`) and never
says which of the two paths the pointer names. Neither answer is correct as
specified:

- **Pointer names the in-flight path:** the plan's own "on successful delivery,
  rename to `sent-<ts>-<pid>.msg`" moves the file out from under it. The member
  reads a path that no longer exists.
- **Pointer names the eventual `sent-` path:** during the entire in-flight
  window - which is exactly when the member is being told to read it - the file
  is at the `inflight-` name. A member that acts promptly (the intended
  behaviour; the message says "act on it now") hits a missing file.

Reproduced with the plan's protocol implemented literally:

```
poll: selector picked: '1785289600-444.msg'
  claimed -> inflight-1785446453-1785289600-444.msg
  multi-line: message sent to pane = 'read .../outbox/m1/inflight-1785446453-1785289600-444.msg and act on it now'
  delivered; resolved -> sent-1785289600-444.msg
  >>> pointer target still exists? NO - DANGLING
```

This is the same failure mode round 2's M4 caught in the sweep, arriving in the
redelivery path because the fix for M4 was scoped to the sweep only. It is not
a corner case: multi-line is the common shape for exactly the messages worth
salvaging (a relayed human answer, a `crew-ask` prompt pointer, a spawn
objective), and `bin/crew-say` writes the *full payload* into the outbox file
(`:90`), so every long relayed answer takes this branch.

The plan must state, explicitly, what path the multi-line pointer names and why
that path is stable from the moment the pointer is typed until the member reads
it. The cleanest resolution consistent with M4's own reasoning is to stop using
a rename-tracked path as a pointer target at all: resolve the payload to a
durable location at **claim** time (the analogue of M4's
`outbox-abandoned/<id>/`), point at that, and let the `inflight-`/`sent-`
states track only the queue's own bookkeeping. Whatever is chosen, the plan's
testing strategy needs a case that asserts the delivered pointer resolves to an
existing file *after* the redelivery has been resolved - nothing in tests 1-10
does.

### M-B. The `wake`-mode channel still does not guarantee the notice reaches its owner

The move off the roster `summary` field and onto the wake file is the right
call, and it fixes all three of round 2's M1 sub-defects (no fallback-chain
preemption, no 60-char truncation, no dependence on `announced` advancing).
But the specific mechanism - one scratch file at `$WM_HOME/pending-wingman-
notices`, read and truncated inside `fire()` - has two defects of its own.

**B1. One global scratch file feeds N per-owner wake files.** `$WAKEFILE` and
`$EXITFILE` are keyed per owner (`bin/watch-fleet:158-167`,
`wake-$_key`/`watch-exit-$_key`) precisely because wingman's `--owner ""`
watcher and every lead's `--owner <lead-id>` watcher run **concurrently**. The
proposed scratch file is not keyed at all. So whichever watcher calls `fire()`
first consumes the file and truncates it - and it writes the content into *its*
owner's wake file. A notice appended by wingman's watcher can be swallowed into
a lead's wake file and never reach wingman.

This is not only a narrow interleaving window. The death flip in
`cmd_reconcile` (`bin/lib/wm-state.py:983-999`) is **fleet-wide** - it iterates
the whole roster with no owner filter - while `needs-attention`
(`bin/watch-fleet:1334`) is **owner-scoped**. So a watcher routinely flips, and
would sweep, a member outside its own scope, and then does *not* fire for it.
The notice sits in the shared file for an unbounded time, during which any
other owner's `fire()` will take it.

Fix: key the scratch file exactly like `$WAKEFILE`
(`$WM_HOME/pending-notices-$_key`), and pass the sweeping watcher's own owner
key into `wm_outbox_sweep_abandoned`'s `wake` mode.

**B2. `fire()` is only one of six exit paths that write a wake file.** The
others write `$WAKEFILE` and `fire\n` to `$EXITFILE` directly and `exit 0`
without ever entering `fire()`:

- `remote-control-dropped` (`:824-834`)
- `outage-detected` (`:1129-1146`)
- `outage-cleared` (`:1148-1177`)
- the two usage-limit transitions (`:1300-1322`)

All five are evaluated **before** the `needs-attention`/`fire()` path at
`:1334`. The consequence is precise and bad: on a correlated mass death - many
members dying at once, many outboxes swept in one poll, the single highest-value
case this whole plan exists for - the poll exits via `outage-detected`, and the
freshly-appended notices are not surfaced. The plan's stated guarantee ("the
poll that runs the death-path sweep is ... the same poll that calls `fire()`,
so the notice rides the already-guaranteed-to-fire death event") does not hold
there, nor in the cross-owner case in B1.

Fix: factor "if the pending-notices file is non-empty, emit the
`## Abandoned messages` section into `$WAKEFILE`, print the stdout line, and
truncate" into one small function, and call it from **every** wake-file-writing
exit, not only `fire()`.

Two things about the mechanism that I checked and that *are* fine: an extra
stdout reason line cannot confuse `--classify` (it reads `$EXITFILE` only,
`:372-380`, and the token stays `fire`), and `died` is in `ATTENTION_STATES`
(`bin/lib/wm-state.py:136`), so an in-scope death does fire on its own poll.

### M-C. The sweep queues its notice into an outbox that is itself already abandoned

Step 4, for a known crew-id sender: "attempt direct delivery via
`wm_tmux_send_message`; on failure or no live window, queue the notice into
**that sender's own** outbox."

There is no check that the sender is still a live member. In the plan's own
primary scenario it is guaranteed not to be. `bin/crew-standdown` cascades:
`AFFECTED` is the target followed by every descendant (`:25`), and the loop
(`:29-92`) kills each window and - per the plan's S1 fix - sweeps each id right
after its own `kill-window`. Stand down a lead `L` with worker `W`:

1. `L` is processed first: window killed, outbox swept.
2. `W` is processed: window killed, outbox swept. `W`'s queued message came
   from `L` (the overwhelmingly common case - a lead is what talks to its
   workers), so the sidecar says `L`.
3. `L`'s window is gone, so the notice is queued into `outbox/L/` - which was
   swept one iteration ago and will never be serviced again.

Reversing the cascade order does not help: `L`'s window is killed in its own
iteration either way, and delivering to a member being stood down is pointless
regardless. The notice is not permanently lost (step 3's log append always
happens, and a future `crew-prune` pass 1 would eventually sweep `outbox/L/`),
but `crew-prune` is explicitly not part of the normal loop - and "the sender
learns *immediately* rather than waiting on an indeterminate future
`crew-prune`" is the plan's own stated justification for sweeping at the death
flip (S4). This path violates that justification in the most common case.

Fix: before queueing into a sender's outbox, check that sender's roster status;
if it is terminal (`done`/`died`/`stood-down`) or its record is gone, skip the
queue and route the notice through the call site's `<notify-mode>` channel
(`stdout` or `wake`) exactly like the wingman/`unknown` case. This is one
`crew-get` and one branch.

### M-D. The `#214` non-overlap claim does not hold, in either direction

The plan asserts that taking round 2's M5 recommendation "keeps phase 1
entirely out of the file `#214` also edits in the one place that mattered for
sequencing: phase 1 now only *adds* a small, self-contained block to
`bin/watch-fleet`'s existing outbox section rather than restructuring it," and
separately that phase 2 "is also the phase that introduces `#214`'s fifth send
site."

One half is true and worth keeping: phase 1 does not touch
`bin/lib/common.sh`'s `wm_tmux_send_message`/`wm_tmux_pane_ready` internals,
which is a real de-risking. The rest is wrong:

1. **Phase 1 does not merely "add a block" - it rewrites the exact lines `#214`
   changes.** `#214`'s accepted scope is settled by human decision
   (`docs/analysis/2026-07-30-tmux-clear-key-interrupt-and-silent-denial.md`,
   "Settled (human decision, 2026-07-30)"): generalize `wm_tmux_pane_ready` to
   a third "busy" refusal code, **and** update every call site with its own
   retry/backoff handling - explicitly including "`watch-fleet`'s four send
   sites". Two of those four are `bin/watch-fleet:924` and `:928` - the two
   sends *inside* the outbox block that phase 1 restructures (new selector, new
   claim rename, new revert, new pointer). That is a direct line-level
   collision, and `#214`'s analysis states plainly that an implementation
   missing any call site "is incomplete." The plan's own "Risks and follow-ups"
   bullet concedes exactly this collision, contradicting the `#214` section
   three hundred lines earlier. One of the two has to go.
2. **Phase 1, not phase 2, introduces a new `wm_tmux_send_message` call site.**
   `wm_outbox_sweep_abandoned` step 4 calls `wm_tmux_send_message` to notify a
   live sender directly, and that function lives in `bin/lib/common.sh` in
   phase 1, invoked from `bin/crew-standdown`, `bin/crew-prune`, and
   `bin/watch-fleet`. That is a new send site in phase 1, and it is one of the
   more dangerous ones for `#214`'s purposes: it fires a blind `C-c` into a
   *live, working* sender's pane (a lead or a peer that is by definition still
   running), at a moment nothing has gated on that sender's execution state -
   which is `#214`'s defect A verbatim.

Fix: state the real overlap plainly (phase 1 rewrites `:914-931`, which
contains two of `#214`'s four `watch-fleet` send sites), and correct the
fifth-send-site claim so `#214`'s implementer knows the sweep's notify call
needs the new busy-refusal treatment in phase 1, not phase 2. No design change
is needed - only an accurate statement, which is what the sequencing depends on.

---

## Should-fix

### S-A. `done` is still permanently unreachable when its window is gone

The S2 fix (a small `done`-status redelivery loop) closes the case it names,
and the disjointness argument for its own capture is sound. But it depends on
the member having a live window (`wm_tmux_windows | grep -qx "$_win"`), and
`done` is not in `LIVE_STATES` - so `cmd_reconcile` **never** flips a
windowless `done` member to `died` (`bin/lib/wm-state.py:127`, `:990`). A
`done` member whose window disappears without a standdown (a window killed by
hand, a botched takeover, a partial tmux-server loss) therefore:

- is excluded from the main loop's population filter (`:880`);
- is skipped by the new `done`-loop (no window);
- is explicitly skipped by `crew-prune` pass 1 ("for every roster id whose
  status is ... `done`, skip");
- is not reachable by pass 2 (its roster record still exists).

Its outbox is unreachable forever - the exact defect this plan exists to close,
left open for one of the three terminal statuses the Problem statement names.

Cheapest complete fix: in `crew-prune` pass 1, skip `done` only while its
window is live; a windowless `done` member is unreachable by redelivery and
belongs in the sweep population.

Related, smaller: derive the main-loop and `done`-loop populations from **one**
`crew-list --json` read, not two. Two reads a fraction of a second apart can
both contain the same id if its status changes in between, which is the one way
the disjointness argument the plan leans on can fail.

### S-B. `crew-prune`'s flag scan must accept `--owner=<value>`

The plan fixes S8 by having the wrapper parse `--owner <value>` and `--dry-run`
explicitly. `wm_state prune`'s own argparse accepts `--owner=<value>` as well
as the space-separated form (argparse always does). If the wrapper's scan
handles only the space form, `crew-prune --owner=some-lead` prunes records
scoped to that lead while the two new sweep passes run **fleet-wide** - a
lead-scoped invocation silently sweeping outboxes outside its own team. Specify
both forms. (`--dry-run=true` is not a concern in the other direction:
argparse's `store_true` rejects it outright, so the command fails before
anything happens.)

### S-C. "No concurrency is introduced" in phase 1 is not true

The Phased delivery section states: "No concurrency is introduced - exactly one
process ever polls a given id's outbox throughout phase 1, so round 1 and round
2's shared-state findings do not apply to it at all."

Polling, yes. But phase 1 adds three *other* processes that mutate the same
directories: `bin/crew-standdown` and `bin/crew-prune` both sweep
`outbox/<id>/` while a watcher may be mid-claim on the same id, and the plan
itself acknowledges three concurrent appenders to `outbox-abandoned.log` two
sections earlier. The standdown case is real: `crew-standdown` kills the window
(`:73`) and then sweeps, and a watcher that captured the pane a moment earlier
can be inside its claim/send/revert sequence for that same id. Concretely, if
the sweep's `ls` snapshot lists a plain file that the watcher renames to
`inflight-` before the sweep's own `mv` runs, that `mv` fails and the message is
neither swept, nor logged, nor notified - silently abandoned again, which is
the bug under repair.

Neither the claim nor the consequence is fatal (the payload survives; a later
prune catches the leftover), but the plan should stop asserting the opposite
and should specify the two cheap defences: the sweep tolerates a `mv` failure
by re-scanning the directory until it is empty or a bounded pass count is
exhausted, and the redelivery's revert/resolve `mv`s already tolerate a
vanished file (they do today, via `2>/dev/null`).

### S-D. The preserved file's name in `outbox-abandoned/<id>/` is ambiguous

Step 2 says the swept file moves to
`$WM_HOME/outbox-abandoned/<id>/<original-filename>`. For an `inflight-` file
that is being swept, "original filename" could mean the decorated name
(`inflight-<epoch>-<ts>-<pid>.msg`) or the `wm_outbox_basename` stem. The
notice's pointer and the log line must name the path that actually results.
Getting this wrong reproduces M4 in the new tree. State it: normalize through
`wm_outbox_basename` on the way in, and derive the pointer from the same
normalized path.

### S-E. Test gaps for the three findings above

Tests 1-10 are otherwise at the right level and cover round 2's gaps properly.
Missing:

- No test asserts a **multi-line redelivery pointer still resolves after the
  redelivery is resolved** (M-A). Test 1 asserts no *second* delivery happens;
  it never opens the path the first one named.
- Test 7 as written ("assert the notice appears in the printed fire-reason
  lines / `$WAKEFILE`") passes under both halves of M-B: a single-watcher test
  never exercises the cross-owner steal, and a test that forces an ordinary
  `fire()` never exercises the outage/usage-limit exits. Add a case with two
  concurrently-armed watchers at different owner scopes, and a case where the
  sweeping poll exits via `outage-detected`.
- Nothing covers M-C (the notice queued to an already-swept sender). Test 6
  (the lead cascade) is one assertion away from it: after standing down the
  lead, assert the worker's abandonment notice actually reached a live channel
  rather than landing in the stood-down lead's own outbox.

---

## Nice-to-have

- `sent-` files are never removed from `outbox/<id>/`, so the plan's `rmdir`
  nice-to-have will essentially never fire for any member that ever had a
  successful redelivery (live state already shows one such directory). Either
  sweep `sent-` files into `outbox-abandoned/` too, or drop the `rmdir` claim
  for that case.
- The three queueing sites still tell the caller "the watcher will retry it
  automatically" (`bin/crew-say:39-41`, `bin/crew-ask:307`,
  `bin/spawn-crew:524`) with no mention of what now happens if the target ends
  first. That promise being unqualified is half of what the issue is about;
  one clause in each is cheap.
- `tests/dialog-delivery-refusal.test.sh:47,73` assert on
  `ls outbox/<id> | grep -v '^sent-'`. Still correct after this change (no
  watcher runs in those tests, so no `inflight-` file can exist), but they
  should gain the `inflight-` exclusion so they keep meaning what they say.
- The `done`-loop needs two consecutive polls before `PANE_STABLE=1`, so it
  can only ever help a `done` member that survived at least `2 x INTERVAL`
  un-reaped. That is exactly its intended population (a crashed or restarted
  orchestrator), but the plan reads as though it is a general safety net; say
  which it is.

---

## Answers to the questions this review was asked

1. **M1 - does the death-path notice genuinely reach wingman now?** Partly. The
   channel choice is right and all three of round 2's specific defects are
   gone. But the mechanism is not a guaranteed delivery: one un-keyed scratch
   file feeding per-owner wake files, surfaced by only one of six wake-file
   writers, and specifically not by the mass-death path - **M-B**.
2. **M2 - selector excludes both `sent-` and `inflight-`?** Yes, closed;
   reproduced. `wm_outbox_basename` is also correct, including its
   shortest-match subtlety, in both `bash` and POSIX `sh`.
3. **M3 - is `mv`'s mtime preservation genuinely irrelevant, and is a crashed
   claimant still reclaimed?** Yes to both, reproduced: reclaim reads only the
   embedded epoch, a back-dated mtime is never consulted, and a stale claim is
   reverted to plain and re-selected on the same poll.
4. **M4 - does any step delete something an earlier pointer references?** Not
   in the sweep - closed. But the *redelivery* path now has the identical
   defect for a different reason - **M-A**, reproduced.
5. **M5 - is phase 1 genuinely no-new-capture, and does it reopen round 1's
   finding?** Yes and no, respectively. Phase 1 takes no new capture at all;
   the loop's single `:887` snapshot is used as-is, so the four downstream
   consumers are unaffected. The `done`-loop's own capture is safe because
   `done` and `LIVE_STATES` are disjoint - verified in `wm-state.py`, not
   assumed. One residual: derive both populations from a single `crew-list`
   read (S-A).
6. **The should-fix items.** S1 (cascade), S4 (`died` rationale), S5 (stated
   once), S6 (corrected test), S7 (`crew-ask` untouched) are properly closed.
   S2 (`done`) is incomplete - **S-A**. S8 (`crew-prune` parsing) is
   under-specified - **S-B**.
7. **Does phase 1 avoid `#214`'s edit path?** It avoids the `common.sh`
   *internals*, which is the valuable half. It does not avoid the overlap: it
   rewrites `bin/watch-fleet:914-931`, which holds two of `#214`'s four
   `watch-fleet` send sites, and it introduces a new `wm_tmux_send_message`
   call site in phase 1 (the sweep's notify), not phase 2 as the plan claims -
   **M-D**.
8. **Anything rounds 1-2 missed?** M-A, M-B(B1 and B2), M-C, S-A, S-B, S-C and
   S-D are new this round. M-A is the one I would rank most likely to ship
   broken, because it looks like settled ground: round 2 closed "the pointer
   names a file that gets removed" for the sweep, and the same sentence is now
   true again for redelivery. M-C is the one most likely to be dismissed as
   theoretical and is in fact the default outcome of a lead standdown.

## Open Questions

None from this review. The plan's own two open questions parse cleanly and both
recommendations remain the right ones.
