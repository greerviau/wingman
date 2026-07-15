![Wingman Logo](assets/wingman-logo.png)

[![CI](https://github.com/greerviau/wingman/actions/workflows/ci.yml/badge.svg)](https://github.com/greerviau/wingman/actions/workflows/ci.yml)

Wingman is a long-lived Claude Code session that runs a **crew** of agents for you.
You (the pilot) give it high-level directives - *"implement this feature"*, *"investigate this issue"*, *"what's my crew doing?"* - and it delegates the real work to a crew, tracks their status, raises only real decisions to you, and keeps its own context clean.
It orchestrates; it does not do the heavy lifting.

Each crew member is an **independent `claude` session in its own tmux window**, launched in your target project - so you can watch it, type into it, or take it over live, and it survives even if wingman itself is killed.

## Why not just subagents?

A subagent call is a function call: it runs inside your context, returns a result, and disappears.
That's fine for a bounded, single-shot task.
It breaks down for anything that outlives one turn - a PR that has to sit through CI and review, a plan that needs your sign-off before code gets written, an effort with more than one moving part.
Wingman is built for that gap specifically, not as a thinner wrapper around the same idea.

- **State lives on disk, not in a transcript.**
  Every crew member's status, artifact, and blocker live in `~/.wingman/crew.json` / `board.md`, not in wingman's own context window.
  Killing wingman, clearing it, or letting it compact does not lose the roster - the next session reads the same files and picks up exactly where it left off.
  A subagent's state is the parent conversation; when that conversation ends or compacts, its work is gone with it.
- **Event-driven, not polled.**
  `bin/watch-fleet` blocks on a harness-tracked background task and exits with one reason line the instant a crew member needs attention (`blocked`, `review`, `done`, `died`, `stalled`) - that exit is what wakes wingman.
  Nothing spends tokens asking "is it done yet?"; wingman does no work at all between a spawn and the moment something actually needs it.
- **Distilled status, not transcript scraping.**
  Wingman never reads a crew member's pane or output directly.
  Every playbook reports through the same status contract, so `bin/crew-list` gives a compact, structured answer - this one is blocked on X, this one is ready for review - instead of a wall of text to re-parse and guess at.
- **Cost-disciplined by design.**
  Spawning a crew member is the expensive act, so the default is the smallest crew that does the job, sequential work, and an explicit announcement before fanning out more than a couple of members at once - never an unbounded swarm just because the framework allows it.
- **A depth-capped org, not a flat swarm.**
  A `lead` runs its own crew (software-analyst -> architect -> developer(s) -> reviewer), sequences the phases, and rolls up a single status line, so wingman's own context stays as light for a ten-member effort as for a two-member one.
  Depth is capped at two layers on purpose, and peers talk to each other directly instead of routing everything through a manager.
- **Guards, not just prompts.**
  The rules above are mechanically enforced, not only written down and hoped for: a hook blocks wingman from editing code directly, another blocks a crew member from merging its own PR unless explicitly authorized (and attributes it when it does), another refuses to let anything kill the watcher process the wake loop depends on.
  These exist because relying on prompt discipline alone for exactly these rules has already failed in this project's own history.

Ad-hoc multi-agent scripts, and a bare "spawn N subagents" pattern, don't have any of this: state is scoped to a single run, there's no wake mechanism so something has to poll or babysit, there's no shared contract for what "done" means across agent types, and there's no cost or depth discipline.
Wingman's answer isn't "more agents" - it's a persistent, event-driven crew coordination layer with an accountable status contract underneath the agents.

## Quick start

```
git clone https://github.com/greerviau/wingman.git
cd wingman
claude          # or: bin/wingman   (adds your project roots via --add-dir)
```

On first launch wingman runs `bin/doctor` (installs any missing dependencies with your consent), discovers your sibling repos with zero config, and starts the supervisor.
Then give it a directive.

The only things you must have before the first run are **`claude`** and **`git`**; `doctor` handles the rest.

## Why `bin/wingman` instead of plain `claude`?

`bin/wingman` is a thin launcher, not a separate program: it wires up a few things that plain `claude` started in this repo will not have, then execs the real `claude` CLI.

- **Every sibling project is pre-added.** It resolves your discovered project roots (`bin/discover-projects`) and passes `--add-dir` for each one, so a crew spawn at global scope, or wingman's own occasional cross-project read, doesn't hit a permission prompt for a directory it has never touched before.
- **A fresh run id is minted and exported.** `WINGMAN_RUN_ID` is stamped once per launch and inherited by every crew member spawned during that run.
  It's what lets the onboarding-preference cache (local vs. Remote Control, whether markdown deliverables also get published as links, how verbose to be, how much of a direct review loop to narrate) answer once per run instead of once per crew member.
  Skip the launcher and there is no run id at all - every consumer in the codebase is written to treat a missing run id as "unanswered, apply the conservative default" rather than ask, so those preference questions are simply never asked and the whole session runs on conservative defaults.
- **Wingman's own pane is registered for Remote Control disconnect detection.** It records the session's tmux pane (when running inside tmux) so `bin/watch-fleet` can notice if *this* session's own Remote Control connection drops and wake you to reconnect it (see [Remote Control](#remote-control) below).
  Skip the launcher and that detection never engages for the top-level session - crew members still get it individually, since that's wired up separately per crew member.
- **State home and project cache are refreshed unconditionally.** The `~/.wingman/` state directory and the discovered-project cache are initialized/refreshed on every launch, so the crew roster and project list are never stale from a previous session.

None of this is required to use wingman - the underlying scripts work with or without the launcher - but skipping it means re-approving `--add-dir` prompts by hand, no onboarding-preference caching for the run, and no disconnect detection for wingman's own session.

## Driving wingman

Talk to it in plain language, or use the slash commands:

| You say | Wingman does |
|---|---|
| "Implement feature X in `<repo>`" | spawns a **software-analyst** crew → plan → (your review) → **developer** crew → PR → the developer crew watches its PR through to merge/close |
| "Investigate issue Y in `<repo>`" | spawns a **software-analyst** crew in report mode (reproduces bugs end-to-end first) |
| "Take the lead on X" (big, end-to-end) | spawns a **lead** that hires and runs its own crew (software-analyst → architect → developers → reviewer) and rolls one status line up to you |
| `/spawn <type> <repo-or-global> <objective>` | launch a crew member of any type - `software-analyst`, `architect`, `developer`, `reviewer`, `lead`, `research`, or one you added; `bin/spawn-crew --list-types` shows every category's roles, and a bare name still works when it's unique across categories; pass `global` instead of a repo for cross-repo work |
| `/status` | compact roster: who's on what (with each member's status), what's blocked, what's stalled, what's ready. Closed history is hidden by default |
| `/blocked` | each blocked member + the decision it needs |
| (a batch of crew died together, or hit a correlated API outage) | wingman relays the one collapsed event plus the fix: `bin/crew-resume --all-died` for an ordinary mass death (e.g. a host/tmux crash); for a detected Anthropic-side outage, new spawns are paused automatically until it clears, already-running crew are left alone, and any outage-tagged deaths are auto-resumed the moment the outage-cleared signal fires - no confirmation needed |
| "Take over X" | `bin/crew-takeover <id>` prints the exact takeover command |
| `/standdown <id>` | wraps up a crew member, closes its window |
| `/prune` | clean the roster: drop fully-closed records (archived first) |

**One session sees its work through.**
A crew member is not spun down the moment its deliverable appears:

- When a developer crew opens a PR, it parks in a `review` state and keeps running: it watches CI and fixes it if it breaks, watches for review feedback and addresses it (dropping back to `working` while it does), and replies on the threads.
- It reports `done` only when the PR is merged or closed.
  `done` is the member's own "stand me down" signal, so wingman reaps it right then - finished members don't linger.
- Feedback you give wingman is routed back to that same session (not a fresh one), so it keeps the full context.
- It stops early only if you `/standdown` it.

The same lifecycle applies to software-analyst and other crew types; how each state is entered lives in one shared status contract (`playbooks/_status-contract.md`), so a playbook only describes the work.

**Take the wheel any time.**

- "Let me takeover X" prints the exact command to attach to a crew member's tmux window - select, type, take over.
  Detach (`Ctrl-b d`) to hand back.
- Killing wingman leaves the crew running; relaunching it rebuilds the roster.
- Every crew member is also reachable straight from `claude.ai/code` or the Claude mobile app, with connection drops recovered automatically in both directions - see [Remote Control](#remote-control) below.

## Remote Control

Claude Code's Remote Control lets you reach a running session from `claude.ai/code` or the Claude mobile app, not only by attaching to its tmux window.
Wingman wires this up in both directions.

- **Every crew member is reachable by default.** `bin/spawn-crew` launches each one with `--remote-control "wm-<id>"` (the `wm-` prefix matches its tmux window name, so it reads the same in both places) - gated by `WM_REMOTE_CONTROL`, on unless you set it empty.
  This fails soft: on an account that can't use Remote Control, the session just starts normally with it quietly unavailable, so it's safe to leave on unconditionally.
- **A crew member's own dropped connection self-heals.** `bin/watch-fleet` recognizes the disconnect banner in that member's pane and automatically retypes `/remote-control` to restore it - no action needed on your end unless the automatic retry itself keeps failing.
- **Wingman's own connection is watched differently, on purpose.** `bin/wingman` registers this session's own pane at startup for read-only detection only; the watcher can see wingman's own disconnect banner but deliberately never types into wingman's own pane - doing so from outside would race the very tool call that's supposed to send the reconnect command.
  Instead, the watcher wakes wingman with an explicit event, and wingman tells you directly to run `/remote-control` yourself to restore it.
- There's no reliable way to detect programmatically whether you're watching a given session locally or over Remote Control at any moment (see [`docs/analysis/2026-07-13-remote-control-transport-detectability.md`](docs/analysis/2026-07-13-remote-control-transport-detectability.md)) - that's why wingman asks once, up front, rather than guessing.

## Autonomous by default

Crew launch with `--permission-mode bypassPermissions` so gated tool calls auto-approve instead of hanging forever with no human at the terminal.

Two one-time interactive gates remain: Claude Code's Bypass-Permissions acceptance, and each repo's first-time workspace-trust dialog.
Wingman detects a crew frozen on either and wakes you to approve once via `bin/crew-takeover`.
After that, crew in that repo run unattended.

A resumed session (`bin/crew-resume`, or `claude --resume` by hand) can also hit the CLI's own "resume from summary?" prompt on a large or old transcript.
`bin/crew-resume` defeats it outright on every relaunch; if it appears anyway, wingman recognizes it and wakes you with a specific one-keypress fix via `bin/crew-takeover`.

## Customizing crew behavior (playbooks)

A crew type is just a playbook - plain prose in `playbooks/`, grouped by category (`playbooks/<category>/<role>.md`).
The `software-development` category's built-ins read as an org:

| Role | Purpose |
|---|---|
| `software-analyst` | requirements / plan or report |
| `architect` | detailed technical design from an approved spec |
| `developer` | worktree → implement → commit → push → PR |
| `reviewer` | review a plan or PR and report findings |

`lead` (manage an effort end-to-end with its own crew) and `research` (an example non-dev type) live in the domain-neutral `common` category, since they apply to any discipline.
Several other categories ship too (`ai-research`, `data-science`, `scientific-research`, `business-development`, `business-operations`, `infrastructure`) - `bin/spawn-crew --list-types` shows every category's roles.

- **Customize a type:** drop a `playbooks/<category>/<type>.local.md` beside the default; if present it wins.
- **Add a type:** create `playbooks/<category>/<type>.md` (tracked) or `.local.md` (yours only), inside the category it belongs to (or a new category directory, for a genuinely new discipline), then spawn it with `--type <name>`.
  There's no hardcoded list - a type exists iff its playbook does.
  A bare name (e.g. `developer`) resolves across every category as long as it's unique; a category-qualified name (`software-development/developer`) breaks a collision.
  `bin/spawn-crew --list-types` shows what's available.

`*.local.md` is gitignored, so your customizations can't be accidentally committed and survive `git pull` of new defaults.
If you have an existing `playbook/<type>.local.md` from before this reorganization, move it yourself to `playbooks/<category>/<type>.local.md` (the category the role now lives under) after pulling this change.

## Run an effort as an org (leads)

Your crew is a **tree** with you at the top.
Small directives take the lean direct paths (a software-analyst for a plan, a developer with a plan in hand).
A large, end-to-end effort - multi-phase, multi-repo, or requirements-through-ship - gets a **lead**: say *"take the lead on X"* (or let wingman suggest one) and it hires and runs its own crew, one layer down.

- The lead **decomposes** the effort, **sequences** the phases (software-analyst → architect → developer(s) → reviewer), **iterates** each deliverable with its owner, **integrates** the results, and rolls a **single status line** up to you.
- **Each layer sees only its direct reports.** A worker's blocker surfaces to its lead, not to you; only a decision the lead can't make escalates up the chain, and your answer flows back down. You see effort-level progress ("planning → building (2/3 PRs open)"), not worker chatter.
- **Peers collaborate directly.** Two developers negotiating an interface, or a developer and a reviewer, talk to each other without going through the lead.
- **Drill down any time:** `/status --tree` for the whole org, `/status --owner <lead-id>` for one lead's team; `~/.wingman/board.md` renders the tree.

The tree is domain-neutral - only the playbooks carry domain, so the same machinery runs a science lab (PI → experimental design → analysis → peer review) or a business team by swapping playbooks.
Management depth is capped at two crew layers (a lead does not spawn leads).

## Tests

`bash tests/run.sh` runs the bash E2E suites (no real `claude`/tmux fleet needed).
Requires `bash`, `git`, `tmux`, and `uv`.

GitHub Actions runs the same suite on every push and pull request to `main` (see [`.github/workflows/ci.yml`](.github/workflows/ci.yml)), wrapped in a bounded timeout so a stuck watcher can never hang the job.

## Under the hood

The crew coordination layer, the wake loop, machine-local state in `~/.wingman/`, and the harness-agnostic design are documented in [`docs/architecture.md`](docs/architecture.md).
