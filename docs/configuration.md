# Configuration and invocation

How wingman is configured, how it is launched, how crew are spawned, and the machine-local state that results.
Part of the [architecture reference](architecture.md); for day-to-day use see the [README](../README.md).

## The settings file - `config.local.toml`

`config.local.toml` at the repo root is where a pilot persists settings across runs.
It is gitignored, so a `git pull` updates the shipped defaults without touching it; [`config.example.toml`](../config.example.toml) is the documented template (`cp config.example.toml config.local.toml`).
Everything in it is optional - with no file at all, wingman behaves exactly as it does with no configuration: it asks the onboarding-preference questions once per run, and every spawn falls through to the agent CLI's own model.

`bin/lib/wm_config.py` is its single reader. Three consumers use it: `bin/lib/common.sh` exports the environment-backed settings so every `bin/` script picks them up, `bin/lib/wm-state.py` layers the `[prefs]` table underneath its own per-run answer store, and `bin/config` drives it directly to report and validate the resolved settings.

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

`bin/config` prints every setting as actually resolved, with the source each value came from (`env` / `config.local.toml` / `run` / `unanswered` / `default`), which is the answer to "why is this spawn using that model?".
`bin/config --check` validates the file, and `bin/doctor` runs the same check: an unknown key would otherwise fail silently, since a setting wingman does not recognize simply never applies.

### What it holds

- **`[prefs]`** - the onboarding preferences (see below). A key answered here is never asked again.
- **`[models]` / `[effort]`** - `default` for every spawn, plus a per-crew-type entry under the bare role name (`developer`) or the category-qualified one (`software-development/developer`).
- **`[projects]`** - `roots`, `ignore`, and a `[projects.pins]` name→path table for `bin/discover-projects`. `~` and `$VAR` are expanded.
- **`[harness]`** - `agent`, `permission_mode`, `remote_control`, `backend`, and `tmux_session`: agent-CLI and runtime-backend settings. `agent` accepts either a scalar or a per-crew-type `[harness.agent]` table, like `[models]`/`[effort]`. `backend` defaults to `tmux`; `herdr` is experimental and requires the `herdr` CLI plus `jq`.
- **`[env]`** - a raw `WM_*` passthrough for everything above does not model (see below).

### `[env]`: the rest of the knobs

Wingman has around a hundred `WM_*` variables beyond the typed settings - internal timings, thresholds, the pane-detector regexes - each documented at its point of use rather than in a central list. They exist for the rare case of tuning wingman's own internals, which is not worth a schema entry each, so `[env]` carries them verbatim:

```toml
[env]
WM_WATCH_INTERVAL = "5"
WM_STALL_IDLE = "180"
WM_WEDGE_SECS = "1800"
WM_WEDGE_PANE_GAP = "60"
WM_WEDGE_PROC_RE = "watch-fleet|pr-watch"
```

Two rules, both enforced by `bin/config --check`:

- **`WM_`-prefixed names only.** This is wingman's configuration, not a general environment injector; a config file that can set `PATH` or `LD_PRELOAD` is a footgun rather than a feature.
- **No name a typed setting already owns.** `[env].WM_MODEL` and `[models].default` write the same variable, so setting both would leave the reader unable to say which is in force. The error names the setting to use instead.

To find a knob, grep the source for `${WM_`.

## The orchestrator's own self-bootstrap

There is no launcher. Wingman's own top-level session is an ordinary session of whatever agent CLI you started - `claude`, `codex`, `grok`, `opencode`, or `pi`, the same five descriptors a crew member can already run on via `--agent` - run directly, with nothing wrapping it: `git clone`, `cd` into the repo, and start your harness.

Everything a launcher would otherwise have wired up instead bootstraps itself, from inside the session, on its own first action - `bin/lib/orchestrator-bootstrap.sh --agent <name>` is the one shared implementation every harness's own entry point calls (claude's `hooks/session-init.sh`, a `SessionStart` hook, eagerly; claude's `hooks/orchestrator-guard-sync-gate.sh`, a `PreToolUse` hook, as the actual fail-closed gate; the other four's `hooks/lib/guard_dispatch.py`, as a lazy first step before its own guard evaluation, on the session's own first tool call). See [guards.md](guards.md#hooks-that-need-user-level-settings) for the gate and [architecture.md](architecture.md#harness-agnostic-by-design) for the descriptor mechanism.

- **Guard-hook reconcile + self-test.** Installs (if needed) and verifies the resolved harness's own guard transport by executing it against a known-deny and known-allow fixture - self-healing even on a machine where `bin/doctor -y` was never run. Cached per session (keyed by the harness process's own computed identity, `bin/lib/harness-identity.sh`) so this only runs once per session, not on every tool call. A failure denies every subsequent tool call except a retry of the bootstrap itself (`bin/lib/orchestrator-bootstrap.sh` directly, or `bin/doctor -y`) until it is fixed.
- **Self-pane registration.** Registers this session's own tmux pane path at `$WM_HOME/self-pane` (only when running inside tmux, and only on claude, whose descriptor is the only one with a Remote Control flag) - the read-only signal `bin/watch-fleet`'s `self_pane_check` uses to detect wingman's own dropped Remote Control connection (see [Remote Control](architecture.md#remote-control)).
- **tmux-guardian launch.** Launches `bin/lib/tmux-guardian.sh`, scope-wrapped independently of the tmux server it watches, so the shared server's whole cgroup dying (issue #218) does not also take out the one thing watching for it (see [Survival & reconciliation](architecture.md#survival--reconciliation)).
- **A checkout-freshness advisory and the fleet-continuity notice.** Both one-time, non-blocking notices - the former if this checkout is behind `origin/main`; the latter (§ below) if the resolved harness has no wired wake-loop mechanism.

**The run-id mechanism no longer needs a launcher to mint anything.** The effective run identity any consumer scopes its own state to (onboarding-preference answers, the fleet's foreign-cycle-takeover protection, the artifact-publish contract) is `$WINGMAN_RUN_ID` when genuinely set, else computed on demand from the harness CLI's own root-process identity (`bin/lib/harness-identity.sh`'s `wm_harness_process_identity`) - fresh per genuine restart, stable across `/clear`/`/compact`, and identical whether a hook resolves it or the model issues a plain Bash command. Nothing needs to export it, and nothing needs to mint it at launch.

**`$WINGMAN_BIN`/`$WINGMAN_REPO`/`$WINGMAN_STATE` are resolved the same way, not exported by anything.** Run `git rev-parse --show-toplevel` if you don't already know the repo root; `$WINGMAN_BIN` is `<root>/bin`; `$WINGMAN_STATE` is `uv run --no-project --quiet $WINGMAN_BIN/lib/wm-state.py`, never separately tracked. On claude, `hooks/session-init.sh` hands you these three values as literal, already-resolved text via `additionalContext` at the start of every session, so you do not even need to run the `git rev-parse` yourself there.

**Fleet continuity (the wake loop) remains claude-exclusive** - not by design choice, but because `WM_AGENT_CONTINUITY_TRANSPORT` is empty for the other four descriptors (no wired mechanism exists yet to re-invoke their own session after a blocking wait). This is never a reason to refuse anything: guard enforcement, preferences enforcement, crew spawning, and status commands all work identically on any of the five. The bootstrap surfaces the gap as a one-time, honest notice instead - via `additionalContext` on claude (where it never fires, since claude has the transport); via a self-clearing PreToolUse denial worded as an informational pass-through on the other four, since none of their own guard-hook contracts has a channel for a non-blocking message on allow (reissuing the identical command immediately after proceeds normally).

**`--add-dir` pre-population is not ported.** `bin/wingman` used to pass `--add-dir <root>` for every discovered sibling project so a global-scope spawn or an occasional cross-project read never hit a first-time directory-permission prompt. No hook can add a flag to a session that is already running, and there is no mechanism to substitute for it - a directory-permission prompt for a sibling project is an accepted, occasional cost of running with no launcher.

## Spawning crew (the recipe)

Every crew member is an independent, interactive agent-CLI session (`claude` by default; `--agent codex|grok|opencode|pi` selects another of the five shipped descriptors) at a backend-owned terminal endpoint, launched in the target project:

```
bin/spawn-crew --type <name> (--repo <name-or-path> | --scope global) \
  --objective "<one-line task>" [--id <slug>] [--input <plan-path>] \
  [--model <alias|id>] [--effort <low|medium|high|xhigh|max>] [--agent <name>] \
  [--backend <tmux|herdr>] [--allow-merge] [--waive-review-gate] \
  [--force-during-outage] [--force-during-usage-limit] \
  [--constraint "<text>" ...]
```

The script resolves the project, resolves the playbook (`<type>.local.md` if present, else `<type>.md`), forces a known session id, opens the selected backend endpoint, records the member in `~/.wingman/crew.json`, and delivers the objective as the session's first message. Explicit `--backend` wins over `WM_BACKEND`, `[harness].backend`, runtime detection, and the default `tmux`; a recorded member always keeps its original backend.
It prints the crew `id`.

Backend selection uses this order: `--backend`, `WM_BACKEND`, `[harness].backend`, `$TMUX`, `HERDR_ENV=1`, then `tmux`.
A configured or explicit backend never falls back to another backend after setup fails.
Herdr uses `HERDR_SESSION` (default `default`) and requires the Herdr CLI, `jq`, and protocol 14 or newer.

Pass `--scope global` (instead of `--repo`) to ground a crew member at the global project scope: it launches at the workspace root with every discovered repo added, so it can read and work across all of them and choose the target repo(s) itself.
Use it for cross-repo work or when the repo is genuinely unclear.

**Wingman's own root `CLAUDE.md` is mechanically excluded from every `claude`-descriptor crew session's context.** For an `--agent claude` launch (the default), the generated launch carries `--settings` with a `claudeMdExcludes` entry naming wingman's own repo root (and its `<repo>-*` worktree-sibling glob), regardless of `--scope` or target - so the orchestrator persona never auto-loads for a crew member, even one working on wingman's own files. The same payload is re-emitted by `bin/crew-takeover`'s printed resume command and `bin/crew-resume`'s relaunch script, so it survives past a member's first process (see `docs/guards.md`). `--settings` is a claude-specific mechanism with no equivalent in the adapter contract, so another descriptor suppresses repo docs through its own `WM_AGENT_CONTEXT_SUPPRESS_FLAG` instead - populated for `codex` and `pi`; `opencode` and `grok` deliberately stay on the composed-brief disclaimer, with no narrow flag available in either CLI.

**Merge authorization.** `--allow-merge` is per-spawn and never a default: a crew member cannot merge its own PR unless the human explicitly granted it for that one effort (see [guards.md](guards.md)'s `hooks/no-merge-guard.sh`). It is visible in `bin/crew-list`/`board.md` as `allow_merge`. To grant it to a member that is already running, use `$WINGMAN_STATE crew-set --id <id> --allow-merge true` rather than respawning; it takes effect on the next merge attempt.

**Pilot-stated constraints.** `--constraint "<text>"` is per-spawn and repeatable: a verbatim record of something the pilot said about *how* this effort must be carried out.
It is visible in `bin/crew-list`/`board.md` as `constraints`, and `bin/crew-say` refuses a later follow-up to that member unless `--ack-constraints` is also passed (see [guards.md](guards.md)).
To add one to a member that is already running, use `$WINGMAN_STATE crew-set --id <id> --add-constraint "<text>"`; to record that the pilot lifted one, `--clear-constraints --confirm-clear` (the confirmation is mandatory whenever the record is non-empty - a bare `--clear-constraints` is refused and reprints what it would erase, so the record this whole mechanism depends on can never be silently emptied).

**Model and effort selection.** Most specific wins: an explicit `--model`/`--effort` on the spawn, then the settings file's `[models]`/`[effort]` entry for *that crew type*, then `$WM_MODEL`/`$WM_EFFORT` (where the file's own `default` lands), then the agent CLI's own default. See [the settings file](#the-settings-file---configlocaltoml) for the full chain. `--model`/`--effort` are per-spawn - they affect only that one session, never wingman's own model or any other member's.

The git/branch/PR workflow (worktrees, branches, opening a PR, the no-merge guard) is conditional on git-ness, not universal: it applies whenever the crew type is a `software-development` role (`bin/spawn-crew` refuses to spawn one against a target that isn't a confirmed git repo), or whenever the target project happens to be a confirmed git repo regardless of category.
`bin/spawn-crew` detects this mechanically at spawn time - for `--repo` targets, `git -C "$REPO" rev-parse --show-toplevel` compared (physically, symlink-resolved) against `$REPO` itself, so a directory merely nested inside a repo reads as non-git - and exports the result as two roster-scoped env vars: `WINGMAN_IS_GIT=true|false` and, only when a repo, `WINGMAN_HAS_REMOTE=true|false` (whether `origin` is configured, i.e. whether there's anywhere to open a PR against).
Both are a real tri-state: absent (never exported for `--scope global`, and not carried forward by `bin/crew-resume` for a pre-change roster record) means "not yet known - detect it yourself" for whatever directory the member decides to work in, and must never be conflated with `false`.
A non-software-development member (e.g. `data-engineer`, `ml-engineer`, `experimentalist`) branches on these two variables to choose between the full worktree/branch/PR flow, a git-but-no-remote local-commits-only flow, or a plain-files-no-git flow; `developer` has no non-git fallback by design and blocks if it ever finds itself in one.

## State home - `~/.wingman/`

Machine-local runtime state, created on first run, never committed:

- `crew.json` - the live roster (id, type, session id, backend-owned endpoint and physical identity, repo, status, `parent`, `is_git`/`has_remote`). Herdr records also carry the named session, workspace, tab, and pane IDs.
  `parent` is the id of the crew that spawned the member (`""` for a member wingman spawned directly); it is what scopes each layer to its own direct reports.
  `is_git`/`has_remote` are recorded for repo scope only (`null`/absent for global scope) - see "Spawning crew" above.
- `crew/<id>.json` - each crew member's distilled status record.
- `preferences.json` - the cached onboarding-preference answers, keyed by wingman run id, with the settings file's own `[prefs]` table layered underneath at read time.
- `board.md` - the human-readable render of the roster, its Active section indented as a tree so a reader sees the org.
- `watch.pid` / `watch.beat` - wingman's (owner `""`) watcher cycle's pid and liveness beacon.
  A lead's watcher keys its own files by owner (`watch-<owner>.pid` / `watch-<owner>.beat`), so per-owner watchers coexist.
- `watch.pid.owner/` (a directory, `owner` file inside) - the authoritative singleton-lifetime liveness record for that same cycle: the claiming process's pid plus its process start time, checked identity-first rather than by beacon freshness alone, so a reused pid or a merely-stalled-but-alive cycle is never mistaken for dead.
  One character away from `watch.pid.lock/owner` (the separate, sub-second claim lock) - do not confuse the two.
  A lead's cycle keys this `watch-<owner>.pid.owner/` the same way as its pid/beat files above; `watch.ownercheck` (owner-scoped cycles only) is the small debounce counter for a transiently-unreadable owner-status read.
- `watch.code` - a content fingerprint (`cksum` of `watch-fleet` + `lib/common.sh`) stamped at arm time; compared every poll so a cycle notices its own code went stale on disk and exits (`stale-code`) rather than running superseded logic indefinitely (issue #219).
  A lead's watcher keys its own `watch-<owner>.code` the same way as its pid/beat/run files.
- `watch.codecheck` - a small consecutive-mismatch streak counter guarding the check above against spinning: a SECOND consecutive freshly-armed cycle whose own first poll also mismatches is treated as a malfunction, not a real code update, and falls through to the ordinary spurious-failure accounting instead of repeating `stale-code`. Unlike `watch.ownercheck`, this one is deliberately NOT cleared at claim time - it has to persist across the exact re-arm the malfunction it detects would otherwise be invisible across.
- `wake` - the attention list wingman's watcher writes when it fires; a lead's watcher writes `wake-<owner>`.
- `acked.json` - the last `announced` stamp surfaced per crew id, so a surfaced event (blocked/review/done/died) is delivered once instead of on every watcher arm and Stop-hook check.
  A new `announced` (a genuine state change) re-surfaces.
- `handled.json` - the last `announced` stamp fully HANDLED by the Stop hook for each crew id, set only when a stop is allowed to proceed - distinct from `acked.json` so a surfaced-but-unhandled event still re-blocks instead of being permanently suppressed by a premature ack.
- `pr/<id>.json` - a developer member's `pr-watch` cursor: what PR events it has already surfaced (CI signature, conversation high-water mark, whether it has settled green), so a red build or a handled comment does not re-fire.
- `usage/<session-id>.json` - one live session's most recent `rate_limits` capture, written by `bin/lib/usage-statusline.py` on every statusline invocation and aggregated per poll by wingman's own watcher - see [fleet resilience](fleet-resilience.md#fleet-wide-usage-limit-quota-detection).
- `outbox/<id>/` - messages queued for a crew member whose pane could not take a delivery, retried on later passes and swept by `bin/crew-prune`.
- `ask/` - the `bin/crew-ask` request and captured-answer store, retained for `WM_ASK_RETENTION_HOURS` and pruned by `bin/crew-prune`.
- `projects.json` - the discovered-projects cache.
- `crew-archive.jsonl` - append-only history of records removed by `bin/crew-prune` (one JSON object per line).
  Pruning removes fully-closed (`stood-down`) records from `crew.json` and deletes their `crew/<id>.json`, archiving each here first so the roster stays lean without losing the record of who ran.
  It is also the only durable record that a crew id was ever retired (`wm_state crew-derive-id` reads it, issue #178) - any future rotation of this file must not outlive that id's sidecar files, or the id becomes reusable again with no test failing.
- `orphan-candidates.json` - `{window_name: first_seen_iso_stamp}` for a live `wm-*` tmux window with no matching `crew.json` record, tracked by `wm_state reconcile`'s grace-period-gated orphan-window adoption (owner `""` only) - see [Survival & reconciliation](architecture.md#survival--reconciliation).

All *user-editable* customization lives in the repo as gitignored `*.local.md` / `config.local.*` (see [the settings file](#the-settings-file---configlocaltoml)), not here.
`~/.wingman/` is pure runtime state you never hand-edit.
