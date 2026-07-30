# A lead's ready PR sat unescalated behind `working`, and a worker spawned its own worker

**Date:** 2026-07-30
**Mode:** investigate only (report mode) - no fix applied, no PR opened.

## Summary

A lead (`own-the-engineering-skills-expan-lead`, effort: engineering-skills expansion in `greerviau/skills`) spawned a developer, which delivered [PR #17](https://github.com/greerviau/skills/pull/17) and parked in `review`. Neither the lead nor the developer held `allow_merge`, so the PR could only be landed by the requester. The lead's own status stayed `working` for at least the next ~8.5 minutes while the PR sat ready, and the requester found the open PR by checking the repository directly rather than being told. The requester then merged it by hand at `2026-07-30T16:44:12Z`.

Two independent findings, both confirmed against the live crew roster and the actual GitHub state:

1. **The rollup obligation is real but underspecified.** `playbooks/common/lead.md` does tell a lead to enter `review` once "the integrated delivery is up and waiting on the human," but that instruction is a single terse clause disconnected from any concrete trigger, and - per design intent relayed directly by the requester mid-investigation - the correct trigger is **not** "a worker parked in review," it is "a worker parked in review **and neither it nor I hold `allow_merge`**." That second, sharper condition is not written anywhere.
2. **A worker (the developer) spawned its own worker (a reviewer)**, one layer deeper than the documented pilot→wingman→lead→worker chain. This is mechanically unrestricted - nothing stops any crew session, worker or lead, from invoking `bin/spawn-crew` - and it was not an accident: the lead's own spawn objective told the developer to do it, pointing at a procedure ("per your own playbook") that does not actually exist in the developer's playbook. Because `watch-fleet`'s owner-scoping is strictly direct-parent-only, that extra hop put the review verdict one layer outside anything the lead's own watcher could ever see.

Both findings, and their interaction, are detailed below with exact quotes, line numbers, and the live timestamps that ground them.

## How this was investigated

This report is grounded in the actual live incident, not a hypothetical: the crew roster (`~/.wingman/crew.json`), the crew board (`~/.wingman/board.md`), and `gh pr view` against the real PR were all read directly, per the instruction to investigate the defect "in the live roster right now." No pane transcripts were scraped. The wingman checkout used throughout was confirmed fresh against `origin/main` for every file quoted (`bin/lib/git-freshness-check.sh`) - the one commit it was behind (`00afb82`) only committed this repo's own pre-existing analysis docs and touches none of the files cited here.

This report also incorporates design intent relayed directly by the requester partway through the investigation (reproduced in full in "The `allow_merge` discriminator" below), which sharpens the diagnosis in sections 1 and 2 and the ranking in section 4. That guidance is authoritative for what follows; where an earlier line of reasoning in this investigation would have concluded differently, this report states the corrected conclusion.

Four existing reports in `docs/analysis/` cover adjacent watcher/reconcile territory and are cited, not duplicated, where relevant:
- `2026-07-28-watch-fleet-spurious-deaths-and-dropped-wakes.md` (a lead's own watch-fleet exit event silently discarded by a `crew-ask` race - issue #197, open)
- `2026-07-29-usage-limit-threshold-latching.md`
- `2026-07-30-tmux-server-death-and-reconcile-blind-spot.md`
- `2026-07-30-why-wingman-keeps-crashing.md` (synthesis of the first two plus a new tmux-server-death finding)

None of these four address the lead-rollup gap or the worker-spawns-worker pattern; this is new ground.

## Incident reconstruction (live data)

From `~/.wingman/crew.json` (read directly, not via `bin/crew-list` since the running effort is not mine to summarize secondhand - the raw record is the actual evidence):

| id | type | parent | status | `allow_merge` | delivery | `updated` |
|---|---|---|---|---|---|---|
| `own-the-engineering-skills-expan-lead` | lead | (top-level) | `working` → `review` | `false` | PR #17 | `16:41:22Z` |
| `implement-the-non-skill-fixes-se-developer` | developer | the lead | `review` | `false` | PR #17 | `16:32:52Z` |
| `review-pr-17-https-github-com-gr-reviewer` | reviewer | **the developer** | `done` → stood-down | `false` | PR #17 | `16:41:39Z` |

The developer settled into `review` at **16:32:52Z**. The lead's own status did not move to `review` until **16:41:22Z** - **8 minutes 30 seconds** later, and only once its own state file shows the developer's self-spawned reviewer's outcome already resolved. `gh pr view 17` confirms the PR was merged at **16:44:12Z** by the requester's own GitHub account - and since `allow_merge` was `false` on both the lead and the developer, `hooks/no-merge-guard.sh` would have refused a `gh pr merge` from either agent session, so this was a human hand-merge, consistent with the requester's report of finding the PR by checking the repository directly.

(As of this report, the situation has since resolved on its own: the lead's current board line reads "PR 1 (non-skill fixes) merged by the human. Starting PR 2: mermaid skill" - it caught up, reaped the reviewer, and moved on to the next phase. The defect is the *gap*, not a permanently stuck state.)

The developer's own spawn objective (verbatim, from its crew record) contains the instruction that produced the extra layer:

> "Get this reviewed (spawn or coordinate with a reviewer per your own playbook) before considering it done. Do not merge the PR yourself under any circumstances - the human merges; park it open and watch it per your own playbook's PR-watch step."

That objective was authored by the lead itself when it spawned the developer (see the lead's own record - the developer-spawn text is the lead's own composition, following its playbook's "Build" pipeline step). This is the direct cause of finding 3 below.

## 1. The rollup gap: is the obligation written down?

**Answer: partially written, and the part that actually matters here is absent.**

`playbooks/common/lead.md`'s only explicit state-mapping instruction is the last paragraph of the file (`lead.md:93`):

> "You are yourself a report of your owner's, so you keep your own status file honest: `working` while you are orchestrating, `blocked` when you must escalate a decision, `review` when the integrated delivery is up and waiting on the human, `done` when the whole effort is delivered and dispositioned."

Read charitably, "review when the integrated delivery is up and waiting on the human" *does* cover the case that happened - the developer's PR was up, green, and waiting on the requester. So the obligation is not *genuinely absent* at the level of "a lead must eventually reflect a ready deliverable in its own status." Two things make it easy to miss in practice, and one thing about it is actually missing:

- **Positioning.** This is one clause in the very last sentence of a 93-line playbook, stated as a terse four-way state mapping rather than as a triggered rule. The concrete event that should fire it - "a direct-report worker just settled into `review` holding a PR" - is never named next to it. The closest the playbook comes to a concrete trigger is the "Confirm forward motion for every `review` worker" section (`lead.md:44-51`), which is about *keeping a worker's review moving* (has it got a reviewer, has a fix been relayed, is it externally blocked) - not about *the lead's own status* at all. A careful reading of the whole file gets there; a reading focused on "what do I do when my worker parks in review" (the "Supervise & iterate" and "Confirm forward motion" sections, which is where that question is actually answered for the worker's *own* forward motion) does not surface the lead's own state obligation, because it isn't stated there.

- **The pipeline section undersells it too.** Step 5, "Human checkpoints" (`lead.md:67`): "Surface phase gates upward for the human's sign-off (general spec approved? plan approved? ship?). A developer that opened a PR additionally waits on the human's own review/merge on the forge." This sentence describes what the *developer* does ("waits"), not what the *lead* must do in response. It reads as background on the pipeline shape, not as an instruction to the lead to transition its own status.

- **The specific discriminator is genuinely absent.** Per design intent relayed directly during this investigation (quoted in full below): the correct trigger is not "a worker is in `review`," it is "a worker is in `review` **and neither it nor I hold `allow_merge`**." When the effort *does* hold merge autonomy, a worker reaching `review` is routine internal progress the lead should absorb and continue past, not escalate. `lead.md`'s existing text has half of this: the "Confirm forward motion" section's case (c) (`lead.md:48`) already tells the lead what to do when *the worker itself* holds `allow_merge` and the gate looks satisfied (nudge it to attempt the merge) - but it never states the inverse, far more common case: no `allow_merge` anywhere in the chain, PR green, worker parked in `review` → the lead's own status must become `review` (or otherwise escalate), now, unconditionally. That specific rule does not appear anywhere in `lead.md` or `playbooks/_status-contract.md`.

So: **not "the lead ignored an instruction that was clearly there."** The general "review means waiting on the human" mapping exists, but the one instruction that would have made this specific case unambiguous - the `allow_merge`-keyed trigger - was never written. A lead following the letter of the current playbook has no rule that says "check `allow_merge` before deciding whether a report's readiness is my problem to escalate."

### The `allow_merge` discriminator (design intent, relayed directly)

The requester supplied this framing directly partway through the investigation, and it is treated as authoritative for the diagnosis and the recommendations below:

> The rule is that merge autonomy is the discriminator for whether a ready PR must be escalated: a lead WITHOUT merge autonomy (`allow_merge` false, the default) cannot land its own work, so when one of its workers reaches a PR that is waiting on human review, that lead is structurally stuck - the effort cannot progress without the human. It MUST alert its owner, who alerts the human. Sitting at `working` while a worker parks on an unmergeable PR is the bug. This is exactly what happened with PR #17. A lead WITH merge autonomy can land the work itself; a worker's PR reaching `review` is then an ordinary internal step, not a human-facing event, and the lead should absorb it and carry on without alerting anyone.

This was independently corroborated by the live data: both the lead's and the developer's `allow_merge` were `false` for this effort, and the PR did in fact require a manual human merge - exactly the "structurally stuck, must alert" case.

**Is `allow_merge` actually readable from state a lead or a watcher can see?** Yes, confirmed by direct inspection. It is a plain field on every crew roster record (`bin/lib/wm-state.py:521`, `:844-845`), fully readable by any session with normal file/roster access - not session-scoped, not write-restricted-implies-read-restricted (only the *write* path is gated, to human/owner-only, via `hooks/no-merge-guard.sh`'s `check_allow_merge_grant`). It is already surfaced in every rendering `bin/crew-list` produces: the flat view annotates a line with `merge: AUTHORIZED for this effort (issue #46)` (`wm-state.py:2477-2478`), the tree view does the same (`wm-state.py:2503-2504`), and the board's active-table id cell appends `(merge-authorized)` (`wm-state.py:2524`). So a lead reading its own team via `crew-list` already sees this, in plain text, with no extra digging - the mechanical version of the fix is not harder than the prose version on this specific point.

## 2. Can the architecture detect this at all?

**Answer: no existing safety net covers it, and the reason is a specific, confirmed mechanical property of `watch-fleet`'s owner scoping - not a vague design smell.**

`bin/watch-fleet`'s own header states the scoping rule plainly (`watch-fleet:85-89`):

> "Owner scope: each cycle watches exactly one owner's direct reports. Wingman arms its own cycle (`--owner ""` - it has no `$WINGMAN_CREW_ID`) and never sees a lead's workers; a lead arms its own (`--owner <lead-id>`, the default from its own `$WINGMAN_CREW_ID`)..."

And the filter that implements it, in `cmd_needs_attention` (`wm-state.py:1613`):

```python
if owner is not None and parent_of(r) != owner:
    continue
```

`parent_of` (`wm-state.py:343-346`) returns the record's *immediate* `parent` field - not an ancestor chain, not "anyone transitively under me." This is a **direct-parent-only** filter, confirmed by reading the code, not inferred from behavior. The same direct-parent semantics govern `bin/crew-list`'s default (non-`--tree`) view (`wm-state.py:934-936`: `rows = [r for r in rows if parent_of(r) == owner]`).

Applied to this incident: the lead's own watch-fleet cycle runs `--owner own-the-engineering-skills-expan-lead`. The developer (`parent = own-the-engineering-skills-expan-lead`) is in scope - its `working → review` transition is exactly the kind of event that cycle exists to catch, and should have fired it. But the developer's own reviewer (`parent = implement-the-non-skill-fixes-se-developer`, i.e. the developer, not the lead) is **structurally outside** that watcher's scope. No `--owner` value the lead could pass would ever include it, short of `--tree` (which is a manual, whole-org rendering command, not a watch mode - `watch-fleet` has no tree/recursive mode at all). The reviewer's `done`-with-approve event was therefore, by construction, invisible to the one mechanism designed to wake the lead.

This matters independent of whether the lead's own turn-taking was diligent: **even a lead that perfectly follows every instruction in its playbook has no channel through which its own watcher tells it "your worker's own worker just finished."** The information can only reach the lead if the developer proactively relays it - and nothing in `playbooks/software-development/developer.md` or `playbooks/_delivery.md` instructs a developer to report a self-spawned reviewer's verdict to its owner. `_delivery.md`'s own state-mapping section (`_delivery.md:100-115`) lists the developer's `working`/`review` transitions purely in terms of PR/CI signals (`ci-failed`, `conflict`, `checks-passed`, `merge-ready`, `merged`/`closed`) - an inter-agent reviewer's `crew-say` verdict is not one of the enumerated triggers, so a developer already parked in `review` (PR green, waiting on humans) has no documented reason to touch its own status file at all when that verdict arrives. It can simply stay silent in `review` - correctly, by the letter of its own playbook - while holding information its owner has no way to learn about.

**Is there an existing safety net?** No - checked directly against `wm-state.py`'s `reconcile` (dead-window detection and dead-owner re-adoption, both scoped to `owner == ""` and both about *liveness*, not about a live-but-quiet lead sitting on stale information) and against the stall detector (`playbooks/_status-contract.md`'s "A state you never set yourself: `stalled`" - explicitly about *no pane activity*; a lead correctly re-armed on its own watcher and idling normally is, by design, never flagged, per `_status-contract.md:74`: "Parking on an armed harness-tracked watcher is recognized... and is never flagged"). None of the four existing analysis reports in `docs/analysis/` describe this pattern either - the closest is `2026-07-28-watch-fleet-spurious-deaths-and-dropped-wakes.md`'s finding (issue #197, open) that a lead's own watch-fleet *exit* event can be silently discarded when a concurrent `crew-ask` interrupts the lead's turn before it calls `--classify`. That is a plausible **compounding** factor for the 8.5-minute gap even on the direct-parent hop that *should* have worked (the developer's own `working → review` transition) - it is not verified for this specific incident (no pane transcript was read, consistent with the general guidance against scraping crew panes), but it is a known, confirmed mechanism that would produce exactly this symptom (a fire that should have woken the lead promptly, silently dropped, with the lead only catching up later via some other path). This report does not re-derive #197; it flags the overlap.

### Does a mechanical safety net belong here, and where?

Yes - and it does not require weakening owner-scoping's context-protection property, because the *data* is never actually siloed, only the *watch/notification* layer is. `crew.json` is a single flat roster with a `parent` field on every record; `descendants_inclusive` (`wm-state.py:349-353`) already walks it downward for stand-down cascades. Walking it *upward* (record → parent → parent's parent → ...) to test a specific, narrow condition is a small, well-scoped addition, not an architectural change - and it need not run on every poll or surface every intermediate state, only compute a boolean.

There is also direct precedent for exactly this shape of cross-cutting check living outside normal owner-scoped polling: `wm-state.py` already runs several checks unconditionally on `owner == ""` (wingman's own top-level cycle) that look *past* simple direct-report scoping - dead-owner re-adoption (`wm-state.py:1001-1002`), orphan-window adoption (`:1043,1051`), the fleet-wide outage state machine (`cmd_outage_update`, `:1782`), and the usage-limit-quota state machine (`cmd_usage_update`, `:1881`), each explicitly commented as "owner-''-only" specifically because only the top-level cycle is positioned to see the whole fleet. A new check - "does any live record in the whole tree hold a ready PR (`status == review`, `delivery` set) with no `allow_merge` anywhere between it and the root, whose nearest lead/orchestrator ancestor is *not itself* already in an attention state" - fits this exact established pattern: computed once per `owner == ""` poll, from the full roster already in memory, surfacing only a boolean-plus-pointer rather than any transcript detail. It does not need `watch-fleet` to abandon direct-parent scoping for its normal per-owner cycles (which remains correct and desirable for keeping each layer's context small); it needs one additional, narrowly-scoped check bolted onto the one cycle that already looks at everything.

## 3. The depth-cap anomaly: a worker spawned a worker

**Confirmed as reported, and the mechanism is now precisely understood.**

CLAUDE.md states the cap (`CLAUDE.md:223`):

> "**Depth cap: 2 crew layers.** The chain is pilot → wingman → lead → worker. A lead spawns workers but **not** further leads."

And `lead.md` restates it from the lead's own side (`lead.md:87`):

> "**Depth cap: you do not spawn managers.** You may spawn `software-analyst`/`architect`/`developer`/`reviewer` workers; management depth is capped at two layers (you and your workers). Deeper nesting is a future opt-in."

Both statements are about **leads not spawning further leads/managers**. Neither says anything about whether a *worker* (developer/reviewer/architect/software-analyst) may spawn its own crew. That is a real gap in the stated policy, not just an enforcement gap: the literal cap as written was not violated (no lead spawned a lead here), yet the effort ended up five sessions deep (human → wingman → lead → developer → reviewer) - one layer past what "capped at two layers (you and your workers)" describes, via a route the policy simply never addresses.

**Mechanical enforcement: none, for any crew type, for any spawn target.** Checked directly:
- `bin/spawn-crew` never reads or branches on the *caller's own* `$WINGMAN_CREW_TYPE` to restrict what it may spawn - the only use of `WINGMAN_CREW_TYPE` in the whole script is to *export* the spawned child's own type into its environment (`spawn-crew:364`), never to gate the parent.
- The only two `PreToolUse` hooks that touch `spawn-crew` at all are `hooks/api-outage-spawn-guard.sh` and `hooks/usage-limit-spawn-guard.sh` - both are global rate/availability gates, unconditional on crew type.
- `hooks/no-direct-edit-guard.sh` - the hook that *does* mechanically enforce a CLAUDE.md prime directive (`no-direct-edit-guard.sh:1-9`, citing issue #17: "the prompt-level instruction alone did not stop wingman from editing code directly once 'it's a small change' felt like an implicit exception") - is scoped to block `Edit`/`Write`/test-runner calls only for `WINGMAN_CREW_TYPE=lead` or wingman's own top-level session, and explicitly says every worker type is exempt because editing/testing is "literally the job" for them (`no-direct-edit-guard.sh:26-28`). It has no opinion on `spawn-crew` at all.

So today, **any** crew session - a `developer`, a `reviewer`, an `architect`, a `software-analyst`, or a `lead` - can invoke `bin/spawn-crew --type <anything, including lead>` and it will succeed, exactly as any other `Bash` call would. The depth cap is prose in two files, unenforced in the one direction that was actually exercised.

**Was this a rogue action, or an instructed one?** Instructed - traced directly to the lead's own spawn objective, quoted above: "Get this reviewed (spawn or coordinate with a reviewer per your own playbook) before considering it done." This phrasing was almost certainly drawn from `lead.md`'s own pipeline step 4 ("Integration"), which says developers "share an interface coordinate directly with each other... pulling in a `reviewer` as needed" (`lead.md:66`) - a sentence written about multi-developer interface coordination, but generic enough to read as blanket license for any developer to self-serve a reviewer. Critically, **the referenced procedure does not exist**: `playbooks/software-development/developer.md` (17 lines total) never mentions spawning anything, and `playbooks/_delivery.md`'s "Getting review feedback" section (`_delivery.md:48-52`) describes review arriving passively ("When a reviewer looks at your work, its verdict and findings reach you as a `bin/crew-say` message") without ever saying who is responsible for causing that reviewer to exist. "Per your own playbook" pointed the developer at a playbook section that isn't there. Faced with an instruction to get reviewed, no interactive way to ask a human, and unrestricted `Bash` access to the same `bin/spawn-crew` tool every lead uses, the developer did the only thing available: spawned a reviewer itself.

**Did this extra depth contribute to finding 1? Directly and mechanically**, per section 2 above: had the lead spawned the reviewer itself (keeping it a direct report, a sibling of the developer under the lead), the reviewer's `done`/approve transition would have been squarely inside the lead's own `watch-fleet --owner <lead-id>` scope, and would have fired the lead's watcher independent of anything the developer did or didn't relay. Because the developer spawned it instead, that entire event class - "the review concluded, with this verdict" - was pushed one hop outside the one channel designed to reach the lead automatically. The lead was left dependent on either its own diligence in re-reading `crew-list` on an unrelated wake, or an explicit relay from the developer that no playbook instructs it to send. This is the same underlying mechanism from section 2 (owner-scoping is direct-parent-only), just triggered by the depth-cap anomaly rather than by anything the lead itself did wrong.

## 4. Recommended fixes, ranked

Ranked by cost/risk to ship first; 1-2 are cheap and safe, 3 changes behavior in a load-bearing hook, 4 is the architectural addition.

### 1. (Cheap, safe, prose-only) Add the `allow_merge`-keyed escalation rule to `lead.md`

**File:** `playbooks/common/lead.md`, in the "Confirm forward motion for every `review` worker" section (`lead.md:44-51`), as an explicit case alongside (a)/(b)/(c), or immediately following it.

Add language stating, precisely: when a direct-report worker is parked in `review` holding a ready delivery (PR green, or - for a non-PR deliverable - an artifact awaiting sign-off), and **neither that worker nor the lead itself holds `allow_merge` for this effort**, the lead's own status must become `review` (with that worker's `delivery`/`artifact` reflected as the lead's own, per the existing "Integrate" step) as its very next action - not "eventually," not "once I next check in," immediately upon recognizing the condition. Conversely, state explicitly that when `allow_merge` **is** held (by the worker or granted to the effort), a worker's arrival in `review` is routine and must **not** move the lead's own status - it stays `working`, consistent with `_status-contract.md`'s "self-managed churn" framing, and the lead simply relies on the existing merge-ready/nudge flow ((c) in the same section) to see it through.

This single rule closes the specific gap identified in section 1: it is the sharp, checkable trigger that today's text only gestures at, and it directly encodes the discriminator the requester specified. It costs nothing to ship, changes no code, and cannot false-positive against a merge-autonomous effort (which was the requester's explicit concern about a cruder "worker entered review" heuristic).

**Tradeoff:** still relies entirely on the lead's own turn actually running the check - it does nothing for a dropped wake (issue #197) or for a lead that never gets woken in the first place because the ready deliverable is a grandchild's, not a child's (see #2 below). It is necessary but not sufficient.

### 2. (Cheap, safe, prose-only) Stop instructing workers to self-serve a reviewer; have the lead spawn it

**Files:** `playbooks/common/lead.md` pipeline step 4 (`lead.md:66`) and, if the same "get this reviewed, per your own playbook" pattern is used elsewhere when a lead spawns a developer, whatever text authors that objective.

Reword step 4's "pulling in a `reviewer` as needed" to make explicit that *the lead* spawns the reviewer as its own direct report (a sibling of the developer under the lead) when a single developer's PR needs review, reserving "developers coordinate directly" for the genuinely multi-developer interface-negotiation case the sentence was originally about. Stop composing developer-spawn objective text that says "spawn or coordinate with a reviewer per your own playbook" - that playbook section does not exist (confirmed in section 3); either write the objective without it, or add a real "how to request review" section to `developer.md`/`_delivery.md` that says explicitly **not** to spawn one, but to report readiness to the owner instead.

This is the fix that most directly prevents a recurrence of the *specific* incident (section 3), and as a side effect it closes the owner-scoping blind spot from section 2 for the review-spawning case specifically, for free - no mechanical change needed, because the reviewer simply never leaves the lead's watch scope in the first place.

**Tradeoff:** purely a convention fix. It does not stop a worker from spawning crew in some other future situation nobody anticipated - see #3.

### 3. (Medium, behavior change) Mechanically restrict `spawn-crew` to orchestrator-type callers

**File:** a new `PreToolUse` hook, structurally mirroring `hooks/no-direct-edit-guard.sh`'s activation condition (`WINGMAN_CREW_TYPE` check), denying a `bin/spawn-crew` invocation when the calling session's own `WINGMAN_CREW_TYPE` is a worker type (`developer`, `reviewer`, `architect`, `software-analyst`, and any other non-`lead` playbook), the same way that existing hook already distinguishes orchestrator roles from worker roles for `Edit`/`Write`/test-running.

This makes the depth cap real rather than aspirational, for every crew type, not just the lead→lead case CLAUDE.md happens to name. It is the kind of fix this project has already reached for once for a closely analogous problem (`no-direct-edit-guard.sh`'s own justification, verbatim: "the prompt-level instruction alone did not stop wingman from editing code directly... once 'it's a small change' felt like an implicit exception" - the same logic applies here: the prompt-level cap did not stop a worker from spawning a worker once its own objective text implied it should).

**Tradeoff:** this is a genuine behavior change, and per `lead.md:87`'s own words ("Deeper nesting is a future opt-in"), the project may want to leave room for an intentional, human-granted exception later rather than hard-blocking universally. It also slightly increases the number of places a spawn can be denied, which needs a clear error message pointing back at "ask your lead/owner to spawn this instead" so a blocked worker doesn't just report a confusing `blocked`. This is a decision for the requester, not something to default into (see "Open question" below).

### 4. (Larger, architectural) A cross-tree `allow_merge`-aware safety net in wingman's own `owner == ""` cycle

**File:** `bin/lib/wm-state.py`, as a new check alongside the existing `owner == ""`-only logic (`cmd_outage_update`, `cmd_usage_update`, the dead-owner re-adopt pass in `cmd_reconcile`) - i.e. extend the pattern already established at `wm-state.py:1782` and `:1881`, not invent a new one.

Add a small ancestor-walk helper (the upward-walking counterpart to the existing downward `descendants_inclusive`, `wm-state.py:349-353`) and a check that runs once per top-level poll: for every live record with `status == review` and a `delivery`/`artifact` set, walk its `parent` chain to the root; if no record on that path (including itself) has `allow_merge` true, and the nearest ancestor of type `lead` is *not itself* already in an attention state (`review`/`blocked`), surface it as a new fire reason (e.g. `stuck-review: <lead-id> has a descendant <id> ready with no merge authority`). This is the true backstop: it fires **regardless of** whether the lead's own diligence holds up, whether a wake got dropped (#197), or how many hops deep the ready deliverable actually is - the exact gap section 2 identifies as structurally undetectable today.

**Tradeoff:** this is real new code in a load-bearing state-machine file, needs its own tests, and needs care to avoid false-firing on a lead that is legitimately mid-integration (e.g. deliberately holding a worker in `review` for a moment while it composes a combined delivery across several workers) - the "not already in an attention state" clause is meant to cover this but should be verified against real multi-developer efforts, not just this single-developer incident. It is the only recommendation here that closes the gap even when everything upstream of it (lead diligence, prose fixes, #2's convention change) fails or hasn't shipped yet - which is also why it is ranked last, not first: it is a backstop for the other three, not a replacement for them.

## Decisions (settled - do not re-open)

Both decisions posed by the original "Open Questions" section have been made by the requester. Recorded here so an implementer does not need to re-litigate them:

- **`spawn-restrict` - settled: add the mechanical hook (recommendation #3).** `bin/spawn-crew` is to be mechanically restricted to orchestrator-type callers (`lead`/wingman's own top-level session), not left prose-only. Implement per recommendation #3 above: a new `PreToolUse` hook mirroring `hooks/no-direct-edit-guard.sh`'s `WINGMAN_CREW_TYPE` activation, denying `bin/spawn-crew` when the caller's own `WINGMAN_CREW_TYPE` is a worker type (`developer`, `reviewer`, `architect`, `software-analyst`, or any other non-`lead` playbook). Give the denial a clear message pointing the blocked worker at its owner/lead rather than leaving it to report a confusing `blocked`. Recommendation #2 (fixing the lead's own spawn-objective text so it stops pointing developers at a "spawn a reviewer per your own playbook" procedure that doesn't exist) is **not** superseded by this decision - both ship together, since the hook stops the mechanism but the misleading objective text is still worth correcting at the source.
- **`mechanical-safety-net` - settled: ship the prose fixes first, defer recommendation #4.** Recommendations #1 (the `allow_merge`-keyed escalation rule in `lead.md`) and #2/#3 above ship now. The cross-tree `allow_merge`-aware safety net in `wm-state.py`'s `owner == ""` cycle (recommendation #4) is deferred - not rejected - pending either a recurrence the cheaper fixes don't prevent, or progress on issue #197 (the dropped-wake race), which #4 is the only recommendation here that would also cover.

Implementation order following from these two decisions: **#1, #2, and #3 ship together** as one pass (all prose plus the one mechanical hook); **#4 stays a documented follow-up**, not scheduled work, until one of the triggering conditions above is observed.
