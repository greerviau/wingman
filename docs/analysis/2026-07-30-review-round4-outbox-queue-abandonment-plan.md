# Plan review, round 4: outbox queue abandonment fix (issue #169)

**Date:** 2026-07-30
**Plan reviewed:** `docs/plans/2026-07-30-outbox-queue-abandonment-fix.md` (revised after rounds 1-3)
**Prior rounds:** `docs/analysis/2026-07-30-review-outbox-queue-abandonment-plan.md`,
`docs/analysis/2026-07-30-review-round2-outbox-queue-abandonment-plan.md`,
`docs/analysis/2026-07-30-review-round3-outbox-queue-abandonment-plan.md`
**Issue:** [greerviau/wingman#169](https://github.com/greerviau/wingman/issues/169)

**Verdict: request changes.** Three must-fix, five should-fix.

Round 3's M-A, M-C and M-D are **genuinely closed**, and I confirmed the first
two by building and running the protocol rather than reading it. All five of
round 3's should-fix items are addressed. **M-B is not closed** - the redesign
fixed the defects round 3 named and introduced two new ones in the same
mechanism. Separately, this round found one defect no prior round looked for:
the plan's central hook - the death-path sweep - has no specified trigger, and
the only signal available at that call site is routinely consumed by an
unrelated process before the watcher ever sees it.

**Is this converging?** Yes, but it is not converged. Three of the four
round-3 must-fix items closed cleanly and stayed closed under adversarial
probing; the remaining work is confined to two mechanisms (what triggers the
sweep, and how the resulting notice is routed). A fifth round is warranted and
should be scoped to exactly those two. Nothing else in this plan needs to
move.

---

## Disclosure

While building a scratch reproduction I ran `wm-state reconcile` with `WM_HOME`
exported instead of `WINGMAN_HOME` (the state engine reads only the latter -
`bin/lib/wm-state.py:156`). It therefore ran against live state and flipped
three live members' roster records to `died`. No session was harmed and no
window was closed; only the roster entries were wrong. I restored two of the
three directly and asked the third to re-report its own status, which the
`artifact-link-guard` hook correctly prevented me from doing on its behalf.
Recording it here because it is material to how the rest of this review was
produced: every subsequent experiment below ran against an isolated
`WINGMAN_HOME` sandbox, verified as such.

---

## Verification performed

The checkout is 2 commits behind `origin/main`; `bin/watch-fleet`,
`bin/crew-standdown`, `bin/crew-say`, `bin/crew-ask`, `bin/crew-prune`,
`bin/crew-list` and `bin/lib/wm-state.py` are byte-identical to `origin/main`,
so those citations are read from the working tree; `bin/spawn-crew` and
`bin/lib/common.sh` differ and were read from `git show origin/main:<path>`.

**Executed, not read:**

- The plan's phase-1 claim/reclaim/pointer protocol, implemented literally
  (selector, embedded-epoch reclaim, claim-gated-on-`mv`, the new
  `outbox-delivered/<id>/<stem>` durable copy, resolve-to-`sent-`, and the
  sweep with its bounded re-scan), run against four cases: multi-line with a
  successful send; multi-line with a failed send, revert, and successful
  re-claim on the next poll; a failed send followed by a sweep; and a sweep
  over a live `inflight-` file.
- `wm_state standdown` against a sandbox lead/worker roster, to establish when
  the cascade actually marks statuses relative to `bin/crew-standdown`'s loop.
- `wm_state reconcile` against a sandbox roster in three configurations:
  simultaneous lead+worker death, sequential (lead first, worker still live),
  and the `bin/crew-list` invocation shape.
- `set -u` scoping of `bin/watch-fleet`'s `$_key`, and `tr -c` sanitization of
  an empty owner string.

---

## Round 3's four must-fix items

### M-A (dangling multi-line redelivery pointer): closed. Reproduced stable end to end.

The fix is the right one and it holds. `outbox-delivered/<id>/<stem>` is
written once, at claim time, by a `cp` - not a rename - and **no step in the
plan ever moves, renames or deletes it**. I ran the pointer's target through
every path the protocol can take:

| path | pointer resolves | content matches |
|---|---|---|
| claim -> send succeeds -> `sent-` | yes | yes |
| claim -> send fails -> revert to plain | yes | yes |
| ...then re-claim on a later poll -> succeeds | yes | yes |
| failed send, then the member dies and is swept | yes (and `outbox-abandoned/<id>/<stem>` also holds it) | yes |

The stem derivation is also correct in the sweep: sweeping a live `inflight-`
file normalizes it to the bare stem in `outbox-abandoned/<id>/`, so the
notice's pointer and the log line name a path that exists - round 3's S-D,
confirmed by execution rather than by reading.

Two consequences worth stating in the plan, neither of them a defect:

- A message can now be delivered **twice**. Today's single rename-to-`sent-`
  happens before the send, so a crash after a confirmed send leaves the file
  marked sent. The new protocol renames to `sent-` *after* the send, so a
  crash in that window leaves an `inflight-` file that the stale reclaim
  correctly reverts and re-delivers. This is a net improvement (a silent loss
  becomes a duplicate), but it changes the delivery semantics to at-least-once
  and the plan never says so.
- After a failed send with rc=3 ("typed but never visibly confirmed"), the
  durable copy is deliberately left behind. If the member then dies, the sweep
  reports the message abandoned to its sender even though the member may have
  read it. Unavoidable given rc=3's ambiguity; worth one sentence.

### M-C (notice queued into an already-swept sender): closed for the case round 3 reproduced.

The liveness check works because of a fact worth stating explicitly in the
plan, since the whole fix rests on it: `bin/crew-standdown` does **not** mark
ids as it walks the cascade. It calls `wm_state standdown` once (`:25`), and
that single locked write marks **every** affected id `stood-down` - roster
record and status file both - before returning the id list
(`bin/lib/wm-state.py:1128-1142`). Verified in the sandbox: after the one
`standdown --id L` call and before `bin/crew-standdown`'s loop has run at all,
both `L` and `W` already read `stood-down`.

So when the loop reaches `W` and sweeps it, `crew-get L` returns `stood-down`,
step 2's check fires, and the notice is routed through `<notify-mode>` instead
of into `outbox/L/`. Round 3's guaranteed-reproduction case is genuinely
prevented.

**The residual race the review was asked about is real but benign.** Sweeping
`W` reads `crew-get L` at T0 and writes into `outbox/L/` at T3; between them
sit the notice composition, the audit-log append, and a
`wm_tmux_send_message` attempt that can block for up to `WM_SEND_LOCK_WAIT`
(default **45s**, `bin/lib/common.sh:658`). If an independent
`crew-standdown L` lands inside that window, the notice is written into an
outbox that was swept moments earlier. This is a true TOCTOU and cannot be
closed without a lock, which is not worth it here: the audit-log append (step
4) always happens first, and `crew-prune` pass 1 sweeps a `stood-down` id with
a non-empty outbox, so the outcome degrades to the plan's own weaker
guarantee rather than to loss. The plan should say this plainly rather than
leave the check reading as absolute.

### M-D (`#214` overlap): accurate, specific, and sufficient.

Confirmed against the code. `bin/watch-fleet` has exactly four
`wm_tmux_send_message` call sites - `:924`, `:928`, `:974`, `:1077` - matching
`#214`'s enumeration. `:924` and `:928` are precisely the two sends inside the
outbox block that phase 1 restructures. The plan now says this in the `#214`
section and again in "Risks and follow-ups", and the two no longer contradict
each other. The correction that the sweep's live-sender notify is a **phase 1**
send site, not phase 2, is also right, and the plan names why it is the more
exposed one (a blind send into a live, working sender's pane). An implementer
picking up `#214` can read this and know exactly what they inherit. Nothing
further needed.

### M-B (wake-mode notice delivery): **not closed.** The redesign fixes what round 3 named and breaks two new things.

What is right: the enumeration of six wake-file-writing exits is exactly
correct (`bin/watch-fleet:779` `fire()`, `:829` `remote-control-dropped`,
`:1142` `outage-detected`, `:1173` `outage-cleared`, `:1306`/`:1318` the two
usage-limit transitions), and the diagnosis that keying by the *sweeping*
watcher's own scope cannot work is correct.

What is wrong, in three parts. See must-fix **N-2** and **N-3** below for the
first two, and **N-4** for the third.

---

## Must-fix

### N-1. The death-path sweep has no specified trigger, and the only signal available at that call site is routinely consumed by `bin/crew-list`

This is the plan's central hook and the thing the whole design turns on: the
moment a member's status flips to `died`, its outbox is swept and its senders
are told. The plan names the hook ("the death-path sweep call",
`bin/watch-fleet`) but never says **what enumerates the ids to sweep**.

The only signal at that site is `_reconcile_died` - the ids
`wm_state reconcile` reports it *just flipped this call*, already captured at
`bin/watch-fleet:846` for the outage state machine. Both round 2 and round 3
discuss the design in exactly those terms ("many outboxes swept in one poll",
"the poll that runs the death-path sweep is the same poll that calls
`fire()`"), so an implementer will use it. That is the trap.

**`bin/watch-fleet` is not the only process that flips deaths.**
`bin/crew-list:27` runs `wm_state reconcile --windows "$(wm_tmux_windows_csv)"`
and **discards the output**. `bin/crew-list` is run constantly - by wingman on
every wake and every status request, by every lead, by `/status`, by
`bin/crew-standdown`'s own preflight path. Whichever process gets there first
performs the flip.

Reproduced in a sandbox:

```
=== W's window has just died. bin/crew-list runs first: ===
  (wm_state reconcile --windows "" >/dev/null)      # exactly bin/crew-list:27
  status now:   "status": "died",
=== now watch-fleet's own poll runs its reconcile: ===
  _reconcile_died = ''
  ^ EMPTY -> a sweep driven off this poll's own flip list never fires for W
```

The death event itself still surfaces (`needs-attention` reads current roster
status, so `fire()` is unaffected). Only the sweep is lost - silently, with no
trace, for as long as the member's record exists. The message then waits for
an `bin/crew-prune` that the plan itself says is "explicitly not part of the
normal loop". That is the pre-fix behaviour, restored, in the plan's primary
path.

The window is not narrow. The watcher polls every `WM_WATCH_INTERVAL` seconds
(default **5**, `bin/watch-fleet:184`); any `crew-list` landing in that
5-second gap wins. In a mass death - many windows gone at once, wingman
immediately running `crew-list` to see what happened - `crew-list` winning is
the *likely* outcome, not the unlucky one.

**Fix, and it is smaller than what the plan implies:** do not drive the sweep
off a flip list at all. Iterate the directories that actually exist under
`$WM_HOME/outbox/` (typically zero to two) and sweep any whose roster status is
terminal and whose directory holds a non-`sent-` file. This is naturally
idempotent - the sweep empties the directory, so a swept member is not a
candidate on the next poll - it needs no marker file, it costs one `ls` per
existing outbox directory per poll, and it subsumes three of the plan's
separate concerns at once: a flip stolen by `crew-list`, a `crew-standdown`
sweep that partially failed, and a windowless `done` member. It also removes
the plan's dependence on `_reconcile_died` entirely.

Add a test: flip a member to `died` via a `crew-list`-shaped reconcile call,
then run a watcher poll, and assert the sweep still fires.

### N-2. Keying the notice by the target's true parent orphans it whenever that parent is itself terminal - which is the mass-death case

The plan's argument for the new keying is quoted in full because the hole is in
it: "regardless of which watcher's reconcile call physically flips a member's
status to `died`, that member's *own* true owner will see the updated status
the next time *its own* `needs-attention --owner <its-id>` runs".

That is true only while the owner is alive. Reproduced in a sandbox, the
simultaneous case:

```
--- SIMULTANEOUS mass death (no windows), owner '' ---
flipped: L W X
  L died parent='' orphaned_from=None
  W died parent='L' orphaned_from=None      <-- parent still points at the dead lead
```

versus the sequential case:

```
--- only L's window gone, W still live ---
  L died parent='' orphaned_from=None
  W working parent='' orphaned_from='L'     <-- re-adopted to wingman
```

The dead-owner re-adopt pass (`bin/lib/wm-state.py:1001-1019`) re-parents a
worker whose owner went terminal - but it skips any worker whose **own** window
is already gone (`:1008-1009`), because the death flip has already handled it.
So when a lead and its workers die together, every worker's `parent` keeps
pointing at the dead lead.

Consequence, exactly: sweeping worker `W` appends the notice to
`pending-notices-<L>`. No `watch-fleet --owner L` process exists or will ever
exist again - a lead's watcher is a background task of the lead's own session,
inside the tmux window that just died. Nothing else reads that file. The notice
is lost permanently.

This is the correlated mass death - the case the plan calls "the single
highest-value case this whole plan exists for". The same shape applies to a
member that dies while its parent is already `stood-down`.

**Fix:** resolve the notice's key by walking up the parent chain to the first
**non-terminal** ancestor, defaulting to wingman (`""`) when none is found.
Wingman's own watcher is the one process guaranteed to outlive a tmux-server
loss, which is what makes it the correct floor. One loop, bounded by the
depth-2 cap.

### N-3. Cross-owner keying breaks the "rides the already-guaranteed death event" guarantee it depends on

The keying fix is what creates this: the notice is now written by watcher **A**
(whichever one ran the fleet-wide flip) but must be surfaced by watcher **B**
(the target's parent). Those are different processes on independent 5-second
timers, and nothing orders them.

Watcher B fires on `W`'s death the moment it sees `died` in the roster - which
is the instant A's `reconcile` call returns. A's sweep for `W` then continues:
composing the notice, appending the audit line, and attempting a direct
`wm_tmux_send_message` to a live sender that can block for up to 45s
(`WM_SEND_LOCK_WAIT`, `bin/lib/common.sh:658`). B's `fire()` very plausibly
completes and acks `W`'s event before A ever writes the notice. Once acked,
that event does not re-fire. The notice then sits in `pending-notices-<B>`
until B happens to fire on something unrelated.

This is materially worse for a lead than for wingman, and the plan's own
six-exit fix is what shows why: **five of the six exits are wingman-only.**
`self_pane_check` opens with `[ -z "$OWNER" ] || return 1`
(`bin/watch-fleet:327`); the outage block is gated at `:1119` and the
usage-limit block at `:1201`, both `[ -z "$OWNER" ]`. A lead's watcher can
reach exactly one of the six - `fire()`. So for any notice keyed to a lead, the
sole surfacing opportunity is that lead's next unrelated attention event, which
may be minutes away or may never come.

**Fix:** stop treating the pending-notices file as a rider on someone else's
event and make it an attention condition in its own right - if
`pending-notices-<this watcher's key>` is non-empty at the top of the poll and
nothing else fires, fire on it. `fire()` truncates the file, so it fires once
and cannot loop. This closes N-3 outright and makes N-2's fallback the only
other thing needed for the channel to be a genuine guarantee.

### N-4. `$_key` does not exist in the scope the plan tells the helper to read it from

The plan specifies the writer as `pending-notices-<parent's sanitized key>`
"sanitized into the identical filesystem-safe form `bin/watch-fleet` already
computes for `$_key`", and the reader as "this watcher's own
`pending-notices-$_key` file".

`bin/watch-fleet` computes `_key` **only** in the `[ -n "$OWNER" ]` branch
(`:155-162`); the `else` branch (wingman, `OWNER=""`) keeps the legacy
un-suffixed filenames and never assigns `_key` at all. The script runs `set -u`
(`:120`). Reproduced:

```
$ bash -c 'set -u; OWNER=""; if [ -n "$OWNER" ]; then _key=x; fi; echo "pending-notices-$_key"'
bash: line 1: _key: unbound variable
```

Implemented as written, the surfacing helper aborts wingman's own watcher on
every poll - and wingman's scope is the primary consumer of this channel.
Related: `printf '%s' "" | tr -c 'A-Za-z0-9._-' '_'` yields the empty string, so
an unqualified reading also gives wingman the filename `pending-notices-` with
a trailing dash. Both sides must agree.

**Fix:** one sentence naming the exact filename for the empty-owner case and
stating that the key is derived from the resolved parent id (after N-2's
walk-up), never from a variable that only exists in the lead branch.

---

## Should-fix

### S-1. The stale-reclaim default is three times too small relative to a single delivery's bounded duration

The plan sets `WM_OUTBOX_INFLIGHT_STALE` to `$((INTERVAL * 3))`. `INTERVAL`
defaults to 5 (`bin/watch-fleet:184`), so the default staleness bound is **15
seconds**. One claimed delivery can legitimately occupy up to
`WM_SEND_LOCK_WAIT` = **45 seconds** waiting on the pane's send lock, plus the
delivery itself (`bin/lib/common.sh:650-668`).

A staleness threshold must exceed the maximum bounded duration of the operation
it is declaring stale. This one is a third of it.

Not reachable in phase 1 - the single poller for an id is blocked inside the
send and cannot reclaim its own file - but it becomes a live duplicate-delivery
bug the moment phase 2's whole-fleet backstop introduces a second poller: the
backstop reclaims a 15-second-old live claim, re-delivers, and the original
claimant's resolving `mv` then fails silently against a filename that changed
underneath it, leaving no `sent-` marker and allowing a third delivery. Set the
default above `WM_SEND_LOCK_WAIT` (e.g. `$((${WM_SEND_LOCK_WAIT:-45} +
INTERVAL * 3))`) in phase 1, where the constant is introduced, and state the
invariant so it is not silently re-tuned later.

### S-2. `crew-prune`'s two sweep passes must be specified to run *before* the record removal, or S-B's `--owner` fix is nullified

`bin/crew-prune` is a pass-through whose first real statement is
`out="$(wm_state prune "$@")"` (`:22`) - records are archived and removed
before anything else happens. The plan says the two sweep passes are
"unconditional on every real invocation" but never says where they sit relative
to that line, and the natural place to append new logic is after it.

If they run after: every id the prune just removed has no roster record, so
pass 1 (which iterates roster ids and scopes by each candidate's own `parent`)
finds nothing, and everything falls through to pass 2 - which the plan
correctly specifies as **always fleet-wide**. A `crew-prune --owner=some-lead`
would then sweep outboxes across the whole fleet, which is exactly the outcome
round 3's S-B fix exists to prevent. The careful `--owner=<value>` parsing is
wasted unless the ordering is pinned.

State it: both sweep passes run before `wm_state prune`.

### S-3. The sidecar/payload write order is unspecified, and one of the two orders misattributes senders

`bin/crew-say:89-90` (and `bin/crew-ask:305-306`, `bin/spawn-crew:522-523`)
create the outbox payload file; the plan adds a sidecar write alongside it but
never says which comes first.

Payload-first leaves a window in which a sweep (or a claim) sees a payload with
no sidecar and attributes it to `unknown`, routing the notice through the
`<notify-mode>` fallback instead of to the real sender - the exact
misattribution the sidecar mechanism exists to prevent. It also leaves the
sidecar orphaned in `outbox-meta/<id>/` if a poll delivers the message in
between, since the deletion looks for a file that does not exist yet.

Sidecar-first has only a cosmetic failure mode (a stray sidecar if the process
dies between the two writes). Specify sidecar-first.

### S-4. Steps 3 and 6 both claim to move the swept payload

Step 3 composes the notice and says "the payload is moved there as part of this
same step". Step 6 says "Move the swept file and its sidecar per step 3". Read
as a numbered sequence, the move happens after the notify in step 5 - and then
the notice's pointer names `outbox-abandoned/<id>/<stem>` before that path
exists, which is round 2's M4 reproduced for the third time in this plan's
history.

The intent is clearly step 3, but this is the single area of this plan that has
now produced a dangling-pointer defect in two consecutive rounds, and it should
not be left to charitable reading. State the order once: the payload moves to
its durable location **before** any pointer naming it is composed or sent, and
step 6 carries only the sidecar move and the `rmdir`.

### S-5. Test gaps for the findings above

Tests 1-11 are otherwise at the right level, and the M-A, M-C and S-A/S-B/S-C
extensions are the right ones. Missing:

- Nothing covers **N-1**. Add: flip a member to `died` via a
  `crew-list`-shaped reconcile call (no `--owner`, output discarded), *then*
  run a watcher poll, and assert the sweep fires anyway.
- Test 7(b) exercises cross-owner keying only with a **live** target parent, so
  it passes under **N-2**. Add a case where a lead and its worker die in the
  same reconcile, and assert the worker's notice reaches a channel someone
  actually reads.
- Nothing covers **N-3**'s ordering. Assert the notice surfaces even when the
  target's owner's watcher already fired on that death before the notice was
  written.

---

## Nice-to-have

- Round 3's S-C is now correctly stated for `crew-standdown`/`crew-prune`, but
  omits the third and most frequent second mutator: **another owner's watcher**,
  which sweeps out-of-scope members on every fleet-wide reconcile flip. The
  bounded re-scan covers it mechanically; the rationale should name it.
- The sweep unconditionally seizes a live `inflight-` file. This is correct in
  every sweep path (the target's window is already gone, so the in-flight send
  is doomed), but the plan asserts it without saying why it is safe.
- `bin/crew-prune`'s new `done`-window check is feasible as specified -
  `wm_tmux_windows` is in `bin/lib/common.sh:735`, which `bin/crew-prune`
  already sources - but it depends on `WM_TMUX_TARGET` resolving in a session
  that today makes no tmux calls at all. Worth one line confirming the
  no-tmux-session case reads as "no live window" rather than erroring.
- The plan's snippet uses `$id` where `bin/watch-fleet`'s loop variable is
  `$_id`; harmless, but this plan is precise enough elsewhere that the
  inconsistency reads as a different variable.

---

## Answers to the questions this review was asked

1. **M-A - is the pointer genuinely stable end to end?** Yes. Reproduced across
   all four paths the protocol can take, including after the redelivery
   resolves and after a subsequent sweep. `outbox-delivered/<id>/<stem>` is
   written once and no step in the plan touches it again. Two semantic
   consequences should be stated (at-least-once delivery; the rc=3 orphan), but
   neither is a defect.
2. **M-B - are all six exits covered and is the keying correct?** The six exits
   are enumerated exactly right. The keying is not correct: it orphans the
   notice whenever the target's parent is itself terminal, which is the mass
   death (**N-2**, reproduced against a real fleet-wide flip); it breaks the
   ordering guarantee the design leans on, made much worse by five of the six
   exits being wingman-only (**N-3**); and it reads `$_key` in a scope where
   that variable does not exist under `set -u` (**N-4**).
3. **M-C - does the liveness check prevent the guaranteed case, including the
   race?** Yes to the guaranteed case, and for a reason the plan should state:
   `wm_state standdown` marks the whole cascade in one locked write before
   `bin/crew-standdown`'s loop begins, so the check always sees `stood-down`.
   The residual TOCTOU race is real and up to 45s wide, but degrades to
   audit-log-plus-future-prune rather than loss. Say so; do not close it with a
   lock.
4. **M-D - is the `#214` prose honest and specific enough?** Yes. Verified
   against the four `wm_tmux_send_message` sites in `bin/watch-fleet`. Nothing
   further needed.
5. **The five round-3 should-fix items.** S-A, S-B, S-C and S-D are properly
   addressed; S-E's test additions are right as far as they go. S-B's fix is
   conditional on an ordering the plan does not state (**S-2**), and S-E now has
   three new gaps (**S-5**).
6. **New races and edge cases.** **N-1** is the significant one and was found by
   asking what actually triggers the sweep rather than by probing the claim
   protocol - the claim/reclaim mechanics themselves survived crash-mid-claim,
   crash-before-resolve, sweep-vs-claim and re-claim probing intact. Also new:
   **S-1** (staleness bound below the send-lock ceiling), **S-3** (sidecar write
   order), **S-4** (payload move ordering).
7. **Standing constraints.** Testing strategy: concrete and at the right level,
   with the three gaps above. Blast radius: appropriate - seven files in phase
   1, no `bin/lib/wm-state.py` changes, and N-1's fix would make it *smaller*
   by dropping the dependence on `_reconcile_died`. Phase 1 as an
   independently-mergeable complete fix: **not yet** - N-1 means its central
   hook misfires whenever any process runs `bin/crew-list` in the five seconds
   before the watcher's poll, and N-2/N-3 mean the notice channel is not a
   guarantee. Fix those three and phase 1 stands on its own.

## Open Questions

None from this review. The plan's own two open questions parse cleanly and both
recommendations remain correct.
