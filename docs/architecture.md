# Wingman architecture

In-depth reference for how wingman works internally.
For day-to-day use, see the [README](../README.md).

## The wingman launcher

`bin/wingman` is a thin wrapper around the real `claude` binary: it wires up a few things, then execs `claude` so the rest of the session is an ordinary Claude Code session.

- It mints and exports a fresh `WINGMAN_RUN_ID`, inherited by every crew member spawned during that run.
  This is the cache key the onboarding-preference questions (remote vs. local, whether markdown deliverables also get published as Artifact links, verbosity, direct-spawn visibility) are asked and cached against exactly once per run rather than once per crew member.
  Every consumer of a missing run id treats it as "unanswered, apply the conservative default" rather than asking - skipping the launcher does not error, it just means the whole session runs on defaults with nothing cached.
- It resolves every discovered sibling project root (`bin/discover-projects`) and passes `--add-dir` for each, so a global-scope spawn, or wingman's own occasional cross-project read, never blocks on a first-time directory-permission prompt.
- It registers this session's own tmux pane path at `$WM_HOME/self-pane` (only when running inside tmux) - the read-only signal `bin/watch-fleet`'s `self_pane_check` uses to detect wingman's own dropped Remote Control connection (see "Remote Control" below).
- It refreshes `~/.wingman/` state and the project-discovery cache unconditionally on every launch, so the roster and project list are never stale from a previous run.

None of this is required - the underlying scripts work without the launcher - but skipping it means hand-approving `--add-dir` prompts, no onboarding-preference caching for the run, and no disconnect detection for wingman's own session.

## Remote Control

Claude Code's Remote Control lets a session be reached from `claude.ai/code` or the Claude desktop/mobile apps, not only via `tmux attach`.
Wingman wires this up in both directions:

- Every crew member launches with `--remote-control "wm-<id>"` (`bin/spawn-crew`, gated by `WM_REMOTE_CONTROL`, on by default) - the `wm-` prefix matches its tmux window name, so it reads identically in both places.
  This fails soft: on an account that can't use Remote Control, the session just starts normally with it quietly unavailable.
- A crew member's own dropped connection self-heals: `bin/watch-fleet`'s `remote_control_dropped_check` recognizes the disconnect banner in that member's pane and automatically retypes `/remote-control` to restore it.
- Wingman's own connection is watched differently, on purpose: `self_pane_check` can see wingman's own disconnect banner but deliberately never types into wingman's own pane - doing so from outside would race the very tool call meant to send the reconnect command.
  Instead it wakes wingman with an explicit `remote-control-dropped` event, and wingman tells the pilot to run `/remote-control` themselves.
- There is no reliable way to detect programmatically whether a given session is being watched locally or over Remote Control at any moment - see [`docs/analysis/2026-07-13-remote-control-transport-detectability.md`](analysis/2026-07-13-remote-control-transport-detectability.md) - which is why wingman asks once, up front, rather than guessing.

## Mechanical guards

The rules stated in prose throughout this document and `CLAUDE.md` are also enforced mechanically, via Claude Code `PreToolUse`/`PostToolUse` hooks in `hooks/`, not left to prompt discipline alone:

- `hooks/no-direct-edit-guard.sh` blocks wingman's own top-level session (and any lead) from editing code or running long investigations directly - heavy work always goes to a crew member.
- `hooks/no-merge-guard.sh` denies `gh pr merge` and equivalents from every crew session unless that specific effort was granted `--allow-merge`; `hooks/merge-attribution-tracker.sh` posts a PR comment attributing an authorized merge to the crew member that made it.
- `hooks/no-watcher-kill-guard.sh` denies a `kill`/`pkill`/`tmux kill-window`/`tmux kill-session` whose target resolves to a live `watch-fleet` cycle, so the wake loop's own process can't be killed by accident.
- `hooks/api-outage-spawn-guard.sh` denies new crew spawns while a fleet-wide API outage is detected as active.
- `hooks/artifact-link-guard.sh` and `hooks/artifact-publish-tracker.sh` enforce the Artifact-publish contract - a markdown deliverable is published as a hosted link only when the pilot asked for that and a content scan passes.
- `hooks/pilot-preferences-guard.sh` denies every other tool call in a fresh run until the onboarding-preference questions are answered.

Each of these exists because relying on the equivalent prose instruction alone had already failed at least once in this project's history; the hook is a backstop, not a replacement for the playbook text.

## Harness-agnostic by design

The **crew** coordination layer - tmux windows, the JSON status files, the watcher loop, and the board - does not depend on any one agent harness.
A crew member is just an agent CLI running in a tmux window that keeps its status file current.

The default launch recipe uses the `claude` CLI and its flags, and that is the single place to change for a different harness: it is isolated in `bin/spawn-crew` and overridable via `WM_AGENT`.
Wingman deliberately avoids a harness's native background-agent/attach/resume features to run or take over *crew*, because that would wed the crew layer to one harness. tmux attach is the takeover path precisely because it is neutral - it reaches whatever agent CLI is in the window.

The one thing that is legitimately harness-specific is **how the watcher wakes wingman** (see below) - a private loop between wingman and its own supervisor, not part of the crew layer.
Swapping harnesses means swapping that one arming primitive, exactly as it means swapping the `WM_AGENT` launch line; both are isolated, neither leaks into the crew coordination layer.

## The wake loop

A file on disk cannot rouse an idle session, so the only reliable way wingman is woken when crew need it is the **completion of a task the harness tracks**.
The watcher, `bin/watch-fleet`, is built for exactly this:

- It **blocks** - watching status files and window liveness, silently absorbing benign "still working" updates - and **exits with one reason line** the instant a crew member flips to `blocked`/`review`/`done`/`died`/`stalled` or freezes on a prompt.
  One run is one *cycle*.
- It is armed as a **harness-tracked background task** (e.g. Bash `run_in_background`), on its own, never bundled onto the tail of another command.
  Because the harness tracks it, its exit re-invokes wingman - that exit **is** the wake.
  It is never run detached (`nohup`/`&`); a detached process cannot wake an idle session.
- On each wake, wingman reads the reason line and `~/.wingman/wake`, surfaces the event to the pilot, then **arms exactly one fresh cycle**.
  The chain persists only if it re-arms after every fire.
- The arm's status line is truth: `armed` (a fresh cycle is now blocking), `healthy` (a live cycle already exists - do not start another), or a `blocked:/review:/done:/died:/stalled:` reason (it fired).
  An atomic claim (an `mkdir`-based lock, verified with a write-then-read-back pass rather than trusting `mkdir` alone) makes two near-simultaneous arms resolve to exactly one live cycle, never two.
  The watcher checks for pending events the moment it arms, so a crew member that finishes in the gap between one fire and the next arm is surfaced by that arm, not lost.

The watcher also detects a crew frozen on a permission or trust prompt - a terminal-UI stall the status files can't see - and flips it to `blocked`. A second, distinctly-worded regex (`WM_RESUME_PROMPT_RE`) layered onto the same generic dialog-shape detector recognizes one further freeze: the CLI's own "resume from summary?" menu, which a `claude --resume` relaunch of a long-transcript session can land on (issue #30). That gets its own specific `blocked` wording (needs one keypress via `bin/crew-takeover`) rather than the generic permission/trust one, so an automated resume attempt that silently froze there is never misreported as a healthy `working` member.
It detects a member gone silently idle (no pane output, no status update, no execution in its process tree) and, before flipping it to `stalled`, sends it a one-shot check-in nudge - a plain message into its pane, worded for an API/connectivity-error signature (a rate limit, a 5xx, a connection reset) if the pane tail shows one, generic otherwise - and waits a full cooldown window for activity; only silence through that whole window confirms the flip. This lets a transient outage, or any other self-resolvable hiccup, self-heal where possible instead of paging the pilot immediately.

### Correlated fleet events

A single `blocked`/`stalled`/`died` member is routine and is always reported individually.
When several members hit the **same** signal in one pass - many crew died together, or many are simultaneously `stalled` with an API-error reason - the watcher collapses them into one synthetic bullet naming every affected id, rather than paging the pilot once per member.
This grouping (`wm_state group-attention`) is a pure, stateless display filter: it only changes what the two `fire()` display channels (stdout, the wake file) render, never the underlying roster, and it is recomputed fresh on every fire rather than persisted.
A `died` batch is partitioned by cause **before** the collapse threshold is applied: a `death_cause` of `api-outage` (see below) collapses into its own `correlated:api-outage-death` bucket, everything else collapses into the crash-flavored `correlated:mass-death` - each partition is evaluated independently, so a minority of one cause is never absorbed into the other's message.
`bin/crew-resume` is the bulk recovery tool a mass-death bullet names as its default remedy: it relaunches every currently-`died` member with `claude --resume <session-id>`, reusing its roster record (parent, worktree, session id) as-is, and is idempotent - a member that is not `died`, or whose window already exists, is skipped rather than relaunched.

### Fleet-wide outage detection

Recurring Anthropic-side `529`/`5xx` bursts are common enough to warrant their own persisted state, not just per-member correlation. `bin/watch-fleet` (owner `""`, wingman's own top-level cycle only - never a lead's) tracks a fleet-wide outage-state machine (`wm_state outage-update`, `$WM_HOME/api-outage-state.json`: `clear`/`active`, `since`, `last_signal`, `signal_count`), advanced every poll from the same per-member API-error pane signature already used for the stall-nudge, plus however many members died *that poll* with `death_cause: api-outage` - a tag `wm_state reconcile` writes at the moment of the death flip, read from a small per-member pane-tail cache (`pane-tail-<id>.txt`, overwritten in place every poll, the last thing known about a pane before its window disappeared) matched against the same regex. `clear` -> `active` crosses the identical count/ratio threshold `group-attention` already applies to a single poll's batch, evaluated continuously; `active` -> `clear` requires a quiet period (`WM_OUTAGE_QUIET`) with zero fresh signal.

A transition fires as an ordinary watcher wake (never a new `--classify` outcome) with its own reason line and wake-file content - structurally identical to a `blocked`/`review`/`done`/`died`/`stalled` reason, just fleet-scoped rather than per-member. Two other mechanisms read this state directly (not through `wm_state`): `hooks/api-outage-spawn-guard.sh` denies `bin/spawn-crew` while it reads `active` (lifted per-call with `--force-during-outage`), pausing new spawns - both wingman's own and any lead's, since both call the same script - without touching already-running crew; and `bin/crew-resume` itself refuses (`--force` required) to relaunch a `died` member while the state is `active`, defense in depth for a human running it by hand. The pilot's own standing instruction (`CLAUDE.md`) treats an `outage-cleared` fire naming outage-tagged deaths as pre-authorized: `bin/crew-resume --all-died` runs immediately, without a fresh confirmation, since the recovery is reversible and low-risk.

## The deliverable lifecycle and `review`

A crew member is not spun down the moment its deliverable appears; one session sees a piece of work through from creation to final disposition.
The **state model is defined once** in the shared status contract (`playbooks/_status-contract.md`), which is appended to every crew brief; playbooks describe only the work, not how to move between states.
The status state machine (`bin/lib/wm-state.py`) encodes the same states:

- `LIVE_STATES = (working, blocked, review, stalled)` - a member in any of these is still in flight and stays on the board's Active list.
- `working` is active work in flight - producing, revising, or seeing through work (e.g. CI) that must conclude before the deliverable is ready.
  It is never surfaced, so summary refreshes here don't wake the pilot.
- `review` is the parked-and-waiting state: the deliverable is produced and surfaced, and the member is now watching an external condition it does not control (a PR merge, a plan approval).
  It is both **live** and **surfaced** - `needs-attention` (`ATTENTION_STATES`) announces it to the pilot once per entry, exactly as `blocked` is announced, but the member keeps running.
  A member moves back to `working` to act on an event (a review comment, a CI failure) and returns to `review` when it settles.
  The dedup key `needs-attention` actually reads is `announced`, not `updated`: `announced` advances on a genuine transition into an attention state, and - for `review` specifically - also on a material change to its `artifact`/`blocker`/`delivery` pointer, but not on a same-status `review` refresh that only touches `summary`.
  `blocked` and `done` are unscoped by this gate: `--silent` is forbidden for them, so every non-silent call announces.
  This is why a re-delivery that answers feedback on an already-`review` deliverable must transition out of `review` and back (through `working`), not restate `--status review` directly: only the transition, or a changed pointer, re-announces.
  Idle time in `review`, or a same-status summary-only refresh, writes nothing new to surface, so a parked member never spams.
- `done` means the terminal condition is met and the member is ready to be reaped: a plan approved/handed off, or a PR merged/closed.
  A ready deliverable is `review`, never `done`.

The lifecycle is uniform across types - deliver → `review` → drop to `working` to act on feedback and back → `done` - and each playbook names its own deliverable, dependency-to-watch, and terminal condition; the contract supplies the state mechanics.

Wingman holds **no** waiting logic itself: it recognizes crew status updates and surfaces the meaningful ones, and it spins a member down in exactly two cases - the member reports `done` (the watcher detects it; wingman relays the outcome and reaps it with `crew-standdown` **in the same turn**, so `done` is transient on the roster and finished members never pile up), or the pilot stands it down explicitly.
Nothing else reaps a member.
*How long* and *why* a member stays alive after delivering is entirely the playbook's concern; wingman only avoids cutting it short.

## The crew-level wake loop (PR review)

A developer member's "seeing it through" is watching its own PR, and it uses the same wake primitive wingman uses on itself, one level down.
A crew Claude session cannot rouse itself once its turn ends, so after opening a PR the member arms `bin/pr-watch` as a **harness-tracked background task** (never detached).
It blocks, polling the PR through the forge CLI, and exits with one reason line (`merged` / `closed` / `changes-requested` / `ci-failed` / `comment` / `checks-passed`) the instant an actionable event occurs; that exit re-invokes the crew member, which acts and arms exactly one fresh cycle - the identical arm-one-cycle discipline as `watch-fleet`.
`checks-passed` fires once when the PR settles with nothing failing and nothing pending (all-green, or a repo with no CI), which is what lets a member stay `working` through CI and be woken to move into `review` only when it is genuinely on the humans; it re-arms once checks go pending/failing and settle again.

A cursor at `$WINGMAN_HOME/pr/<crew-id>.json` records what has already been surfaced, so a persistently-red build or an already-handled comment does not re-fire, and this session's own replies never wake it - identified by an anchored `<!-- wingman-crew:<id> -->` marker matching its own crew id, not by forge login alone (every crew session shares one forge login, so login alone would also drop a human's own genuine comments or a different crew member's own genuine review).
Firing advances only the fired dimension, so a co-occurring lower-priority event still surfaces on the next cycle.
The event-decision logic lives in `bin/lib/pr-eval.py` (pure, unit-testable with canned JSON); `bin/pr-watch` is the thin poll loop around it.

This keeps the two watch loops cleanly separated at different levels: `watch-fleet` is wingman's channel to its crew (forge-agnostic), `pr-watch` is a crew member's channel to the forge.
The forge-specific part is isolated in `pr-watch`'s `gh` calls, overridable via `WM_GH` (point it at another binary or wrapper), exactly as the agent launch line is isolated in `spawn-crew` behind `WM_AGENT`; a non-GitHub forge swaps this one script.
Analyst (and other non-PR) members have no external signal to poll, so they arm no watcher - they idle in `review` until the pilot's feedback arrives via `crew-say`.

## The crew hierarchy (leads)

Wingman's crew is a **tree**, with the pilot at the top. A large effort is owned by a **lead** - a crew member whose playbook is "be a manager for one effort." A lead runs the *same* intake → scope → spawn → supervise → report → escalate loop wingman runs, one layer down, over its own crew (a software-analyst, an architect, one or more developers, a reviewer). This is recursion over the existing primitives, not a parallel subsystem: the lead uses the same `bin/` scripts and the same watcher.

**Ownership falls out of who spawns.** Every crew record carries a `parent` field, stamped by `bin/spawn-crew` from the spawner's `$WINGMAN_CREW_ID`. Wingman has none (it is the top orchestrator), so its spawns get `parent=""` (top level); a lead has its own id, so its spawns get `parent=<lead-id>`. No new flags - the tree is implicit in who ran the spawn.

**Each layer sees only its direct reports.** Surfacing (`needs-attention --owner`), the watcher, and the default `crew-list` are all scoped to an owner (`""` = top level). Wingman's watcher runs `--owner ""` and sees only the top level (including a lead's rolled-up line); a lead's watcher runs `--owner <lead-id>` (the default from its own `$WINGMAN_CREW_ID`) and sees only its own workers. The pidfile/beacon/wake are keyed by owner (`watch-<owner>.*`, `wake-<owner>`; wingman keeps the legacy unsuffixed names), so wingman's watcher and each lead's watcher coexist without contending. Drill-down is always available: `crew-list --owner <id>`, `crew-list --tree`, and the tree-rendered `board.md`.

**Escalation is recursive human-in-the-loop.** A worker that sets `blocked` surfaces to its owner (its lead), not to the pilot. The lead answers via `crew-say` if it can; if the decision is above its pay grade, it re-raises `blocked` on its *own* line, which surfaces one level up. Decisions travel up only as far as needed; the answer flows back down the same chain. Cascade stand-down mirrors this: standing down (or reaping) a member recurses to its descendants, so finishing a lead never orphans its sub-crew.

**Peers collaborate directly.** Siblings under the same lead `crew-say` each other for routine coordination (a developer↔reviewer exchange, a developer↔developer interface negotiation) without routing through the lead - which would pour their detail into the lead's context, the exact bloat the hierarchy prevents. The lead sees only the rolled-up outcome unless a genuine decision escalates. A guardrail in `crew-say` keeps collaboration within a team: a caller may message its own reports, a sibling under the same lead, or its own lead - not arbitrary crew elsewhere in the tree (override with `--force`).

**Depth cap: two crew layers.** The full chain is pilot → wingman → lead → worker; wingman and the pilot are not crew layers, so the two crew layers are the lead and its workers. A lead does not spawn further leads; deeper nesting is a future opt-in gated behind cost guardrails.

**Domain generality.** The tree, escalation, rollup, and owner-scoping know nothing about software; only the playbooks carry domain. The playbook library ships this as a first-class taxonomy rather than a hypothetical: category subdirectories under `playbooks/` (`ai-research`, `data-science`, `scientific-research`, `business-development`, `business-operations`, alongside `software-development`) each carry a domain-appropriate pipeline, so a science lab (experimental-designer → experimentalist → analysis-scientist → peer-reviewer) or a business team (market-analyst → gtm-strategist → partnerships-rep) runs the same machinery out of the box. Adding a further domain is still a playbook swap, not a code change: reuse the default role names with domain-appropriate `*.local.md` prose, or add named roles (`playbooks/<category>/pi.md`, …) and a `lead.local.md` that sequences them. The lead playbook is written in role-and-handoff terms ("gather requirements → design → execute → review → integrate") with software as the concrete default.

## Autonomous mode and interactive gates

Because no human sits at a crew member's terminal, `bin/spawn-crew` launches each member with `--permission-mode bypassPermissions` (`WM_PERMISSION_MODE`) so a gated tool call auto-approves instead of hanging on a prompt forever.
Set `WM_PERMISSION_MODE=` (empty) to fall back to interactive prompting.

Two one-time interactive gates remain that no flag bypasses:

- Claude Code's Bypass-Permissions acceptance (once, ever).
- Each repo's first-time workspace-trust dialog (once per repo).

The watcher catches both (and a per-tool prompt when bypass is off), flips the crew member to `blocked`, and wakes the pilot to approve once via `bin/crew-takeover`.
After that, crew in that repo run fully unattended.

## Playbooks and local overrides

A crew type is defined entirely by a playbook - plain prose in `playbooks/<category>/`:

- `playbooks/software-development/software-analyst.md` - gather requirements and turn a problem into a plan (or, in report mode, an investigation report).
- `playbooks/software-development/architect.md` - turn an approved spec into a detailed technical design / implementation plan.
- `playbooks/software-development/developer.md` - the dev cycle: worktree → implement → commit → push → PR, then watch the PR (CI + review feedback) through to merge/close.
- `playbooks/software-development/reviewer.md` - review a plan or a PR and report findings.
- `playbooks/common/lead.md` - manage an effort end-to-end: decompose it, hire and sequence its own crew, integrate, and roll one status line up. Domain-neutral, so it lives outside any one category.
- `playbooks/common/research.md` - example non-dev type: gather evidence, write a cited report. Also domain-neutral.
  Shows the shape a `scientist`/`pm` role takes.

Five further categories ship alongside `software-development`, each a domain-specific pipeline of roles: `ai-research` (research-analyst → experiment-designer → ml-engineer → research-reviewer), `data-science` (data-analyst → data-engineer → data-scientist → analytics-reviewer), `scientific-research` (experimental-designer → experimentalist → analysis-scientist → peer-reviewer, with a nested `biological-research` sub-domain: assay-designer, bioinformatician), `business-development` (market-analyst → gtm-strategist → partnerships-rep), and `business-operations` (ops-analyst → finance-analyst / process-designer).
A role name is unique across every category, so a bare `--type` (e.g. `developer`) always resolves unambiguously; a category-qualified name (`software-development/developer`) is available to break a future collision.

There is no hardcoded list of types; a type exists iff its playbook does.
`bin/spawn-crew --list-types` enumerates them, grouped by category.

`playbooks/<category>/<type>.local.md` overrides the tracked `<type>.md` when present.
`*.local.md` is gitignored, following the same pattern as Claude Code's `settings.json` / `settings.local.json`: customizations and private crew types can't be accidentally committed and survive `git pull` of new defaults.
Example: to make the software-analyst crew follow your own planning skill or checklist, write `playbooks/software-development/software-analyst.local.md` saying so.

Project-discovery hints follow the same story: an optional gitignored `config.local.sh` in this repo can set extra roots, pinned paths, or an ignore list (`WM_ROOTS`, `WM_PINS` as newline `name|path` entries, `WM_IGNORE`).
It is absent by default; the defaults cover the common case.

## Spawning crew (the recipe)

Every crew member is an independent, interactive `claude` session in its own tmux window, launched in the target project:

```
bin/spawn-crew --type <name> (--repo <name-or-path> | --scope global) \
  --objective "<one-line task>" [--input <plan-path>] \
  [--model <alias|id>] [--effort <low|medium|high|xhigh|max>]
```

The script resolves the project, resolves the playbook (`<type>.local.md` if present, else `<type>.md`), forces a known session id, opens the tmux window, records the member in `~/.wingman/crew.json`, and delivers the objective as the session's first message.
It prints the crew `id`.

Pass `--scope global` (instead of `--repo`) to ground a crew member at the global project scope: it launches at the workspace root with every discovered repo added, so it can read and work across all of them and choose the target repo(s) itself.
Use it for cross-repo work or when the repo is genuinely unclear.

The git/branch/PR workflow (worktrees, branches, opening a PR, the no-merge guard) is conditional on git-ness, not universal: it applies whenever the crew type is a `software-development` role (`bin/spawn-crew` refuses to spawn one against a target that isn't a confirmed git repo), or whenever the target project happens to be a confirmed git repo regardless of category.
`bin/spawn-crew` detects this mechanically at spawn time - for `--repo` targets, `git -C "$REPO" rev-parse --show-toplevel` compared (physically, symlink-resolved) against `$REPO` itself, so a directory merely nested inside a repo reads as non-git - and exports the result as two roster-scoped env vars: `WINGMAN_IS_GIT=true|false` and, only when a repo, `WINGMAN_HAS_REMOTE=true|false` (whether `origin` is configured, i.e. whether there's anywhere to open a PR against).
Both are a real tri-state: absent (never exported for `--scope global`, and not carried forward by `bin/crew-resume` for a pre-change roster record) means "not yet known - detect it yourself" for whatever directory the member decides to work in, and must never be conflated with `false`.
A non-software-development member (e.g. `data-engineer`, `ml-engineer`, `experimentalist`) branches on these two variables to choose between the full worktree/branch/PR flow, a git-but-no-remote local-commits-only flow, or a plain-files-no-git flow; `developer` has no non-git fallback by design and blocks if it ever finds itself in one.

## State home - `~/.wingman/`

Machine-local runtime state, created on first run, never committed:

- `crew.json` - the live roster (id, type, session id, tmux window name and window id, repo, status, `parent`, `is_git`/`has_remote`).
  `parent` is the id of the crew that spawned the member (`""` for a member wingman spawned directly); it is what scopes each layer to its own direct reports.
  `is_git`/`has_remote` are recorded for repo scope only (`null`/absent for global scope) - see "Spawning crew" above.
- `crew/<id>.json` - each crew member's distilled status record.
- `board.md` - the human-readable render of the roster, its Active section indented as a tree so a reader sees the org.
- `watch.pid` / `watch.beat` - wingman's (owner `""`) watcher cycle's pid and liveness beacon.
  A lead's watcher keys its own files by owner (`watch-<owner>.pid` / `watch-<owner>.beat`), so per-owner watchers coexist.
- `wake` - the attention list wingman's watcher writes when it fires; a lead's watcher writes `wake-<owner>`.
- `acked.json` - the last `announced` stamp surfaced per crew id, so a surfaced event (blocked/review/done/died) is delivered once instead of on every watcher arm and Stop-hook check.
  A new `announced` (a genuine state change) re-surfaces.
- `handled.json` - the last `announced` stamp fully HANDLED by the Stop hook for each crew id, set only when a stop is allowed to proceed - distinct from `acked.json` so a surfaced-but-unhandled event still re-blocks instead of being permanently suppressed by a premature ack.
- `pr/<id>.json` - a developer member's `pr-watch` cursor: what PR events it has already surfaced (CI signature, conversation high-water mark, whether it has settled green), so a red build or a handled comment does not re-fire.
- `projects.json` - the discovered-projects cache.
- `crew-archive.jsonl` - append-only history of records removed by `bin/crew-prune` (one JSON object per line).
  Pruning removes fully-closed (`stood-down`) records from `crew.json` and deletes their `crew/<id>.json`, archiving each here first so the roster stays lean without losing the record of who ran.
- `orphan-candidates.json` - `{window_name: first_seen_iso_stamp}` for a live `wm-*` tmux window with no matching `crew.json` record, tracked by `wm_state reconcile`'s grace-period-gated orphan-window adoption (owner `""` only) - see "Survival & reconciliation" below.

All *user-editable* customization lives in the repo as gitignored `*.local.md` / `config.local.*`, not here.
`~/.wingman/` is pure runtime state you never hand-edit.

## Survival & reconciliation

The tmux **server** owns the crew windows, so killing wingman does not kill the crew.
Every session and window target is exact-match (`-t "=name"`; tmux otherwise resolves bare names by prefix, which is how crew once landed inside a similarly-named session - issue #39), and `bin/spawn-crew` guarantees the crew session itself exists before creating a window in it.
On any startup wingman reads `~/.wingman/crew.json`, reconciles against the live windows (`bin/crew-list` does this automatically), re-arms the watcher if crew are in flight, and reports the current roster.
Before judging liveness, reconcile callers adopt strays: a roster member's window found in another tmux session is moved back into the crew session (`tmux move-window`, process intact), so a live member is never reported `died` merely for sitting in an unexpected session (issue #44).
A crew member whose window died shows as `died` and is recoverable either by hand (`bin/crew-takeover <id>` prints the exact resume command) or in bulk via `bin/crew-resume <id>...` / `bin/crew-resume --all-died`, which relaunches it (or every died member) with `claude --resume <session-id>` and verifies the relaunch actually took before flipping it back to `working`.
`bin/spawn-crew` itself only ever reports success once the `crew-add` write is confirmed readable back (a captured exit-status check plus a `crew-get` read-back; either failure tears the just-created window down and dies loudly) - a live, untracked session with no roster record is the failure mode this closes (issue #79).
As a backstop for the remaining ways a record can still go missing (a crash between window creation and `crew-add`, or a window created outside `bin/spawn-crew` entirely), wingman's own reconcile pass (`--owner ""` only) also tracks any live `wm-*`-prefixed window with no matching roster record in `orphan-candidates.json`, and adopts it as a `blocked` roster-only record once it has stayed unmatched past `--grace-seconds` (default 15s) - long enough that an ordinary in-flight spawn, whose window always exists a moment before its `crew-add` lands, is never mistaken for a genuine orphan.

## Tests

`bash tests/run.sh` runs the bash E2E suites.
No real `claude`/tmux fleet is needed; each test uses an isolated throwaway state home and tmux session name.
They cover:

- the wake loop (`watch-fleet` blocks, fires on an actionable event, singleton guard, an atomic claim so two near-simultaneous arms never both win),
- terminal-event de-duplication (an event surfaces once, re-surfaces only on a state change),
- repo-vs-global spawn scope,
- roster views and cleanup (`crew-list` hides `stood-down` by default, `--all` reveals it; `crew-prune` archives + removes terminal records),
- silent-stall detection (the staleness gates, the execution probe, and the API-error reason flavor + nudge-then-escalate flow),
- correlated-event grouping (`group-attention` collapsing a mass-death or API-outage batch into one bullet) and bulk recovery (`crew-resume`, including its idempotency guards and tree preservation),
- PR-event evaluation including `checks-passed` (fires once on green / no-CI, re-arms after a new failing/pending rollup),
- confirmed-write spawning and orphan recovery (issue #79): `bin/spawn-crew` tears down its window and fails loudly on a `crew-add` failure or a failed verify-after-write read-back; `with_locked` propagates a real `flock()` failure instead of swallowing it; `wm_state reconcile` adopts an orphaned `wm-*` window as `blocked` only once it has genuinely outlasted the grace period, never a healthy in-flight spawn.

Requires `bash`, `git`, `tmux`, and `uv`.
