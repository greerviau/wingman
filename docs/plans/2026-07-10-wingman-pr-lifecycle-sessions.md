# Wingman: sessions that see a deliverable through its whole lifecycle

_Plan of action — 2026-07-10.
Target repo: `wingman`._

## Summary

Today a wingman build crew opens a PR, sets its status to `done`, and is treated as finished the instant the PR is out.
The session then sits idle: it does not watch CI, it does not watch for review feedback, and any feedback the pilot has tends to spawn a **new** session instead of returning to the one that already holds all the context.
`done` is overloaded — it means both "a deliverable is ready" and "this engagement is over."

This plan splits those two meanings and makes a single crew session shepherd its deliverable from creation to final disposition:

- A new non-terminal, **live** status `review` means "deliverable is ready and in review — I am still alive and on it." It is announced to the pilot exactly once (like `blocked` is), but it does **not** close the member out.
- A build crew, after opening its PR, enters a **review-watch loop**: it arms its own harness-tracked background watcher (`bin/pr-watch`, new) that blocks and wakes the crew only on an actionable PR event — CI failed, new review comment, merged, or closed.
  The crew fixes CI, addresses feedback, pushes, and replies to comments autonomously, re-arming the watcher after each cycle.
  It reaches the terminal `done` only when the PR is **merged or closed**.
- `done` now uniformly means "the whole engagement is complete, safe to reap." Every crew type (`spec`, `build`, custom) follows the same shape: deliver → `review` (still alive) → revise on feedback via the **same** session → terminal only on explicit disposition or the natural end condition.
- Wingman routes pilot feedback about an in-flight deliverable to the owning member via `bin/crew-say` and never auto-reaps a `review` member.

The design is the existing wingman wake-loop pattern applied one level down: just as `bin/watch-fleet`'s exit wakes wingman, `bin/pr-watch`'s exit wakes the crew member.
It keeps wingman context-light and the crew-coordination layer forge-agnostic (the forge-specific part is isolated in `pr-watch`, exactly as the harness-specific launch line is isolated in `spawn-crew`).

## Scope

Single repo: `wingman`.
Files touched:

- `bin/lib/wm-state.py` — add the `review` state to the state machine.
- `bin/pr-watch` — **new** crew-level watcher (forge-specific, `gh`-based).
- `playbook/build.md` — add the review-watch loop; redefine when `done` is set.
- `playbook/spec.md` — deliver into `review`, revise on feedback, terminal on disposition.
- `playbook/_status-contract.md` — document `review` and the deliver→review→done lifecycle for all types.
- `CLAUDE.md` (wingman's own) — teach wingman the `review` signal, feedback routing to the same session, and reap-only-on-terminal.
- `docs/architecture.md` — document the crew-level wake loop and the lifecycle.
- `tests/` — cover `review` surfacing/dedup/liveness and `pr-watch` event logic.

No changes outside `wingman`.

## Background: how the lifecycle works today

State machine (`bin/lib/wm-state.py`):

- `LIVE_STATES = ("working", "blocked")`
- `TERMINAL_STATES = ("done", "died", "stood-down")`
- `needs-attention` surfaces `blocked`, `done`, `died`, deduped per `(id, updated)` via the ack store so each event wakes the pilot once.

Wake loop: `bin/watch-fleet` blocks as a harness-tracked background task and exits with a reason line the instant a member enters a surfaced state; that exit re-invokes wingman.
`working` is deliberately **not** surfaced, so a member merely refreshing its summary never spends a wingman turn.
`blocked` is the precedent for a state that is **both live and surfaced** — the pilot is pinged, but the member stays in flight.

Build flow: `playbook/build.md` step 7 sets `--delivery <PR>` + `--status done`; step 8 says revisions are handled "if feedback arrives in this session." Feedback routing exists (`bin/crew-say <id>` injects a message into the live tmux session).

The gaps against the request:

1. **No self-waking watch.** A crew Claude session, once its turn ends, is idle and cannot rouse itself — the same constraint wingman solves with `watch-fleet`.
   Nothing watches CI or polls for review comments, so the session cannot react.
2. **`done` = closed.** Opening the PR sets `done`; the board files the member under "Closed" and wingman treats it as finished, so the lived experience is a spin-down the moment the PR is out.
3. **Feedback re-spawns.** Because the member reads as finished, new feedback is scoped as fresh work rather than routed back to the session that owns the context.

## Approach

### The `review` state — "ready and in review, still alive"

Add `review` as a state that is **live** (member stays Active, watcher keeps it in flight, reconcile still guards its window) **and** surfaced once (the pilot hears "ready for review").
This is exactly how `blocked` already behaves, so the mechanism cost is near zero:

- `LIVE_STATES = ("working", "blocked", "review")`
- `needs-attention` surfaces `("blocked", "review", "done", "died")`
- `TERMINAL_STATES` unchanged.

The existing `(id, updated)` ack dedup already makes surfacing one-shot per event.
The one discipline the playbooks must enforce: a member enters `review` **once**, at delivery, and then uses `working` as its steady watch state — it does **not** flap back to `review` on every CI fix (which would re-announce "ready" each time).
So the pilot is pinged once at delivery, once at terminal `done`, and otherwise only on a genuine `blocked`.
No new dedup logic is required.

### The crew-level wake loop (`bin/pr-watch`)

A build crew is itself a Claude Code session, so it has the same wake primitive wingman uses: arm a background task the harness tracks; its exit re-invokes the session.
`bin/pr-watch` is the crew's analog of `bin/watch-fleet`:

- Invoked as `bin/pr-watch --pr <url-or-number>` and armed by the crew as a harness-tracked background task (`run_in_background`), never detached.
- Blocks in a poll loop (default 30s; CI/reviews move on the order of minutes, so a slower interval than the fleet watcher's 5s is right), reading PR state via `gh` (`gh pr view --json state,mergeStateStatus,statusCheckRollup,reviewDecision,comments,reviews`).
- Tracks a **cursor** on disk (last-fired check-rollup conclusion + newest comment/review id/timestamp) under `$WINGMAN_HOME/pr/<crew-id>.json`, so it fires only on events strictly newer than the last one the crew handled.
- **Exits with one reason line** on the first actionable change and clears itself:
  - `merged: <pr>` — PR merged.
  - `closed: <pr>` — PR closed without merge.
  - `ci-failed: <pr> <check>` — a required check concluded failure.
  - `changes-requested: <pr>` — a review requested changes.
  - `comment: <pr> <n>` — new review comment(s)/review since the cursor.
- Forge-specific by design and isolated here, overridable via `WM_PR_WATCH` the same way the launch recipe is overridable via `WM_AGENT`.
  `bin/doctor` already checks `gh` conditionally, so no doctor change is required for the default build playbook.

The crew re-arms exactly one `pr-watch` cycle after handling each event, mirroring wingman's "arm exactly one fresh cycle" rule.
While the crew idles armed on `pr-watch`, the fleet watcher sees a live `working`/`review` member and stays quietly blocked — no wingman turns are spent during a long review.

### The uniform lifecycle (all crew types)

`done` uniformly means "engagement complete, safe to reap." A ready deliverable is `review`, never `done`:

- **build:** deliver → set `--delivery <PR>` + `--status review` (one-shot announcement) → arm `pr-watch` → on each wake, drop to `working` while acting (fix CI / address + reply to comments / push), then re-arm → on `merged`/`closed` clean up the worktree and set `--status done` with the outcome.
- **spec:** deliver → set `--artifact <plan>` + `--status review` → idle awaiting the pilot's review (it has no external signal to poll, so no watcher; the pilot's feedback arrives via `crew-say`).
  On feedback, revise the plan in place and stay `review`.
  On the pilot's approval/disposition, set `--status done`.
- **any other type:** same shape — deliver → `review` → revise-on-feedback in the same session → terminal only on explicit disposition.

The unifying concept is the `review` state plus "route feedback to the same session," **not** a universal watcher.
Autonomous external watching (`pr-watch`) is build-specific; a spec member simply persists in `review` until the pilot acts.

### Wingman's behavior

Update wingman's `CLAUDE.md` so that:

- A member entering `review` is announced once ("PR ready for review — < link>" / "plan ready for review — < path>") and then **left active**.
  Wingman never auto-stands-down a `review` member; it reaps only on `done`/`died`/`stood-down` or an explicit `/standdown`.
- Feedback on an in-flight deliverable is **routed to the owning member** via `bin/crew-say <id>`, matched by repo + `artifact`/`delivery` in `bin/crew-list`.
  Wingman does **not** spawn a new build/spec member for revisions to existing work.
  (Grounding/Intake already resolves against `artifact` fields; extend it to cover "this is feedback on existing work → crew-say, don't re-spawn.")
- For spec→build: on the pilot's approval of a plan, wingman spawns the build member (`--input <plan-path>`, unchanged) and then stands down the spec member — approval is the spec engagement's disposition.

### Rejected alternative: wingman-level PR watching

Have the fleet watcher (or wingman) poll GitHub for every in-flight PR and route events down via `crew-say`.
Rejected: it welds the harness-agnostic crew layer to a specific forge, makes wingman wake and spend context on every CI tick, and puts the fix-it work a hop away from the session that owns the context.
Architecture A keeps each concern where it belongs — wingman↔crew stays forge-agnostic, and each crew owns its own PR end-to-end.

## Steps

1. **State machine (`bin/lib/wm-state.py`).** Add `"review"` to `LIVE_STATES` and to the `needs-attention` surfaced tuple (`blocked`, `review`, `done`, `died`).
   Leave `TERMINAL_STATES`, the ack dedup, `reconcile`, and board rendering as-is — they inherit correct behavior (`review` shows under Active, a windowless `review` member reconciles to `died`, `crew-list --active` includes it).

2. **`bin/pr-watch` (new).** Implement the crew-level watcher described above: arg parsing (`--pr`, `--status`, `--stop`), the `gh`-based poll loop, the on-disk cursor at `$WINGMAN_HOME/pr/<crew-id>.json`, and single-reason exits.
   Model its structure and comments on `bin/watch-fleet`; make the forge command overridable via `WM_PR_WATCH`.
   Keep it bash-3.2-safe and source `lib/common.sh`.

3. **`playbook/build.md`.** Replace steps 7–8 with the review-watch loop: on PR open set `--delivery` + `--status review` as the turn's last status write, arm `bin/pr-watch`, end the turn; on each wake triage the reason (fix CI / address + reply to comments via `gh pr comment` / clean up + `done` on merge or close), pushing and re-arming after each.
   State the discipline explicitly: enter `review` once, use `working` for the loop, reach `done` only at merge/close.
   Add a resume note: on (re)start, if the branch already has an open PR, rejoin the watch loop instead of re-opening.

4. **`playbook/spec.md`.** Change the handoff: write the plan/report, set `--artifact` + `--status review` (not `done`), and stay alive for the pilot's review; revise in place on feedback; set `--status done` only on the pilot's approval/disposition.
   Keep the file-path-as-handoff contract.

5. **`playbook/_status-contract.md`.** Document `review` in the status list and the universal deliver → `review` → (revise on feedback) → `done` lifecycle, with the "enter review once, watch under working" discipline.
   Note that `done` means the engagement is complete and the member may be reaped.

6. **Wingman `CLAUDE.md`.** Update the command vocabulary and operating loop per "Wingman's behavior" above: announce-and-keep-active on `review`, route feedback to the same member via `crew-say`, reap only on terminal, and the spec-approval → spawn-build-then-standdown-spec flow.

7. **`docs/architecture.md`.** Add a "crew-level wake loop" subsection (the `pr-watch` analog of `watch-fleet`) and document the `review` state and uniform lifecycle.
   Note the forge-specific isolation of `pr-watch` (`WM_PR_WATCH`) alongside the existing `WM_AGENT` note.

8. **Tests (`tests/`).** Add coverage:
   - `review` is surfaced by `needs-attention` once, then suppressed while the member refreshes its summary (extend `ack-dedup.test.sh` or add a `review-state.test.sh`).
   - a `review` member counts as active (`crew-list --active`) and a windowless `review` member reconciles to `died`.
   - `pr-watch` fires the right single reason for each event class, driven by a fake `gh` on `PATH` returning canned JSON, with the cursor suppressing an already-handled event (new `pr-watch.test.sh`).
     Register it in `tests/run.sh`.

## Testing & verification

- `bash tests/run.sh` — the existing suites plus the new `review`/`pr-watch` coverage, all against isolated throwaway state homes (no real fleet needed).
- End-to-end smoke, as a user hits it: spawn a real build crew on a throwaway branch in a scratch repo, let it open a PR and enter `review`; confirm (a) the pilot is told once, (b) pushing a failing commit makes `pr-watch` wake the crew and it fixes CI, (c) a review comment wakes it and it replies + pushes, (d) feeding feedback through wingman lands in the **same** session (no new member spawned), (e) merging the PR drives the crew to `done` and it cleans up its worktree.
  Verify wingman never reaps the member until `done`.
- Confirm no wingman-context churn during a long review: with the crew idling in `review`/`working`, the fleet watcher stays blocked and wingman spends no turns.

## Risks & open questions

- **Resumed crew must re-enter its watch loop.** If a crew session is killed while a PR is in review, it shows `died` and is recovered via `bin/crew-takeover`; on resume it must detect the existing PR and re-arm `pr-watch` rather than re-open.
  Covered by the step-3 resume note; flagged as the main operational edge.
- **`gh` review-comment cursor.** Getting "new since last handled" exactly right (review threads vs. issue comments vs. review submissions) needs care so the crew neither misses nor re-handles a comment.
  The on-disk cursor is the mechanism; worth an explicit test matrix (step 8).
- **Spec disposition = approval.** This plan treats the pilot approving a plan as the spec engagement's terminal disposition (wingman spawns build, stands down spec).
  If you'd rather a spec member stay alive even after handoff until you explicitly stand it down, that's a one-line change to step 4/6 — flag your preference.
- **Poll interval / rate limits.** A 30s `gh` poll per in-flight PR is cheap, but a large fleet of open PRs multiplies API calls; the interval is env-overridable if it ever matters.
- **Merging remains a pilot/GitHub action.** The crew watches for merge/close; it does not merge its own PR.
  If you want "tell wingman to merge it" to drive the merge, that's a small add (a `crew-say "merge"` the build playbook acts on) — noted as a possible follow-up, not in this plan.
