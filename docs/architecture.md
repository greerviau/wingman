# Wingman architecture

In-depth reference for how wingman works internally. For day-to-day use, see the
[README](../README.md).

## Harness-agnostic by design

The **crew** coordination layer - tmux windows, the JSON status files, the watcher
loop, and the board - does not depend on any one agent harness. A crew member is
just an agent CLI running in a tmux window that keeps its status file current.

The default launch recipe uses the `claude` CLI and its flags, and that is the
single place to change for a different harness: it is isolated in `bin/spawn-crew`
and overridable via `WM_AGENT`. Wingman deliberately avoids a harness's native
background-agent/attach/resume features to run or take over *crew*, because that
would wed the crew layer to one harness. tmux attach is the takeover path precisely
because it is neutral - it reaches whatever agent CLI is in the window.

The one thing that is legitimately harness-specific is **how the watcher wakes
wingman** (see below) - a private loop between wingman and its own supervisor, not
part of the crew layer. Swapping harnesses means swapping that one arming primitive,
exactly as it means swapping the `WM_AGENT` launch line; both are isolated, neither
leaks into the crew coordination layer.

## The wake loop

A file on disk cannot rouse an idle session, so the only reliable way wingman is
woken when crew need it is the **completion of a task the harness tracks**. The
watcher, `bin/watch-fleet`, is built for exactly this:

- It **blocks** - watching status files and window liveness, silently absorbing
  benign "still working" updates - and **exits with one reason line** the instant a
  crew member flips to `blocked`/`done`/`died` or freezes on a prompt. One run is
  one *cycle*.
- It is armed as a **harness-tracked background task** (e.g. Bash `run_in_background`),
  on its own, never bundled onto the tail of another command. Because the harness
  tracks it, its exit re-invokes wingman - that exit **is** the wake. It is never
  run detached (`nohup`/`&`); a detached process cannot wake an idle session.
- On each wake, wingman reads the reason line and `~/.wingman/wake`, surfaces the
  event to the pilot, then **arms exactly one fresh cycle**. The chain persists only
  if it re-arms after every fire.
- The arm's status line is truth: `armed` (a fresh cycle is now blocking),
  `healthy` (a live cycle already exists - do not start another), or a
  `blocked:/done:/died:` reason (it fired). The watcher checks for pending events
  the moment it arms, so a crew member that finishes in the gap between one fire and
  the next arm is surfaced by that arm, not lost.

The watcher also detects a crew frozen on a permission or trust prompt - a
terminal-UI stall the status files can't see - and flips it to `blocked`.

## Autonomous mode and interactive gates

Because no human sits at a crew member's terminal, `bin/spawn-crew` launches each
member with `--permission-mode bypassPermissions` (`WM_PERMISSION_MODE`) so a gated
tool call auto-approves instead of hanging on a prompt forever. Set
`WM_PERMISSION_MODE=` (empty) to fall back to interactive prompting.

Two one-time interactive gates remain that no flag bypasses:

- Claude Code's Bypass-Permissions acceptance (once, ever).
- Each repo's first-time workspace-trust dialog (once per repo).

The watcher catches both (and a per-tool prompt when bypass is off), flips the crew
member to `blocked`, and wakes the pilot to approve once via `bin/crew-takeover`.
After that, crew in that repo run fully unattended.

## Playbooks and local overrides

A crew type is defined entirely by a playbook - plain prose in `playbook/`:

- `playbook/spec.md` - turn a problem into a plan (or a report).
- `playbook/build.md` - the dev cycle: worktree → implement → commit → push → PR.
- `playbook/lead.md` - decompose a large effort and spawn/integrate its own crew.
- `playbook/research.md` - example non-dev type: gather evidence, write a cited
  report. Shows the shape a `researcher`/`scientist`/`analyst` role takes.

There is no hardcoded list of types; a type exists iff its playbook does.
`bin/spawn-crew --list-types` enumerates them.

`playbook/<type>.local.md` overrides the tracked `<type>.md` when present. `*.local.md`
is gitignored, following the same pattern as Claude Code's `settings.json` /
`settings.local.json`: customizations and private crew types can't be accidentally
committed and survive `git pull` of new defaults. Example: to make the spec crew
follow your own planning skill or checklist, write `playbook/spec.local.md` saying so.

Project-discovery hints follow the same story: an optional gitignored
`config.local.sh` in this repo can set extra roots, pinned paths, or an ignore list
(`WM_ROOTS`, `WM_PINS` as newline `name|path` entries, `WM_IGNORE`). It is absent by
default; the defaults cover the common case.

## Spawning crew (the recipe)

Every crew member is an independent, interactive `claude` session in its own tmux
window, launched in the target repo:

```
bin/spawn-crew --type <name> (--repo <name-or-path> | --scope global) \
  --objective "<one-line task>" [--input <plan-path>] \
  [--model <alias|id>] [--effort <low|medium|high|xhigh|max>]
```

The script resolves the repo, resolves the playbook (`<type>.local.md` if present,
else `<type>.md`), forces a known session id, opens the tmux window, records the
member in `~/.wingman/crew.json`, and delivers the objective as the session's first
message. It prints the crew `id`.

Pass `--scope global` (instead of `--repo`) to ground a crew member at the global
project scope: it launches at the workspace root with every discovered repo added,
so it can read and work across all of them and choose the target repo(s) itself.
Use it for cross-repo work or when the repo is genuinely unclear.

## State home - `~/.wingman/`

Machine-local runtime state, created on first run, never committed:

- `crew.json` - the live roster (id, type, session id, tmux window, repo, status).
- `crew/<id>.json` - each crew member's distilled status record.
- `board.md` - the human-readable render of the roster.
- `watch.pid` / `watch.beat` - the live watcher cycle's pid and liveness beacon.
- `wake` - the current attention list the watcher writes when it fires.
- `acked.json` - the last `updated` stamp surfaced per crew id, so a terminal event
  (done/died/blocked) is delivered once instead of on every watcher arm and
  Stop-hook check. A new `updated` (a genuine state change) re-surfaces.
- `projects.json` - the discovered-projects cache.

All *user-editable* customization lives in the repo as gitignored `*.local.md` /
`config.local.*`, not here. `~/.wingman/` is pure runtime state you never hand-edit.

## Survival & reconciliation

The tmux **server** owns the crew windows, so killing wingman does not kill the
crew. On any startup wingman reads `~/.wingman/crew.json`, reconciles against the
live windows (`bin/crew-list` does this automatically), re-arms the watcher if crew
are in flight, and reports the current roster. A crew member whose window died shows
as `died` and is recoverable by resuming its agent CLI in its repo
(`bin/crew-takeover <id>` prints the exact command).

## Tests

`bash tests/run.sh` runs the bash E2E suites. No real `claude`/tmux fleet is needed;
each test uses an isolated throwaway state home and tmux session name. They cover:

- the wake loop (`watch-fleet` blocks, fires on an actionable event, singleton guard),
- terminal-event de-duplication (an event surfaces once, re-surfaces only on a state
  change),
- repo-vs-global spawn scope.

Requires `bash`, `git`, `tmux`, and `uv`.
