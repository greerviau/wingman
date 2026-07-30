# Plan review, round 7 (confirmation pass): outbox queue abandonment fix (issue #169)

**Date:** 2026-07-30
**Plan reviewed:** `docs/plans/2026-07-30-outbox-queue-abandonment-fix.md` (revised after rounds 1-6)
**Prior round:** `docs/analysis/2026-07-30-review-round6-outbox-queue-abandonment-plan.md`
**Issue:** [greerviau/wingman#169](https://github.com/greerviau/wingman/issues/169)
**Scope:** narrow confirmation pass, not a seventh full adversarial round - round 6's two
must-fix items, its four nice-to-haves, and a final readiness gut-check.

**Verdict: approve.** Both must-fix items are genuinely closed, confirmed by execution
against an isolated scratch `WINGMAN_HOME` rather than by reading. All four nice-to-haves
are addressed. No must-fix items remain. **This plan is ready for a developer; no eighth
round is warranted.**

Four non-blocking observations are recorded at the end. None of them justifies another
review round, and none should gate the hand-off - the right disposition for all four is
for the implementer to fold them in while writing the code, or for the plan's author to
add the two one-clause edits (A and B) in passing if the plan is being touched anyway.

---

## Method

Every experiment ran against an isolated scratch `WINGMAN_HOME` under this session's
scratchpad, asserted not to be `~/.wingman` before any call, and against a scratch tmux
session (`wmr7scratch`) created and torn down by this review. The live roster and the live
`wingman` tmux session were never written to.

**Freshness.** The working tree is diverged from `origin/main`: it carries one local
commit (`4e75612`, the analysis/plan docs) that `origin/main` does not, and is missing two
`origin/main` commits (`51fd782`, `00afb82`). Of the files this review asserts against,
`bin/watch-fleet`, `bin/lib/wm-state.py`, `playbooks/common/lead.md` are byte-identical to
`origin/main` and are cited from the working tree; `bin/lib/common.sh` and `bin/spawn-crew`
differ and were read via `git show origin/main:<path>`. The plan file itself is an
uncommitted working-tree modification - the freshest copy by construction, and the one
reviewed.

**Executed, not read:**

- `wm_tmux_windows_csv` against a live scratch session, and against an absent session
  (the tmux-dead simulation), including under `set -e`.
- Both predicates and `resolve_notice_owner`, transcribed literally from the plan, over an
  8-record scratch roster with two live windows - plus the counterfactual in which the walk
  reuses the delivery predicate, to confirm the split is load-bearing.
- The comma-joined window-set membership test, naive-substring vs. exact-field.

---

## Must-fix 1 (the scan's window-liveness data source): closed

The fix is correct on every dimension it needed to be.

**The data source answers the question, and joins on the right key.**
`wm_tmux_windows_csv` (`origin/main:bin/lib/common.sh:810`) is
`wm_tmux_windows | tr '\n' ',' | sed 's/,$//'`, and `wm_tmux_windows` is
`tmux list-windows -t "$WM_TMUX_TARGET" -F '#{window_name}'`. So the snapshot is a
comma-joined set of tmux **window names** - exactly the value a roster record's `window`
field holds, and exactly the set `cmd_reconcile` itself compares against
(`bin/lib/wm-state.py:988`: `r.get("window") not in live_windows`). The scan is not
inventing a new liveness notion; it is reading the same fact from the same source through
the same join key as the mechanism that already owns liveness. Confirmed by dumping
`crew-list --all --json` against the scratch roster: the fields are `id`, `parent`,
`status`, `type`, `window`, and `--owner` defaults to `None` (`bin/lib/wm-state.py:2705`),
so `crew-list --all --json` with no owner really is fleet-wide.

The premise behind the finding also re-confirms: `LIVE_STATES`
(`bin/lib/wm-state.py:127`) excludes `done`, and `cmd_reconcile`'s death flip is gated on
`m.get("status") in LIVE_STATES` (`:988`), so a `done` member is never flipped to `died`
when its window disappears. Its status genuinely cannot distinguish a live pane from a
dead one, and a tmux query genuinely is the only source.

**The tmux-dead policy is a real fallback, not a crash and not a silent false-negative.**
Executed against a nonexistent session target:

```
rc=0 out=[]                       # empty window set, clean exit
survived set -e, v=[]             # the command substitution does not abort the loop
```

`wm_tmux_windows` swallows the failure with `2>/dev/null`, and the pipeline's exit status
is `sed`'s, so the assignment yields an empty string with rc 0. `bin/watch-fleet`'s loop
therefore cannot be aborted by it. Running the delivery-reachability predicate against an
empty snapshot:

```
lead-done-live    terminal=True  (done, window dead)  -> SWEEP
lead-done-dead    terminal=True  (done, window dead)  -> SWEEP
lead-stood        terminal=True  (stood-down)         -> SWEEP
lead-live         terminal=False (working)            -> leave to redelivery
```

Every `done` member reads terminal and is swept. That is the stated policy, it fires in
the direction the plan says it does, and it is the correct direction on the merits: with no
tmux server there is no pane for the `done`-loop to deliver into, so sweeping is what
actually happens to the message rather than a guess about it. The sweep is also
non-destructive - the payload is moved to `outbox-abandoned/<id>/<stem>` and the audit line
written before any notice is composed - so the worst case in this scenario is a notice
about a message that could not have been delivered anyway.

**The refinement to the S-1 blind-spot disclosure (plan lines 267-274) is accurate.** Under
a whole-tmux-server death the `stood-down`/`died` limbs are frozen (their statuses never
update without a live-tmux reconcile), but the `done` limb is not blind - an empty window
set is an unambiguous answer for that one limb. The execution above is exactly that
distinction: `lead-live` (a member frozen at `working` by the blind spot) is correctly
skipped, while both `done` members are correctly swept.

## Must-fix 2 (splitting the unified predicate): closed

The two questions are now the right two, correctly separated, and the walk genuinely uses
the broader one.

**They are the right two questions.** "Can this member still be delivered to?" and "will
this member's own watcher ever surface a notice?" are not the same question, and the plan's
justification for why they diverge on exactly the `done` limb checks out against the code:
a lead's own watcher is armed by that lead itself (`playbooks/common/lead.md`, the "Arm your
own watcher" bullet), a member that reports `done` has finished its engagement and arms
nothing further, and wingman reaps a `done` member to `stood-down` in the same turn it
observes the `done` (`CLAUDE.md`, "Member lifecycle"). So a `done` parent's notice file has
no reader regardless of whether its window is still up at the instant the walk runs -
whereas a `done` member's *pane* is exactly what phase 1's `done`-loop exists to service.
Window liveness is load-bearing for one question and irrelevant to the other. The split is
correct.

**The walk genuinely uses the broader one.** The pseudocode (plan lines 328-339) calls
`is_notice_routing_terminal(parent)`, named distinctly from the delivery predicate and
annotated inline with `# missing/stood-down/died/done - no window limb`. There is no
accidental reuse of the narrower predicate anywhere in the walk.

**Executed.** Against the scratch roster with live windows `{wm-lead-done-live,
wm-lead-live}`:

| consumer | member / chain | result |
|---|---|---|
| delivery (scan target test) | `lead-done-live` - `done`, window **live** | not terminal - **not swept**, `done`-loop keeps it |
| delivery | `lead-done-dead` - `done`, window dead | terminal - **swept** |
| delivery | `lead-stood` - `stood-down` | terminal - swept |
| delivery | `lead-live` - `working` | not terminal - left alone |
| notice-routing walk | parent `done`, window **live** | `''` - floors to wingman |
| notice-routing walk | parent `done`, window dead | `''` |
| notice-routing walk | parent's record absent | `''` |
| notice-routing walk | parent `working` | `'lead-live'` |

And the counterfactual, with the walk wrongly reusing the delivery predicate:

```
w-under-done-live -> 'lead-done-live'     # round 6's finding 2, reproduced exactly
```

That is the shape round 6 reported - a notice written to a dead-end parent's file that no
live watcher reads - and it is closed by the split, not by accident. Test 21 in the plan's
testing strategy pins precisely this case, which is the right instrument: it is the
assertion that stops the two predicates from being re-unified later.

## Round 6's four nice-to-haves: all addressed

1. **S-4's residual, and softening the "never loses it" claim** - plan lines 484-502.
   Addressed more thoroughly than asked: the residual window is named precisely (the
   appender's open-to-write gap intersected with the fire's `mv`→`rm` span), the reason it
   is narrow for a shell builtin redirect is stated, the fully race-free alternative
   (`pending-notices-<key>.d/`) is described, and the decision not to build it today is
   stated with a reason rather than left implicit.
2. **Step 7 contradicting step 3** - plan lines 427-434. Step 7 is now explicitly
   sidecar-removal plus `rmdir` only, and the paragraph names the specific hazard it is
   guarding against (implementing step 3 as a `cp`, which would destroy the mv-as-claim
   property S-2 depends on). That is the right way to write it: the invariant plus why.
3. **`NOTICEFILE` sanitization on both sides** - plan lines 462-471. States the writer
   applies the identical `tr -c 'A-Za-z0-9._-' '_'` transform, and names the reason the
   ids can differ (an explicit `--id` is passed through `bin/spawn-crew` unslugified).
   Reader side confirmed at `bin/watch-fleet:155`.
4. **The `:838` citation** - corrected at plan line 180. Verified:
   `bin/watch-fleet:838` is `if wm_tmux has-session -t "$WM_TMUX_TARGET" ...`.

## Other citations spot-checked

All correct: `WM_SEND_LOCK_WAIT`'s 45s default at `origin/main:bin/lib/common.sh:658`;
`GRACE` 30s at `bin/watch-fleet:188`; the beacon touch at `:807`; the four
`wm_tmux_send_message` sites at exactly `:924`, `:928`, `:974`, `:1077`; `LIVE_STATES` at
`bin/lib/wm-state.py:127`; `wm_tmux_windows_csv` at `origin/main:bin/lib/common.sh:810`.

The scan's stated placement - "immediately after the beacon touch" - is verified safe: it
lands before `self_pane_check`, which is itself an `exit 0` path sitting between the beacon
(`:807`) and the tmux gate (`:838`). The plan's own wording ("immediately after the beacon
touch") is precise enough to put the scan ahead of that exit; a looser reading of "near the
top of the loop body" alone would not be, so the precision matters and is present.

---

## Non-blocking observations

None of these is a must-fix and none warrants another round. A and B are one-clause plan
edits worth making only if the plan is being touched anyway; C and D are notes.

**A. Specify exact-field membership when matching a window name against the comma-joined
snapshot.** The plan says the scan derives liveness "by matching that record's own `window`
field against `$_live_windows_csv`". A naive substring match is wrong, and the collision is
not hypothetical - it exists in the live roster right now. The ids
`issue-169-plan-reviewer` and `issue-169-plan-reviewer2` … `issue-169-plan-reviewer7` are
all present, and `wm-issue-169-plan-reviewer` is a strict prefix of every one of the
others:

```sh
csv="wm-issue-169-plan-reviewer7,wm-issue-169-analyst"   # reviewer1's window is gone
win="wm-issue-169-plan-reviewer"
case "$csv"  in *"$win"*)   ... ;;   # matches - reports a DEAD window as live
case ",$csv," in *",$win,"*) ... ;;  # does not match - correct
```

Sequentially-numbered ids for repeated rounds of the same role are this project's ordinary
naming habit, so the colliding shape is the common one, not the exotic one. The error
direction is fail-safe (a dead window read as live means the member is not swept,
i.e. the status-quo orphaning), so this is not dangerous - but it silently defeats the fix
for any colliding pair, and one clause naming the `",$csv,"` form closes it by
construction. This is the same class of "make both sides agree by construction" edit as
round 6's nice-to-have 3, which the plan already accepted.

**B. `crew-prune` pass 1 and `crew-standdown`'s cascade also consume the
delivery-reachability predicate, and the plan names a window snapshot only for the scan.**
The scan's snapshot is specified precisely (one per poll, hoisted alongside the roster read,
for cost). `crew-prune` pass 1 (plan lines 527-531) and `wm_outbox_sweep_abandoned`'s step 2
test the same predicate but have no stated source. The natural implementation - the
predicate helper in `bin/lib/common.sh` takes the live window set as an argument, the scan
passes its hoisted snapshot, the one-shot commands pass a freshly-taken one - is obviously
right and costs nothing in a one-shot CLI. Lower risk than round 6's finding 1 (the data
source is now named prominently, and the worst case here is a notice routed to the wake
channel rather than queued to a live sender - a degradation, not a loss), but one clause
would make the symmetry explicit.

**C. The scan's snapshot is taken before `wm_tmux_adopt_strays`, unlike every other
reconcile caller.** `bin/crew-list:27` and `bin/watch-fleet:846` both run stray adoption
before computing `wm_tmux_windows_csv`, precisely so "liveness never declares a member dead
while its window exists elsewhere on the server" (`bin/lib/common.sh:720-724`). The scan
sits before the tmux gate, so its snapshot is pre-adoption; a `done` member whose window is
a stray in another tmux session would read as windowless and be swept while its pane is
alive. Adoption's own roster pass skips only `stood-down` records, not `done` ones, so the
asymmetry does bite exactly the class the window limb governs. **Reachability is effectively
nil on current code** - `bin/spawn-crew:453` creates the window with an exact-match session
target (`-t "$WM_TMUX_TARGET:"`), so no new stray can arise from a spawn; the adoption pass
is retained for the transitional shape left by issue #39 and for manual tmux surgery. Noted
for completeness, not as a defect. If it were ever worth closing, `wm_tmux_adopt_strays`
self-gates on `has-session` (`origin/main:bin/lib/common.sh:752`) and is safe to call from
before the gate.

**D. Trivial citation.** The plan cites `fire()`'s `exit 0` at `bin/watch-fleet:803`; it is
`:802` (`:803` is the closing brace). Round 6 cited it correctly. Nothing depends on this.

---

## Readiness gut-check

Honest answer: **this is ready.** Round 6 predicted no seventh full round would be needed
once its two edits landed, and having reproduced both, that prediction holds - the edits are
what they claimed to be, they were verified rather than asserted, and each is pinned by a
named test (20 and 21) so it cannot silently regress.

The things that would make me block are absent. There is no reachable shape left where a
member's message is lost: the durable payload move and the audit-log line precede every
notice composition, so the residual risks in the plan are all about a wake *announcement*,
and the plan says so plainly instead of overclaiming. There is no unstated data source
behind a load-bearing decision. There is no predicate doing double duty for two different
questions. The blast radius is seven files in phase 1 with no `bin/lib/wm-state.py` changes,
verified: everything the scan needs (`crew-list --all --json`, `wm_tmux_windows_csv`)
already exists and behaves as the plan says.

Where the plan is genuinely imperfect it discloses rather than papers over - the
tmux-server-death reconcile blind spot it inherits, the `fire()` fold's narrow residual, the
unbounded growth of `outbox/<id>/` directories, at-least-once delivery. Each is stated with
its mechanism, its bound, and why it is out of scope. That is what a plan handed to a
developer should look like.

The four observations above are the kind of thing that gets settled in code review of the
implementation, not in a further round of plan review. Hand it to a developer.

## Open Questions

None from this review. The plan's own two open questions (`audit-log`,
`audit-log-retention`) parse cleanly and both recommendations remain correct; neither is
affected by anything above.
