# Reporting contract: surface results, not mechanics

Date: 2026-07-13
Status: ready for implementation
Scope: repo-scoped (`wingman`), single-role (developer implements directly from this plan)

## Problem

The pilot's stated principle (`~/OPINIONS.md`, "Only surface finished deliverables"):

- An agent reports what it **did**, not what it is **doing**.
- The test for anything surfaced upward: is this something the recipient needs to **action**? If not, it does not get reported.
- This applies at every layer: worker → lead, lead → wingman, wingman → pilot.
- A deliverable is surfaced **once**, when it is genuinely ready - never "here's a PR", then "it has conflicts", then "now it's ready."
- **Corollary for signal routing:** a problem that is the owning agent's own to fix (a merge conflict, a failing check, a stale branch) is routed *to that agent*, not up the chain. Detection is useful; escalation is not.
- A status report to the pilot is high-level effort state, ready deliverables, and actionables - not crew ids, session ids, window names, watcher pids, or tool mechanics.

This is a concrete, live violation of that principle: PR #36 (`e659155`, merged 2026-07-12) added merge-conflict drift detection to `bin/watch-fleet`. The feature works as designed, but the design itself violates the principle it should have followed: it detects a PR's mergeability drifting into `CONFLICTING` and surfaces that as a synthetic `needs-attention` row (`"<id>#conflict"`), which fires `bin/watch-fleet`'s wake exactly like a genuine `blocked`/`stalled` event - i.e. **upward**, to wingman (or a lead), which is then instructed (`CLAUDE.md`) to relay it back down to the owning developer via `bin/crew-say`. The detection is right; the escalation hop through wingman is not. A merge conflict is exactly the class of problem the corollary above names: the owning developer's own to fix, silently.

A second, related gap: `bin/pr-watch` (armed by the developer against its own PR while parked in `review`) does not request `mergeable`/`mergeStateStatus` either (documented as an open question in the original PR #36 plan, `docs/plans/2026-07-12-watch-fleet-merge-conflict-drift-detection.md`, "open question 4"). So even a developer actively watching its own PR would miss this class of drift today - the supervisor-level feature was compensating for a gap in the *owning* member's own loop, at the wrong altitude, instead of closing the gap where it actually lives.

A third, broader gap: even where a member's return to `review` is legitimate, the current state machine re-fires a wake **every** time `status` flips to `review` with a new `updated` timestamp - regardless of whether anything changed that the recipient needs to know about. A developer that self-fixes CI, a conflict, or a routine review comment and settles green again re-announces "ready" a second (or Nth) time for the same PR, which is precisely the "come back again saying it's ready" pattern the pilot's principle rules out. This also means every such touch re-fires `hooks/stop-guard.sh` (needs a fresh block-then-allow cycle each time), which is a symptom of the same root cause, not a separate bug to patch with more suppression.

## Investigation: auditing every existing upward-attention source

`bin/lib/wm-state.py`'s `ATTENTION_STATES = ("blocked", "review", "done", "died", "stalled")` plus the merge-conflict synthetic row are the only things that ever wake wingman/a lead. Checked each:

| Source | Genuinely a boss-only decision? | Verdict |
|---|---|---|
| `blocked` (member self-reports) | Yes - by definition the member cannot proceed without a human decision. | Correct altitude, unchanged. |
| `review` (member self-reports) | Yes, **the first time** - a new deliverable is worth one look. Re-entries are the problem (see below). | Needs the fix in this plan (§3). |
| `done` (member self-reports) | Yes - terminal, fires once by construction (a member reaches `done` once, then is reaped). | Correct altitude, unchanged. |
| `died` / `stalled` (watcher-detected) | Yes - reviving a dead/frozen session or deciding to stand it down is not something any agent can do to itself. | Correct altitude, unchanged. |
| Permission/trust-prompt freeze → `blocked` | Yes - only a human can answer an interactive gate. | Correct altitude, unchanged. |
| API-error nudge (`WM_APIERR_RE` match) | No - and it already isn't escalated. `bin/watch-fleet` sends the nudge directly into the member's own pane (`wm_tmux_send_message`) and only escalates to `stalled` if the nudge fails to clear it. | Already the right pattern - this is the existing precedent the merge-conflict feature should have followed and didn't. |
| Mass-death / correlated-outage grouping | Yes, in the sense that resuming several dead sessions is a spawn-equivalent cost decision the pilot should confirm. | Correct altitude, unchanged. |
| **Merge-conflict drift → synthetic `"<id>#conflict"` attention row** | **No** - it is a plain example of "a failing check" from the corollary. Nothing about it requires the pilot or wingman; the owning developer can rebase and resolve it exactly as it already does for `ci-failed`. | **Wrong altitude - the one violation. Fixed by this plan.** |

Conclusion: the merge-conflict feature is the sole wrong-altitude escalation in the system today; every other attention source already reserves upward signaling for a genuine human decision. No other `bin/watch-fleet` behavior needs to change.

## Design

### 1. Remove the wrong-altitude escalation; fix it at its actual source

Two designs were weighed for "reroute the conflict signal downward":

**A - Keep `bin/watch-fleet`'s own polling, but have it nudge the owning member's pane directly** (reusing the API-error nudge's `wm_tmux_send_message` primitive) instead of firing a `needs-attention` row.

**B - Delete the supervisor-level polling entirely and close the gap where it actually belongs: the developer's own `bin/pr-watch` loop, which is already armed against this exact PR while the member is parked in `review`.**

**Recommendation: B.** Reasoning:

- The developer is already the one watching this PR (`pr-watch`, armed per `playbooks/software-development/developer.md`, "Seeing the PR through"). It has always been responsible for noticing and self-resolving `ci-failed`/`changes-requested`/`comment` without any supervisor-level duplicate detection. Treating mergeability differently - inventing a second, parallel detector at the supervisor layer for one specific PR fact - is an inconsistency, not a robustness improvement.
- If the developer's own session is dead or genuinely stalled and can't watch its own PR, that failure mode is already caught by the existing pane-backstop (`stall-check`) exactly as it is for a dead/stalled member missing a merge or a CI failure today. Option A's only real advantage - catching drift on a member that isn't actively watching - isn't a new capability, it's an inconsistency with how every *other* PR fact is already handled (nobody proposed a supervisor-level CI-poller for the same reason).
- Option A keeps `mergeability.json`, its locking, its standdown/prune cleanup, and its display columns - a second store and a second poller for a fact `pr-watch` can and should just carry as one more of its own dimensions, exactly like `ci`.
- Option B is strictly the more literal reading of "downward, never upward": the signal never leaves the owning member's own loop at all, which is stronger than "the supervisor detects it, then nudges downward."

Follow-up (not blocking): if a future incident shows a real gap - e.g. a `blocked` member's PR silently drifting while it waits on an unrelated decision - Option A's mechanism (`mergeability.json` + a direct pane nudge, never a `needs-attention` row) is the fallback to revisit, not this plan's default.

#### 1a. Remove from `bin/watch-fleet` and `bin/lib/wm-state.py`

Delete everything added by PR #36:

- `bin/watch-fleet`: the `GH`/`MERGE_CHECK_INTERVAL`/`MERGE_CHECK_ENABLED` tunables and the polling block in the main loop (`grep -n mergeability bin/watch-fleet` to find both).
- `bin/lib/wm-state.py`: `mergeability_path()`, `PR_URL_RE`, `load_mergeability()`, `cmd_mergeability_poll_list`, `cmd_mergeability_set`, `_cleanup_mergeability` and its two call sites in `cmd_standdown`/`cmd_prune`, the second loop in `cmd_needs_attention` that walks `mergeability.json`, the `merge_conflict`/`merge_checked` display annotation and its use in `render_roster_text`/`render_tree_text`/`render_board` (including the `conflict` column), and the `mergeability-poll-list`/`mergeability-set` argparse wiring in `build_parser()`. (`grep -n mergeability bin/lib/wm-state.py` finds every site; none of this is referenced outside these two files and `tests/merge-conflict-watch.test.sh`.)
- `tests/merge-conflict-watch.test.sh`: delete.
- A stale `~/.wingman/mergeability.json` left over from testing is harmless (nothing will read it after this change); no migration needed.

#### 1b. Add mergeability as a new `pr-watch` dimension

`bin/pr-watch`'s `gh pr view` call (`poll_once()`) additionally requests `mergeable,mergeStateStatus`:

```
--json state,mergedAt,statusCheckRollup,reviews,comments,number,url,mergeable,mergeStateStatus
```

`bin/lib/pr-eval.py` (`evaluate()`) gets a small mapping helper, the same 3-rule collapse the removed `wm-state.py` code used (`mergeable == "CONFLICTING"` or `mergeStateStatus == "DIRTY"` → `CONFLICTING`; both `UNKNOWN` → `UNKNOWN`, meaning "not computed yet, treat like pending"; anything else → `MERGEABLE`), inlined directly in `pr-eval.py` (it is a dependency-free standalone script by design - do not import from `wm-state.py`, and there is nothing left to import from once §1a lands).

Wire it into the existing priority chain (`merged > closed > changes-requested > ci-failed > comment > checks-passed`) as a new dimension parallel to `ci`:

- Insert **`conflict`** right after `ci-failed`: `merged > closed > changes-requested > ci-failed > conflict > comment > checks-passed`.
- Track it with its own edge-triggered cursor, `cur["mergeable"]`, exactly mirroring the existing `cur["ci"]` pattern: fire `"conflict: <pr>"` only on the transition into `CONFLICTING`; clear the cursor (without re-firing) the moment it leaves `CONFLICTING`; a mapped result of `UNKNOWN` touches neither the cursor nor `ready_fired` (GitHub hasn't finished computing it - treat it like a pending check, not a resolved one).
- Redefine `ready` (the `checks-passed` gate, currently `(not fail) and (not checks_pending(pr))`) to also require the mapped mergeability is `MERGEABLE` - i.e. `checks-passed` now means green **and** mergeable, closing exactly the gap this plan exists to fix: a member is not told "ready for a human" while its PR still has conflicts.

`playbooks/software-development/developer.md` (and the two other playbooks that duplicate its PR-lifecycle section verbatim, `playbooks/data-science/data-engineer.md` and `playbooks/ai-research/ml-engineer.md`) gain one bullet in the `pr-watch` event list, next to `ci-failed`:

> **`conflict: <pr>`** - the base branch moved and your PR now has merge conflicts. Merge or rebase `main` into your branch, resolve the conflicts in your worktree, and push. This is yours to fix exactly like a failing check - never report it upward as a problem; only the eventual settled state matters.

### 2. Stop re-announcing `review` for self-managed churn

#### The general rule (codify in `playbooks/_status-contract.md`)

Add a new subsection, "Re-entering `review` without re-announcing," directly after "The states":

> Returning to `review` after a stint in `working` announces again **only when you are handing back a direct response to a request the party watching you made** - feedback that arrived as a message from your owner (the pilot, your lead, or a peer via `bin/crew-say`/`crew-ask`), where they are genuinely waiting to hear the outcome.
>
> It must **not** announce again when you cycled through `working` to silently resolve something that was yours to fix and that nobody upstream asked about - a failing check, a merge conflict, a stale branch, a routine review comment you've already replied to at its own source (e.g. the PR thread). Your owner already knows this deliverable exists and is in flight; telling them again that it's "ready" for the second or third time is exactly the noise the reporting contract rules out.
>
> Use `crew-set --status review --silent` for the second kind of transition: it updates your status/summary/artifact/delivery exactly like a normal call (so `bin/crew-list`/`board.md` stay accurate for anyone who looks), but does not re-fire the watcher/Stop-hook wake. Reserve the plain (non-`--silent`) call for: the very first time a deliverable reaches `review`, and any return to `review` that answers feedback your owner gave you. Never pass `--silent` with `--status blocked` or `--status done` - those are always genuine, always announce.

Update the `crew-set` invocation shown at the top of the contract to include `[--silent]` in the flag list, with a one-line pointer to the new subsection.

#### The mechanism (`bin/lib/wm-state.py`)

Add `--silent` (`action="store_true"`) to the `crew-set` subparser. Add a 7th field, `"announced"`, to `STATUS_FIELDS` (currently `("status", "summary", "blocker", "artifact", "delivery", "updated")`) so `merged()` overlays it onto the roster exactly like every other live-status field. In `cmd_crew_set`:

- Change the per-field copy loop from `STATUS_FIELDS[:-1]` to `STATUS_FIELDS[:-2]` (both `updated` and `announced` are computed here, never taken from args).
- Keep `live["updated"] = now()` unconditionally (so "last touched" stays accurate for display, exactly like today).
- Then: `live["announced"] = live["updated"]` unless `args.silent`, in which case leave `announced` untouched (`live.setdefault("announced", live["updated"])` so a first-ever write - which should never be silent per the rule above, but shouldn't crash if it somehow is - still gets a value).
- Guard: `sys.exit(...)` if `args.silent` and `args.status in ("blocked", "done")`.

In `cmd_needs_attention`, change the roster loop's dedup key from `upd = r.get("updated")` to `upd = r.get("announced") or r.get("updated")` (fallback covers records written before this field existed). This is the only change needed anywhere in the attention pipeline: `ack`/`mark-handled`/`fire()`/`hooks/stop-guard.sh` are already fully generic over whatever value `needs-attention` prints in the `updated` column (verified by reading all four - none of them look up `crew/<id>.json` directly), so they require no changes. `blocked`/`done`/`died`/`stalled` transitions never pass `--silent`, so `announced` always equals `updated` for them and their behavior is byte-for-byte unchanged.

`bin/crew-list`/`board.md` continue to display the plain `updated`/`summary` fields exactly as today - so a human who explicitly looks sees the freshest state even through silent churn; only the *push* wake is suppressed, never the passively-checked truth.

#### Applying it: `playbooks/software-development/developer.md` (+ `data-engineer.md`, `ml-engineer.md`)

Add to "Seeing the PR through," after the existing event-list bullets:

> The **first** time you settle into `review` for this PR (the point where `pr-watch` first tells you `checks-passed`), announce it normally - a new deliverable is worth one look. Every later return to `review` - triggered by your own `pr-watch` loop resolving `ci-failed`/`conflict`/`changes-requested`/`comment` - is self-managed churn nobody upstream asked about; use `crew-set --status review --silent` for it (see `playbooks/_status-contract.md`, "Re-entering `review` without re-announcing"). If you instead act on feedback that arrived as a message from your owner via `bin/crew-say`, that response **does** announce normally when you settle again - they're waiting to hear it.

### 3. `playbooks/common/lead.md`: filter, don't relay

A lead already keeps its own status as "the rollup wingman sees" (existing text: "wingman sees only your line, not your workers'"). Make explicit that this extends to the same result-not-mechanics discipline, one layer up. Add to "Roll up & escalate":

> Your workers' own self-managed churn - a developer's CI fix, a resolved merge conflict, a routine peer-to-peer exchange - never belongs in your rollup or triggers one of your own status transitions. Apply the same test `playbooks/_status-contract.md` gives every member: does wingman need to *action* this? If a worker resolved it without asking you anything, the answer is no, and your own `summary` should read exactly as it did before the worker's blip happened.

No change needed to the lead's escalation rule itself (`playbooks/common/lead.md`, "Escalation") - "answer it with `bin/crew-say` if you can" already keeps routine decisions from traveling further than they need to.

### 4. Other playbooks: audited, no change needed

`software-analyst.md`, `architect.md`, and `reviewer.md` were read in full. None narrates intermediate mechanics, and each already treats "deliver, then wait for feedback, revise in place" as its whole loop - their only path back into `review` is genuine owner-relayed feedback, which is exactly the case §3's rule keeps as a normal (announcing) transition. They inherit the new subsection from `playbooks/_status-contract.md` automatically and need no direct edits. Every other category playbook (`ai-research`, `data-science`, `business-development`, `business-operations`, `scientific-research`, `infrastructure`) was checked for a bespoke reporting pattern outside the shared contract; only `data-engineer.md` and `ml-engineer.md` duplicate the PR-watch lifecycle (see §1b/§2) and need the same edit as `developer.md`. `infra-operator.md`'s propose→`blocked`→confirm→apply→verify cycle already reports only genuine decisions and a final verified result - no change needed.

### 5. `CLAUDE.md`: altitude rule for wingman's own reports

**Remove** (all added by PR #36, now stale once §1 lands):
- "The wake loop" section: the trailing paragraph explaining the `conflict: <id>#conflict <note>` reason-line format.
- "Command vocabulary": the "A `conflict:` event fires" bullet.
- "Report" step: the sentence carving out `conflict:` events as the one exception to the self-report-hedging rule.

**Add** to the "Report" step, stating the altitude rule directly (the pilot's principle, applied to wingman's own voice):

> **Report altitude: results and actionables, never mechanics.** A status report to the pilot is the high-level state of each effort, the deliverables that are ready, and what needs the pilot's action - nothing else. Never surface crew ids, session ids, window names, or watcher pids to the pilot; those are your own bookkeeping for running a command, not something the pilot needs to parse. Describe an effort by its repo and objective/deliverable ("the merge-conflict-drift fix for wingman"), not by its crew id. A member's own self-detected, self-resolved hiccup (a merge conflict it rebased away, a failing check it fixed, a stale branch it rebased) is its business, never yours to narrate - if it never asked you anything and never got stuck, there is nothing to report about it.

**Add** to the "Escalate" step, the corollary as durable doctrine (not just this incident's fix):

> Only a genuine decision the pilot alone can make is escalated. A problem the owning member (or its lead) can resolve itself is routed *to that member* - directly, or by trusting its own playbook loop to catch and fix it - never surfaced upward as an attention event. Detection is useful; escalation of something the owner can fix is not.

**Reword** (apply the altitude rule; keep every underlying `bin/` command unchanged - these are wingman's own lookup keys, not something to stop using):
- "Status" / "what's my crew doing?": add "Describe each effort by its repo and objective/deliverable when talking to the pilot; keep the crew id as your own lookup key for running a command, not something you say out loud."
- "Crew stalled" / "Take over X": keep relaying the exact `bin/crew-takeover <id>` command (the pilot may need to run it themselves - that is the actionable pointer, not narration), but lead with the plain-language state ("the `<repo>` effort has gone quiet") before the command, not the id.

## Files touched

- `bin/watch-fleet` - remove the `MERGE_CHECK_*`/`GH` tunables and polling block (§1a).
- `bin/lib/wm-state.py` - remove all `mergeability-*`/`mergeability.json` machinery (§1a); add `--silent` to `crew-set`, the `announced` field, and the `cmd_needs_attention` dedup-key change (§2).
- `bin/pr-watch` - add `mergeable,mergeStateStatus` to the `gh pr view --json` field list (§1b).
- `bin/lib/pr-eval.py` - add the mergeability mapping helper, the `conflict` dimension/cursor, and fold mergeability into the `ready` gate for `checks-passed` (§1b).
- `playbooks/_status-contract.md` - new "Re-entering `review` without re-announcing" subsection; `--silent` added to the documented `crew-set` invocation (§2).
- `playbooks/software-development/developer.md`, `playbooks/data-science/data-engineer.md`, `playbooks/ai-research/ml-engineer.md` - new `conflict:` event bullet; new paragraph on when to use `--silent` (§1b, §2).
- `playbooks/common/lead.md` - "Roll up & escalate" gains the filter-don't-relay paragraph (§3).
- `CLAUDE.md` - remove the three `conflict:`-specific passages; add the Report-altitude paragraph and the Escalate corollary; reword the "Crew stalled"/"Status" bullets (§5).
- `tests/merge-conflict-watch.test.sh` - delete (§1a).
- `tests/pr-eval.test.sh`, `tests/pr-watch.test.sh` - extend (below).
- New test coverage for `--silent`/`announced` in `wm-state.py`'s existing test suite for `crew-set`/`needs-attention` (find the existing file with `grep -rl "needs-attention\|crew-set" tests/*.test.sh`).

## Testing strategy

1. **`tests/pr-eval.test.sh`** (unit-level, canned JSON):
   - `mergeable=CONFLICTING` (or `mergeStateStatus=DIRTY`) with previously-clean state fires `conflict: <pr>`; feeding the same input again does not re-fire (cursor holds).
   - Feeding `mergeable=MERGEABLE` afterward clears the cursor silently (no event); feeding `CONFLICTING` again after that fires a **new** `conflict:` event (resolve-then-reconflict re-fires, mirroring the existing `ci` cursor test if one exists).
   - `mergeable=UNKNOWN`/`mergeStateStatus=UNKNOWN` neither fires nor clears an existing conflict cursor, and does not satisfy `ready` (no spurious `checks-passed`).
   - `checks-passed` does not fire while `mergeable=CONFLICTING` even with all checks green; fires once mergeability resolves to `MERGEABLE` with checks still green.
   - Priority: a PR that is simultaneously `ci-failed` and `conflict` fires `ci-failed` first; `conflict` still surfaces on the next poll (mirrors the existing "co-occurring lower-priority event still surfaces" test pattern for `comment`/`checks-passed`).
2. **`tests/pr-watch.test.sh`** (fake `gh` via `WM_GH`, existing pattern): a fake `gh pr view` response with `mergeable=CONFLICTING` produces a `conflict: <pr>` line from a real `poll_once` call; flipping the canned response back to `MERGEABLE` produces no further event until something else changes.
3. **`wm-state.py` `--silent`/`announced` tests** (extend whichever existing suite covers `crew-set`/`needs-attention`/ack-dedup, e.g. `tests/ack-dedup.test.sh` or `tests/watch-fleet.test.sh` - `grep -rl "crew-set --status review" tests/*.test.sh` to find the right home):
   - `crew-set --status review` (no `--silent`) on a member with no prior `review` entry: `needs-attention` emits a row; acking it suppresses a repeat with the same `announced`.
   - `crew-set --status working ...` then `crew-set --status review --silent`: `needs-attention` emits **nothing** for this member (the `announced` value from the first entry is unchanged), even though `bin/crew-list`/`board.md` show the fresh `summary`/`updated`.
   - A subsequent plain (non-`--silent`) `crew-set --status review` on the same member **does** emit a fresh row (a real new `announced` stamp).
   - `crew-set --status blocked --silent` (or `--status done --silent`) exits non-zero with a clear error.
   - A record written before `announced` existed (only `updated` present) still dedups correctly via the `r.get("announced") or r.get("updated")` fallback.
4. Run `tests/run.sh` in full at the end to confirm no regression - this removes a subsystem `cmd_needs_attention`/`render_board` currently reads on every call, and changes the field list `merged()` overlays, so the full suite (not just the new/touched files) is the confirmation this didn't ripple.

## Open questions / follow-ups

Not blocking; flag for the requester or leave as explicit follow-ups:

1. **Option A (supervisor-level pane nudge) as a defense-in-depth fallback.** If a real incident later shows a `blocked`/dead member's PR drifting unnoticed for an extended period, revisit adding a *non-escalating* `bin/watch-fleet` check that nudges the member's own pane directly (never a `needs-attention` row) - the same primitive the API-error nudge already uses. Not built now because it duplicates a case (member not actively watching its own PR) that isn't handled for any other PR fact either.
2. **`--silent`'s "did feedback arrive from my owner" distinction is a playbook-level judgment call, not something `wm-state.py` can verify.** A developer that mislabels genuine owner feedback as self-managed churn (or vice versa) will under- or over-announce; there's no mechanical way to catch this beyond code review of the playbook text itself. Acceptable given the mechanism is a single documented rule applied by one playbook family (PR-lifecycle members), not a fleet-wide inference.
3. **`bin/crew-list`/`board.md` do not currently expose `announced` at all**, by design (§2) - if a future need arises to audit *why* a wake did or didn't fire for a given member, `crew/<id>.json` already holds both `updated` and `announced` for direct inspection; no UI surface is proposed for this now.
