# Effort decomposition: four wingman reliability issues (#17, #12, #22, #23)

Owner: crew lead `lead-implementation-of-four-rela-lead`.
Date: 2026-07-11.

## Objective

Fix four wingman reliability issues as one coordinated but not monolithic effort:

1. **#17** - mechanical `PreToolUse` guard blocking wingman/lead sessions from direct `Edit`/`Write`/`NotebookEdit` and direct test-runner `Bash` calls, mirroring `hooks/stop-guard.sh`'s pattern.
2. **#12** - idempotent watcher arming: guarantee exactly one live watcher, fix the pid-confusion failure mode (a fresh `healthy pid=N` line misread as "a second watcher exists," leading to the live one being killed).
3. **#22** - detect a mass crew-death event (tmux/host crash) distinctly from a routine single `died` member, and provide a bulk-resume path via `claude --resume <session-id>` that preserves conversation context and the parent/owner tree.
4. **#23** - recognize network/Anthropic-outage API errors in crew panes distinctly from a generic stall, detect a correlated fleet-wide outage, and prefer automatic nudge/resume over manual pilot diagnosis.

## Constraint: PR #26

PR #26 (open, mergeable as of 2026-07-11) rewrites playbook resolution across `bin/spawn-crew`, `bin/doctor`, `bin/lib/common.sh`, `CLAUDE.md`, and moves `playbook/` to `playbooks/<category>/`.
Verified via its diff which specific regions are touched:

- `bin/lib/common.sh`: only `wm_crew_types`, new `wm_glob_escape`, new `wm_resolve_playbook`, and the `WM_PLAYBOOKS` root var (all near the top of the file, all playbook-resolution logic). The pane-capture helpers and the team-guardrail section are untouched.
- `bin/spawn-crew`: only the playbook-resolution block, the `ID` slugify line, and the sysprompt `_status-contract.md` path. The env-export block (`export WINGMAN_CREW_ID`, etc., further down the file) is untouched.
- `CLAUDE.md`: only paragraphs renaming `analyst` -> `software-analyst` and the playbook path format. Most of the file (wake loop, watcher, escalation, lifecycle sections) is untouched.
- `bin/doctor`: untouched by any of these four issues' scope.

**Rule for all crew below:** do not edit `wm_crew_types`, `wm_resolve_playbook`, `wm_glob_escape`, the playbook-resolution block in `bin/spawn-crew`, or the `analyst`/playbook-path paragraphs of `CLAUDE.md`.
Everything else in these files is fair game.
If a design turns out to genuinely require touching those exact regions, stop and report it to the lead rather than editing around the conflict.

## Prior art (context, not to be re-derived)

`docs/plans/2026-07-10-wingman-reliability-consolidated-implementation.md` (already implemented, merged) added the `stalled` state, `wm-state.py stall-check` with a process-tree execution probe, and the wake-file-carries-full-roster mechanism in `bin/watch-fleet`.
#23 extends that existing stall detector with a new stall *reason* (`api-error`); it does not build stall detection from scratch.

## Decomposition into two tracks

The four issues split cleanly by file surface:

- **Track A (#17):** `hooks/` + `.claude/settings.json` only. No overlap with Track B.
- **Track B (#12 + #22 + #23):** all three live in `bin/watch-fleet`'s core loop and its supporting state (`bin/lib/wm-state.py`, `bin/lib/common.sh` pane/pid helpers). #22 and #23 are explicitly related (the issue bodies both call out a shared "is this a fleet-wide correlated event" detector as worth designing together), and #12's idempotent-arming primitive touches the same pidfile/beacon liveness pattern the mass-event detectors need to reason about. Designing these three together avoids three uncoordinated edits to the same 449-line file.

Tracks A and B touch disjoint files and have no dependency between them, so they run in parallel.

### Track A: #17 mechanical delegation guard

Small, mechanically well-specified (mirrors an existing hook), with one real design decision resolved here so a dedicated architect phase isn't needed:

**Design decision - orchestrator vs. worker scoping.** `stop-guard.sh` scopes itself via `OWNER="${WINGMAN_CREW_ID:-}"` - empty means "this is wingman's own top-level layer." But a `lead` session (which has `WINGMAN_CREW_ID` set) must *also* be blocked - a lead is a conductor, not a worker, per its own playbook - while a `developer`/`architect`/`software-analyst`/`reviewer`/`research`/custom-type session must *not* be blocked, since editing files and running tests is literally their job. `WINGMAN_CREW_ID` alone cannot distinguish these; there is currently no crew-type env var exported into a spawned session. `bin/spawn-crew`'s env-export block (untouched by PR #26) is the place to add one.

Objective for the developer:
- Add `WINGMAN_CREW_TYPE` to the env-export block in `bin/spawn-crew` (the block containing `export WINGMAN_CREW_ID=...`, NOT the playbook-resolution block above it).
- New hook `hooks/no-direct-edit-guard.sh` (or similar name), a `PreToolUse` hook wired in `.claude/settings.json` (additively - do not disturb the existing `Stop` hook entry), scoped like `stop-guard.sh`: active when `WINGMAN_CREW_ID` is unset (top-level wingman) OR `WINGMAN_CREW_TYPE` = `lead`.
- When active: block `Edit`, `Write`, `NotebookEdit` tool calls unconditionally; block `Bash` calls that are clearly direct test-runner invocations (e.g. invoking `tests/*.test.sh`, `pytest`, `npm test`/`go test`, etc. - use judgment, but do not block generic `Bash` like `gh`, `git status`, `ls`, `grep`, since wingman/leads run those constantly as part of legitimate orchestration - this very lead session depends on it).
- Block message redirects to `bin/spawn-crew` (mirror the tone/format of `stop-guard.sh`'s block reason).
- Add test coverage under `tests/` following the existing bash E2E conventions (`tests/lib.sh`, isolated `WINGMAN_HOME`).
- Update `playbook/_status-contract.md` or `CLAUDE.md` only if genuinely needed to document the new guard, and only in regions PR #26 does not touch; prefer documenting in the hook's own header comment if a CLAUDE.md edit isn't essential.

Sequence: **developer -> reviewer.** A reviewer pass is warranted here specifically because a mis-scoped guard could false-positive and block legitimate orchestration Bash calls (including this effort's own lead/developer sessions), or false-negative and defeat the point.

### Track B: #12 + #22 + #23 watch-fleet reliability

Sequence: **architect -> developer -> reviewer.**

The architect reads `bin/watch-fleet`, `bin/lib/wm-state.py`, `bin/lib/common.sh`, and the three issue bodies (already fetched by the lead; pass the full issue text as input) in full, and produces one design covering:

- **#12:** a single idempotent arming primitive with unambiguous states (none-live -> arms one; already-live -> no-op that clearly reports the existing pid, not a "second watcher"). Root-cause the exact pid-confusion failure mode from the issue (a `healthy pid=N` line misread as a duplicate to kill) and design the reporting so that misreading is structurally harder - e.g. a single `bin/watch-fleet status` or `--ensure` entry point that never prints an ambiguous "N" without full context, and a documented, scriptable "is a watcher live right now?" check.
- **#22:** reconciliation-time mass-death detection (N of M crew died in the same pass, above some ratio/count threshold, flagged distinctly from one routine `died`), plus a bulk-resume path (`claude --resume <session-id>` relaunched in a fresh tmux window under the existing crew id) that preserves the parent/owner tree recorded in `crew.json`, is idempotent (does not double-launch a session already resumed or already live), and falls back to today's manual standdown path only when a session's own `--resume` genuinely fails.
- **#23:** pane-text pattern recognition for API/connectivity errors (rate limit, connection error, 5xx, `overloaded_error`, etc.), a distinct stall reason (e.g. `stalled: api-error`) instead of the generic silent-stall bucket, correlated-event detection when many/most crew show this signature around the same time, waiting past the CLI's own retry window before flagging, and an automatic nudge (keypress/continue) or fallback to #22's resume mechanism when the CLI has genuinely given up.
- **Shared code path:** the architect decides whether #22's mass-death detector and #23's correlated-outage detector share one "fleet-wide correlated event" primitive (the issue bodies suggest this is likely, since both are "N of M crew show the same abnormal signal in one reconciliation pass") or stay separate; either is acceptable, but the design must state the decision and why.
- **PR shape:** the design states whether #12/#22/#23 ship as one PR or a small stack of sequential PRs (same file, so parallel developers are not an option regardless).

Deliverable: one design doc in `docs/plans/`, approved by the lead before build starts.

Then one developer implements per the approved design (in the sequence the design specifies), followed by one reviewer pass given the complexity (concurrent process management, tmux window lifecycle, idempotency requirements called out explicitly in #22's own issue text).

## Crew

- Track A: 1 developer, 1 reviewer. Sequential.
- Track B: 1 architect, 1 developer, 1 reviewer. Sequential within the track.
- Tracks A and B run in parallel (disjoint files, no dependency).

5 crew members total across the effort, none concurrent beyond the A/B pairing (max 2 live at once in the first wave: developer-A + architect-B).

## Integration

Two independent PRs (or Track B's small stack) against `wingman`, both based on current `main` (not on PR #26 - that PR is explicitly left alone).
The lead verifies both merge cleanly against each other (disjoint files, so no conflict expected) and against `main`, then rolls up a single status line to wingman.
