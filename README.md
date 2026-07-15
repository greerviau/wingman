![Wingman Logo](assets/wingman-logo.png)

[![CI](https://github.com/greerviau/wingman/actions/workflows/ci.yml/badge.svg)](https://github.com/greerviau/wingman/actions/workflows/ci.yml)

Wingman is a long-lived Claude Code session that runs a **crew** of agents for you.
You (the pilot) give it high-level directives - *"implement this feature"*, *"investigate this issue"*, *"what's my crew doing?"* - and it delegates the real work to a crew, tracks their status, raises only real decisions to you, and keeps its own context clean.
It orchestrates; it does not do the heavy lifting.

Each crew member is an **independent `claude` session in its own tmux window**, launched in your target project - so you can watch it, type into it, or take it over live, and it survives even if wingman itself is killed.

## Quick start

```
git clone https://github.com/greerviau/wingman.git
cd wingman
claude          # or: bin/wingman   (adds your project roots via --add-dir)
```

On first launch wingman runs `bin/doctor` (installs any missing dependencies with your consent), discovers your sibling repos with zero config, and starts the supervisor.
Then give it a directive.

The only things you must have before the first run are **`claude`** and **`git`**; `doctor` handles the rest.

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
| (a batch of crew died together, or hit a correlated API outage) | wingman relays the one collapsed event plus the fix - `bin/crew-resume --all-died` for a mass death, or nothing (an auto-nudge already tried) for an outage |
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
- Every crew member is also reachable straight from `claude.ai/code` or the Claude mobile app - each launches Remote-Control-visible by default (`WM_REMOTE_CONTROL=1`, on unless set empty) - so `tmux attach` is one option, not the only one.
- If a member's connection drops, wingman's watcher notices the disconnect banner and retypes `/remote-control` for it automatically; no action needed.

## Autonomous by default

Crew launch with `--permission-mode bypassPermissions` so gated tool calls auto-approve instead of hanging forever with no human at the terminal.

Two one-time interactive gates remain: Claude Code's Bypass-Permissions acceptance, and each repo's first-time workspace-trust dialog.
Wingman detects a crew frozen on either and wakes you to approve once via `bin/crew-takeover`.
After that, crew in that repo run unattended.

A resumed session (`bin/crew-resume`, or `claude --resume` by hand) can also hit the CLI's own "resume from summary?" prompt on a large or old transcript.
There is nothing to approve there, so wingman defeats it outright on every relaunch and, as a backstop, auto-dismisses it if it still appears.

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
