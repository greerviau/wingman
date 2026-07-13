# Unattended boot-time launch: measured behavior under the onboarding-preferences guard

**Date:** 2026-07-13
**Scope:** follow-up to PR #43 (commit 61c0f24). Corrects that PR's Regressions claim, records the measured behavior of an unattended `bin/wingman` launch under the preference gate, and documents three defects found while exercising the boot path (two fixed in this follow-up's PR, one fixed in machine-local tooling).

## Correction of the record

PR #43's Regressions section states that an unattended `bin/wingman` launch hard-stalls on the preference gate and accepts that on the grounds that "unattended launches are not a supported flow today".
That premise is false: on the machine wingman runs on, an unattended launch exists and fires on every boot.
A systemd user timer (`~/.config/systemd/user/wingman.timer`, `OnBootSec=30s`, `OnUnitActiveSec=5min`) runs `~/.config/wingman-autostart/start-wingman.sh`, which launches `bin/wingman --remote-control Wingman` inside a detached tmux session with no human attached.
The operator attaches later, via `tmux attach` or Remote Control.
This tooling is machine-local (under `~/.config/`, not in this repository), which is presumably why the PR's author did not see it; it predates the PR's merge.

The claim's substance is also wrong: the measured behavior is benign, not a hard stall (next section).
"Hard-stall" was, however, unobservable either way at the time, because a separate boot-path defect killed the session within seconds of every genuinely unattended launch (see "Defect 1"), before the guard could matter.

## Measured behavior under the guard (benign)

Method: the production launch script was run inside a transient `Type=oneshot` systemd user service (the same execution context as the real timer), against an isolated tmux server (`TMUX_TMPDIR`), an isolated `WINGMAN_HOME`, and a distinct Remote Control name, producing a real detached claude session in the wingman repo with the real hooks active.
Observations:

- **At launch, the session is inert.** With no initial message, no model turn runs: zero assistant turns, no tool calls, no guard denials, no token burn. Remote Control registers normally. The session simply sits at an empty prompt.
- **The 5-minute timer re-fire is a no-op** against the live session ("already running ... nothing to do"), so a live-but-gated session is never disturbed.
- **On the first directive** (typed into the detached pane, as an attaching operator would), the SessionStart nudge steers the session straight to the batched `AskUserQuestion`; no denied tool calls preceded it in the measured run. The pending question renders as a normal interactive prompt in the detached pane.
- **While the question pends, the session is quiescent**: the transcript was byte-stable over a measured 2-minute window. There is no retry loop and no turn burn; the turn blocks on the question indefinitely, which is exactly the desired parking behavior.
- **The supervision allowlist works while gated**: `bin/crew-list` executed successfully before the preferences were answered.
- **On answering** (three selections + submit in the pane), the session cached the answers and completed the directive.

Conclusion: an unattended boot-time launch degrades benignly - it idles until a human answers, it keeps fleet supervision available, and it recovers fully on answering.
The env-var escape hatch contemplated in the plan's open questions (pre-set `WM_PREF_*` answers honored by the guard and the ask step) is therefore **not needed** and was deliberately not built.

One real defect surfaced during the recovery step - the answers initially failed to cache; see "Defect 3".

## Defect 1 (machine-local, fixed): systemd reaps the boot-time tmux server

The boot-time launch on 2026-07-13 died silently within a minute (tmux session created 03:55:48, gone by 03:56:49; no crash log, no transcript, no stderr).
Root cause, reproduced empirically without rebooting: `wingman.service` is `Type=oneshot` with the default `KillMode=control-group` and `RemainAfterExit=no`.
At boot no tmux server exists, so the script's `tmux new-session -d` forks a new server inside the service's own cgroup, and systemd kills every process left in that cgroup the instant the script exits.
A transient-oneshot reproduction showed the freshly-forked server dead within 3 seconds of the unit finishing; a pre-existing server (the 03:54:51 pre-reboot launch, and the operator's manual 03:59:01 SSH start) survives because only the client runs in the mortal cgroup.
This also explains why the 5-minute timer never self-healed: every fire re-forked a server into a fresh cgroup and had it reaped again.

Fix (machine-local `start-wingman.sh`, verified end-to-end): every server-forking tmux call is wrapped in `systemd-run --user --scope --collect`, detaching the server's lifetime from the unit's cgroup.
`KillMode=process` was also verified to work but leaves the server stranded in a dead unit's cgroup and is the variant systemd's documentation discourages; the scope wrapper is the recommended form.
The stderr-tee logging previously added to the script captures nothing for this failure class (an external kill produces no stderr) but remains useful for the adjacent class - claude itself exiting with an error at startup - and is kept.

## Defect 2 (repo, fixed in this PR): bare tmux targets prefix-match the wrong session

Tracked as issue #39; confirmed live on this machine with availability impact.
tmux resolves a bare `-t <name>` by exact name, then prefix, then fnmatch - so with no session literally named `wingman`, every `-t wingman` target silently bound to `wingman-main`, wingman's own orchestrator session.
Every crew member spawned in that state was a window inside `wingman-main`, so restarting wingman (or its session dying) would have killed the whole fleet; the crew/orchestrator session separation existed in name only.
The same bug bit the autostart script's own `has-session` check, which is why the crew session was never recreated after the boot-time reap.

Fixes in this PR: every session/window target in `bin/` is exact-match (`=` prefix, via `WM_TMUX_TARGET` / `wm_tmux_win_target`); `wm_tmux_ensure_session` creates-and-verifies the exact-named session (and uses the scope wrapper of Defect 1, so a server it forks is durable); `bin/spawn-crew` therefore guarantees the crew session itself rather than depending on the autostart script.
Regression tests (`tests/tmux-session-targeting.test.sh`) prove: a spawn with only a prefix-sibling session present lands in the exact-named crew session; the fleet survives the sibling (orchestrator) session dying; absent-window targets do not prefix-match neighbours.

**Transitional hazard, also handled:** a member spawned before this fix lives in the wrong session, and the moment the exact-named crew session appears, name-scoped liveness stops seeing it - it would be reported `died` and reaped while its live process kept running unsupervised (observed live on this machine).
Reconcile callers (`bin/crew-list`, `bin/watch-fleet`) now run `wm_tmux_adopt_strays` first: a roster member's window found in another session is moved home with `tmux move-window` (process intact) before liveness is judged.
Spawn and resume additionally record the tmux window id (`@N`) in the roster, so adoption matches exact identity where available (ids restart with the tmux server, so the window name remains the primary key).
Liveness remains name-based by design - names survive a tmux server restart, ids do not, and the crew layer must survive server restarts.

## Defect 3 (repo, fixed in this PR): the guard denies the documented `$WINGMAN_STATE` commands

During the measured recovery, `pref-set` - and even the always-allowlisted `prefs-list` - were denied 14 times, so the answers initially failed to cache.
Two stacked causes:

1. Hooks receive the Bash command string before shell expansion, so the literal `$WINGMAN_STATE prefs-list ...` shape that CLAUDE.md instructs arrives as an unresolvable `$WINGMAN_STATE` token. PR #43's cmd_match fix handled the expanded `uv run --no-project --quiet .../wm-state.py` form, and its tests fed only that form; the unexpanded form every session actually types was never covered. `cmd_match.resolve_command` now expands a leading `$VAR`/`${VAR}` token from the hook's own environment (an unset variable stays unresolved, which can only produce a false deny, never a wrong allow).
2. Nothing exported `WINGMAN_STATE` into wingman's own session in the first place - `bin/spawn-crew` exports it for crew, but `bin/wingman` did not, so even an allowed call would have failed at the shell. `bin/wingman` now exports it.

The prior live session survived this only because its model happened to improvise the expanded `uv run` form instead of the documented one.

## Restart semantics (machine-local, changed as a consequence of Defect 1's fix)

The cgroup reap was accidentally the only working "stop" for wingman: killing the service killed the server, and the next timer fire recreated it.
With the reap fixed, `systemctl --user restart wingman.service` became a silent no-op against a live session (the script is an idempotent starter), which would have made the operator's standing "pull then restart" workflow silently ineffective.
Resolution, verified empirically on an isolated instance (a new claude process replaced the old on restart; a killed session was recreated by the ensure path):

- `wingman.timer` → `wingman-ensure.service`: idempotent ensure (boot + 5-minute self-heal), never touches a live session.
- `wingman.service` → `start-wingman.sh --restart`: kills and recreates wingman's own session (exact-match target; the crew session is never touched), so the operator's existing `systemctl --user restart wingman.service` habit performs a true restart.
- Operator documentation lives in `~/.config/wingman-autostart/README.md`.

The two semantics cannot share one unit: an idempotent starter makes restart a no-op, and a `RemainAfterExit` supervisor makes the periodic timer a no-op that kills self-healing.

The autostart tooling itself stays machine-local by design (its own header states it is for that box only and is not shipped as a repo feature); this document records its fixes because they are prerequisites for the measurements above, not because any of it belongs in the repository.
