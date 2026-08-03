---
description: Process one watch-fleet wake and arm the next cycle
allowed-tools: Bash(bin/watch-fleet:*), Bash($WINGMAN_BIN/watch-fleet:*), Bash(bin/crew-list:*), Read(~/.wingman/wake*)
---

1. **If I was just woken because a `watch-fleet` background task I armed
   completed:** run `$WINGMAN_BIN/watch-fleet --classify` (bare - no stdin, no pipe)
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
     `playbooks/common/lead.md`'s absorb-and-roll-up discipline to its owner.
     **If the reason line contains any of these, read
     `docs/runbooks/incidents.md` and follow that reason's procedure before
     reporting anything** - each has a specific response the generic roster
     report gets wrong:
     `stalled` · `correlated:mass-death` · `correlated:api-outage` ·
     `correlated:api-outage-death` · `outage-detected` · `outage-cleared` ·
     `usage-limit-approaching` · `usage-limit-reset`.
     Every other reason needs no extra read. (The last five are produced by
     wingman's own top-level cycle only, so a lead never sees them.)
     Then proceed to step 2.

     Under `direct_spawn_visibility=summary-only`, the roster report is itself
     an instance of wingman's Report step, not a separate mandate: a wake
     caused solely by an absorbable round of a direct revise loop produces no
     roster report at all - just proceed to step 2 and end the turn silently.
   - `remote-control-dropped` - **wingman's own top-level session's** Remote
     Control connection dropped. This outcome is only ever produced for the
     owner `""` cycle: `self_pane_check()` in `bin/watch-fleet` gates on
     `[ -z "$OWNER" ] || return 1` before it ever reads `$WM_HOME/self-pane`,
     so a lead's own cycle (non-empty `$WINGMAN_CREW_ID`) can never see this
     outcome - if you are a lead, this case does not apply to you and needs no
     action. If you are wingman's own top-level session, relay the wake
     file's message to the pilot immediately and explicitly - e.g. "Remote
     Control disconnected on this session; run `/remote-control` to restore
     it" - then proceed to step 2. A *crew member's* own dropped connection
     is different and needs no pilot action: `bin/watch-fleet` recovers it
     automatically and never surfaces it unless the automatic retry is
     itself failing.
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
       arming `$WINGMAN_BIN/watch-fleet` directly."*

   **`healthy` and `spurious` mean literally zero characters of chat output
   this turn - not even a one-line acknowledgment.** "Nothing to report"
   means producing no message, not producing a message that says there is
   nothing to report. Never say things like "Watcher armed.", "Watcher
   re-armed (transient blip, nothing to report).", or "Re-arming, all
   quiet." on either of these two outcomes specifically - just do what that
   outcome's bullet above says (arm the next cycle for `spurious`; end the
   turn with no re-arm for `healthy`) and produce no text output at all.
   This is a hard rule, not a style preference: `healthy` and `spurious`
   carry no new information for the pilot, so any acknowledgment - however
   short - is itself the mechanics leak CLAUDE.md's Report-altitude rule
   forbids. This does not extend to `fire`, `stopped`, `remote-control-dropped`,
   or `spurious-repeated`, which already report by design per the bullets
   above.
2. **Arm one fresh cycle, but only if none is already live and the failure
   budget was not just exceeded.** Arm it as a Bash call with
   `run_in_background: true`, on its own - not bundled onto another
   command: `$WINGMAN_BIN/watch-fleet` (or, for a lead, the same invocation,
   which self-scopes via `$WINGMAN_CREW_ID`) - cwd-independent, unlike a bare
   `bin/watch-fleet` (issue #214); `$WINGMAN_BIN` is exported for you by
   `bin/wingman` (or, for a lead, by `bin/spawn-crew`/`bin/crew-resume`). If
   `$WINGMAN_BIN` is unset (this session was started by running `claude`
   directly rather than via `bin/wingman`), fall back to `bin/watch-fleet`
   resolved relative to this repo's own root. **Never foreground, and never
   detached** (`nohup`, `setsid`, a trailing `&`) - `bin/watch-fleet` blocks
   until an event fires, so any way of running it other than as a
   harness-tracked background task wedges this session indefinitely, invisible
   to the stall detector (issue #202; a mechanical guard,
   `hooks/no-foreground-watcher-guard.sh`, denies the foreground and detached
   forms at the tool-call boundary, but do not rely on the guard - state the
   invocation correctly the first time). **If you cannot arm it as a
   background task, arm nothing** - no watcher at all is strictly better than
   a foreground one, because a missing watcher is recoverable and a wedged
   session is not. The `healthy` branch above already
   short-circuits before reaching this step, and `bin/watch-fleet`'s own
   singleton claim-then-check is atomic regardless, so arming here is always
   safe to *attempt* even under a race. `spurious-repeated` is a third,
   deliberate reason to skip this step - not a race, but a refusal to keep
   re-arming a watcher that has just demonstrated it cannot stay up. If this
   arm instead fails with "refusing to arm - an unclassified ... record is
   still pending" (issue #197), step 1 was skipped or its result was never
   acted on: run `$WINGMAN_BIN/watch-fleet --classify`, act on what it
   reports, then retry this arm - the record and the wake file are both left
   untouched by the refusal, so nothing is lost by classifying late.
   **After arming, confirm it actually launched** (a live pid) before
   treating the cycle as armed - `hooks/stop-guard.sh`'s
   `active_crew > 0 && watcher_up == 0` branch is the existing backstop for a
   failed arm, by design rather than coincidence.
3. End the turn once armed (or once step 1 concluded no re-arm is
   warranted). Never call `/watch` twice in the same turn, and never bundle
   its arm onto the tail of another command.

If I was **not** just woken by a completed background task (e.g. this is the
very first arm of a fresh run, with nothing yet to classify), skip step 1
entirely and go straight to step 2.
