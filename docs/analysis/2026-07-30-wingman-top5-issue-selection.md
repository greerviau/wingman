# Wingman improvement effort — top 5 issue selection

## REVISED per human reprioritization (2026-07-30, after #213 landed)

The human filed 3 new issues from live failures observed in *this session*
(#214, #216, plus a priority-insert #213 already shipped) and asked to
reweight the five, folding these in. Revised order (#169 already mid-flight
when this landed, finish it first regardless of new ranking; #212 already
had a slot; one slot kept from the original four, three dropped):

1. **#169** (in flight, finishing per explicit instruction not to abandon
   partway) — outbox message loss.
2. **#214** — a blind `C-c` in `wm_tmux_send_message` aborts a crew member's
   in-flight tool call; the harness reports it back as a user refusal, which
   is then absorbed into silence. General race in the shared delivery layer
   (`crew-say`, `crew-ask`, `crew-resume`'s nudge, `crew-standdown`'s
   reconnect, watch-fleet's own stall-check nudge, `/remote-control`
   retries) — not scoped to one crew type. Its worst case (the stall-check
   nudge aborting genuine in-progress work into an apparent stall) defeats
   the exact mechanism meant to catch stalls. Fired twice today. Design
   decisions settled in the issue body — implementing as written.
3. **#212** — lead rollup gap + worker-spawns-worker (unchanged from
   original ranking; see below). Live-reinforced today: issue #213's own
   developer spawned 6 throwaway sub-crew despite an explicit instruction
   not to, during this very effort.
4. **#216** — a stood/resolved `blocker` field survives the transition out
   of `blocked` and gets reported as current by the stop-guard hook,
   producing a misleading escalation. Small, cheap, but directly observed
   today wasting a round-trip on a resolved question re-surfacing as live.
5. **#203** — kept over #199/#202 (the two dropped): #203 has the widest
   demonstrated blast radius (every blocked question serializes *all*
   unrelated work, not one narrower failure mode) and is a direct, verbatim,
   repeated pilot complaint with the largest quantified cost (~25+6+7 issues
   parked across three cited incidents). #199 (54-min false-status stall)
   and #202 (5.5h foreground-watcher wedge) are both real and severe but
   narrower in trigger frequency/scope than #203; dropped to make room for
   #214/#216 per the human's explicit "keep only the strongest of yours"
   instruction. Not closed, just out of this pass's five.

Original selection reasoning below, still accurate for the picks that
survived.


Selected from 37 open issues (`gh issue list --state open`), ranked by impact on
wingman actually working reliably for the human who runs it. Silent loss of
work/information ranks above cosmetics; a defect already observed live ranks
above a hypothetical.

## Ranked five (execution order)

1. **#169 — Queued crew messages are silently abandoned when the target member ends.**
   The outbox retry only runs inside the *target's owner's* watch cycle, and
   nothing services it once the target goes `done`/`stood-down`/`died`. Live
   evidence: six queued messages, all senders believing delivery was
   guaranteed, sitting undelivered for two+ days; the redelivery path has
   **never once succeeded** across the entire observed history
   (`ls outbox/*/sent-* | wc -l` → 0). This is silent data loss on the exact
   channel that carries the human's answers to blocked crew — the single
   worst "drops work invisibly" defect in the list.

2. **#212 — A lead's ready PR sat unescalated behind `working`, and a worker
   spawned its own worker.** Filed from a live incident in this same lead
   role I am running as. Two settled defects: (a) a lead isn't told to
   propagate a worker's `review` upward when it lacks `allow_merge`, so a
   ready PR is structurally invisible to the owner; (b) nothing mechanically
   stops a worker from spawning its own crew, breaking the two-layer depth
   cap. Design decisions are already settled in the issue body (mechanical
   spawn restriction: yes; cross-tree safety net: defer) — implementing as
   written, not re-litigating.

3. **#199 — A lead can stall indefinitely waiting on a watcher fire that
   never arrives, with no independent recheck.** Live incident: a lead sat
   idle 54 minutes with three finished, unreviewed PRs, reporting "parked,
   awaiting reset" the whole time — a false status relayed to the human.
   Caught only because the owner grew suspicious and asked directly. This
   breaks the core "consume distilled status, trust the roster" contract the
   whole system depends on.

4. **#202 — A delegate told to arm its own watcher can run watch-fleet in the
   foreground and wedge itself indefinitely, invisible to the stall
   detector.** Live incident, most severe single duration observed anywhere
   in the tracker: a lead wedged for **5 hours 27 minutes** with its entire
   effort stopped behind it. `blocked` carries no liveness expectation at
   all, so a wedge in that state is undetectable by design, not by accident.

5. **#203 — A blocked lead stops its entire effort, so one unanswered
   question halts every unrelated issue.** Direct, verbatim pilot complaint:
   "stop holding up progress by asking me so many questions... it halts all
   development, sometimes overnight when I want it most." Quantified
   real-world cost: ~25 issues parked overnight on one merge-gate question,
   6 issues parked on a product question, 7 parked on a denied spawn. This is
   the most directly "bitten in practice, repeatedly" item in the tracker
   after #169.

Note: #199, #202, and #203 are cross-referenced by the reporter as "the same
lead stopped making progress while looking healthy" — related symptoms, not
duplicates. Each gets its own scoped plan; later plans will check what the
earlier fixes already cover to avoid conflicting changes to
`playbooks/common/lead.md` / `_status-contract.md` / `bin/watch-fleet`.

## Notable issues considered and not selected

- **#209** (mass-death reconcile skipped when tmux session absent) — real
  incident, severe, but only triggers on a rarer whole-tmux-server death;
  #203's failure mode (every blocked question) is far higher frequency.
- **#188** (send-confirm checksums the whole pane, false-positive delivery on
  a busy pane) — thorough, code-verified, and plausibly upstream of some of
  #169's data loss, but derived from an audit rather than a live incident;
  #169's queue-service gap is the confirmed, measured loss. Worth a follow-up
  pass later.
- **#197** (genuine watch-fleet fires logged as dropped-wake on a message
  race) — a contributing cause of stalls like #199, but #199's own proposed
  fix (an independent recheck instead of relying solely on the fire) already
  neutralizes the consequence without needing #197's race fixed too.
- **#196** (watch-fleet killed by an out-of-band signal, likely SIGURG from
  the harness) — root-caused with strong evidence, but the issue's own
  conclusion is that no fix inside this repo can reach the harness-owned
  wrapper process. Not actionable here.
- **#187** (member parked in `review` with no armed waker never resurfaces)
  — real gap, but the issue explicitly flags a tension with #57 that the
  issue author says needs an explicit pilot decision before implementing.
  Deferred rather than forcing that decision as part of this pass.
- **#205** (a lead's own handoff doc has nowhere legal to live) — real
  incident, but narrower blast radius (fires once, at a lead's standdown)
  than the top five.
