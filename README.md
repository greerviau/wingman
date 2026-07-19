![Wingman Logo](assets/wingman-logo.png)

[![CI](https://github.com/greerviau/wingman/actions/workflows/ci.yml/badge.svg)](https://github.com/greerviau/wingman/actions/workflows/ci.yml)

**Talk to one agent. Run a whole crew.**

Wingman is a long-lived Claude Code session that orchestrates a crew of agents for you.
You (the pilot) give it high-level directives - *"implement this feature,"* *"investigate this issue,"* *"what's my crew doing?"* - and it delegates the real work, tracks status, and surfaces only real decisions to you.
It orchestrates; it never does the heavy lifting itself.

Each crew member is an independent `claude` session in its own tmux window, launched in your target project - so you can watch it, type into it, or take it over live, and it survives even if wingman is killed.

## Why not just subagents?

A subagent is a function call: it runs in your context and vanishes when it returns.
That fits a single bounded task, not work that outlives one turn - a PR sitting through CI, a plan awaiting your sign-off, a multi-step effort.
Wingman fills that gap:

- **Survives restarts** - state lives on disk (`~/.wingman/`), not in a transcript, so it outlasts compaction and restarts.
- **Zero-token supervision** - the wake loop is event-driven; nothing burns tokens asking "done yet?"
- **One status contract** - every crew type reports through a shared contract, never transcript scraping.
- **Cost-disciplined** - spawning is deliberate and the org is depth-capped, never an unbounded swarm.
- **Enforced by hooks**, not prompt discipline alone.

Crew members can still spin off their own subagents for bounded lookups - wingman is the coordination layer above that.
See [`docs/architecture.md`](docs/architecture.md) for how each piece works.

## Quick start

```
git clone https://github.com/greerviau/wingman.git
cd wingman
bin/wingman          # recommended; plain `claude` also works
```

On first launch wingman runs `bin/doctor` (installs any missing dependencies with your consent), discovers your sibling repos with zero config, and starts the supervisor.
Then give it a directive. All you need up front is `claude` and `git`.

> `bin/wingman` is a thin launcher: it pre-adds sibling repos (`--add-dir`), mints a run id so preferences are asked once per run, and wires up Remote Control disconnect detection. Plain `claude` works too, with less - see [the launcher docs](docs/configuration.md#the-wingman-launcher).

## Driving wingman

Talk in plain language, or use the slash commands:

| You say | Wingman does |
|---|---|
| "Implement feature X in `<repo>`" | software-analyst plans it → you review → developer ships a PR and shepherds it to merge |
| "Investigate issue Y" | software-analyst investigates in report mode (bugs reproduced end-to-end first) |
| "Take the lead on X" | a **lead** hires and runs its own crew, rolling one status line up to you |
| `/spawn <type> <repo\|global> <objective>` | launch any crew type; `bin/spawn-crew --list-types` shows them all |
| `/status` | compact roster: who's on what, blocked, stalled, or ready |
| `/blocked` | each blocked member and the decision it needs |
| "Take over X" | prints the exact command to attach to a crew member's window |
| `/standdown <id>` | wrap up a member and close its window |
| `/prune` | drop fully-closed records (archived first) |

Fleet-wide events are handled for you: a mass crew death offers a one-command resume, and a detected API outage or an approaching usage-quota pauses new spawns and resumes automatically - already-running crew are never touched.
See [fleet resilience](docs/fleet-resilience.md).

## One session sees its work through

A crew member isn't spun down the moment its deliverable appears.
A developer that opens a PR parks in a `review` state and keeps running - watching CI, fixing breakage, and addressing feedback (dropping back to `working` while it does) - and reports `done` only when the PR merges or closes.
Your feedback routes back to that same session, so it keeps full context.
It stops early only if you `/standdown` it.

## Take the wheel any time

- Attach to any crew member's tmux window to type or take over; detach (`Ctrl-b d`) to hand back.
- Killing wingman leaves the crew running; relaunching rebuilds the roster.
- Every crew member is also reachable from `claude.ai/code` and the Claude desktop/mobile apps via Remote Control, with dropped connections auto-recovered - see [Remote Control](docs/architecture.md#remote-control).

## Autonomous by default

Crew launch with `--permission-mode bypassPermissions`, so gated tool calls auto-approve instead of hanging with no human at the terminal.
Two one-time gates (Claude Code's Bypass-Permissions acceptance and each repo's first-time trust dialog) are detected before a window opens, refusing the spawn with the exact remedy rather than freezing; once cleared, crew in that repo run unattended.

**Model:** an explicit `--model` on a spawn wins; otherwise `$WM_MODEL` (see [`config.example.sh`](config.example.sh)); otherwise the agent CLI's default.

## Playbooks: customize the crew

A crew type is just a playbook - plain prose in `playbooks/<category>/<role>.md`. The `software-development` category reads as an org:

| Role | Purpose |
|---|---|
| `software-analyst` | requirements / plan or report |
| `architect` | detailed technical design from an approved spec |
| `developer` | worktree → implement → commit → push → PR |
| `reviewer` | review a plan or PR and report findings |

`lead` and `research` live in the domain-neutral `common` category; more categories ship too (`ai-research`, `data-science`, `scientific-research`, `business-development`, `business-operations`, `infrastructure`).
`bin/spawn-crew --list-types` lists every role.

- **Customize:** drop a `<type>.local.md` beside the default; if present it wins.
- **Add:** create `<type>.md` and spawn with `--type <name>`. A type exists iff its playbook does; a bare name works when it's unique, and a category-qualified name (`software-development/developer`) breaks a collision.

`*.local.md` is gitignored, so your customizations can't be committed by accident and survive `git pull`.

## Run an effort as an org (leads)

Your crew is a tree with you at the top.
Small directives take lean direct paths; a large, end-to-end effort gets a **lead** that decomposes it, sequences the phases (software-analyst → architect → developer(s) → reviewer), integrates the results, and rolls a single status line up to you.

- **Each layer sees only its direct reports.** A worker's blocker surfaces to its lead; only a decision the lead can't make escalates to you, and your answer flows back down.
- **Peers collaborate directly** - two developers on an interface, or a developer and a reviewer, without routing through the lead.
- **Drill down any time:** `/status --tree` for the whole org, `/status --owner <lead-id>` for one team.

The tree is domain-neutral - swap playbooks and the same machinery runs a science lab or a business team. Depth is capped at two crew layers (a lead does not spawn leads).

## Tests

`bash tests/run.sh` runs the bash E2E suites - no real `claude`/tmux fleet needed, just `bash`, `git`, `tmux`, and `uv`.
GitHub Actions runs the same suite on every push and PR to `main`.

## Learn more

- [architecture.md](docs/architecture.md) - the core model: the wake loop, the deliverable lifecycle, and the crew hierarchy.
- [configuration.md](docs/configuration.md) - the launcher, the spawn recipe, model selection, and state in `~/.wingman/`.
- [guards.md](docs/guards.md) - the mechanical guards, checkout freshness, and autonomous mode.
- [fleet-resilience.md](docs/fleet-resilience.md) - correlated fleet events, API-outage and usage-limit detection.
- [playbooks.md](docs/playbooks.md) - crew types, categories, and local overrides.
