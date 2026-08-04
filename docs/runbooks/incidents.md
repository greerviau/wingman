# Incident runbooks: what to do on a specific fire reason

The per-reason response procedures for a `watch-fleet` fire. `/watch` routes
here by reason; everything else about handling a fire (read the wake file,
report per your own contract, then arm the next cycle) lives in `/watch`
itself and is unchanged by anything below.

Reasons marked **wingman-only** are produced by wingman's own top-level cycle
(owner `""`) alone - the outage and usage-limit state machines are tracked
there and nowhere else - so a lead never sees them. The detection mechanics
behind these events are documented in
[fleet-resilience.md](../fleet-resilience.md); this file is only the response.

### `stalled`

Three distinct mechanisms produce this fire, and they differ on the one thing
that matters for your response - whether a nudge was already sent and a
self-heal window already ran:

1. **The nudge-gated liveness stall** (`cmd_stall_check`) - no pane output, no
   status update, no running child process, for the idle window. The
   mechanical layer sends one check-in nudge and waits a full cooldown before
   this fire reaches you, **and it retries until the submit is confirmed, up
   to `WM_STALL_NUDGE_TRIES` attempts.** The reason text tells you which
   happened:
   - If it reads `even after a check-in nudge`, the nudge was **confirmed
     delivered** and the member ignored it for a full window. Do not send
     your own nudge and do not wait again.
   - If it reads `the submit was never confirmed`, the member's input is
     **not reachable** - a nudge of your own is unlikely to land either. Go
     straight to `bin/crew-takeover <id>`; this is the one `stalled` shape
     where sending a message is close to futile. The watcher has *attempted*
     a best-effort clear of the stray nudge text from its composer, but that
     clear is sent and never verified, so check the pane when you attach
     rather than assuming it is clean.
2. **The probe-free structural forward-motion stall** (`cmd_forward_motion_check`,
   issue #199) - a lead (or sub-lead) whose own roster shape (its
   `summary`/`blocker`/`artifact`/`delivery`, plus every active report's
   status/announced) hasn't changed for `WM_FORWARD_MOTION_SECS` despite it
   still reporting `working`. **No nudge is sent first** - this flips directly,
   with no liveness signal to nudge in the first place (the session may be
   actively orchestrating, just making no forward progress on its roster).
3. **The probe-free wedge stall** (`wm_state wedge-check`, issue #202) - a
   member's pane has repainted *continuously*, never idle at a prompt, for
   `WM_WEDGE_SECS` while its own record went unwritten and a
   `watch-fleet`/`pr-watch` descendant of its pane has itself been running
   that long. **Also no nudge is sent first** - the signature this detects
   *is* the session actively running, foreground, on a call that blocks until
   an event fires (its own `watch-fleet`/`pr-watch` cycle, armed the wrong
   way), so a nudge into that pane would sit unread until the underlying call
   itself returns, which for this cause is never. The reason text names the
   matched process/pid and both durations, and mentions "wedged mid-turn" /
   "FOREGROUND" - that combination means the session foregrounded its own
   watcher and **will not resume on its own**.

So the old assumption - a `stalled` fire is always post-nudge, never a first
response - only holds for case 1. Check the reason text before assuming a
nudge already ran.

Also check case 1's reason text for a live-report count (issue #234): when it
names one or more live reports, the flipped member is very likely a lead whose
own wake chain (its armed watcher, its Stop-hook re-arm) died over a sub-crew
that is still live, not a member whose own agent errored. `bin/crew-takeover
<id>` or `bin/crew-standdown <id>` would each interrupt or discard a session
that was doing nothing wrong; relay `bin/crew-say <id> <nudge>` first instead -
it makes the member re-arm and resume supervising its reports with no session
lost - and reach for takeover/stand-down only if that nudge itself goes
unanswered. (Case 2's own reason text carries a similar-looking "%d active
report(s)" count with a different remedy - see its description above; the two
are not the same clause.)

Relay it once with the remedy - `bin/crew-takeover <id>` to inspect, or
`bin/crew-standdown <id>` to reap (or, per the paragraph above, `bin/crew-say
<id> <nudge>` when the reason names live reports) - then **leave it running**;
like `blocked` and `review`, the pilot decides its disposition. Lead with the
plain-language state ("the `<repo>` effort has gone quiet") before the
command, not the id; keep relaying the exact command regardless - the pilot
may need to run it themselves, and that is the actionable pointer, not
narration.

An invalid `--model` value is one cause of case 1: the agent CLI accepts it at
startup, so the window stays alive, but every turn comes back as an in-chat
model error instead of doing any work - the member never self-reports, so it
surfaces as `stalled`, not `died`. `bin/crew-takeover <id>` attaches to the
live window, where the model error is directly visible in the transcript.

**A `stalled` classification is now self-correcting** (issue #235): once you
relay it, `watch-fleet` keeps re-running the SAME detector's own evidence
against the record on every subsequent poll, and reverts it on its own once
that evidence stops holding for a sustained number of consecutive polls.
`bin/crew-list`/`board.md` show this directly - the status cell always
carries the classification's own age (`stalled (flagged 3h12m ago)`), and,
while a reverting streak is in progress, an extra clause
(`showing activity for 10s - classification may be stale`). A record
annotated that way is likely about to clear itself, so a takeover launched
against it may turn out to be unnecessary - check the board again before
attaching if the flagged age is small and the streak clause is present.
**A silent clear produces no second fire**: nothing pages you when this
happens (see [architecture.md](../architecture.md) for why), so if you were
relayed "X is stalled, take it over" and come back to it later, re-read the
board rather than assume the absence of a follow-up wake means X is still
stalled. `$WINGMAN_HOME/stall-recheck.log` is the durable record of every
clear (`<iso> <id> <source> cleared after <N> polls`) - check it to confirm
whether, and when, a given member cleared itself. The one exception: a
wedge stall (case 3 above) that reverts to `blocked` DOES fire once, because
the restored `blocker` is a genuinely open question nobody answered, not a
notification about the supervisor's own bookkeeping.

This is distinct from `died` (the session/window is confirmed gone, so no
nudge was ever possible) - a `died` member is always relayed immediately, with
no wait of any kind.

### `correlated:mass-death` (no outage tag)

Relay it plainly ("N crew members died together around \<time\>, looks like a
host/tmux crash") and **confirm with the pilot before running
`bin/crew-resume --all-died`** - resuming sessions is the same costly act as
any other spawn - unless the pilot has separately pre-authorized auto-recovery
for this specific effort. The note itself also states how many of the batch
have a confirmed-intact session transcript (`N/M`, issue #251) - relay that
too, since it's the difference between "N crew died, work may be lost" and
"N crew died, M of them are confirmed resumable, none of the work is
actually gone." A `died` member whose worktree was dirty at the moment of
death also has its state auto-anchored at `refs/wip/<id>` (`bin/crew-takeover
<id>` surfaces it) - mention this too if the pilot asks about uncommitted
work specifically, though it's not part of the note's own text. If the
shared tmux server itself is what died (issue #218),
`~/.wingman/tmux-guardian-events.log` - written by a process independent of
the server that just died, so it survives to report on it - may have the
death timestamp, a last-known-good heartbeat, and (for a revival) the new
server's process ancestry; worth checking before relaying.

### `correlated:api-outage` / `correlated:api-outage-death` / `outage-detected` — wingman-only

Relay it plainly ("N crew members hit API errors together / died together
during a detected outage - looks like an Anthropic-side burst"). **Do not run
`bin/crew-resume` for any outage-tagged death yet.** New spawns are already
mechanically paused (`hooks/api-outage-spawn-guard.sh` denies `bin/spawn-crew`
while the outage state is `active`), and `bin/crew-resume` itself refuses
outage-tagged resumes without `--force` while `active`. Wait for the
`outage-cleared` fire instead of polling or asking the pilot to confirm on the
spot.

### `outage-cleared` — wingman-only

**This is the one pre-authorized auto-recovery case.** If it names any
outage-tagged died member(s), run `bin/crew-resume --all-died` immediately,
**without asking the pilot first**, then relay the outcome ("the outage
cleared; resumed N previously-died member(s): \<ids\>" or naming any that
failed to come back). If it names no died members, there is nothing to resume -
just relay that new spawns are unpaused again.

This is the only case where `crew-resume` runs without a fresh pilot
confirmation, because the recovery is reversible (a resumed session that fails
is simply `died` again), low-risk, and the pilot's own standing instruction for
this exact case.

### `usage-limit-approaching` — wingman-only

New spawns are already mechanically paused
(`hooks/usage-limit-spawn-guard.sh` denies `bin/spawn-crew` while the state is
`approaching`/`paused`). **Already-running crew are never touched by this
pause and keep working and keep consuming quota** - this only stops the fleet
from *growing*.

Relay it plainly with the concrete numbers ("usage is at N% of the 5-hour
window, resets at \<time\>") and ask, via `AskUserQuestion`, whether to wait
for the reset or continue anyway and accept the risk of hitting the hard limit
mid-task - and say plainly that **"wait" only holds new spawns; it does not
stop crew already running, which can still hit the hard limit on their own
before the window resets.**

Record the answer immediately with
`$WINGMAN_STATE usage-decide --decision wait|continue`.

- On **continue**, tell the pilot new spawns are unpaused. If the fleet does
  hit the hard limit later, that surfaces reactively as an "API outage" rather
  than distinctly as quota exhaustion - mention that mislabel if it comes up.
- On **wait**, tell the pilot new spawns stay paused until the window resets on
  its own - nothing further to do; your own watcher already wakes you on the
  `usage-limit-reset` fire the moment `resets_at` passes.

If the window resets before the pilot ever answers, the state clears itself
automatically and the ask is moot - if you get a late answer to an ask you
already relayed, tell the pilot the window already reset and no decision is
needed.

### `usage-limit-reset` — wingman-only

Relay it plainly ("the usage window reset; new spawns are unpaused again")
and, **only** if the prior decision was "wait" (or the reset arrived before the
pilot answered at all), note that the fleet can resume normal spawning - no
manual restart needed, this is fully automatic. A "continue anyway" decision
resets silently with no fire at all, so there is nothing to announce there.

## Other incidents (not a `watch-fleet` fire)

### A guard hook is not firing

Check registration first, before suspecting the hook's own matching logic: `bin/lib/sync-user-hooks.py --check --report --settings ~/.claude/settings.json` (from the wingman repo) lists every guard the manifest (`bin/lib/user-hooks.json`) expects that is not currently registered in user-level `settings.json`. Since issue #241, every session-creation path (`bin/wingman`, `bin/spawn-crew`, `bin/crew-resume`) reconciles this automatically and fails closed if it can't, so an unregistered guard here means either a checkout old enough to predate the manifest itself, or a settings file the reconciler could not parse. A registration written mid-run never retrofits an already-running session - Claude Code binds hooks at session start - so the fix is a restart (`systemctl --user restart wingman.service` or equivalent), not just a pull.

### `wingman.service` is active but there is no tmux session

`~/.wingman/last-launch-failure` is the durable trace for this: `bin/wingman`'s systemd unit is `Type=oneshot`/`RemainAfterExit=yes` with `ExecStart=tmux new-session -d`, which succeeds the instant the session exists - before `bin/wingman` itself has done anything - so `systemctl --user status wingman.service` reads `active` regardless of what happens next. If `bin/wingman` then refuses to start (most commonly: it could not reconcile its user-scope guard hooks, see above), its own `wm_die` message goes to a tmux pane that is destroyed moments later along with the session, reaching nobody. If the file is present, `bin/doctor` also surfaces it near the top of its own output. Read it, fix the named problem, then start wingman again - the file is only cleared by a launch that actually succeeds, so its mere presence means the last attempt refused.
