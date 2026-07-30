# The 2026-07-30 01:22 UTC fleet loss: tmux server death on SSH logout, and the reconciliation blind spot that hid it

**Date:** 2026-07-30
**Mode:** investigation only - no code was changed.
**Scope:** two questions from the requester. (1) Why the tmux server hosting wingman and its crew died at 2026-07-30 01:22:02 UTC. (2) Why `bin/crew-list` still reported the atrium developer as `review` after the restart, when the documented behavior is that a member whose window died shows as `died`.

**Outcome:** two distinct defects confirmed, both reproduced or evidenced directly from the system journal and from a controlled reproduction. Neither is intended behavior.

---

## Summary

**Defect 1 - the tmux server dies whenever the operator's last login session ends.**
The whole tmux server, including every crew window, lives inside `user@1000.service`. Lingering is disabled for this user (`Linger=no`), so when the operator's SSH connection timed out at 01:21:52, `systemd-logind` removed the last session and stopped the user manager ten seconds later. The user manager's `exit.target` teardown stopped every transient scope under it - including the `systemd-run --user --scope --collect` scope that holds the tmux server - and the server died with all its panes. The scope wrapper protects the server from `systemctl --user stop wingman.service`; it provides no protection at all against user-manager teardown, because the scope is *inside* the user manager. This is not a one-off: a network blip on the operator's SSH connection is sufficient to destroy an entire in-flight fleet.

**Defect 2 - liveness reconciliation is skipped precisely when the whole fleet has died.**
Both `bin/crew-list` and `bin/watch-fleet` guard their reconcile call on `tmux has-session -t "$WM_TMUX_TARGET"`. When the tmux server itself is gone, that session does not exist, so reconcile never runs and every crew record keeps its last self-reported status. The atrium developer therefore rendered as `review` after the restart. Worse, the `correlated:mass-death` machinery built for exactly this scenario is downstream of the same skipped reconcile, so a whole-server death produces no fire at all. The stale status cleared only because a later `bin/spawn-crew` happened to recreate the crew session as a side effect, which re-enabled reconcile on the next call.

Neither the 80% seven-day usage-limit state nor memory pressure contributed. There was no OOM kill and no crew action that could have killed the server.

---

## Defect 1: the tmux server is inside `user@1000.service`, and lingering is off

### Timeline (all times UTC, from `journalctl`)

| Time | Event |
|---|---|
| 2026-07-29 23:00:07 | Host boots (`uptime -s`; boot id `ce4c30bd…`). |
| 2026-07-29 23:01:57 | Operator SSHs in from their workstation, port 49197. `systemd-logind` opens session 1 (class `user`) and session 2 (class `manager`); user manager pid 1454 starts. |
| 2026-07-29 23:01:57 | `wingman.service` starts automatically - it is `enabled` and `WantedBy=default.target`, so it starts with the user manager, not by operator action. It runs `systemd-run --user --scope --collect -- tmux new-session -d -s wingman-main …`, creating transient scope `run-p2221-i24918.scope` which holds the tmux **server** (pid 2223). |
| 2026-07-29 23:09:55 | A deliberate `wingman.service` restart. Unremarkable; the tmux server survives it, which is what the scope wrapper is for. |
| 2026-07-29 23:26:57 | Seven-day usage window recorded at 80%, `state: acknowledged` (`~/.wingman/usage-limit-state.json`). No effect on any of what follows. |
| **2026-07-30 01:21:52.393** | `sshd-session[1496]: Read error from remote host <workstation> port 49197: Connection timed out`. The operator's SSH connection dies on the network. `systemd-logind` logs out and removes session 1. |
| **2026-07-30 01:22:02.558** | ~10 s later, after logind's user-release delay and with no remaining session and `Linger=no`: `systemd[1]: Stopping user@1000.service - User Manager for UID 1000...` |
| 2026-07-30 01:22:02.560 | The user manager activates `exit.target` and begins stopping **every** unit under it, including `run-p2221-i24918.scope` (the tmux server) and each `tmux-spawn-*.scope` (the individual panes). |
| 2026-07-30 01:22:02.567 | `Stopped run-p2221-i24918.scope`. The tmux server is dead at this instant. |
| 2026-07-30 01:22:02.581 | `wingman.service`'s `ExecStop` runs `tmux kill-session -t =wingman-main` and prints `no server running on /tmp/tmux-1000/default`. **This message is a consequence, not a cause** - the server had already been stopped 14 ms earlier. |
| 2026-07-30 01:22:04.147 | `Removed slice app.slice`, `user@1000.service: Deactivated successfully`. `user-runtime-dir@1000.service` stops and `/run/user/1000` is removed. |
| **2026-07-30 01:51:14** | Operator SSHs back in (port 49586). New user manager pid 277654 starts; `wingman.service` starts automatically with it. This is the "restart" - it was the login, not a manual `systemctl restart`. |
| 2026-07-30 01:54:17 | `bin/spawn-crew` runs `wm_tmux_ensure_session`, creating `run-p280174-i288294.scope - tmux new-session -d -s wingman -n _wm_idle`. The crew session exists again for the first time since the death. |
| 2026-07-30 01:54:32 | The atrium developer's status file flips to `died` (`~/.wingman/crew/implement-the-approved-plan-for--developer.json`, `updated: 2026-07-30T01:54:32.009115Z`). See Defect 2 for why this took until now. |

### Mechanism

The cgroup placement is the whole story. Verified against the currently-running server:

```
$ systemd-cgls --user-unit run-p277675-i273028.scope
Unit run-p277675-i273028.scope (/user.slice/user-1000.slice/user@1000.service/app.slice/run-p277675-i273028.scope):
└─277682 /usr/bin/tmux new-session -d -s wingman-main -n wingman …
```

The `systemd-run --user --scope` wrapper moves the tmux server out of `wingman.service`'s own cgroup, which is what the unit's comment says it is for:

> `systemd-run --user --scope --collect` puts the tmux server in its own transient scope instead of this unit's cgroup - the same trick `bin/lib/common.sh`'s `wm_tmux_scoped` uses - so stopping this service never takes the crew session (and its live crew windows) down with it.

That claim is true for its stated case and the design works as intended there. What it does not do - and what nothing in the unit or the repo accounts for - is survive the *user manager* going away. A `--user` scope is by construction a child of `user@UID.service`; when that unit stops, every scope beneath it stops with it. `--collect` is irrelevant to this: it only controls whether a transient unit is garbage-collected after failing, and it neither extends nor shortens the scope's lifetime.

The gate that decides whether the user manager stops on logout is lingering, and it is off:

```
$ loginctl show-user greer | grep Linger
Linger=no
$ ls /var/lib/systemd/linger/
(empty)
```

With `Linger=yes`, `user@1000.service` persists across logout and the tmux server - and the whole fleet - survives an SSH disconnect.

### Ruled out

- **OOM killer.** No `Out of memory`, `oom-kill`, or `Killed process` entries in the kernel log across any boot (`journalctl -k | grep -ciE 'out of memory|oom-kill'` returns 0). The host has 15 GiB RAM with 13 GiB available. The teardown log does show high watermarks - `tmux-spawn-64eb6757…scope: 7.7G memory peak` for one crew pane, `user-1000.slice: 8.7G memory peak` overall - which is worth knowing but is not what killed anything. Every process died through an orderly systemd stop, not a kill signal from the kernel.
- **`--collect` in the `ExecStart`.** As above: no lifetime effect. Not causal.
- **A crew action killing the server.** There is no `tmux kill-server` anywhere in `bin/`, `hooks/`, or `playbooks/`; the only repo hits for the string are in `hooks/no-watcher-kill-guard.sh`'s own comments describing what it defends against. `wingman.service`'s `ExecStop` is exact-match (`-t =wingman-main`) and can only ever target the pilot session, and it ran after the server was already gone. The journal shows a systemd-initiated teardown of the whole user manager, not a targeted kill.
- **The usage-limit state.** Recorded at 23:26:57 as `acknowledged` at 80% of the seven-day window, roughly two hours before the death, and the usage-limit machinery only gates new `bin/spawn-crew` calls - it never touches running crew. Unrelated.
- **`crew.json`'s 01:21 mtime.** This is the last ordinary status write before the death, consistent with the fleet still working normally up to the moment the SSH connection dropped. It is not a signal of anything going wrong.

### Why this is a repo-level defect, not just a machine misconfiguration

The `wingman.service` unit is not in this repository - it is a hand-installed user unit at `~/.config/systemd/user/wingman.service`. `bin/doctor` does not manage it, does not check it, and never mentions lingering; the string `linger` appears nowhere in `bin/`, `docs/`, or `README.md`. Closed issue #45 ("The autostart tooling (systemd units + start-wingman.sh) is untracked and untested, and has now produced two silent, serious bugs") recommended shipping a supported reference implementation in the repo precisely so this class of bug would be reviewable and testable. That recommendation was never implemented, and this incident is the third silent failure from the same untracked glue - and the first to destroy an in-flight fleet rather than merely fail to start one.

### Recommended fix (not applied)

1. **Immediate, machine-local:** `loginctl enable-linger greer`. This alone prevents recurrence and is safe to apply at any time; it makes `user@1000.service` persist across logout so the tmux server survives an SSH disconnect.
2. **Repo-level, the durable fix:** add a linger check to `bin/doctor` that fails (or offers to fix, with consent, in keeping with how `doctor` handles its other dependencies) when `loginctl show-user "$USER"` reports `Linger=no` while a systemd-managed wingman unit is installed. A fleet whose survival depends on an undocumented, unchecked per-user systemd flag will lose a fleet again.
3. **Optional, larger:** revisit #45's recommendation and ship the unit in the repo with the linger requirement documented next to it, so the constraint travels with the thing that depends on it.

---

## Defect 2: reconcile is guarded on the crew session existing, so a whole-fleet death is invisible

### What the documentation promises

`bin/crew-list`'s own header comment:

> `crew-list` - print the roster (merged roster + live status), **reconciled against the live tmux windows first so a crew member whose window died shows as 'died'.**

`CLAUDE.md`, on startup reconciliation and on liveness generally:

> reconcile against the live windows (`bin/crew-list` does this automatically) […] `bin/crew-list` is always the source of truth for whether a member is alive, never Remote Control's displayed state.

Nothing in either place documents an exception. This is a defect against stated behavior, not intended behavior.

### The guard

`bin/crew-list:25-28`:

```bash
if wm_tmux has-session -t "$WM_TMUX_TARGET" 2>/dev/null; then
  wm_tmux_adopt_strays
  wm_state reconcile --windows "$(wm_tmux_windows_csv)" >/dev/null
fi
```

`bin/watch-fleet:838-846` carries the identical guard around its own reconcile call.

When the tmux server dies, the crew session `wingman` ceases to exist, `has-session` fails, and the entire block is skipped. `wm_state reconcile` is never invoked, so no record is examined and every member keeps its last self-reported status. `review` is in `LIVE_STATES` (`bin/lib/wm-state.py:127`), so the atrium developer stayed exactly as it had last reported itself.

The reconcile implementation itself is *not* at fault. `cmd_reconcile` (`bin/lib/wm-state.py:959`) handles an empty window set correctly - with `live_windows` empty, every member in a live state whose window is absent is flipped to `died`. The bug is entirely in the shell-level guard that prevents it from ever being called.

Note this is not specific to `review`. Any member in `working`, `blocked`, `review`, or `stalled` is equally affected; `review` is simply what the atrium developer happened to be in.

### Reproduction

Isolated `WINGMAN_HOME` with a single roster record in `review` whose window `wm-demo-developer` does not exist anywhere. The only variable between the two runs is whether the crew tmux session exists.

**A - crew session absent (the post-server-death state):**

```
$ WINGMAN_HOME=$SCRATCH/wmhome WM_TMUX_SESSION=wm-repro-absent-sess WINGMAN_CREW_ID="" bin/crew-list
  [developer ] demo-developer         review    PR ready
      delivery: https://example/pr/1
```

Stale `review`. Reconcile was skipped.

**B - crew session present, member's window still absent:**

```
$ tmux new-session -d -s wm-repro-present-sess -n _wm_idle 'sleep 120'
$ WINGMAN_HOME=$SCRATCH/wmhome WM_TMUX_SESSION=wm-repro-present-sess WINGMAN_CREW_ID="" bin/crew-list
  [developer ] demo-developer         died      PR ready
      delivery: https://example/pr/1
```

Correct `died`. Same roster, same absent window; only the existence of the crew session differs.

This matches the incident exactly. After the 01:51:14 restart the crew session did not exist, so `bin/crew-list` reported `review`. At 01:54:17 `bin/spawn-crew` called `wm_tmux_ensure_session` and recreated the session as an incidental side effect of spawning unrelated crew; the next reconcile, at 01:54:32, flipped the atrium developer to `died`. The recovery was accidental. Had no new crew been spawned, the entire dead fleet would have sat in stale live statuses indefinitely.

### The more serious consequence: `correlated:mass-death` cannot fire

`bin/watch-fleet` captures the ids reconcile *just* flipped into `_reconcile_died`, and that variable is only ever assigned inside the `has-session` branch (`bin/watch-fleet:846`). Everything downstream - the correlated-batch split, `wm_state group-attention`, the fleet-wide outage signal - is fed from it. `bin/watch-fleet` never calls `wm_tmux_ensure_session` (verified: no occurrences in the file), so it cannot recreate the session itself.

The result is that the one event the mass-death machinery exists to catch is the one it structurally cannot see. `docs/runbooks/incidents.md` documents the `correlated:mass-death` fire as:

> Relay it plainly ("N crew members died together around \<time\>, looks like a host/tmux crash") and **confirm with the pilot before running `bin/crew-resume --all-died`**

A host or tmux crash that takes the *server* down - the exact wording of that runbook entry, and the motivating scenario of closed issue #22 ("No clean automated recovery after a mass crew-death (tmux/host crash)") - leaves no live crew session behind, so reconcile is skipped, `_reconcile_died` stays empty, and no fire is ever produced. The recovery path built for #22 is reachable only by an operator who already suspects something is wrong. In this incident it was never offered.

### Why the guard exists, and why it cannot simply be deleted

The guard is original to the first commit (`6251ade`) and was only ever touched to switch it to exact-match targeting (`8869678`, PR #48). There is no recorded rationale, but a real hazard is visible in the code: `wm_tmux_adopt_strays` (`bin/lib/common.sh:725-726`) exists because a crew window can legitimately live in a *different* tmux session, and its very first line is the same `has-session` early return. If reconcile were called unconditionally with an empty window list while the crew session merely did not exist yet, any genuinely-live stray window would be falsely flagged `died` - the failure mode issue #44 was filed for.

The fix therefore needs to distinguish "the crew session does not exist" from "no crew windows are alive anywhere on the server", rather than treating the first as a reason to do nothing. Two shapes that both satisfy that:

- Call `wm_tmux_ensure_session` before reconciling, so the session always exists and the stray-adoption pass can run normally. Cheap and consistent with what `bin/spawn-crew` and `bin/crew-resume` already do, but it means `bin/crew-list` starts a tmux server as a side effect of a read-only status query, which may not be acceptable.
- Reconcile against **all** live `wm-*` windows across every session on the server (which is what `wm_tmux_adopt_strays` already enumerates in its authoritative pass) rather than only those inside the crew session, and treat "tmux server unreachable" - distinct from "session absent" - as the only condition that skips reconcile entirely.

Choosing between these is an implementation decision for whoever fixes it; both are noted here so the fix does not reintroduce #44.

---

## Recommended next steps

1. Apply `loginctl enable-linger greer` on the host. This is the single action that prevents recurrence of the fleet loss and can be done immediately.
2. Fix Defect 2 first among the code changes. It is the reason the incident was silent, and it is what makes every future infrastructure crash recoverable through the path #22 already built.
3. Fix Defect 1 at the repo level via `bin/doctor`, and consider finally acting on #45's recommendation to bring the autostart unit under version control.
4. Both defects are filed: Defect 1 as https://github.com/greerviau/wingman/issues/208, Defect 2 as https://github.com/greerviau/wingman/issues/209.

## Open questions

None that block acting on this report. Both defects are confirmed with direct evidence, and both fixes are ordinary engineering work with no decision the requester needs to make first. The one genuinely open item - which of the two reconcile-fix shapes to take - belongs to the implementation and is recorded above rather than raised here as a question.
