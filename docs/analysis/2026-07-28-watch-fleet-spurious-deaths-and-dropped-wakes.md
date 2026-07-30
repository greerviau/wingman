# Watch-fleet reliability incident: repeated spurious deaths and dropped wakes (2026-07-28)

## Summary

Two symptoms were reported against `bin/watch-fleet` on 2026-07-28: (A) wingman's own
top-level cycle died four times in ~10 minutes with the classify hint
`clean-exit-or-sigterm`, and (B) a lead's own cycle (`clear-the-atrium-github-issue-bo-lead`)
logged six `dropped-wake fire` entries spread across the day. A third question was
whether `.claude/commands/watch.md`'s "do not re-arm after `spurious-repeated`" rule
and `hooks/stop-guard.sh`'s "no live watcher → arm one now" rule deadlock, and whether
that is by design.

Findings, in brief:

- **A and B are different root causes.** A is a real, repeated, external termination of
  the watched process with no self-inflicted trigger found anywhere in the fleet's own
  tool-call history. B is not a process death at all — every one of the lead's cycles
  exited normally on a genuine event; the lead's own turn-taking simply never paired the
  resulting wake with the mandatory `--classify` call before re-arming, because a
  concurrently arriving message pulled its attention away first.
- **The rule conflict is real and already happened, verbatim, in the live transcript** —
  not a hypothetical. It is a genuine, unaddressed gap, not a considered design
  tradeoff: `hooks/stop-guard.sh` has no knowledge of the spurious-failure budget at all.
- A's most likely mechanism (well-supported, not conclusively proven down to the exact
  trigger) is an out-of-band signal from the Claude Code harness's own background-task
  lifecycle handling reaching the tracked wrapper shell — the same SIGURG-class hazard
  `bin/watch-fleet`'s own header comment already anticipated, but whose existing
  mitigation (`trap '' URG`) cannot reach the harness-owned wrapper process.

Everything below states plainly what was **proven** (direct log/transcript/reproduction
evidence) versus **inferred** (the best-supported explanation once every provable
alternative was ruled out).

## Symptom A: repeated watcher death (`clean-exit-or-sigterm`)

### What "clean-exit-or-sigterm" means mechanically

In `bin/watch-fleet --classify` (`bin/watch-fleet:359-437`), the classification order is:

1. `bin/watch-fleet:372-382` — if `$EXITFILE` exists, trust it, print its recorded
   outcome (`fire`/`healthy`/`stopped`/`remote-control-dropped`), reset the
   per-owner spurious-failure counter, done.
2. `bin/watch-fleet:384-388` — else, if a live cycle exists (`cycle_live`: pidfile names
   a live pid **and** the beacon is fresh), that's `healthy`.
3. `bin/watch-fleet:389-412` — else, genuinely spurious: nothing to trust, nothing
   live. The forensic hint is picked here:
   - `stale-claim-lock` if the claim-lock directory is still present (`:397-398`)
   - **`clean-exit-or-sigterm` if `$PIDFILE` is simply absent** (`:399-400`)
   - `sigkill-suspected` if `$PIDFILE` names a pid that is dead (a `SIGKILL` cannot run
     the cleanup trap, so the pidfile survives its own process) (`:402-406`)
   - `hung-or-stale-pidfile` if the pidfile's pid is alive but the beacon is stale
     (`:407-410`)

`$PIDFILE` is removed in exactly three places in this script: the `--stop` path
(`:446-457`), the run-id-mismatch "foreign cycle" replacement path (`:613-630`,
discussed and ruled out below), and the script's own signal trap,
**`trap 'rm -f "$PIDFILE"; exit 0' INT TERM` (`bin/watch-fleet:664`)**. `clean-exit-
or-sigterm` specifically means: no exit record was ever written (so it wasn't a
"real" fire/outage/usage event, all of which write `$EXITFILE` before removing
`$PIDFILE`), and the pidfile is gone — which, once `--stop` and the run-id-mismatch
path are ruled out, leaves "the process's own `INT`/`TERM` trap fired" as the only
mechanism left standing. This is consistent with, but does not by itself prove,
literal signal delivery — see below for direct confirmation that it was exactly that.

### What was ruled out, with direct evidence

- **Manual `bin/watch-fleet --stop`**: not run. The classify outcome would have been
  the literal token `stopped` (`:446-457`), never seen in this cluster; the human
  directive also confirmed this wasn't done.
- **A `kill $$` self-target from something in the same run** (the run-id-mismatch
  "foreign cycle" kill at `bin/watch-fleet:613-630`): requires two arms with
  *different* `$WINGMAN_RUN_ID` values racing over the same pidfile. Checked directly:
  `~/.wingman/watch.run` and `ps` both confirm a single, unbroken wingman process
  (pid 14095, started 06:38 UTC, still running) — one continuous session, one stable
  `$WINGMAN_RUN_ID` the entire time. This kill path cannot fire against itself.
  `journalctl --user` shows exactly one `wingman.service` start (06:38:31), no restarts.
- **An explicit `kill`/`pkill`/`tmux kill-*`/`TaskStop` from *any* session on the whole
  fleet** during the incident window (17:15–17:33 UTC): checked by grepping every
  session transcript under `~/.claude/projects/-home-greer-*/*.jsonl` for tool calls
  containing `kill`, `pkill`, `TaskStop`, or `tmux kill` in that window. The only hits
  were false positives (the word "kill" appearing inside this investigation's own
  objective text). Wingman's own transcript
  (`~/.claude/projects/-home-greer-github-wingman/b03e5bd5-c8a1-45fd-9e97-583de2a7ec7d.jsonl`)
  independently confirms it never called `TaskStop` (only `AskUserQuestion`, `Bash`,
  `Read`, `Skill`, `Write` appear as tool names anywhere in it) and never ran a
  `kill`/`pkill` command.
- **OOM kill / systemd scope teardown**: `dmesg -T` and `journalctl -k` show no OOM
  events; `journalctl --user` shows no start/stop for
  `tmux-spawn-664a91bc-9734-4123-bcb5-a4df1834916f.scope` (the cgroup scope actually
  containing wingman's `claude` process and its `watch-fleet` children) anywhere near
  the incident window. `free -h` shows ample memory headroom at investigation time.
  `systemd-oomd` is not even installed on this host.

### Direct transcript evidence of the actual sequence

Reading wingman's own transcript directly (timestamps UTC) shows five arm/classify
cycles back to back, each following `/watch`'s contract exactly (classify first, then
re-arm) — i.e. wingman was never the one skipping steps:

| Armed at | Bg task id | Notified at | Delta | Classify result |
|---|---|---|---|---|
| 17:20:25 | `bnl3zw5mh` | 17:22:27 | ~122s | `spurious 1 clean-exit-or-sigterm` |
| 17:22:35 | `bqpvm9pf0` | 17:24:57 | ~142s | `spurious 2 clean-exit-or-sigterm` |
| 17:25:04 | `bmwnttasa` | 17:26:17 | ~73s  | `spurious-repeated 3 clean-exit-or-sigterm` |
| 17:26:52 | `b8xkc6bsq` | 17:30:03 | ~191s | `spurious 1 clean-exit-or-sigterm` (budget had just reset) |
| 17:30:55 | `b6vy9v3m1` | (still alive at investigation time) | | |

The irregular deltas (73–191s, no fixed period) argue against a periodic host cron/
timer as the trigger and are consistent with something environmental/intermittent
rather than a deterministic timeout. The fifth cycle (armed 17:30:55, pid `1748873`)
was confirmed alive and healthy throughout this investigation (survived 15+ minutes of
ordinary idle waiting with no further death) — the failure was a transient cluster, not
an ongoing condition.

### Reproduction

A minimal probe (`sigwatch.sh`) was armed the same way `bin/watch-fleet` arms itself —
via the `Bash` tool's `run_in_background`, in this investigating session, against an
isolated scratch directory (no shared state with the real fleet). It trapped every
trappable signal and looped a 5-second heartbeat, exactly mirroring `watch-fleet`'s own
blocking-loop shape.

- **Left alone**, it ran cleanly for 15+ minutes with zero anomalies — this rules out
  "this environment routinely kills idle background bash tasks" as a general
  explanation; ordinary idle waiting is not, by itself, sufficient to reproduce the
  failure.
- **When deliberately killed** (`pkill -f sigwatch.sh`, sent as an ordinary `SIGTERM`),
  something notable surfaced: the probe's own child process caught `TERM` exactly as
  expected (logged `CAUGHT TERM`), but the *outer wrapper* process — the actual
  harness-tracked background task, analogous to `bin/watch-fleet`'s own
  `bash -c ... eval bin/watch-fleet ...` wrapper (pid `1748794` in the real fleet) — was
  reported by the harness as **failed with exit code 144**, i.e. `128 + 16` = terminated
  by **`SIGURG`** (signal 16), not the `SIGTERM` (15, which would be exit 143) that was
  actually sent.

This is the same hazard `bin/watch-fleet`'s own header comment already documents and
defends against, in its own words (`bin/watch-fleet:123-133`):

> "a stray SIGURG that reaches it terminates the process (exit 144 = 128+16) and
> silently ends that session's turn ... the background-launch environment can hand the
> process a non-default disposition"

`bin/watch-fleet:133` mitigates this with `trap '' URG` — but that trap is set inside
the **script process itself** (the child, analogous to pid `1748873`). It cannot reach
the **wrapper shell** the harness generates and tracks (analogous to pid `1748794`),
because that wrapper is not code this repo owns or can add a trap to. If the harness's
own background-task lifecycle bookkeeping delivers this same `SIGURG`-class signal to
the tracked wrapper — for reasons internal to the harness, not driven by any command
this investigation could find in any session's transcript — the wrapper's exit is what
the harness reports as the background task completing, and (through whatever exact
mechanism connects the two, not independently re-confirmed here) the actual
`watch-fleet` script under it also goes down, cleanly, through its own `INT`/`TERM`
trap — matching `clean-exit-or-sigterm` precisely.

### Conclusion (A)

**Best-supported inference:** an out-of-band signal from the Claude Code harness's own
background-task lifecycle/cancellation handling — consistent with `SIGURG`, and
matching a hazard this exact file already anticipated for its own process but cannot
extend to the harness-owned wrapper — is what repeatedly ended these cycles. Every
self-inflicted, repo-code-level alternative (manual kill, `TaskStop`, run-id-mismatch
self-kill, `--stop`, OOM, cgroup/scope teardown) was checked directly and ruled out.
**Not proven:** the exact trigger condition that caused this to cluster specifically in
this ~10-minute window rather than at other times — this was not reproducible on
demand from ordinary idle waiting alone, only once this investigation deliberately sent
an external signal to a same-shaped analog process.

## Symptom B: dropped-wake

### What "dropped-wake" means mechanically, and exactly when it's recorded

At claim time — the moment a fresh `bin/watch-fleet` arm successfully takes ownership of
`$PIDFILE` after passing the singleton guard (i.e. no live cycle currently holds it) —
`bin/watch-fleet:658-661` runs:

```sh
if [ -f "$EXITFILE" ]; then
  spurlog dropped-wake "$(cat "$EXITFILE" 2>/dev/null)"
  rm -f "$EXITFILE"
fi
```

The **only** code path that legitimately consumes `$EXITFILE` is `--classify`
(`:372-382`), which reads it, reports its outcome, and deletes it. If a *bare* arm
(`bin/watch-fleet`, no `--classify`) is invoked while a previous cycle's exit record is
still sitting there unconsumed, the claim step above discovers it, logs it as
`dropped-wake <detail>` (`<detail>` is whatever outcome was recorded — every observed
instance here was `fire`), and discards the file. This is precisely: **a wake actually
happened, but nothing ran `--classify` on it before the next arm silently overwrote the
evidence.**

### Direct transcript evidence for the mechanism (verified against one occurrence)

The lead's transcript
(`~/.claude/projects/-home-greer-github-atrium/142320d9-2e8b-4d76-8c8f-708999c37bd3.jsonl`)
was read directly for the `07:02:55Z` `dropped-wake fire` entry — the exact second the
lead's arm command was sent matches the log timestamp to the second. Tracing backward:

- `06:53:51Z` — lead arms watch-fleet (background task `bhb2davdu`).
- `07:01:44Z` — task-notification for `bhb2davdu` arrives (~8 minutes later — a genuine
  fire, not a redundant near-instant "healthy" exit).
- `07:01:50Z` — **before the lead ever reads `bhb2davdu`'s output or calls
  `--classify`**, an unrelated, concurrently-arriving `crew-ask` message from its own
  `toolchain-validation-only-do-not-developer` worker interrupts. The lead follows that
  thread to completion: reads the message, replies to the ask, checks the roster,
  stands the worker down, spawns a new reviewer, updates its own status.
- `07:02:55Z` — only once the lead reaches its own "arm one fresh cycle before ending
  the turn" step does it call `bin/watch-fleet` again — and *that* claim discovers
  `bhb2davdu`'s still-unconsumed exit record (written when it fired at 07:01:44) and
  logs it as `dropped-wake fire`.

The lead never went back and ran `--classify` against `bhb2davdu` specifically — it
moved on once the competing thread was resolved.

This is **not** "the lead doesn't know to classify": across its ~64 watch-fleet cycles
this session, it explicitly reads `.claude/commands/watch.md` (confirmed via a literal
`cat` of that file in its own transcript) and correctly calls `bin/watch-fleet
--classify` 57 times. The gap is a **race between two asynchronous event sources** — a
watch-fleet task-notification and an incoming crew message — that happened to arrive
close together; whichever the agent's own turn-taking latches onto first can run to its
natural conclusion before the other is ever paired with its required follow-up action,
and nothing anywhere enforces that pairing. The other five `dropped-wake` entries in
the log were not individually re-traced to this level of detail, but they share the
identical structural precondition (a `fire` outcome recorded, then a bare re-arm before
`--classify` ever runs against it), so the same class of race is the most likely
explanation for all six.

Two contributing gaps worth naming precisely:

1. **The wake file's own text never mentions `--classify`.** `fire()`'s payload
   (`bin/watch-fleet:780-787`, written to both `$WAKEFILE` and stdout) ends with "Then
   arm one fresh watch-fleet cycle before you stop" — it does not say `--classify` must
   run first. Only `.claude/commands/watch.md` (a *separate* file) states that
   ordering requirement. A reader who acts on the task's own output/wake-file content
   directly — which is exactly the designed use of that content — has no signal in
   that content that skipping `--classify` has this consequence.
2. **Only `--classify` resets the per-owner spurious-failure counter**
   (`bin/watch-fleet:655-657`'s own comment states this explicitly: "the count file's
   only three writers are inside `--classify`"). A dropped-wake also means that
   counter goes untouched by the cycle in question — not itself observed to have caused
   a problem here (there are zero `spurious` entries logged for this lead, consistent
   with it simply never taking the `--classify` branch on these particular occasions),
   but it is a latent inconsistency in the failure-budget accounting for any owner that
   experiences both a real transient death and this race in close succession.

### Are A and B the same root cause?

**No.**

- **A**: wingman's own top-level `watch-fleet` process was genuinely, repeatedly
  terminated — a real external kill, most likely an out-of-band harness signal, with
  zero self-inflicted trigger found anywhere in the fleet's tool-call history.
- **B**: the lead's own `watch-fleet` cycles were **never killed**. Each one exited
  completely normally via a genuine crew event. The lead's own agent behavior simply
  failed to pair the resulting notification with `--classify` before its next re-arm,
  because a concurrently-arriving message consumed its attention first.

They share only a structural similarity — both are instances of "an exit record's value
depends entirely on something running `--classify` before the next arm clobbers it" —
but the *event that breaks that invariant* is different in kind: an external kill in A,
an agent-side scheduling race in B.

## The rule conflict: `spurious-repeated` (don't re-arm) vs. stop-guard (arm now)

This was directly observed happening, not merely theorized. From wingman's own
transcript:

- **17:26:22Z** — `bin/watch-fleet --classify` returns `spurious-repeated 3
  clean-exit-or-sigterm` (the third consecutive death, hitting the failure budget).
- **17:26:43Z** — wingman states: *"Fleet supervision has stopped and I'm not
  re-arming it."* — correctly following `.claude/commands/watch.md:61-67`'s explicit
  instruction: *"Do not proceed to step 2"* (i.e., do not re-arm), framed at
  `watch.md:107-109` as *"a third, deliberate reason to skip this step — not a race,
  but a refusal to keep re-arming a watcher that has just demonstrated it cannot stay
  up."*
- **Same turn, 17:26:43Z** — the Stop hook fires back: *"Stop hook feedback: You have
  crew in flight but no live watcher cycle. Arm one by running 'bin/watch-fleet' as a
  harness-tracked background task so its exit wakes you when crew need you, then you
  may stop."* — this is `hooks/stop-guard.sh:155-157` firing unconditionally, exactly
  as written.
- **17:26:52Z** — wingman narrates the override explicitly: *"The stop guard requires a
  live cycle, so I'm arming one despite the failure budget — that's a deliberate
  override of the 'don't re-arm' rule, not me forgetting it."* — and re-arms.

**Verdict: this is a genuine, unaddressed gap, not a deliberate design tradeoff.**
`hooks/stop-guard.sh` contains zero references to the spurious-count file or the
failure budget anywhere (confirmed by grepping the file directly) — its "no live
watcher" branch (`:148-157`) has exactly one unconditional exit: if `active_crew > 0`
and `watcher_up == 0`, demand an arm, full stop. Nothing in this hook's own (otherwise
quite thorough) design commentary — which covers its two-pass state machine, the
`SCRATCH`/ack mechanics, and the run-id-scoped pidfile/beacon check in real detail —
ever mentions or carves out an exception for the `spurious-repeated` state. Symmetrically,
`.claude/commands/watch.md`'s own text gives no guidance for what a caller should do
about the Stop hook's competing demand once `spurious-repeated` has fired; it says to
report the state to the pilot and stop there, implicitly assuming supervision will
somehow be re-established, without addressing that the Stop hook will not let that very
reporting turn end without arming again anyway. The entire purpose of the failure
budget — refusing to keep re-arming something that just proved it cannot stay up — is
defeated by force the first time it trips while any crew is in flight, which, given
wingman routinely runs crew, is effectively always.

**Related but distinct prior art:** issue #67 ("Root-cause the stuck stop-hook loop
incident") investigated a similarly-shaped stop-guard/re-arm interaction on
2026-07-15 and was closed as not-reproduced, but only against two specific narrower
hypotheses: (1) a defect in `stop-guard.sh`'s own two-pass state machine, and (2) a
"healthy" redundant-arm outcome being misread by a caller as needing a further arm
attempt. Neither of those is the interaction found here — this is a **third**,
previously untested case: a legitimate, deliberate refusal to re-arm (`spurious-
repeated`) colliding with a Stop-hook guard that has no way to recognize that refusal
as legitimate. Issue #67's closure does not cover this gap.

## Suggested direction (not implemented — report mode)

- **Rule conflict**: `hooks/stop-guard.sh`'s "no live watcher" branch (`:155-157`)
  should consult the same per-owner spurious-count file `bin/watch-fleet` already
  maintains (`$WM_HOME/watch-spurious-count[-<owner>]`) and soften or skip its demand
  once that owner is at/past the budget — otherwise the failure budget can never
  actually take effect while any crew is in flight, which defeats its stated purpose.
- **Symptom B**: state the `--classify`-before-anything-else requirement directly in
  the wake file's own body text (`bin/watch-fleet:780-787`), not only in the separate
  `.claude/commands/watch.md` skill file — so a reader acting on the task output/wake
  file content directly (a normal, designed-for path) sees the ordering rule in the one
  place guaranteed to be read. Consider also surfacing a dropped record's content back
  into the *next* successful `--classify`/roster read (e.g. "note: an earlier `fire` was
  dropped, its content was: ...") so a race doesn't erase the forensic trail even when
  the substance was already seen through another channel.
- **Symptom A**: no code fix in this repo can reach the harness-owned wrapper process
  directly. Worth raising with the harness itself (attach the `sigwatch.sh`
  reproduction and its exit-144 finding as supporting evidence) as a question about
  background-task lifecycle signal behavior. Independent of root cause, making the
  rule-conflict fix above land would at least stop a real external kill cluster from
  also taking down the pilot's ability to get a clean status report while it's
  happening.

## What was proven vs. inferred — quick reference

| Claim | Status |
|---|---|
| `clean-exit-or-sigterm` means "no exit record, no live cycle, pidfile absent" | Proven (direct code read, `bin/watch-fleet:397-400`) |
| `dropped-wake` fires exactly when claim-time finds a stale, unconsumed `$EXITFILE` | Proven (direct code read, `bin/watch-fleet:658-661`) |
| Wingman ran a single, unbroken session/run-id throughout the incident | Proven (`ps`, `watch.run`, `journalctl --user`) |
| No session on the fleet ran `kill`/`pkill`/`TaskStop`/`tmux kill` in the incident window | Proven (transcript grep across every live session) |
| No OOM kill or systemd scope teardown occurred in the window | Proven (`dmesg`, `journalctl -k`, `journalctl --user`) |
| The stop-guard/spurious-repeated deadlock actually occurred | Proven (direct transcript quotes, timestamped) |
| `hooks/stop-guard.sh` has no awareness of the spurious budget | Proven (grep of the file) |
| The lead's 07:02:55 dropped-wake was caused by a crew-ask interrupt preempting `--classify` | Proven for this one occurrence (transcript trace) |
| The same race explains the other five dropped-wake entries | Inferred (same structural precondition, not individually re-traced) |
| Symptom A's proximate trigger is an out-of-band harness signal (SIGURG-class) to the tracked wrapper | Inferred (matches this file's own documented SIGURG concern; directly reproduced an exit-144 signature on an analogous wrapper under deliberate kill, but the *spontaneous*, undriven trigger during ordinary idle waiting was not reproduced on demand) |
| A and B share a root cause | Ruled out — different mechanisms (external kill vs. agent-side scheduling race) |
