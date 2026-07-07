# wingman

**You're the CTO. Wingman runs the crew.**

Wingman is a long-lived Claude Code session that acts as your **Head of Software**.
You (the CTO) give it high-level directives — *"implement this feature"*,
*"investigate this issue"*, *"what's my crew doing?"* — and it delegates the real
work to a crew, tracks their status, raises only real decisions to you, and keeps
its own context clean. It orchestrates; it does not do the heavy lifting.

Each crew member is an **independent `claude` session in its own tmux window**,
launched in your target repo — so you can watch it, type into it, or take it over
live, and it survives even if wingman itself is killed.

## Quick start

```
git clone <this repo> ~/Documents/GitHub/wingman
cd ~/Documents/GitHub/wingman
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
| `/status` | compact roster: who's on what, what's blocked, what's ready |
| `/blocked` | each blocked member + the decision it needs |
| "Take over X" | prints `tmux attach -t wingman \; select-window -t wm-<id>` |
| `/standdown <id>` | wraps up a crew member, closes its window |

Take the wheel of any crew member any time: `tmux attach -t wingman`, select its
window, type. Detach (`Ctrl-b d`) to hand back. Killing wingman leaves the crew
running; relaunching it rebuilds the roster.

## How behavior is configured (playbooks)

Each crew type's behavior is plain prose in `playbooks/`:

- `playbooks/spec.md` — turn a problem into a plan (or a report).
- `playbooks/build.md` — the dev cycle: worktree → implement → commit → push → PR.
- `playbooks/lead.md` — decompose a large effort and spawn/integrate its own crew.

**To customize, drop a `playbooks/<type>.local.md` beside the default.** If present
it wins. `*.local.md` is gitignored, so your customizations can't be accidentally
committed and survive `git pull` of new defaults — the same pattern as Claude
Code's `settings.json` / `settings.local.json`. Example: to make the spec crew use
your own `/spec` skill, write `playbooks/spec.local.md` that says so.

Project-discovery hints are the same story: an optional gitignored
`config.local.sh` in this repo can set extra roots, pinned paths, or an ignore list
(`WM_ROOTS`, `WM_PINS` as newline `name|path` entries, `WM_IGNORE`). Absent by
default; the defaults cover the common case.

## Layout

```
CLAUDE.md              the wingman persona + operating loop (activates wingman here)
playbooks/
  spec.md build.md lead.md    git-tracked default crew behavior
  *.local.md                  your gitignored overrides (win over the defaults)
  _status-contract.md         the status discipline every crew member is given
bin/
  doctor                dependency preflight + consented install
  discover-projects     zero-config repo discovery → projects.json cache
  spawn-crew            the core recipe: tmux window → claude in the target repo
  crew-say              send a follow-up into a crew member's session
  crew-list             the reconciled roster (human or --json)
  crew-standdown        wrap up + close a crew member
  watch-fleet           the zero-token, event-driven supervisor
  wingman               optional launcher (claude + --add-dir <roots>)
  lib/                  common.sh (shared shell helpers) + wm-state.py (state engine)
hooks/stop-guard.sh     Stop hook: no going idle blind while crew are in flight
.claude/
  settings.json         wires the Stop hook (scoped to this repo)
  commands/             /status /blocked /spec /build /standdown
```

## State home — `~/.wingman/`

Machine-local runtime state, created on first run, never committed:

- `crew.json` — the live roster (id, type, session id, tmux window, repo, status).
- `crew/<id>.json` — each crew member's distilled status record.
- `board.md` — the human-readable render of the roster.
- `projects.json` — the discovered-projects cache.

All *user-editable* customization lives in this repo as gitignored `*.local.md` /
`config.local.*`, not here. `~/.wingman/` is pure runtime state you never hand-edit.

## Prior art

Wingman draws on [firstmate](https://github.com/kunchenguid/firstmate) — tmux as
the crew backend, a spec → build pipeline, event-driven zero-token supervision,
behavior-as-configuration, and a machine-local state home — but is its own build
using plain `git` worktrees (no extra worktree tooling) and tmux only.
