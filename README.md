# wingman

**You're the pilot. Wingman runs the crew.**

Wingman is a long-lived Claude Code session that runs a **crew** of agents for you.
You (the pilot) give it high-level directives - *"implement this feature"*,
*"investigate this issue"*, *"what's my crew doing?"* - and it delegates the real
work to a crew, tracks their status, raises only real decisions to you, and keeps
its own context clean. It orchestrates; it does not do the heavy lifting.

Each crew member is an **independent `claude` session in its own tmux window**,
launched in your target repo - so you can watch it, type into it, or take it over
live, and it survives even if wingman itself is killed.

## Quick start

```
git clone https://github.com/greerviau/wingman.git
cd wingman
claude          # or: bin/wingman   (adds your project roots via --add-dir)
```

On first launch wingman runs `bin/doctor` (installs any missing dependencies with
your consent), discovers your sibling repos with zero config, and starts the
supervisor. Then give it a directive.

The only things you must have before the first run are **`claude`** and **`git`**.
`doctor` handles `tmux`, `uv`, `uuidgen`, and (only if your build playbook uses
it) `gh`. `uv` runs the state engine and manages the Python interpreter, so no
system `python3` is required.

## Driving wingman

Talk to it in plain language, or use the slash commands:

| You say | Wingman does |
|---|---|
| "Implement feature X in `<repo>`" | spawns a **spec** crew → plan → (your review) → **build** crew → PR |
| "Investigate issue Y in `<repo>`" | spawns a **spec** crew in report mode (reproduces bugs end-to-end first) |
| `/spawn <type> <repo> <objective>` | launch a crew member of any type - `spec`, `build`, `research`, or one you added |
| `/status` | compact roster: who's on what, what's blocked, what's ready |
| `/blocked` | each blocked member + the decision it needs |
| "Take over X" | `bin/crew-takeover <id>` prints the exact takeover command |
| `/standdown <id>` | wraps up a crew member, closes its window |

Take the wheel of any crew member any time - `bin/crew-takeover <id>` prints the
exact command (`tmux attach` into its window; select, type, take over). Detach
(`Ctrl-b d`) to hand back. Killing wingman leaves the crew running; relaunching it
rebuilds the roster.

**Harness-agnostic.** The coordination layer - tmux windows, JSON status files,
the watcher, the board - doesn't depend on any one agent harness; a crew member is
just an agent CLI in a tmux window keeping its status file current. The default
launch recipe uses `claude` (overridable via `WM_AGENT`, isolated in
`bin/spawn-crew`). Wingman deliberately avoids a harness's native
background-agent/attach/resume features for orchestration, so tmux attach - which
is neutral - is the takeover path.

## How behavior is configured (playbooks)

A crew type is just a playbook - plain prose in `crew/`. The built-ins:

- `crew/spec.md` - turn a problem into a plan (or a report).
- `crew/build.md` - the dev cycle: worktree → implement → commit → push → PR.
- `crew/lead.md` - decompose a large effort and spawn/integrate its own crew.
- `crew/research.md` - example non-dev type: gather evidence, write a cited
  report. Shows the shape a `researcher`/`scientist`/`analyst` role takes.

**To customize a type, drop a `crew/<type>.local.md` beside the default.** If
present it wins.

**To add a new type, create `crew/<type>.md`** (tracked) **or
`crew/<type>.local.md`** (yours only) - then spawn it with
`--type <name>`. There is no hardcoded list; a type exists iff its playbook does.
`bin/spawn-crew --list-types` shows what's available. So a `scientist`,
`reviewer`, or `data-analyst` crew is one file away.

`*.local.md` is gitignored, so your customizations and private crew types can't be
accidentally committed and survive `git pull` of new defaults - the same pattern as
Claude Code's `settings.json` / `settings.local.json`. Example: to make the spec
crew follow your own planning skill or checklist, write `crew/spec.local.md` that
says so.

Project-discovery hints are the same story: an optional gitignored
`config.local.sh` in this repo can set extra roots, pinned paths, or an ignore list
(`WM_ROOTS`, `WM_PINS` as newline `name|path` entries, `WM_IGNORE`). Absent by
default; the defaults cover the common case.

## Autonomous by default

No human sits at a crew member's terminal, so crew launch with
`--permission-mode bypassPermissions` (`WM_PERMISSION_MODE`): a gated tool call
auto-approves instead of hanging on a prompt forever. Set `WM_PERMISSION_MODE=`
(empty) to fall back to interactive prompting.

Two one-time interactive gates remain that no flag bypasses: Claude Code's
Bypass-Permissions acceptance (once, ever) and each repo's first-time workspace-trust
dialog. The watcher detects a crew frozen on either (or on a per-tool prompt when
bypass is off) and flips it to `blocked`, waking you to approve once with
`bin/crew-takeover`. After that, crew in that repo run unattended.

## State home - `~/.wingman/`

Machine-local runtime state, created on first run, never committed:

- `crew.json` - the live roster (id, type, session id, tmux window, repo, status).
- `crew/<id>.json` - each crew member's distilled status record.
- `board.md` - the human-readable render of the roster.
- `projects.json` - the discovered-projects cache.

All *user-editable* customization lives in this repo as gitignored `*.local.md` /
`config.local.*`, not here. `~/.wingman/` is pure runtime state you never hand-edit.
