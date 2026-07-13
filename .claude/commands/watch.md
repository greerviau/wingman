---
description: Process one watch-fleet wake and arm the next cycle
allowed-tools: Bash(bin/watch-fleet:*), Bash(bin/crew-list:*), Read(~/.wingman/wake)
---

Scoped to wingman's own top-level session only (owner `""`, the bare
`~/.wingman/wake` path) - not for a lead's own watcher.

1. **If I was just woken because a `watch-fleet` background task I armed
   completed:** run `bin/watch-fleet --classify` (bare - no stdin, no pipe)
   and act on the single-line result:
   - `healthy` - a cycle is already live. Do nothing further: no report, no
     log, no re-arm. End the turn.
   - `fire` - a genuine crew event. Read `~/.wingman/wake` (or run
     `bin/crew-list` as the documented fallback) for the full roster, report
     a compact status to the pilot exactly as CLAUDE.md's "Report" step
     specifies, then proceed to step 2.
   - `remote-control-dropped` - my own Remote Control connection dropped.
     Relay `~/.wingman/wake`'s message to the pilot immediately (run
     `/remote-control` to restore it), then proceed to step 2.
   - `spurious <count> <hint>` - one transient death, not yet at the failure
     budget. Report nothing to the pilot (nothing about the fleet actually
     changed), then proceed to step 2 immediately.
   - `spurious-repeated <count> <hint>` - the watcher has died `<count>`
     times in a row with no successful cycle in between; fleet supervision is
     not being maintained. **Do not proceed to step 2.** Report this to the
     pilot as a genuine attention event: *"the watcher for this session has
     died `<count>` times in a row with no successful cycle in between (see
     `~/.wingman/watch-spurious.log`); fleet supervision is not being
     maintained."* Then append a remedy chosen from `<hint>`, the third field
     on this same outcome line (no separate file read needed):
     - `stale-claim-lock`: *"A stale claim-lock directory
       (`~/.wingman/watch.pid.lock`) is blocking every arm attempt - remove it
       (e.g. `rmdir` that directory, after confirming no genuine
       `watch-fleet` arm is concurrently in progress) before resuming;
       re-arming alone will not succeed. This is a known bug - the lock is
       supposed to self-clear after 50 failed attempts and does not (see
       issue #74)."*
     - any other hint (`sigkill-suspected` / `clean-exit-or-sigterm` /
       `hung-or-stale-pidfile`): *"Resume it by running `/watch` again or
       arming `bin/watch-fleet` directly."*
2. **Arm one fresh cycle, but only if none is already live and the failure
   budget was not just exceeded.** The `healthy` branch above already
   short-circuits before reaching this step, and `bin/watch-fleet`'s own
   singleton claim-then-check is atomic regardless, so arming here is always
   safe to *attempt* even under a race. `spurious-repeated` is a third,
   deliberate reason to skip this step - not a race, but a refusal to keep
   re-arming a watcher that has just demonstrated it cannot stay up.
3. End the turn once armed (or once step 1 concluded no re-arm is
   warranted). Never call `/watch` twice in the same turn, and never bundle
   its arm onto the tail of another command.

If I was **not** just woken by a completed background task (e.g. this is the
very first arm of a fresh run, with nothing yet to classify), skip step 1
entirely and go straight to step 2.
