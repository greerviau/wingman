# PR-6-downstream reliability fixes: effort decomposition

Owner: lead crew `own-and-ship-fixes-for-three-rel-lead`.
Date: 2026-07-10.

This effort owns three related reliability defects, all downstream of PR #6, all touching the shared watcher / wake-loop / roster-reconciliation surface.
Each fix ships as its own PR.
Because the three share deep surface (chiefly `bin/watch-fleet`, `bin/lib/wm-state.py`, and the standdown/spawn teardown path), design and build must sequence and integrate carefully rather than fan out blindly.

## The three fixes

### Fix A - GH #8: wake handling, close the deferred handled-marker gap
- Reconstruct the live incident's actual path first (which of the two documented paths occurred): from the supervising session's state home, compare `acked.json` stamps against the member's status-file history.
- Design and implement the §9.1 follow-up: a `handled` marker distinct from `ack`, keyed by `(id, updated)`, respected by both `fire()` and `needs-attention`, so an incompletely-handled acked event can re-fire. Solve the re-fire race the plan flagged.
- Consider an owner watcher-liveness self-check (path 1), beyond the existing Stop-hook nudge.
- Surface: `bin/lib/wm-state.py` (ack/handled store, `needs-attention`), `bin/watch-fleet` (fire), the Stop hook.

### Fix B - GH #11: dead lead orphans its live workers
- Detect a dead lead during reconciliation / on a watcher cycle, and surface its still-live workers as an actionable state (re-adopt / cascade stand-down / takeover) instead of letting them run invisibly.
- Make `crew-standdown` teardown robust to non-graceful exit: when force-closing a window or reaping a dead/orphaned member, complete teardown as a fallback, including worktree removal, using a worktree path recorded at spawn time. Graceful path stays the agent's own responsibility.
- Surface: `bin/spawn-crew` (record worktree path at spawn), `bin/crew-standdown` (fallback teardown), `bin/watch-fleet` / `bin/crew-list` (dead-lead detection + reconciliation).

### Fix C - GH #7: prompt-freeze detection anchoring
- Refine anchoring so a parked pane that quotes a verbatim full-dialog block is no longer flipped to `blocked`.
- Preferred directions: require the selection-marker column (one `❯ N.` among ≥2 consecutive option rows) and/or a negative-liveness veto (status file updated within the last poll interval or two).
- Must not regress current true-positive coverage (per-tool gates, workspace-trust dialog, Bypass acceptance) and stay overridable for other harnesses.
- Surface: `bin/watch-fleet` (prompt-freeze detection block).

## Shared-surface conflict map

All three touch `bin/watch-fleet`. Fix A and Fix B both also touch state/reconciliation.
Sequential build on one coherent context avoids cross-PR merge churn on `watch-fleet`.

| Fix | wm-state.py | watch-fleet | crew-standdown | spawn-crew | Stop hook |
|-----|-------------|-------------|----------------|------------|-----------|
| A #8  | yes | yes | - | - | yes |
| B #11 | maybe (reconciliation) | yes | yes | yes | - |
| C #7  | - | yes | - | - | - |

## Phases

1. **Design (architect).** One consolidated design plan covering all three fixes: reconstruct the #8 incident path, per-fix design, the shared-surface integration order, and the exact PR sequence. Iterate with the architect.
2. **Review (reviewer).** Critique the plan for the shared-surface integration risk and true-positive regression risk (#7). Gate the approved plan on the requester's sign-off.
3. **Build.** Deliver three PRs in the architect-recommended order. Default: a single developer building the three sequentially on one coherent context (each PR rebased on the prior), to eliminate `watch-fleet` merge conflicts. Each PR shepherded to merge via the normal review lifecycle.
4. **Integration.** Verify the three fixes compose on the shared surface; roll the three merged PRs up as one combined delivery.

## Human checkpoints
- Plan approved? (after review)
- Each PR: real human review on GitHub.
- Ship (all three merged)?
