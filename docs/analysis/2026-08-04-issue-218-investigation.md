# Issue #218 investigation: forensics behind the "no root cause" conclusion

**Date:** 2026-08-04
**Mode:** investigation plus instrumentation - no root cause identified; `bin/lib/tmux-guardian.sh` landed as the forensic backstop for the next occurrence.
**Purpose of this document:** the PR built on this investigation asserted four exclusions (a correction to the "zero trace" framing, plus three ruled-out mechanisms) without recording the commands or output behind them. This document supplies that record so the conclusions are independently re-checkable rather than taken on faith.

All commands below were run directly against the host that experienced both incidents (2026-08-02 11:26-11:28 UTC and 2026-08-04 08:02:23 UTC), against `journalctl` boot `-1` (`ce4c30bd7e2b45a29240ef4c3f111233`), which spans both events.

## 1. The "zero journal trace" framing needed correction

Both existing postmortems (`docs/analysis/2026-08-02-fleet-loss-incident-investigation.md`, `docs/analysis/2026-08-04-wingman-session-death-postmortem.md`) treat the absence of a `Stopping`/`Stopped`/`Failed` line for the dying scope as itself anomalous. This is checkable directly: does *any* transient `tmux-spawn-*.scope` on this host ever produce such a line, including ones with no relation to either incident?

```
$ journalctl -b -1 -o short-precise --no-hostname | grep -c "Started tmux-spawn"
36086
$ journalctl -b -1 -o short-precise --no-hostname | grep -c "tmux-spawn.*Consumed"
559
$ journalctl -b -1 -o short-precise --no-hostname | grep -icE "tmux-spawn.*(succeeded|stopped|failed)"
0
```

Zero, out of 559 scope terminations this boot actually produced a "Consumed" (resource-accounting) line - none of them, related to either incident or not, ever show a `Stopping`/`Stopped`/`Succeeded`/`Failed` line. Checking the structured journal fields for one such line (a normal, unremarkable termination) confirms why:

```
$ journalctl -b -1 -o verbose --no-hostname _SOURCE_REALTIME_TIMESTAMP=1785830543545930
...
    PRIORITY=5
    CODE_FILE=src/core/unit.c
    CODE_LINE=2562
    CODE_FUNC=unit_log_resources
    MESSAGE_ID=ae8f7b866b0347b9af31fe1c80b127c0
    CPU_USAGE_NSEC=1398023942000
    MEMORY_PEAK=11591680
    MESSAGE=run-p540977-i557802.scope: Consumed 23min 18.023s CPU time over 5d 3h 35min 29.260s wall clock time, 11M memory peak.
    USER_UNIT=run-p540977-i557802.scope
```

`unit_log_resources` fires unconditionally whenever a scope's cgroup empties - there is no `JOB_RESULT`/`STOP_RESULT` field, no exit-code tracking, nothing that distinguishes a clean self-exit from an external `SIGKILL` sent directly to the pid from a D-Bus `KillUnit` call (which signals without opening a stop job, so it never logs "Stopping" either). This is a genuine limitation of how this systemd version logs scope units, not a property of the two incidents. **Conclusion: "no Stopping line" is not itself evidence of anything unusual about the two deaths - it is how every scope termination looks on this host.** This does not identify the mechanism; it removes a piece of evidence that was never actually discriminating.

## 2. Ruled out: a fatal-signal crash of the tmux server

If the tmux server had crashed via SIGSEGV/SIGILL/SIGBUS/SIGFPE, the kernel's own fault handler would print a `traps:` line via `journalctl -k` - independent of whether a coredump facility is installed. Confirmed this host's kernel does emit these for genuine crashes, unrelated to either incident:

```
$ journalctl -b -1 -o short-precise --no-hostname | grep -iE "core.?dump|segfault|signal|abort|traps:"
Jul 30 16:53:17.274295 kernel: traps: chrome-headless[2075229] trap int3 ip:633733be190a sp:7ffdbde8a730 error:0 in chrome-headless-shell[...]
Jul 31 14:59:41.087870 kernel: traps: druk[831974] trap invalid opcode ip:3caa865 sp:7ffdf5dc6b68 error:0 in druk[...]
...
```

Searching the same boot's kernel log for `tmux` or for either death's timestamp window produces no such line - no `traps:` entry for pid 540985 (the 08-04 orchestrator's tmux server) or for any pid active during the 08-02 window. `coredumpctl` is not installed on this host (`command not found`), so a coredump was never available to check either way, but the kernel-level `traps:` line does not depend on that facility - it is the line that is actually absent.

## 3. Ruled out: resource exhaustion in tmux's own systemd cgroup integration

This host's tmux build is compiled with systemd support:

```
$ tmux -V
tmux 3.6
$ ldd $(which tmux) | grep -i systemd
	libsystemd.so.0 => /usr/lib/x86_64-linux-gnu/libsystemd.so.0 (...)
$ strings $(which tmux) | grep -i "launched by process\|tmux-spawn"
tmux-spawn-%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x.scope
tmux child pane %ld launched by process %ld
```

Every new pane spawn does a D-Bus round trip to wrap it in a `tmux-spawn-*.scope` - a tmux feature, not wingman's own code. If a burst of pane creation exhausted a resource in that path (an fd leak, a D-Bus rate limit) shortly before either death, the pane-creation rate in the minutes immediately before ought to show an anomalous spike relative to an unrelated baseline window. It does not:

```
$ journalctl -b -1 --since "2026-08-04 07:57:00" --until "2026-08-04 08:02:24" -o short-precise --no-hostname | grep -c "Started tmux-spawn"
63
$ journalctl -b -1 --since "2026-08-04 06:00:00" --until "2026-08-04 06:05:00" -o short-precise --no-hostname | grep -c "Started tmux-spawn"
89
$ journalctl -b -1 --since "2026-08-02 11:20:00" --until "2026-08-02 11:28:20" -o short-precise --no-hostname | grep -c "Started tmux-spawn"
6
```

The 5 minutes immediately before the 08-04 death (63 spawns) were *quieter* than an arbitrary unrelated 5-minute baseline (89 spawns); the 08-02 window shows even less activity (6 spawns across 8 minutes). No burst signature either time.

## 4. Ruled out: `systemd-tmpfiles` cleaning the `/tmp` socket

```
$ grep -n "^[a-zA-Z]" /usr/lib/tmpfiles.d/tmp.conf
q /tmp 1777 root root 10d
$ stat /tmp/tmux-1000/default
  Access: 2026-08-04 12:42:16...
```

Default age threshold for `/tmp` cleanup is 10 days; the socket in question was 2-5 days old at either death, comfortably under threshold. This also would not explain the actual finding regardless of age - `systemd-tmpfiles` removing a stale socket *file* does not kill an already-listening process bound to it; the observed teardown is of the scope holding the live process itself (confirmed via matching CPU/memory accounting spanning the process's full multi-day lifetime), not a dangling socket path.

## 5. Noted, unconfirmed: a `systemd --user` re-exec

```
$ journalctl --user -b -1 -o short-precise --no-hostname | grep -iE "reexecut|reload|deserializ"
Aug 01 06:16:46.405220 systemd[540956]: Reexecuting.
```

The user manager underwent exactly one `Reexecuting` event this boot, 1-3 days before either death (`06:16:46` on 08-01; the 08-02 crew-session death and the 08-04 orchestrator death happened on 08-02 and 08-04 respectively). Re-exec/serialization bugs are a known class of systemd defect that can occasionally scramble transient-unit bookkeeping. This is flagged because it is the only irregular systemd-manager-level event found anywhere in the boot's history predating both incidents - but it is not temporally adjacent to either death, so it is recorded as background, not as a finding with any causal claim attached.

## What remains open

No mechanism is identified. What's ruled out narrows the space (not a crash, not tmux's own resource exhaustion, not a stale-socket cleanup, and the log's own silence is uninformative rather than a clue) without closing it. `bin/lib/tmux-guardian.sh` exists because none of the above investigation, however thorough, could be done *after the fact* for a live-forensics question ("what process, if any, is alive during the transition") - only a process external to the dying cgroup, watching in real time, can answer that. The next occurrence's evidence should come from `~/.wingman/tmux-guardian-events.log`, not from another retrospective journalctl dig.
