# Plan review, round 2: outbox queue abandonment fix (issue #169)

**Date:** 2026-07-30
**Plan reviewed:** `docs/plans/2026-07-30-outbox-queue-abandonment-fix.md` (revised after round 1)
**Round 1 findings:** `docs/analysis/2026-07-30-review-outbox-queue-abandonment-plan.md`
**Issue:** [greerviau/wingman#169](https://github.com/greerviau/wingman/issues/169)
**Verdict:** **Request changes.** Five must-fix; three of round 1's five are genuinely closed, one is closed only for two of its three call sites, and one is fixed in phase 2 while leaking into phase 1.

---

## Summary

The revision is a real improvement and the architecture is unchanged and still
correct. Three of round 1's must-fix items are closed cleanly and by the right
mechanism, and I verified each against the actual code rather than taking the
revision's word for it:

- **Sidecars (round 1 must-fix 1): closed, by construction.** The selector is
  `ls "$WM_HOME/outbox/$_id"` (`bin/watch-fleet:914`) and the sweep iterates the
  same directory; `outbox-meta/` is a sibling tree, so no selector anywhere can
  reach it. The claim that this cannot recur "by construction" is accurate.
- **Claim-before-send (round 1 must-fix 4): closed.** Gating the send on the
  `mv`'s own exit status, with the send unreachable outside the successful
  branch, genuinely eliminates both the loser's spurious second delivery and the
  loser's revert un-claiming the winner's already-delivered file. The reasoning
  that the failure-revert is then safe unconditionally is also correct.
- **`crew-prune --dry-run`/`--owner` (round 1 must-fix 5): closed.** Report-only
  passes under `--dry-run` fix the destructive-inert-command defect, and the
  `--owner` scoping via each candidate's `parent` mirrors `cmd_prune`'s own
  `parent_of(r) != owner` filter exactly (verified in `bin/lib/wm-state.py`).
  Pass 2's documented fleet-wide exception is correctly justified.

The empirical correction is accurate - I re-read live state and it is exactly
one `sent-` file plus one empty directory, as described. The freshness
correction is accurate. Every line cite in the revision was re-verified against
`origin/main` and every one is right. The phase 1 / phase 2 split is coherent
and phase 1 is genuinely self-contained.

What is left is concentrated in three places:

1. **The death path's delivery channel for a wingman-sent notice does not
   work** - the headline case of the issue, and the one round-1 finding the
   revision chose to fix by a different mechanism than the one round 1
   recommended. The mechanism it picked is preempted or truncated to
   uselessness by the code it relies on.
2. **The claim protocol has two internal defects** the revision introduced
   while fixing must-fix 4 and should-fix 7: the selector does not exclude the
   new `inflight-` state, and the stale-claim rule is keyed on a timestamp
   `mv` does not change.
3. **Round 1's must-fix 2 (shared `PANE_STABLE` corruption) is fixed for the
   phase-2 backstop but lands unfixed in phase 1**, because the phase-1
   refactor also takes its own in-function capture and the namespace fix is
   scoped only to the backstop's call.

Plus one straightforward correctness bug: the abandonment notice points at a
file the sweep then deletes.

---

## Verification performed

The local checkout is two commits behind `origin/main` and one of those commits
(`51fd782`) touches `bin/lib/common.sh` and `bin/spawn-crew`, so **every
assertion below is read from `git show origin/main:<path>`, not the working
tree.**

Read directly: `bin/watch-fleet` (`:867-883` population filter, `:898-933`
outbox block, `:914` selector, `:922-930` the two send branches, `:942` RC-drop
gate, `:963-983` reconnect, `:991-993` the `review|stalled` continue, `:995`
`prompt_freeze_check`, `:1031-1055` stall nudge, `:755-802` `fire()`,
`:836-846` the reconcile/death-flip call site); `bin/lib/common.sh:379-393`
(`wm_pane_snapshot`); `bin/lib/wm-state.py` (`cmd_needs_attention`,
`cmd_crew_set`, `cmd_prune`, `cmd_reconcile`'s dead-owner re-adopt,
`render_roster_text`, `render_tree_text`); `bin/crew-say:75-96`;
`bin/crew-ask:285-310` and its `undeliverable` path at `:156-167`;
`bin/spawn-crew:510-525`; `bin/crew-standdown` (all 101 lines);
`bin/crew-prune` (all 30 lines); `tests/dialog-delivery-refusal.test.sh`,
`tests/outbox-redelivery.test.sh`, `tests/lib.sh`.

Also: live `$WINGMAN_HOME/outbox/` and `crew.json` (78 records), and a direct
filesystem experiment confirming `mv` preserves mtime.

---

## Must-fix

### M1. The death path's wingman-sender notice is preempted or truncated - the issue's headline case is still not delivered

The revision fixes round 1's finding 3 per call site. Two of the three are
correct and I confirmed them:

- `bin/crew-standdown` and `bin/crew-prune` are never invoked programmatically
  anywhere in `bin/` or `hooks/` (grepped) - they only ever run in the
  orchestrator's or a lead's own foreground turn, so a flagged stdout line does
  land in the caller's tool result. **This works.**

The third does not. For the `bin/watch-fleet` death path the plan stamps the
note onto the dying member's own roster `summary` and asserts it "rides that
fire without a new mechanism." Three separate things in the code it depends on
defeat that:

1. **The fire's reason line never shows `summary` for most members.**
   `cmd_needs_attention` computes:

   ```python
   note = (r.get("blocker") or r.get("delivery")
           or r.get("artifact_url") or r.get("artifact") or r.get("summary") or "")
   ```

   `summary` is *last* in the fallback chain. Any member carrying a blocker, a
   PR/branch `delivery`, or an `artifact` path shows that instead. On the live
   roster **60 of 78 records (77%) carry one of those fields** - and they are
   precisely the members most likely to have a queued message: a developer with
   a PR, an analyst with a plan path, a reviewer with a findings file.

2. **The wake file's roster render truncates it.** `render_roster_text` emits
   `(r.get("summary") or "").split("\n")[0][:60]` - first line only, 60
   characters. The plan's own proposed sentence ("- N pending message(s) to you
   were abandoned when you ended; see outbox-abandoned.log") is ~90 characters
   *before* whatever it is appended to. It is cut off mid-word in the one place
   it was supposed to survive.

3. **`crew-set --summary` alone does not advance `announced`.** In
   `cmd_crew_set`, the `announced` bump is gated on
   `not args.silent and args.status in ATTENTION_STATES`; a call with no
   `--status` falls through to `live.setdefault("announced", ...)`, leaving it
   unchanged. So the note has no event of its own and rides only if the sweep
   hook happens to run after `reconcile` and before `fire()` in the same poll -
   an ordering the plan never states. Note that the precedent it cites
   (`cmd_reconcile`'s dead-owner re-adopt) does **not** rely on this: it
   explicitly sets `live["announced"] = stamp` to force a re-fire. The plan
   copies the visible half of the pattern and drops the half that makes it work.

Separately: the pattern **overwrites** `summary` (as does the precedent). On a
death, the dying member's last self-report is the single most useful diagnostic
the human has. Destroying it to carry a message-abandonment note is a bad trade.

Round 1's own recommendation - route the notice through `bin/watch-fleet`'s
existing wake-file-plus-fire-reason channel, the same mechanism
`remote-control-dropped`, the outage machine and the correlated-death batch all
use - is the one that actually works here, and it is no larger a change. Use it,
or add an explicit extra line to the wake payload in `fire()`. Whatever the
choice: **append** to `summary`, never replace, if the roster record is touched
at all.

### M2. The redelivery selector does not exclude the new `inflight-` state

The claim protocol adds a third file state but leaves the selector as-is - the
plan describes `wm_outbox_try_redeliver` as a refactor of the existing block,
whose selector is:

```sh
_obfile="$(ls "$_obdir" 2>/dev/null | grep -v '^sent-' | sort | head -1)"
```

The only exclusion is `sent-`. So a non-stale `inflight-<ts>-<pid>.msg` is a
valid selection. The claim step then runs
`mv "$plain" "$inflight"` on it, producing
`inflight-inflight-<ts>-<pid>.msg` - and succeeding, so the send fires for a
message another process (or this process's predecessor) may still be
delivering. Worse, the sidecar lookup is specified as "the timestamp-pid stem,
with any `sent-`/`inflight-` prefix stripped" (singular); stripping one prefix
off `inflight-inflight-<ts>-<pid>.msg` yields `inflight-<ts>-<pid>.msg`, which
matches no sidecar - so the sender reads as `unknown` and the sidecar leaks
forever. A third pass compounds it.

This is currently *masked* in phase 1 by M3 below (every `inflight-` file reads
as instantly stale, so the reclaim pass converts them all back to plain before
selection). Fixing M3 without also fixing M2 makes it live. Fix both together:
the selector must be `grep -v '^sent-' | grep -v '^inflight-'`, and
`inflight-` files may be touched **only** by the stale-reclaim pass.

### M3. The stale-claim reclaim is keyed on a timestamp `mv` does not change

The rule is "any `inflight-*` file older than `WM_OUTBOX_INFLIGHT_STALE`
(default ~15s)", and test 6 confirms the intended reading is mtime
(`wm_age_path`, which back-dates mtime).

`mv` within a directory is `rename(2)`: it updates the file's *ctime* and the
directory's mtime, but **not the file's mtime**. Verified directly:

```
before mtime age: 600
after mv mtime age: 600      <- unchanged
ctime age: 0
```

So an `inflight-` file's mtime is when the message was **queued**, not when it
was **claimed**. Queued messages are old by construction - that is the entire
subject of this issue - so essentially *every* claim is "stale" the instant it
is made.

Consequences: in phase 1 (one process per id) this silently disables the stale
gate, which is harmless but means the mechanism is never actually exercised. In
phase 2 it is fatal: the backstop and the owner-scoped loop each reclaim the
other's live, in-flight claim on sight, converting the claim protocol into
exactly the double-delivery race it exists to prevent. Since the protocol lands
in phase 1, get it right now.

Fix: record the claim time explicitly - `touch` the file immediately after a
successful claim `mv`, or encode the claim epoch in the in-flight name
(`inflight-<claim-epoch>-<original-name>`, which also makes the reclaim
inspectable without a `stat`). Derive the threshold from the watcher's own
`INTERVAL` rather than hardcoding 15s.

Also specify that the reclaim pass runs **before** the pane-stability gate, not
after it - otherwise a member whose pane never stabilises never reclaims.

### M4. The abandonment notice points at a file the sweep then deletes

`wm_outbox_sweep_abandoned`'s steps, as written:

2. compose the notice with "the content (inline if short/single-line, **a
   pointer** if long/multi-line)";
3. append the same "content-or-pointer" to `outbox-abandoned.log`;
4. notify the sender - possibly by *queueing the notice into the sender's own
   outbox*, i.e. delivered minutes or hours later;
5. **"Remove the swept file and its sidecar from disk."**

For any multi-line message the sender receives a pointer to a path that no
longer exists, and the audit-log line is dangling from the moment it is
written. Multi-line is the common case for exactly the messages worth
salvaging - a relayed human answer, a `crew-ask` prompt pointer, a spawn
objective.

Fix: don't delete the payload. Move the swept file into a durable location
(`$WM_HOME/outbox-abandoned/<id>/<file>`, alongside the log) and make both the
notice and the log line point *there*. `outbox/<id>/` still ends up empty,
which is all the sweep actually needs.

### M5. Round 1's must-fix 2 lands unfixed in phase 1

The namespace fix (`wm_pane_snapshot <id> <win> [ns]` → `pane-backstop-<id>.hash`)
is correct and I verified it genuinely restores independent two-poll semantics.
But it is specified **only** under the phase-2 backstop section, as something
"the backstop's own call into `wm_outbox_try_redeliver` passes." Meanwhile the
phase-1 section of `wm_outbox_try_redeliver` says the function takes "its own
`PANE_STABLE`/`PANE_TEXT` capture rather than depending on the caller's prior
one," with no namespace and no isolation from the caller's globals.

That reproduces the defect inside a single process, in phase 1.
`wm_pane_snapshot` is not a pure read and does not scope its variables:

```sh
wm_pane_snapshot() {
  _id="$1"; _win="$2"
  PANE_TEXT="$(wm_tmux_pane_text "$(wm_tmux_win_target "$_win")")"
  _hashfile="$WM_HOME/pane-<id>.hash"
  ...
  if [ -n "$_prev" ] && [ "$_hash" = "$_prev" ]; then PANE_STABLE=1; else PANE_STABLE=0; fi
}
```

`bin/watch-fleet`'s loop calls it once at `:887` and then four separate later
checks read those same globals:

- `:942` `[ "$PANE_STABLE" = 1 ] && remote_control_dropped_check` (RC drop);
- `:963` the `/remote-control` reconnect, gated on `_rc_dropped`;
- `:995` `prompt_freeze_check`, whose final test is `[ "$PANE_STABLE" = 1 ]`;
- `:1049` `[ "$PANE_STABLE" != 1 ] && continue` (stall nudge).

A second capture inside the redelivery function, milliseconds after the first,
overwrites `pane-<id>.hash` with the second capture and sets `PANE_STABLE` from
a millisecond-scale comparison - which reads `1` almost unconditionally. Every
one of those four checks then acts on a pane that has *not* been confirmed
stable across two polls. That is the exact regression round 1 flagged, arriving
one phase earlier than the plan's fix for it.

**Smallest fix, and the one I'd recommend: don't extract or re-capture in
phase 1 at all.** Phase 1 has exactly one caller. Apply the claim protocol
in place in `bin/watch-fleet`'s existing block, using the caller's already-
computed `PANE_STABLE` exactly as today, and defer the extraction into
`bin/lib/common.sh` to phase 2, when a second caller actually exists and the
namespace argument earns its keep. This removes the finding entirely, shrinks
phase 1's `common.sh` footprint to the sweep function alone, and removes the
`watch-fleet` refactor from the file that #214 is also editing - which is the
sequencing entanglement the plan is otherwise trying to keep out of phase 1.

If the extraction is kept in phase 1 anyway, the function must both pass its
own namespace *and* not clobber the caller's `PANE_TEXT`/`PANE_STABLE`.

---

## Should-fix

### S1. The standdown sweep must cover the whole cascade, after the window is killed

`bin/crew-standdown` cascades: `AFFECTED="$(wm_state standdown --id "$ID")"`
(`:25`) returns the target *and every descendant*, and the loop at `:29-92`
processes each. A lead standdown reaps a whole sub-crew, each member with its
own outbox. The plan says only "`bin/crew-standdown` (sweep call)". Specify:
sweep every id in `$AFFECTED`, inside that loop, **after** `kill-window`
(`:73`), so nothing can be re-queued into a pane that is about to disappear.

### S2. `done` is not covered by phase 1

The Problem statement names all three terminal statuses: "Once a member reaches
`done`, `stood-down`, or `died`, its outbox becomes permanently unreachable."
Phase 1 covers `stood-down` (standdown sweep), `died` (death hook), and
record-gone (prune pass 2) - and `crew-prune` pass 1 now *explicitly skips*
`done`. The population filter also excludes `done`. So a member that reports
`done` and is never reaped (wingman crashed, restarted, or simply did not get
the turn) keeps an unserviced queue indefinitely, with nothing in phase 1
covering it. The plan credits phase 2's backstop with closing this "for free" -
which is true, and is a phase-1 gap.

Either state plainly that `done` is covered only transitively by the same-turn
reap and accept the residual, or close it cheaply by adding `done` to the
outbox-servicing population (it still has a live window, so redelivery is the
right action, not sweeping).

### S3. "Behavior-preserving" contradicts the plan's own hardening

The Phased delivery section describes the `watch-fleet` work as "refactor the
existing block into the shared function - **behavior-preserving**", while
`wm_outbox_try_redeliver`'s own section adds the claim state machine and a new
capture. A developer following the phase list literally would skip the claim
work. Fix the wording (moot if M5's recommendation is taken).

### S4. Sweeping a `died` member's queue conflicts with `died` being recoverable

`died` is explicitly a *recoverable* state in this repo: `bin/crew-takeover <id>`
prints the resume command, and `bin/crew-resume --all-died` is the documented
outage remedy - both bring the same id back with a live window and a servicable
outbox. Sweeping at the death flip destroys the queue for a member that may be
about to come back. It is not *silent* (the sender is notified), which is why I
rank this should-fix rather than must-fix, but the plan should state the
tradeoff and say why immediate sweep beats deferring the `died` case to
`crew-prune`. The same question applies to `crew-prune` pass 1, which sweeps
`died` outboxes even though `crew-prune`'s own default deliberately does *not*
remove `died` records ("the `died` records you may still want to recover").

### S5. The second-level-sweep terminal case is stated inconsistently

Step 4 says a re-queued abandonment notice that is itself later swept "does not
attempt a third-level requeue - it just logs, per the case below." The case
below is stdout (standdown/prune) or the roster-record stamp (death path), not
log-only. Pick one and state it once.

### S6. Test 3 asserts the broken mechanism

Test 3 asserts the wingman-sender death case "lands on the **dying member's own
roster `summary`** (not merely a log line)". Under M1 that assertion passes
while the feature does not work - the note is written and never reaches
wingman. The test must assert on the channel wingman actually reads (the fire's
reason lines / the wake file), not on the roster field.

### S7. The `crew-ask` case already has an existing resolution path

`bin/crew-ask await` already detects a delegate that died or vanished and
resolves the request `undeliverable` (`bin/crew-ask:156-167`), independently of
anything here. So an abandoned `crew-ask` pointer produces *both* that
resolution and the sweep's notice to the asker. That is not a conflict, but the
plan should say so explicitly, and say that the sweep must **not** try to
resolve the ask record itself (`ask-resolve` is a compare-and-set on `pending`;
a second writer racing the await watcher is exactly what that guard exists to
prevent).

### S8. `bin/crew-prune` does not parse the flags the plan needs

`crew-prune` is a 9-line wrapper. It does not parse `--owner` at all (it is an
undocumented passthrough to `wm_state prune`), and it detects `--dry-run` with
`case " $* " in *" --dry-run "*)` - a positional string match that misses
`--dry-run=true` or any bundled form. The plan requires the wrapper itself to
branch on both. Specify the parsing, and update `crew-prune`'s header usage
block (which currently documents neither `--owner` nor any outbox behaviour) as
part of the change.

---

## Nice-to-have

- Empty `outbox/<id>/` directories are never removed - live state already has
  one from July 28. `rmdir` after a sweep, and cover `outbox-meta/<id>/` too,
  including a `outbox-meta/<id>/` whose `outbox/<id>/` is already gone.
- `outbox-abandoned.log` has three concurrent appenders (`watch-fleet`,
  `crew-standdown`, `crew-prune`). `>>` gives `O_APPEND`, so single writes below
  `PIPE_BUF` are atomic; cap the inlined content length so a long single-line
  message cannot exceed it and interleave.
- The death-path summary text addresses the dead member ("N pending message(s)
  **to you**") while the actual reader is wingman. Moot if M1's channel changes.
- `tests/dialog-delivery-refusal.test.sh:47,73` assert on
  `ls outbox/<id> | grep -v '^sent-' | head -1`. Unaffected by this plan as
  written, but worth a glance when the `inflight-` state lands.

---

## Answers to the round-2 review questions

1. **Sidecar selector - does the `outbox-meta/` tree actually hold?** Yes,
   verified. The selector reads `$WM_HOME/outbox/$_id` and the sweep iterates
   the same directory; `outbox-meta/` is a sibling of `outbox/`, unreachable by
   either. "By construction" is accurate, not aspirational.
2. **Shared `PANE_STABLE` - do two concurrent callers still collide?** The
   namespace fix is correct and sufficient *for phase 2*. But phase 1 also
   re-captures, without a namespace and without isolating the caller's globals,
   so the collision arrives one phase early inside a single process - **M5**.
3. **Claim-before-send - is the race closed, and is a stale claim genuinely
   reclaimed?** The race is closed: gating on `mv`'s exit status with the send
   unreachable outside the successful branch fixes both round-1 sub-defects.
   Stale reclaim is **not** genuinely working: it is keyed on mtime, which `mv`
   preserves, so it fires on every claim rather than only on abandoned ones -
   **M3**. And the selector can pick a live `inflight-` file - **M2**.
4. **Does the wingman-sender routing deliver?** For `crew-standdown` and
   `crew-prune`, yes - verified they are only ever foreground calls. For the
   death path, no - **M1**. That is the issue's headline case.
5. **`crew-prune --dry-run`/`--owner`?** Yes, both genuinely fixed; `--owner`
   scoping matches `cmd_prune`'s own filter and pass 2's exception is correctly
   justified. Only the flag *parsing* is unspecified - **S8**.
6. **Is phase 1 a complete, coherent, mergeable fix on its own?** Yes,
   architecturally - it does not depend on phase 2 landing, and the split is
   the right call. Two caveats: it does not cover `done` (**S2**), and as
   currently scoped it drags the `watch-fleet` extraction and its capture into
   phase 1 for no phase-1 benefit (**M5**). With M5's recommendation taken,
   phase 1 becomes strictly smaller *and* strictly safer.
7. **Anything round 1 missed?** M2, M3, M4, S1, S2, S7, S8 are new this round.
   M4 (the notice points at a file the sweep deletes) is the one I would rank
   most embarrassing to ship.
8. **Standing constraints.** Blast radius is defensible and would improve under
   M5. The testing strategy is at the right level and the round-1 gaps are all
   filled; test 3 asserts the wrong thing (**S6**), and nothing yet covers M2's
   selector case, M3's claim-time semantics, or M4's pointer-survives-the-sweep
   case. The empirical correction, the freshness correction, and every line
   cite in the revision are accurate - I re-pulled all of them from
   `origin/main`.

## Open Questions

None from this review; the plan's own two open questions parse cleanly and both
recommendations are the right ones.
