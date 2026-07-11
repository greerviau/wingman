# Effort Decomposition: Fix Three Wingman Reliability Issues

Owner: crew lead `own-end-to-end-fix-three-wingman-lead`.
Date: 2026-07-10.

## Objective

Fix three wingman reliability issues as one coordinated effort, since all three touch the watcher/wake/intake machinery:

1. **Lead-suggestion miss at intake** - approved report: `docs/analysis/2026-07-10-wingman-lead-suggestion-miss.md`.
2. **Short-circuited wake handling** - approved report: `docs/analysis/2026-07-10-short-circuited-wake-handling.md`.
3. **Silent crew stall detection** - existing plan: `docs/plans/2026-07-10-detect-silent-crew-stall.md`.

## Phases

1. **Consolidated plan (analyst).**
   One analyst reads all three inputs together and produces a single consolidated implementation plan in `docs/plans/`, resolving overlaps in the watcher/wake/intake machinery and sequencing the changes so they compose rather than conflict.
2. **Approval gate (human).**
   The consolidated plan is surfaced to the requester for review and approval before any implementation begins.
3. **Build (developer).**
   One developer implements the approved plan in the wingman repo and shepherds a PR through the standard lifecycle.
4. **Review (reviewer).**
   One reviewer reviews the resulting PR against the plan and the three source documents; findings iterate directly with the developer.
5. **Integration and rollup (lead).**
   The lead verifies the delivery covers all three issues and rolls up a single status line.

## Crew

- 1 analyst (phase 1), stood down after plan approval.
- 1 developer (phase 3), through PR merge.
- 1 reviewer (phase 4), stood down after review findings are dispositioned.

Sequential, single repo (`wingman`); no parallel fan-out is warranted.
