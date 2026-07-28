# Configuration and invocation

How wingman is configured, how it is launched, how crew are spawned, and the machine-local state that results.
Part of the [architecture reference](architecture.md); for day-to-day use see the [README](../README.md).

## The settings file - `config.local.toml`

`config.local.toml` at the repo root is where a pilot persists settings across runs.
It is gitignored, so a `git pull` updates the shipped defaults without touching it; [`config.example.toml`](../config.example.toml) is the documented template (`cp config.example.toml config.local.toml`).
Everything in it is optional - with no file at all, wingman behaves exactly as it does with no configuration: it asks the onboarding-preference questions once per run, and every spawn falls through to the agent CLI's own model.

`bin/lib/wm_config.py` is its single reader. Two consumers use it: `bin/lib/common.sh` exports the environment-backed settings so every `bin/` script picks them up, and `bin/lib/wm-state.py` layers the `[prefs]` table underneath its own per-run answer store.

### Precedence

Most specific wins:

| | |
|---|---|
| an explicit flag | `--model`, `--effort`, … on one spawn |
| a per-crew-type entry | `[models].developer` - more specific than any global default |
| the `$WM_*` environment | an explicitly-set variable always outranks the file |
| the settings file's own default | `[models].default`, which is exported *as* `$WM_MODEL` |
| wingman's built-in default | or the agent CLI's own |

The one place this is not a straight top-to-bottom list is a per-type entry versus `$WM_MODEL`: the entry wins, because `[models].default` is exactly what `$WM_MODEL` carries by the time a spawn reads it, so specificity - not layer - has to decide for a per-type entry to mean anything.

`bin/config` prints every setting as actually resolved, with the source each value came from (`env` / `config.local.toml` / `run` / `default`), which is the answer to "why is this spawn using that model?".
`bin/config --check` validates the file, and `bin/doctor` runs the same check: an unknown key would otherwise fail silently, since a setting wingman does not recognize simply never applies.

### What it holds

- **`[prefs]`** - the onboarding preferences (see below). A key answered here is never asked again.
- **`[models]` / `[effort]`** - `default` for every spawn, plus a per-crew-type entry under the bare role name (`developer`) or the category-qualified one (`software-development/developer`).
- **`[projects]`** - `roots`, `ignore`, and a `[projects.pins]` name→path table for `bin/discover-projects`. `~` and `$VAR` are expanded.
- **`[harness]`** - `agent`, `permission_mode`, `remote_control`, `tmux_session`: the agent-CLI-specific knobs, previously environment-only.
- **`[env]`** - a raw `WM_*` passthrough for everything above does not model (see below).

### `[env]`: the rest of the knobs

Wingman has around a hundred `WM_*` variables beyond the typed settings - internal timings, thresholds, the pane-detector regexes - each documented at its point of use rather than in a central list. They exist for the rare case of tuning wingman's own internals, which is not worth a schema entry each, so `[env]` carries them verbatim:

```toml
[env]
WM_WATCH_INTERVAL = "5"
WM_STALL_IDLE = "180"
```

Two rules, both enforced by `bin/config --check`:

- **`WM_`-prefixed names only.** This is wingman's configuration, not a general environment injector; a config file that can set `PATH` or `LD_PRELOAD` is a footgun rather than a feature.
- **No name a typed setting already owns.** `[env].WM_MODEL` and `[models].default` write the same variable, so setting both would leave the reader unable to say which is in force. The error names the setting to use instead.

To find a knob, grep the source for `${WM_`.

## The wingman launcher

`bin/wingman` is a thin wrapper around the real `claude` binary: it wires up a few things, then execs `claude` so the rest of the session is an ordinary Claude Code session.

- It mints and exports a fresh `WINGMAN_RUN_ID`, inherited by every crew member spawned during that run.
  This is the cache key the onboarding-preference questions (remote vs. local, whether markdown deliverables also get published as Artifact links, verbosity, direct-spawn visibility, whether crew may write to GitHub PRs) are asked and cached against exactly once per run rather than once per crew member.
  Every consumer of a missing run id treats it as "unanswered, apply the conservative default" rather than asking - skipping the launcher does not error, it just means the whole session runs on defaults with nothing cached.
  A preference answered in the settings file's `[prefs]` table is never asked at all, on any run; an answer given during a run (`/prefs`) is cached against that run id and outranks the file for the rest of it.
- It resolves every discovered sibling project root (`bin/discover-projects`) and passes `--add-dir` for each, so a global-scope spawn, or wingman's own occasional cross-project read, never blocks on a first-time directory-permission prompt.
- It registers this session's own tmux pane path at `$WM_HOME/self-pane` (only when running inside tmux) - the read-only signal `bin/watch-fleet`'s `self_pane_check` uses to detect wingman's own dropped Remote Control connection (see [Remote Control](architecture.md#remote-control)).
- It refreshes `~/.wingman/` state and the project-discovery cache unconditionally on every launch, so the roster and project list are never stale from a previous run.

None of this is required - the underlying scripts work without the launcher - but skipping it means hand-approving `--add-dir` prompts, no onboarding-preference caching for the run, and no disconnect detection for wingman's own session.

## Spawning crew (the recipe)

Every crew member is an independent, interactive `claude` session in its own tmux window, launched in the target project:

```
bin/spawn-crew --type <name> (--repo <name-or-path> | --scope global) \
  --objective "<one-line task>" [--input <plan-path>] \
  [--model <alias|id>] [--effort <low|medium|high|xhigh|max>] [--allow-merge]
```

The script resolves the project, resolves the playbook (`<type>.local.md` if present, else `<type>.md`), forces a known session id, opens the tmux window, records the member in `~/.wingman/crew.json`, and delivers the objective as the session's first message.
It prints the crew `id`.

Pass `--scope global` (instead of `--repo`) to ground a crew member at the global project scope: it launches at the workspace root with every discovered repo added, so it can read and work across all of them and choose the target repo(s) itself.
Use it for cross-repo work or when the repo is genuinely unclear.

**Merge authorization.** `--allow-merge` is per-spawn and never a default: a crew member cannot merge its own PR unless the human explicitly granted it for that one effort (see [guards.md](guards.md)'s `hooks/no-merge-guard.sh`). It is visible in `bin/crew-list`/`board.md` as `allow_merge`. To grant it to a member that is already running, use `$WINGMAN_STATE crew-set --id <id> --allow-merge true` rather than respawning; it takes effect on the next merge attempt.

**Model and effort selection.** Most specific wins: an explicit `--model`/`--effort` on the spawn, then the settings file's `[models]`/`[effort]` entry for *that crew type*, then `$WM_MODEL`/`$WM_EFFORT` (where the file's own `default` lands), then the agent CLI's own default. See [the settings file](#the-settings-file---configlocaltoml) for the full chain. `--model`/`--effort` are per-spawn - they affect only that one session, never wingman's own model or any other member's.

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
- `orphan-candidates.json` - `{window_name: first_seen_iso_stamp}` for a live `wm-*` tmux window with no matching `crew.json` record, tracked by `wm_state reconcile`'s grace-period-gated orphan-window adoption (owner `""` only) - see [Survival & reconciliation](architecture.md#survival--reconciliation).

All *user-editable* customization lives in the repo as gitignored `*.local.md` / `config.local.*` (see [the settings file](#the-settings-file---configlocaltoml)), not here.
`~/.wingman/` is pure runtime state you never hand-edit.
