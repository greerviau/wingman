# Configuration and invocation

How wingman is launched, how crew are spawned, and the machine-local state that results.
Part of the [architecture reference](architecture.md); for day-to-day use see the [README](../README.md).

## The wingman launcher

`bin/wingman` is a thin wrapper around the real `claude` binary: it wires up a few things, then execs `claude` so the rest of the session is an ordinary Claude Code session.

- It mints and exports a fresh `WINGMAN_RUN_ID`, inherited by every crew member spawned during that run.
  This is the cache key the onboarding-preference questions (remote vs. local, whether markdown deliverables also get published as Artifact links, verbosity, direct-spawn visibility) are asked and cached against exactly once per run rather than once per crew member.
  Every consumer of a missing run id treats it as "unanswered, apply the conservative default" rather than asking - skipping the launcher does not error, it just means the whole session runs on defaults with nothing cached.
- It resolves every discovered sibling project root (`bin/discover-projects`) and passes `--add-dir` for each, so a global-scope spawn, or wingman's own occasional cross-project read, never blocks on a first-time directory-permission prompt.
- It registers this session's own tmux pane path at `$WM_HOME/self-pane` (only when running inside tmux) - the read-only signal `bin/watch-fleet`'s `self_pane_check` uses to detect wingman's own dropped Remote Control connection (see [Remote Control](architecture.md#remote-control)).
- It refreshes `~/.wingman/` state and the project-discovery cache unconditionally on every launch, so the roster and project list are never stale from a previous run.

None of this is required - the underlying scripts work without the launcher - but skipping it means hand-approving `--add-dir` prompts, no onboarding-preference caching for the run, and no disconnect detection for wingman's own session.

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

**Model selection.** An explicit `--model` on a spawn always wins; otherwise `$WM_MODEL` (settable in `config.local.sh`, see [`config.example.sh`](../config.example.sh)) is the default for every spawn; with neither set, the agent CLI's own default applies. `--model`/`--effort` are per-spawn - they affect only that one session, never wingman's own model or any other member's.

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

All *user-editable* customization lives in the repo as gitignored `*.local.md` / `config.local.*`, not here.
`~/.wingman/` is pure runtime state you never hand-edit.
