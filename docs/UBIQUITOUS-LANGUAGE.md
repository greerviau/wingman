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
- **Self-heal nudge** — the one-shot check-in message the watcher sends an apparently-idle member before flipping it to `stalled`. A `stalled` fire is therefore always post-nudge, never a first response.
