# The reporting contract

What wingman says to the pilot, and what it deliberately does not. The operating rules are stated in `CLAUDE.md`'s "Report" step; this page carries the case analysis behind them - which `review` states are absorbable, why housekeeping is never a report, and how the two visibility preferences interact.

Part of the [architecture reference](architecture.md). The crew-side half of the same contract - how a member reports its own state - is `playbooks/_status-contract.md`.

## Report altitude

A status report is the high-level state of each effort, the deliverables that are ready, and what needs the pilot's action. Nothing else.

Crew ids, session ids, window names, and watcher pids are wingman's own bookkeeping for running a command, not something the pilot needs to parse. An effort is named by its repo and objective ("the merge-conflict-drift fix for wingman"), never by its crew id.

A member's own self-detected, self-resolved hiccup - a merge conflict it rebased away, a failing check it fixed, a stale branch it rebased - is that member's business. If it never asked anything and never got stuck, there is nothing to report about it.

**Routine lifecycle bookkeeping is never itself a report,** for the same reason ids and pids are not. Standing down a `done` member, re-arming the watcher, spawning a routine follow-up review pass - these are things wingman *does*, not things it *says*. "Reviewer stood down, watcher re-armed", "watcher armed", "re-arming the watcher" and every variant are mechanics leaks: the pilot does not need to know the watcher exists, let alone that it just cycled. When a turn's only news is housekeeping with no substantive result attached, the correct output is no message at all.

## Self-report is a claim, not verified state

A crew member's status, artifact, or verdict is that member's own claim. When a member reports external system state - a PR *approved*, *merged*, *passing/green*, or *deployed* - it is not relayed as settled fact. Either it is verified against the system of record first:

```
gh pr view <pr> --json state,mergeStateStatus,reviewDecision,statusCheckRollup
```

…and what that shows is reported, or it is attributed explicitly as the crew's self-report ("the reviewer's verdict is approve" - not "the PR is approved"). A reviewer's internal `approve` is not a GitHub review decision, and a "CI green" claim is not the merge gate.

**This binds wingman's own volunteered claims too.** Any external-system state wingman asserts - an issue open or closed, a PR merged or approved, CI green - must be one it just verified, not one carried from stale or assumed context. Never offer an action premised on an unverified state ("want me to close these open issues?" when their being open has not been confirmed).

The same rule from the crew's side is `playbooks/_status-contract.md`'s "Self-report is a claim, not verified external truth".

## `direct_spawn_visibility`

Read with `$WINGMAN_STATE pref-get --run-id "$WINGMAN_RUN_ID" --key direct_spawn_visibility`. Unanswered, or `$WINGMAN_RUN_ID` unset, defaults to `each-round`.

It governs exactly one thing: a revise loop **wingman runs itself** by spawning members directly - a software-analyst and a reviewer it spawned, iterating via `crew-say` with no `lead` in between.

- **`each-round`** (default): report each substantive round as it lands - a member spawned, a verdict reported, feedback routed back.
- **`summary-only`**: absorb routine intermediate progress narration, the same way a lead absorbs its own workers' churn. It does **not** shrink what gets surfaced or when; it removes only the play-by-play in between.

### Never absorbed, whatever the setting

- **`blocked` and `stalled`** - a decision or a takeover/stand-down call only the pilot can make. Attention events, not progress rounds.
- **`died`,** including a mass-death or correlated-outage batch.
- **A pilot-facing `review` surface** (below).
- **A `done` reviewer's disposal.** When an intermediate reviewer reports `done` mid-loop and its verdict is absorbed, the reap still happens in the same turn. `summary-only` suppresses the *relay*, never the housekeeping act that keeps the roster accurate.

### Pilot-facing vs loop-internal `review`

The line is drawn on *what the `review` state is for*, not on how many times it recurs. A member enters or re-enters `review` on every round of a direct analyst↔reviewer loop, so "a member reports `review`" cannot by itself be the never-suppressed trigger - that would still narrate plan v1, v2, v3, which is exactly the behavior `summary-only` exists to remove.

**Pilot-facing - never suppressed, always announced with its pointer.** A `review` whose deliverable is being handed to the pilot for the pilot's own action: the plan reaching the approval gate that licenses the developer spawn, a PR reaching "ready for review" from the pilot's perspective, or any deliverable the pilot explicitly asked to see again. In a direct analyst↔reviewer loop this is the round where wingman stops iterating and hands the result up - typically the round the reviewer approves, never before. This is also the moment that triggers the structured open-questions flow.

**Loop-internal - absorbable under `summary-only`.** A `review` that is purely an input to a review round wingman has commissioned or is about to commission: any round before wingman ends the loop. This covers the analyst's very first entry into `review` exactly as it covers every later re-entry after a request-changes verdict.

**Absorbed never means ignored.** Wingman is still woken, and still acts exactly as it always does - spawns the next reviewer pass, routes feedback. `summary-only` suppresses the narration of that round, never the handling of the wake.

And `summary-only` never means "wait until a developer is already spawned before saying anything". The pilot's sign-off is the gate that licenses the developer spawn; nothing in this preference authorizes skipping it or delaying it past the point the loop actually concludes.

### It does not touch a lead's rollup

A lead already absorbs its own crew's round-by-round churn unconditionally and rolls one line up. That absorption is not optional and is not something this preference turns on or off. `direct_spawn_visibility` governs only the case where wingman itself is running the loop - functionally the same role a lead plays, without a lead in between.

### Orthogonal to `verbosity`

`verbosity` controls how much reasoning accompanies whatever is said (the *why*). `direct_spawn_visibility` controls which events get said at all in a direct revise loop (the *what*). A `verbosity=concise` pilot on `each-round` still wants every round - just reported tersely. `concise` never implies `summary-only`; they are independent.

## Never empty, never repeated

A message whose entire content is "no update this turn" - "still waiting", "nothing to report yet", "silently monitoring" - is never correct, at either visibility setting. If a turn produces no new substantive event, the output is nothing.

This covers restatement as well as emptiness. Before sending any status update, compare it against the last thing actually reported on that topic. If it restates a fact - a PR's state, a check's result, an effort's status - with nothing changed since, cut it. A duplicate report is exactly as uninformative as a contentless one.

## Formatting links for a remote pilot

The `remote` preference (`$WINGMAN_STATE pref-get --run-id "$WINGMAN_RUN_ID" --key remote`; exits nonzero when unanswered) governs how URLs are phrased. It is presentation-only - it never changes *what* is relayed, only how a URL within it reads - and it reuses the one cached answer rather than asking again.

- **`true`** - format every URL as a markdown link with short, descriptive text (`[PR #29 ready for review](https://github.com/...)`). A bare URL is least usable read on a phone or in a browser.
- **`false`, unanswered, or unaskable** - plain URLs, unchanged.

This applies to any URL wingman surfaces: an Artifact link, a GitHub PR or issue link, a `delivery` reference.
