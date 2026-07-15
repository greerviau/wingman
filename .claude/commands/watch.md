---
description: Process one watch-fleet wake and arm the next cycle
allowed-tools: Bash(bin/watch-fleet:*), Bash(bin/crew-list:*), Read(~/.wingman/wake*)
---

1. **If I was just woken because a `watch-fleet` background task I armed
   completed:** run `bin/watch-fleet --classify` (bare - no stdin, no pipe)
   and act on the single-line result. Throughout, "the owner-scoped wake
   file" means `~/.wingman/wake` for wingman's own top-level cycle,
   `~/.wingman/wake-<key>` for a lead's own cycle - `bin/watch-fleet
   --classify` and `bin/crew-list` already self-scope via
   `$WINGMAN_CREW_ID` (empty for wingman, the lead's own id for a lead), so
   nothing extra needs passing; run them exactly as shown, unchanged, from
   either kind of session.
   - `healthy` - a cycle is already live. Do nothing further: no report, no
     log, no re-arm. End the turn.
   - `fire` - a genuine event for your own crew. Read the owner-scoped wake
     file (or run `bin/crew-list`, which self-scopes the same way) for the
     full roster, then act on it per **your own** report/roll-up contract -
     wingman's own top-level session reports a compact status to the pilot
     exactly as CLAUDE.md's "Report" step specifies; a lead instead rolls the
     event into its own `summary` and escalates only a genuine decision, per
     `playbooks/common/lead.md`'s absorb-and-roll-up discipline to its owner -
     then proceed to step 2.
   - `remote-control-dropped` - **wingman's own top-level session's** Remote
     Control connection dropped. This outcome is only ever produced for the
     owner `""` cycle: `self_pane_check()` in `bin/watch-fleet` gates on
     `[ -z "$OWNER" ] || return 1` before it ever reads `$WM_HOME/self-pane`,
     so a lead's own cycle (non-empty `$WINGMAN_CREW_ID`) can never see this
     outcome - if you are a lead, this case does not apply to you and needs no
     action. If you are wingman's own top-level session, relay the wake
     file's message to the pilot immediately (run `/remote-control` to
     restore it), then proceed to step 2.
   - `stopped` - the last cycle ended via a deliberate `bin/watch-fleet
     --stop` (manual/testing use only), not a failure. Report this once,
     plainly ("the watcher was intentionally stopped and is not currently
     armed"), then **do not proceed to step 2** - do not auto-re-arm. A human
     (or this session, deliberately) re-arms it when ready, exactly as
     `--stop`'s own contract in CLAUDE.md already requires.
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
     - `stale-claim-lock`: *"A claim-lock directory
       (`~/.wingman/watch.pid.lock`) is blocking every arm attempt.
       `watch-fleet` already self-clears a lock left behind by a killed
       process once it is old enough and provably ownerless (issue #74) - so
       a lock that is still here and still causing repeated failures was
       deliberately left alone: either it is too young to trust as abandoned,
       or its stamped owner pid is alive and has not yet crossed the
       hard-stale-age threshold. Recovering means finding that live process,
       not deleting the directory out from under it: read
       `~/.wingman/watch.pid.lock/owner` for its pid and check whether that
       process is a genuinely wedged `watch-fleet` arm (the lock is meant to
       be held for well under a second) - if so, it needs attention (or
       killing) before re-arming will succeed. Removing the lock while its
       owner is still alive risks two watchers racing to write
       `~/.wingman/watch.pid` at once, which is exactly what this lock exists
       to prevent."*
     - any other hint (`sigkill-suspected` / `clean-exit-or-sigterm` /
       `hung-or-stale-pidfile`): *"Resume it by running `/watch` again or
       arming `bin/watch-fleet` directly."*

   **`healthy` and `spurious` mean literally zero characters of chat output
   this turn - not even a one-line acknowledgment.** "Nothing to report"
   means producing no message, not producing a message that says there is
   nothing to report. Never say things like "Watcher armed.", "Watcher
   re-armed (transient blip, nothing to report).", or "Re-arming, all
   quiet." on either of these two outcomes specifically - silently arm the
   next cycle (step 2) and end the turn with no text output at all. This is
   a hard rule, not a style preference: `healthy` and `spurious` carry no
   new information for the pilot, so any acknowledgment - however short -
   is itself the mechanics leak CLAUDE.md's Report-altitude rule forbids.
   This does not extend to `fire`, `stopped`, `remote-control-dropped`, or
   `spurious-repeated`, which already report by design per the bullets
   above.
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
