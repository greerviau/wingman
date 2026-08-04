# Ubiquitous language

The words wingman's docs, prose, and code use for its domain concepts. Use these terms verbatim; when a term settles or goes stale, update it here in the same change.

## Configuration

- **Settings file** — `config.local.toml` at the repo root: the gitignored, declarative file where a pilot persists settings across runs. Templated by `config.example.toml`, read by `bin/lib/wm_config.py`. "The settings file" and "the config file" both name it.
- **Onboarding preference** — one of the answers only the pilot can give (`remote`, `artifact_linking`, `verbosity`, `direct_spawn_visibility`, `pr_comments`), governing wingman's and every crew member's behavior. The required key set and each key's vocabulary live in `hooks/lib/pilot-prefs.sh`, which is what the guard enforces.
- **Setting** — any other configurable value (a model, an effort, a project root, a harness knob). A setting is never asked for; an unanswered *preference* is.
- **Typed setting** — a setting with its own key and schema in `wm_config.py`'s `SCHEMA`, validated by shape. As opposed to an **`[env]` passthrough**: a raw `WM_*` variable carried verbatim, for the ~100 internal knobs no typed home is worth adding for.
- **Source** — which layer a resolved value came from: `env`, `config.local.toml`, `run` (answered this run via `/prefs`), or `default`. `bin/config` reports it per setting.

## Roles and structure

- **Pilot** — the human wingman flies for. Never used in text a crew member will read (a crew member mirrors wording into PR bodies and comments, where "pilot" is meaningless to outsiders); say "the human" there instead.
- **Wingman** — the top-level orchestrator session, started by running `claude` from this repo. Not a crew member and not a crew layer.
- **Crew member** — an independent agent session in its own tmux window, recorded in `~/.wingman/crew.json`. Embodied by `bin/spawn-crew`.
- **Lead** — a crew member (`--type lead`) that runs its own crew one layer down and rolls a single status line up to its owner. `playbooks/common/lead.md`.
- **Playbook** — the markdown file at `playbooks/<category>/<type>.md` that defines a crew type's behavior. A crew type *is* its playbook; overridable with a gitignored `<type>.local.md`.

## The wake loop

- **Cycle** — one run of `bin/watch-fleet`: it blocks, then exits on the first attention event.
- **Fire** — a cycle exiting because something needs attention. The exit itself is the wake; the reason line says why.
- **Fire reason** — the single-line cause a fire reports (`blocked:`, `review:`, `done:`, `died:`, `stalled:`, `outage-detected`, `usage-limit-approaching`, …).
- **Arm** — to start one cycle as a harness-tracked background task, so its exit re-invokes the session that armed it. A detached process cannot wake anyone and is never an arm.
- **Attention state** — a member status that ends a cycle: `blocked`, `review`, `done`, `died`, `stalled`.

## Reporting

- **Pilot-facing `review`** — a `review` state whose deliverable is being handed to the pilot for the pilot's own action (the plan reaching the approval gate, a PR ready for the pilot's review). Always announced, never absorbed by `direct_spawn_visibility=summary-only`.
- **Loop-internal `review`** — a `review` state that is only an input to a review round wingman itself commissioned or is about to commission, in a loop that has not yet concluded. Absorbable under `summary-only`. The distinction is drawn on what the `review` is *for*, not on how many times it recurs.
- **Absorb** — to handle an event fully while not narrating it to the pilot. Never means ignore: the handling always happens, only the narration is suppressed.
- **Report altitude** — the rule that a status report carries results and actionables only, never mechanics (crew ids, session ids, window names, watcher pids, housekeeping actions).
- **Self-report** — a crew member's own claim about its status, artifact, or verdict. Never external truth: a reviewer's "approve" is not a GitHub review decision, and a "CI green" claim is not the merge gate.

## Fleet resilience

- **Correlated event** — the same signal hitting several members in one poll, collapsed into one bullet rather than paging per member. Partitioned by cause before collapsing.
- **Outage state** — the persisted fleet-wide `clear`/`active` machine tracked by wingman's own cycle. `active` mechanically pauses new spawns; already-running crew are never touched.
- **Usage-limit state** — the persisted fleet-wide `clear`/`approaching`/`paused`/`acknowledged` machine derived from the CLI's own `rate_limits` statusline signal. Pausing holds only *new* spawns; running crew keep consuming quota.
- **Self-heal nudge** — the check-in message the watcher sends an apparently-idle member, retried (bounded by `WM_STALL_NUDGE_TRIES`) until its submit is confirmed before the member can flip to `stalled`; a confirmed nudge stamps the member's marker `confirmed`, an unconfirmed one exhausts its retry budget and escalates with a distinct reason instead. Not a universal precondition of every `stalled` fire — see [incidents.md](runbooks/incidents.md#stalled) for the three fire shapes, only one of which is nudge-gated.
- **Resumable** — a `died` member whose Claude Code session transcript is confirmed present on disk (`is_resumable`, issue #251), independent of whether its worktree survived. Rendered as `died (resumable)` in `crew-list`/`board.md`; a `died` member without one is not called resumable even though `crew-takeover` still prints the manual command, since it would fail immediately.
- **WIP anchor** — the `refs/wip/<id>` git ref a dirty worktree's uncommitted state is pointed at, the moment its member flips to `died` (`git stash create` + `git update-ref`, issue #251). Zero-disruption (neither the working tree nor `HEAD` moves) and outside `refs/heads/`, so it is invisible to branch listings. Overwritten, not appended to, on a repeat death — always the latest anchored state, never a history of every death.

## Merge authorization

- **Merge gate** — wingman's own, `hooks/no-merge-guard.sh`. Governed by a crew record's `allow_merge` and `review_gate_waived` fields. Never used to mean the forge's own gate below — the two are distinct and a session's grant on one has zero effect on the other.
- **Forge gate** — GitHub's own branch ruleset or classic branch protection on the default branch. Enforced by GitHub, not by wingman; no wingman-side field affects it. Cleared only by an operator-side remedy (an admin override, a genuinely distinct reviewer credential, or a relaxed ruleset).
- **Admin override** — merging with `gh pr merge --admin` through an existing ruleset bypass actor. The sanctioned forge-gate remedy for this project, authorized per effort by the human. Not a bypass of the merge gate, which still applies in full — `--admin` still needs `allow_merge` like any other `gh pr merge` invocation.
- **Unmeetable review requirement** — a forge gate requiring an approving review on a PR whose author is the same account every crew session authenticates as (issue #50). Unsatisfiable by construction, not merely unsatisfied: GitHub structurally refuses self-approval, so no grant a crew session or the human could make on the wingman side ever closes the gap.
