# Why wingman keeps crashing

**Date:** 2026-07-30
**Mode:** investigation only — no code was changed by this investigation.
**Question from the requester:** "Why does wingman keep crashing?" — plus a root-cause of the newest fleet loss in the 04:05–04:27 UTC window, and a synthesis of the three existing post-mortems.

**Status: closed.** Both open questions have been decided by the requester and are recorded under "Decisions taken" below. The host remedy has been applied and verified. The scope call on the systemd unit has been applied throughout this document.

---

## The short answer

**Wingman is not crashing. Nothing has crashed at any point in the last three days.** There is no segfault, no OOM kill, no panic, and no unhandled error in any of the events under investigation. Three different things have been experienced as "wingman keeps crashing," and they are three unrelated failures:

1. **Twice in the current boot — 01:22:02 and 04:05:20 UTC — the entire tmux server hosting wingman and its crew was destroyed by an orderly, deliberate systemd shutdown.** The trigger both times was the requester's own SSH connection dropping. Because lingering was disabled for this user, `systemd-logind` stopped the whole user manager ten seconds after the last login session closed, and every process underneath it — including the tmux server and every crew window — was stopped with it. This was a host configuration consequence, not a fault in wingman. It is also the only one of the three that destroyed in-flight work. **This is now fixed at the host level: `loginctl enable-linger greer` has been applied and verified (`Linger=yes`).**
2. **On 2026-07-28, wingman's supervision loop was repeatedly killed** by an out-of-band signal originating outside this repository's code. Wingman itself stayed alive; it lost its ability to be woken by crew events. This was checked against the mechanism in (1) and is **confirmed unrelated** — see Part 4.
3. **On 2026-07-29, wingman stopped being able to spawn crew** because the usage-limit state machine latched a pause at 80% and then ignored the requester's raised threshold. Again nothing died; the fleet was simply blocked.

**The reason it kept happening was not that any of it was unknown.** Every confirmed defect behind all three events was already root-caused and already filed. The fleet-destroying one had a one-command host remedy that had been written down and not yet run:

> `loginctl enable-linger greer` was recommended in writing at 02:01 UTC on 2026-07-30. It had not been applied when, **2 hours and 4 minutes later at 04:05:20 UTC, the identical failure destroyed the fleet again** from the identical cause, with `Linger=no` still set. It has since been applied.

That is the whole of "why it kept happening." The diagnosis was complete; the remedy was one host command. With lingering now enabled, this failure mode is closed.

---

## Part 1 — Root cause of the 04:05 UTC fleet loss

**Verdict: confirmed.** The mechanism identified in the 2026-07-30 01:22 post-mortem is confirmed unchanged as the cause of the 04:05 event. Nothing new is required to explain it. This section is the confirmed record of what happened and is unchanged by the scope decision discussed later.

### Timeline (all times UTC, from `journalctl`)

| Time | Event |
|---|---|
| 2026-07-29 23:00:09 | Host boots (boot id `ce4c30bd…`). This is the current boot; **there was no reboot in the incident window** — machine uptime at investigation time was 5 h 29 min. |
| 2026-07-30 01:51:14.573 | Requester SSHs in from `<workstation>` port 49586. `user@1000.service` (pid 277654) starts. `wingman.service` starts automatically with it — it is `enabled` and `WantedBy=default.target`. Its `ExecStart` creates transient scope `run-p277675-i273028.scope`, holding tmux server pid 277682. |
| 04:05:10.025 | `sshd-session[277697]: Read error from remote host <workstation> port 49586: Connection timed out`. **The requester's SSH connection dies on the network.** |
| 04:05:10.026 | `pam_unix(sshd:session): session closed for user greer`; `session-3.scope: Deactivated successfully`; `systemd-logind: Session 3 logged out. Waiting for processes to exit`; `Removed session 3`. |
| **04:05:20.058** | Exactly 10 s later — `logind`'s `UserStopDelaySec` default, confirmed as `#UserStopDelaySec=10` in the logind config — and with no session remaining and `Linger=no`: `systemd[1]: Stopping user@1000.service - User Manager for UID 1000...` |
| 04:05:20.060 | The user manager activates `exit.target` and begins stopping **every** unit beneath it. |
| 04:05:20.060 | `Stopping run-p277675-i273028.scope - [systemd-run] /usr/bin/tmux new-session -d -s wingman-main …` — **the tmux server.** |
| 04:05:20.061–.062 | `Stopping tmux-spawn-2c0967b9….scope` and `tmux-spawn-c385a6a4….scope` — the individual crew panes. |
| 04:05:20.068 | `Stopped run-p277675-i273028.scope` … `Consumed 5.529s CPU time over 2h 14min 5.246s wall clock time`. **The tmux server is dead at this instant.** |
| 04:05:20.069 | `Removed slice session.slice - User Core Session Slice`. |
| 04:05:20.089 | `tmux[540912]: no server running on /tmp/tmux-1000/default` — this is `wingman.service`'s `ExecStop` running `tmux kill-session -t =wingman-main`. **It is a consequence, 21 ms too late to be a cause.** |
| 04:05:21.618–.735 | The crew pane scopes finish stopping: one consumed `4min 48s` CPU / `366.8M` peak, the other `28min 16s` CPU / `363.7M` peak. `Removed slice app.slice … 1.3G memory peak`. |
| 04:05:21.745 | `user@1000.service: Deactivated successfully`. `run-user-1000.mount` deactivated; `user-1000.slice` removed; `/run/user/1000` gone. |
| **04:26:54.047** | Requester SSHs back in from the **same** host, port 53769. A new `user@1000.service` (pid 540956) starts; `wingman.service` starts automatically with it at 04:26:54.302. **This is the "restart" — it was the login, not a `systemctl restart`.** |
| 04:29:36.638 | `bin/spawn-crew` calls `wm_tmux_ensure_session`, creating `run-p543277-i542809.scope - tmux new-session -d -s wingman -n _wm_idle`. The crew session exists again for the first time since the death. |
| 04:29:47.567 | The lost software-analyst's record flips from `review` to `died` — **only now**, as an incidental side effect of the spawn above. See Part 3. |

### Mechanism

A `systemd-run --user --scope` scope is, by construction, a child of `user@UID.service`. Verified live against the then-running server:

```
$ pgrep -f "tmux new-session -d -s wingman-main"
540985
$ cat /proc/540985/cgroup
0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-p540977-i557802.scope
```

When `user@1000.service` stops, every scope beneath it stops too. The `--scope` wrapper in the unit's `ExecStart` does exactly what its own comment claims — it keeps the tmux server out of that unit's cgroup, so `systemctl --user restart` on it does not kill the crew — and that design works for its stated purpose. What it does not and cannot do is survive the user manager itself going away.

The gate on whether the user manager survives logout is lingering, and at the time of both deaths it was off:

```
$ loginctl show-user greer | grep Linger
Linger=no
$ ls -A /var/lib/systemd/linger/
(empty)
```

`--collect` is irrelevant to this. It governs whether a transient unit is garbage-collected after *failing*; it has no effect on scope lifetime in either direction.

**Remedy applied.** `loginctl enable-linger greer` has since been run on this host, and verified:

```
$ loginctl show-user greer -p Linger
Linger=yes
$ ls -A /var/lib/systemd/linger/
greer
```

With lingering enabled, `user@1000.service` persists across logout, so the tmux server and every crew window now survive an SSH disconnect. This failure mode is closed.

### Explicitly ruled out for the 04:05 event

Each of these was checked directly for this event, not carried over from the earlier report.

- **OOM killer / memory pressure.** Zero matches for `out of memory`, `oom-kill`, `oom_kill`, `Killed process`, or `memory cgroup out of` across the entire current boot's kernel log. Every process died through an orderly systemd stop. The teardown does record real high-water marks (`366.8M` and `363.7M` per crew pane, `1.3G` for `app.slice` overall), but the host has 15 GiB and nothing was killed for memory. `systemd-oomd` is not installed.
- **A host reboot.** Uptime 5 h 29 min at investigation time; `journalctl --list-boots` shows the current boot beginning 2026-07-29 23:00:09 and continuing unbroken through the incident. No reboot.
- **A service restart cascading into the server.** There was no restart. The journal shows the unit stopping only as part of the user-manager teardown (04:05:20.066, *after* the scope was already being stopped) and starting only with the new user manager at 04:26:54. Nobody ran `systemctl restart`. Even had they, that is the case the `--scope` wrapper correctly defends.
- **A crew action killing the server.** The teardown in the journal is a systemd-initiated stop of the whole user manager, not a targeted kill — every unit under `user@1000.service` went down together, in dependency order. The unit's `ExecStop` is exact-match (`-t =wingman-main`) so it can only ever target the pilot session, and it ran 21 ms after the server was already stopped.
- **The `--collect` flag.** No lifetime effect. Not causal.
- **The usage-limit state.** That machinery gates new `bin/spawn-crew` calls only; it never touches running crew. Not causal here.
- **Systemd-level teardown of anything other than the user manager.** `session-3.scope` was deactivated first as a normal consequence of the SSH session closing; it is the *trigger* for the user-manager stop, not an independent cause.

### Every occurrence, enumerated

Every `user@1000.service` teardown in the journal's full history (which begins at the host's first boot, 2026-07-28 06:07:59, so coverage is complete for the three-day period):

| Time (UTC) | Trigger | Fleet destroyed? |
|---|---|---|
| 2026-07-29 22:58:56 | Host reboot | Not an SSH-logout death |
| 2026-07-29 23:00:01 | Host reboot | Not an SSH-logout death |
| **2026-07-30 01:22:02** | SSH session closed 01:21:52 (`Read error … Connection timed out`) | **Yes** |
| **2026-07-30 04:05:20** | SSH session closed 04:05:10 (`Read error … Connection timed out`) | **Yes** |

Both fleet-destroying events: same cause, same 10-second delay, same client. Before the linger fix this was reproducible in practice — any network blip on the requester's SSH connection destroyed the fleet.

The exact 10-second gap is `logind`'s `UserStopDelaySec` at its compiled-in default. This mattered because it meant the window in which a reconnect would have saved the fleet was ten seconds wide — far too narrow to rely on. `KillUserProcesses` is also at its default `no`, which is why processes were stopped by the user manager's own `exit.target` rather than killed by logind directly; it was never the relevant knob.

---

## Part 2 — Scope decision: the systemd unit is not a wingman concern

The requester has ruled the host service unit explicitly out of scope, in their own words:

> "The system service is a custom thing for this machine, it's not a wingman feature, shouldn't be considered as such, close any issues related to it."

Recorded plainly, because none of it should be silently dropped:

- **The mechanism was confirmed**, with direct journal, cgroup, and configuration evidence. Part 1 stands as written and is not in dispute.
- **The host fix was applied and verified** — `Linger=yes`, marker present. The fleet-destroying failure mode is closed on this host.
- **The unit itself was ruled out of wingman's scope by the requester.** It is a hand-installed, machine-specific user unit; it is not a wingman feature and is not treated as a wingman defect.

Consequently, and applied throughout this document:

- **Two issues are closed as out of scope:** the SSH-logout fleet death and the unit's inability to supervise what it launches. Both remain accurate as diagnoses; neither is wingman work.
- **Three earlier recommendations are withdrawn:** shipping a reference unit in the repository, adding an installer for it, and adding a `bin/doctor` linger check. All three treated the unit as wingman's responsibility, which the requester has rejected. They are not carried anywhere in this document's recommendations.
- **Prior art is likewise out of scope.** Closed issue #45 ("the autostart tooling is untracked and untested") recommended bringing this glue into the repository. Under this scope call that recommendation does not apply and is not revived here.

Lingering remains a genuine operating requirement for this host — it is simply the host's requirement to keep met, not something wingman ships, checks, or documents.

---

## Part 3 — The three existing post-mortems, answered directly

### Confirmed root cause of each event

| # | Event | Root cause | Status | Issue |
|---|---|---|---|---|
| 1 | **2026-07-28** — wingman's own watch-fleet cycle died 4× in ~10 min (`clean-exit-or-sigterm`) | An out-of-band signal (SIGURG-class, exit 144) from the Claude Code harness's own background-task lifecycle handling reaching the harness-owned wrapper shell, which this repo cannot install a trap on. | **HYPOTHESIS.** Every repo-level alternative was directly disproven, and an exit-144 signature was reproduced on an analogous wrapper under a deliberate kill — but the *spontaneous* trigger was never reproduced on demand. Now also confirmed **not** to be the Part 1 teardown (Part 4). | [#196](https://github.com/greerviau/wingman/issues/196) — open |
| 2 | **2026-07-28** — a lead logged 6 × `dropped-wake fire` | Not a death at all. Each cycle exited normally on a real event; a concurrently-arriving `crew-ask` message preempted the lead's turn before it ran `--classify`, and the next bare re-arm discarded the unconsumed exit record. Nothing enforces the pairing. | **CONFIRMED** for the traced 07:02:55 occurrence (direct transcript trace); inferred for the other five (identical structural precondition). | [#197](https://github.com/greerviau/wingman/issues/197) — open |
| 3 | **2026-07-28** — the `spurious-repeated` / stop-guard rule conflict | `hooks/stop-guard.sh` has zero awareness of the per-owner spurious-failure budget, so its "no live watcher → arm one now" branch forces a re-arm that `/watch` explicitly forbids. The failure budget is therefore defeated by force whenever any crew is in flight. | **CONFIRMED** — observed verbatim in the live transcript with timestamps, and confirmed by direct inspection of the hook. | [#198](https://github.com/greerviau/wingman/issues/198) — open |
| 4 | **2026-07-29** — a raised `WM_USAGE_WARN_THRESHOLD` could not release a latched pause | `cmd_usage_update` evaluates the threshold **only while the state is `clear`**. Once latched to `approaching`/`paused`/`acknowledged`, the threshold is never consulted again until `resets_at`. Lowering the threshold is live; raising it is not. | **CONFIRMED** — direct code read plus a sandboxed reproduction. | [#206](https://github.com/greerviau/wingman/issues/206) — open |
| 5 | **2026-07-29** — `artifact-scan.sh` false positive | `INFRA_RE`'s internal-hostname alternative reads the repo's own settings *filename* as though it were a `.local` hostname, blocking publication of documents containing no IP or hostname at all. The same pattern also catches the repo's other `.local`-infixed convention filenames. | **CONFIRMED** — reproduced directly, and hit a third time by this very report (see "Note on publishing"). | [#207](https://github.com/greerviau/wingman/issues/207) — open |
| 6 | **2026-07-30 01:22 and 04:05** — the tmux server died, taking the whole fleet | The tmux server lived in a transient scope inside `user@1000.service`; `Linger=no`, so logind stopped the user manager 10 s after the last SSH session closed and the scope went with it. | **CONFIRMED** — journal evidence and cgroup verification; recurred identically twice. **Host fix applied** (`Linger=yes`); **unit ruled out of wingman scope.** | Closed as out of scope |
| 7 | **2026-07-30 01:54 and 04:05** — a dead crew member still reported `review` | `bin/crew-list` and `bin/watch-fleet` both guard their reconcile call on `tmux has-session`. When the tmux *server* is gone that session does not exist, reconcile never runs, and every record keeps its last self-reported status. `correlated:mass-death` is downstream of the same skipped reconcile, so a whole-server death produces **no fire at all**. | **CONFIRMED** — controlled two-arm reproduction, and re-reproduced live (Part 5). | [#209](https://github.com/greerviau/wingman/issues/209) — open |
| 8 | Discovered here — the host unit supervises nothing | The `--scope` wrapper leaves the unit with an empty cgroup, so it reports `active (exited)` whether or not wingman is alive and no `Restart=` policy can apply. | **CONFIRMED** by direct inspection (Part 6). **Ruled out of wingman scope.** | Closed as out of scope |

### Do they share one underlying cause, or are they independent failures?

**They are independent failures — three distinct causes with no shared mechanism.**

- Events 1–3 (07-28) concern the watcher/wake loop. Event 1's trigger is external to this repository; events 2 and 3 are repo-level logic gaps. The original 07-28 post-mortem ruled out a shared cause between its two symptoms (external kill vs. agent-side scheduling race), and that conclusion holds.
- Events 4–5 (07-29) concern the usage-limit state machine and the artifact scanner. Neither touches process lifetime; neither is related to the watcher or to tmux.
- Events 6–8 (07-30) concern host process supervision and liveness reconciliation.

**Events 6 and 7 were a matched pair, and that pairing is the important structural finding.** The host misconfiguration destroyed the fleet; #209 guaranteed nobody was told. Across both 07-30 losses, four crew members were destroyed and **zero** produced a watcher fire. With the host side now fixed, #209 is what remains — and it is what makes *any* future infrastructure failure silent, not just this one.

There is also a weaker **thematic** pattern worth naming, though it is not a shared root cause: in most of these cases, wingman's own reporting could not see the failure it was suffering. The watcher's forensic record is destroyed by the next re-arm (#197); the failure budget is overridden without the override being reportable as legitimate (#198); the usage guard message under-reports because the reading is frozen at flip time (#206); a whole-fleet death leaves stale `working`/`review` statuses and fires nothing (#209). The recurring weakness is not any single component — it is that the fleet's self-report is treated as evidence of external state.

### Which defects survive the scope call

**Six wingman-side defects survive and remain open.** All are in code this repository owns:

| Issue | Component | Actionable in-repo? |
|---|---|---|
| [#209](https://github.com/greerviau/wingman/issues/209) | `bin/crew-list`, `bin/watch-fleet` reconcile guard | **Yes — highest value.** |
| [#206](https://github.com/greerviau/wingman/issues/206) | `bin/lib/wm-state.py` usage state machine | Yes; design already settled in its report. |
| [#198](https://github.com/greerviau/wingman/issues/198) | `hooks/stop-guard.sh` | Yes. |
| [#197](https://github.com/greerviau/wingman/issues/197) | `bin/watch-fleet` wake-file text and `--classify` pairing | Yes. |
| [#207](https://github.com/greerviau/wingman/issues/207) | `bin/lib/artifact-scan.sh` `INFRA_RE` | Yes. |
| [#196](https://github.com/greerviau/wingman/issues/196) | watcher lifecycle | Partly — see Part 4. |
| [#175](https://github.com/greerviau/wingman/issues/175) | repo hygiene for crew deliverables | Yes. |

**Two are closed as out of scope:** the SSH-logout fleet death and the unit's lack of supervision. Both diagnoses stand; neither is wingman work.

---

## Part 4 — #196 checked against the Part 1 mechanism: confirmed unrelated

The teardown in Part 1 is a plausible-looking candidate for the 07-28 watcher kills — "an out-of-band signal killed my background task" describes both. It was therefore checked directly, and **it is refuted.**

The user manager ran **continuously across the entire 2026-07-28 incident window** — over 40 unbroken hours:

```
Jul 28 06:08:34.002 systemd[1]: Started  user@1000.service - User Manager for UID 1000.
Jul 29 22:58:56.337 systemd[1]: Stopping user@1000.service - User Manager for UID 1000...
```

The watcher deaths clustered at 17:15–17:33 UTC on Jul 28, squarely inside that span. There is no teardown, no restart, and no session churn anywhere near them:

```
$ journalctl --system --since "2026-07-28 16:00" --until "2026-07-28 18:00" \
    | grep -iE "session closed for user greer|Read error from remote|Removed session|logged out|Accepted publickey"
(no output)
```

No logout, no dropped connection, no new login in the two-hour bracket around the incident. This independently confirms the original investigation's own finding that `journalctl --user` showed no scope start/stop near the window.

The two failures are genuinely independent, and the evidence separates them cleanly: the Part 1 mechanism destroys *every* pane in the tmux server simultaneously and is loudly visible as an orderly systemd teardown; the 07-28 incident killed *only* the watcher process, four times, leaving wingman alive and its pane intact, with nothing in the journal at all. Different mechanism, different blast radius, different evidence.

### Judged on its own merits, not by association

**The watcher-lifecycle concern is real, but its actionable parts are already filed elsewhere.**

*Still real and unexplained:* wingman's supervision loop was terminated four times in ten minutes by something no session on the fleet did. Every repo-level alternative was directly disproven, and the Part 1 teardown is now disproven too. The `clean-exit-or-sigterm` signature — no exit record written, pidfile removed by the script's own `INT`/`TERM` trap — still points at genuine signal delivery, and the reproduced exit-144 (`128+16`, SIGURG) signature on an analogous harness-owned wrapper remains the best-supported explanation. Nothing found since weakens that inference.

*Not straightforwardly fixable here:* the `trap '' URG` at `bin/watch-fleet:133` protects the script process, not the wrapper shell the harness generates and tracks. This repository does not own that wrapper and cannot install a disposition on it. That part is a question for the harness.

*What genuinely belongs to wingman is already tracked separately:*

- **[#185](https://github.com/greerviau/wingman/issues/185)** — watcher re-arm depends on model memory; a tokenless auto-arm in the Stop hook would make a killed cycle self-heal regardless of *why* it died. **This is the cause-agnostic remedy and the highest-value mitigation.**
- **[#189](https://github.com/greerviau/wingman/issues/189)** — no durable per-cycle watcher lifecycle log. Had this existed, the question answered above would have been answerable from wingman's own records rather than by reconstructing the journal.
- **[#198](https://github.com/greerviau/wingman/issues/198)** — the stop-guard/failure-budget conflict, which is what turned four external kills into a rule conflict.
- **[#197](https://github.com/greerviau/wingman/issues/197)** — the `--classify` pairing race, which decides whether a cycle's forensic record survives at all.

**Assessment:** #196 survives as the evidence record for the external-kill hypothesis and is *not* closed by association with the scope call — nothing about the host-unit decision touches it. But #185 is the actual remedy: it makes wingman resilient to the watcher dying for any reason without needing the trigger identified. If the preference is to hold only actionable issues open, #196 could reasonably be closed in favour of #185/#189/#198 with its evidence preserved on the issue. It has been left open pending that call, with this reasoning recorded there.

---

## Part 5 — Live re-reproduction of #209 during this investigation

The reconciliation blind spot re-occurred during the 04:05 event and was still active when this investigation began. This is direct confirmation, not a repeat of the earlier controlled reproduction.

Two crew members were lost at 04:05:20:

- An atrium developer whose record read `died` with `updated: 2026-07-30T01:54:32Z`. Note the timestamp: that is from the **previous** (01:22) death. It was never resumed after that one, and its delivery — atrium PR #363 — remains open, `mergeStateStatus: BLOCKED`, `reviewDecision: REVIEW_REQUIRED`.
- A wingman software-analyst whose window was destroyed at 04:05:20 while its record said `review`, holding a completed report as its artifact.

The analyst's record then asserted a **live** member — `review` — from 04:05:21 until **04:29:47**, when it flipped to `died`. That flip landed roughly 11 seconds after `bin/spawn-crew` recreated the crew tmux session at 04:29:36, as an incidental side effect of spawning *this* investigation. Nothing noticed the death; a subsequent unrelated spawn happened to re-enable reconcile.

This matches #209's predicted behaviour exactly, including the accidental nature of the recovery: had no new crew been spawned, the destroyed analyst would have continued rendering as a live member holding a deliverable awaiting review, indefinitely. **No `correlated:mass-death` fire was produced at any point**, for either loss.

An additional consequence worth recording: the analyst had reached `review` and its report was already on disk, so the loss cost a session's context and any revision loop on it, not the document itself.

---

## Part 6 — The unit supervision finding (confirmed, then ruled out of scope)

Recorded because it was confirmed, not because it is actionable here. The requester has ruled the unit out of wingman's scope, so **no fix is proposed and the corresponding issue is closed.**

Verified live while wingman and its tmux server were running normally:

```
$ systemctl --user status <the unit>
● Active: active (exited) since Thu 2026-07-30 04:26:54 UTC; 6min ago
  Process: 540977 ExecStart=/usr/bin/systemd-run --user --scope --collect --quiet -- /usr/bin/tmux new-session …
 Main PID: 540977 (code=exited, status=0/SUCCESS)
 Mem peak: 1.7M

$ cat /sys/fs/cgroup/…/user@1000.service/app.slice/<the unit>/cgroup.procs
cat: …: No such file or directory          <- the unit has no cgroup at all

$ cat /proc/540985/cgroup                   <- the actual tmux server
0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-p540977-i557802.scope
```

The unit tracks **zero** processes. Its `Main PID` is the short-lived `systemd-run` helper, which exited `0` immediately; `Mem peak: 1.7M` is that helper alone. The tmux server lives in a sibling transient scope. The unit is `Type=oneshot`, `RemainAfterExit=yes`, `Restart=no`.

The confirmed consequences, for the host operator's awareness only:

- **`systemctl --user is-active` on it reports `active` whether or not wingman is alive** — a false green for any health check or human relying on it.
- **No `Restart=` policy could work, even if added.** There is no process in the unit that could fail, so `Restart=on-failure` here would be inert. This matters because "just add `Restart=`" is the obvious reading and it does not work on this unit shape.
- **A tmux-server death that leaves the user manager up would go undetected.** Both 07-30 losses also took the user manager down, so login-triggered restart masked this. It would not mask a server-only death.
- **If the `claude` process inside the pane exits**, the orchestrator is gone while the unit still reports `active (exited)`, and any crew still running continue with no supervisor.

The first two are confirmed by the inspection above; the last two are latent and were never observed. All four are properties of a machine-specific unit outside this repository, and none is wingman work.

---

## Part 7 — What remains, and in what order

The fleet-destroying failure is closed at the host level. What is left is ordinary wingman defect work, and the ordering is no longer contested:

1. **[#209](https://github.com/greerviau/wingman/issues/209) — the reconcile blind spot. Now the highest-value fix outright.** It is what made both losses silent, and it is what makes every *future* infrastructure failure — a genuine tmux crash, a host reset, an OOM in a different shape — equally silent. Lingering removes one trigger; it does nothing about the blind spot. Fixing this is what makes such failures recoverable through the path closed issue #22 already built.
   The caution from the original investigation still stands: the fix must distinguish "the crew session does not exist" from "no crew windows are alive anywhere on the server," or it will falsely flag genuinely-live stray windows as `died` and reintroduce #44.
2. **[#185](https://github.com/greerviau/wingman/issues/185) — tokenless watcher auto-arm.** The cause-agnostic remedy for #196, and it also blunts #198's rule conflict. Valuable precisely because it does not require identifying the external trigger.
3. **[#206](https://github.com/greerviau/wingman/issues/206), [#198](https://github.com/greerviau/wingman/issues/198), [#197](https://github.com/greerviau/wingman/issues/197), [#207](https://github.com/greerviau/wingman/issues/207)** — ordinary defects with settled designs recorded in their reports and issues. None has destroyed work.
4. **[#196](https://github.com/greerviau/wingman/issues/196)** — no in-repo fix reaches the harness-owned wrapper. Keep as the evidence record, or close in favour of #185/#189/#198; see Part 4.

### Host-side, for completeness

Nothing further is required. Lingering is applied and verified, and it is the only host setting that mattered. Two notes:

- **Lingering must stay enabled.** It is host state in a root-owned path, not something the repository ships or checks — by the requester's scope call, deliberately so. If this host is ever rebuilt or the user recreated, it must be re-applied or the 01:22/04:05 failure returns exactly as documented.
- **SSH keepalives remain an optional, unnecessary mitigation.** Both losses were triggered by the TCP connection dying rather than a clean logout, so `ClientAliveInterval`/`ServerAliveInterval` would have reduced how often the trigger fired. With lingering enabled this is moot for fleet survival; noted only so it is not rediscovered as a remedy later.

`KillUserProcesses` and `UserStopDelaySec` are both at their defaults and neither was ever the right knob.

---

## Part 8 — The prior analysis documents were uncommitted

**Stated plainly, as originally requested: all three prior post-mortems were untracked in git and had never been committed.** Confirmed against a fresh checkout (`HEAD` already contained `origin/main`):

```
$ git status --short docs/analysis/
?? docs/analysis/2026-07-28-watch-fleet-spurious-deaths-and-dropped-wakes.md
?? docs/analysis/2026-07-29-usage-limit-threshold-latching.md
?? docs/analysis/2026-07-30-tmux-server-death-and-reconcile-blind-spot.md
```

This report was a fourth untracked file in the same directory.

**They should be committed, and the requester has confirmed this is wanted.** Three reasons:

1. **They are the only durable record of these root causes.** The GitHub issues carry summaries, but the full evidence — journal excerpts, reproductions, ruled-out alternatives, the settled design decisions in the 07-29 report — existed only in a working tree on a single host. A host failure would have lost the analysis behind eight issues.
2. **They are load-bearing for the open issues.** #206's recommended fix depends on two decisions recorded only in its report. #209's fix depends on that report's warning about not reintroducing #44. A developer picking up either needs the file.
3. **They are the direct evidence that the recurrence was already diagnosed** — the 07-30 report's recommendation predates the identical 04:05 failure by two hours, which is the central finding of this investigation.

The general problem is filed as **[#175](https://github.com/greerviau/wingman/issues/175)** ("Crew deliverables accumulate untracked in `docs/analysis` and `docs/plans`"), which asks for a *policy*; these four specific files are being committed now regardless of when that policy lands. All four were reviewed for host and address detail first — the one genuinely sensitive item, the requester's workstation IP quoted from the journal, is redacted to `<workstation>` in this report and was already redacted in the 07-30 post-mortem.

---

## Note on publishing — a third instance of #207

This report was initially blocked from publication by `bin/lib/artifact-scan.sh`:

```
fail:matches an internal IP/hostname pattern (RFC1918 address or .internal/.corp/.local hostname)
```

Two separate causes, disclosed here rather than silently worked around:

1. **A genuine match, correctly caught and fixed at source.** Early drafts of the timeline quoted the requester's workstation IP verbatim from the journal. That is real host detail with no analytical value, so it was **redacted to `<workstation>`** — the same treatment the 07-30 post-mortem already uses. This is the scan working as intended.
2. **A false positive, #207 again.** With the IP gone, the scan still failed — on this report's own *description of #207*, which quoted the settings filename that trips `INFRA_RE`'s `.local` alternative. The document contained no IP and no hostname at that point. The description was reworded to convey the same meaning without embedding the literal filenames.

The second point is worth recording as evidence on #207: the defect blocks not only documents that happen to mention a config filename, but any document that *describes the defect itself*. It also demonstrates the practical cost — a `fail:` verdict is deterministic and correctly refuses to publish, so a false positive resolves as either an unpublished deliverable or an author rewording prose around a regex. Nothing sensitive was removed to clear it; the one genuinely sensitive item stays redacted.

---

## Decisions taken

Both open questions raised by this investigation have been decided by the requester. Recorded as settled; no questions remain outstanding.

**`linger-now` — "Enable it now," accepted as recommended.** `loginctl enable-linger greer` has been run on this host and verified (`Linger=yes`, marker present in the linger directory). The fleet-destroying failure mode documented in Part 1 is closed.

**`unit-fix-shape` — none of the three offered options.** The requester's decision, verbatim: *"The system service is a custom thing for this machine, it's not a wingman feature, shouldn't be considered as such, close any issues related to it."* The systemd unit is out of wingman's scope. No in-repo unit, no installer, and no `bin/doctor` linger check is proposed; the two corresponding issues are closed as out of scope. The confirmed findings behind them are preserved in Parts 1 and 6.

**Also confirmed:** committing the three prior post-mortems plus this report, per #175.
