# Investigation: a `done` crew event re-surfaces on every watcher arm and every Stop-hook check

- **Date:** 2026-07-09
- **Mode:** report (investigate-only, no build handoff)
- **Repo:** `wingman`
- **Files at the center of the bug:** `bin/lib/wm-state.py` (`needs-attention`), `bin/watch-fleet`, `hooks/stop-guard.sh`

## Symptom

A spec crew member flipped to `done`. Its **same** `done` event was surfaced to wingman
repeatedly across multiple wake cycles, even though wingman had already read and relayed
it. It kept re-firing from `bin/watch-fleet` on every re-arm **and** from the Stop hook
(`hooks/stop-guard.sh`) on every stop attempt. It only stopped after the crew was stood
down.

## Root cause (one sentence)

`wm-state needs-attention` is a **pure, stateless query** that reports every crew member
currently in `blocked` / `done` / `died`, and **nothing anywhere records that an event has
already been surfaced** - so a terminal state (`done`/`died`), which never changes on its
own, is re-reported as "actionable" on every single call by both consumers, forever, until
something mutates the crew out of that state set (which is exactly what stand-down does).

## Trace

### 1. `needs-attention` has no acknowledgment / de-dup - it is a pure function of current state

`bin/lib/wm-state.py:241`:

```python
def cmd_needs_attention(_args):
    """Print ids of crew that need wingman: blocked, done, or died. Used by the
    watcher to decide whether to wake wingman."""
    for r in (merged(x) for x in load_roster()):
        if r.get("status") in ("blocked", "done", "died"):
            print("%s\t%s\t%s" % (r["id"], r["status"], r.get("blocker") or r.get("summary") or ""))
```

This reads the merged roster and emits one line per crew member whose current status is in
`{blocked, done, died}`. There is **no** "seen" / "acked" / "surfaced" / "last-delivered"
field consulted here, and no such bookkeeping is written anywhere else in the codebase. A
grep across `bin/` and `hooks/` for `ack`/`acked`/`surfaced`/`delivered`/`last_seen` finds
nothing but unrelated log text. The state home (`~/.wingman/`) contains only
`crew.json`, `crew/<id>.json`, `board.md`, `projects.json`, `wake`, `watch.pid`,
`watch.beat` - **no ack store**.

Consequently `needs-attention` returns the identical output on every call for as long as
the crew's status is unchanged. For `working` this is harmless (not in the set). For
`blocked` the pilot arguably wants a reminder, but for the **terminal** states `done` and
`died` the state never changes on its own, so the output is permanent noise once produced.

State-model context (`wm-state.py:29-30`):

```python
LIVE_STATES = ("working", "blocked")
TERMINAL_STATES = ("done", "died", "stood-down")
```

Note `stood-down` is terminal but is **not** in the `needs-attention` set - which is why
standing the crew down was the only thing that silenced the storm (see step 4).

### 2. The watcher fires on every arm and never records what it fired

`bin/watch-fleet` claims a cycle, then at the **top** of its loop (before sleeping) reads
`needs-attention` and fires on any non-empty result (`bin/watch-fleet:156-158`):

```bash
attention="$(wm_state needs-attention 2>/dev/null)"
[ -n "$attention" ] && fire "$attention"
```

`fire()` (`bin/watch-fleet:107-121`) writes the human-readable payload to `~/.wingman/wake`,
prints the machine reason lines to stdout, removes the pidfile, and `exit 0`. That exit is
the wake: the harness re-invokes wingman. **`fire()` records nothing about what it
delivered** - it does not touch any ack store.

The tight re-surface loop is therefore:

1. Wingman arms a fresh cycle. It claims the pidfile and enters the loop.
2. Top of loop: `needs-attention` still returns the `done` crew (unchanged state, no ack) ->
   `fire()` immediately -> writes `wake` -> `exit 0`.
3. The exit wakes wingman. Wingman reads the (same) `done` event and relays it again.
4. Per its playbook, wingman **arms exactly one fresh cycle** before ending the turn -> back
   to step 1.

The singleton guard (`bin/watch-fleet:87-90`) does not help here: it only suppresses a
*second* arm while a cycle is still **live** (pid alive + fresh beacon). Here the cycle has
already fired and exited (pidfile removed), so the next arm is a legitimately fresh cycle
that immediately re-fires. Each re-arm = one immediate duplicate fire.

The header comment (`bin/watch-fleet:17-21`) explains that checking at the top of the loop
gives "at-least-once delivery" so an event pending the instant a cycle is armed is not lost
in the fire->re-arm gap. That reasoning is correct and worth keeping - but with no ack, the
same top-of-loop check that protects a *second* crew's event also **re-delivers the same
crew's event** every arm. At-least-once with no de-dup degrades to at-least-once-per-arm =
infinitely.

### 3. The Stop hook is a second, independent re-surface channel with the same root cause

`hooks/stop-guard.sh:33` calls the same query:

```bash
attention="$(WINGMAN_HOME="$WM_HOME" $WM_UV "$STATE_PY" needs-attention 2>/dev/null)"
...
if [ -n "$attention" ]; then
  reason="Crew need your attention before you go idle:
$attention
Surface each blocker/PR to the pilot (or answer via bin/crew-say), then you may stop."
```

Whenever wingman tries to end a turn, the Stop hook independently runs `needs-attention`;
because the `done` crew is still present and there is no ack, it **blocks the stop** and
re-injects the same event as the block reason - even though wingman just relayed it. The
only thing preventing an *intra-turn* infinite loop is the `stop_hook_active` guard
(`hooks/stop-guard.sh:21-27`), which allows the stop once the hook has already blocked once
this turn. That guard is per-turn only; it does nothing to stop the event re-appearing on
the *next* turn's stop. So the Stop hook re-surfaces the same `done` event once per turn,
in lock-step with the watcher re-surfacing it once per arm.

### 4. Why stand-down was the only thing that stopped it

`cmd_standdown` (`wm-state.py:225-238`) sets the crew's status to `stood-down`. That value
is **not** in `needs-attention`'s `{blocked, done, died}` set, so from that point
`needs-attention` returns empty for that crew, both the watcher loop and the Stop hook see
nothing actionable, and the storm ends. Stand-down "fixed" it only as a side effect of
moving the crew to a status the query ignores - it is not the intended dismissal path.

## Is there any de-dup/ack mechanism? Why does it fail to suppress a re-surface?

There is **none**. The `wake` file is overwritten on each fire and carries no delivered/seen
marker; `watch.pid` / `watch.beat` are only liveness signals for the singleton guard, not
delivery records. Because the reportable set is derived purely from current status, and
`done`/`died` are terminal, the system has no way to distinguish "this event is new" from
"this event has already been shown." Both consumers treat *presence in the set* as *needs
surfacing now*, so every poll re-surfaces.

## Recommended fix

Introduce a per-crew **acknowledgment (last-delivered) record**, filter `needs-attention`
against it, and have each delivery channel record what it delivered. This is the smallest
change that makes an event "surface once, and again only when its state changes," while
preserving the at-least-once gap protection the watcher deliberately relies on.

Key the ack on **`(id, updated)`**. Every state write (`crew-set`, `reconcile`, `standdown`)
already bumps the `updated` timestamp, so `updated` is a natural per-event version stamp:
same `updated` = same event (suppress); new `updated` = genuine state change (re-surface).

### Changes

1. **New ack store** `~/.wingman/acked.json`, shape `{ "<id>": "<updated-timestamp>" }`
   (the last `updated` value delivered for that crew). Read/written through `wm-state.py`
   like the other state files (atomic `write_json`).

2. **`needs-attention` filters against the ack store** and emits the `updated` field so a
   deliverer can ack the exact tuple. It stays a pure read (no side effects):

   ```python
   def cmd_needs_attention(_args):
       acked = read_json(acked_path(), {})
       for r in (merged(x) for x in load_roster()):
           if r.get("status") in ("blocked", "done", "died"):
               if acked.get(r["id"]) == r.get("updated"):
                   continue  # already surfaced this exact event
               print("%s\t%s\t%s\t%s" % (
                   r["id"], r["status"], r.get("updated") or "",
                   r.get("blocker") or r.get("summary") or ""))
   ```

3. **New explicit command** `wm-state ack --id <id> --updated <ts>` that records
   `acked[id] = ts`. It is explicit (not a side effect of the read) so the mutation happens
   only at a real delivery point, and it acks exactly the tuple that was surfaced (passed in),
   not whatever the crew's state happens to be at ack time - avoiding a race where the crew
   transitions between the read and the ack.

4. **Watcher acks what it fires.** In `bin/watch-fleet`, after `fire()` writes the wake file
   and before `exit 0`, loop over the fired lines and call `wm_state ack --id <id> --updated <ts>` for each. Firing is the delivery, so this is the correct ack site. The
   top-of-loop check and the gap protection are unchanged: a *different* crew that finishes
   in the fire->re-arm window is still unacked and still surfaces on the next arm; only the
   *already-delivered* tuple is now suppressed.

5. **Stop hook acks what it blocks on.** In `hooks/stop-guard.sh`, after it decides to block
   on `attention`, call `wm-state ack` for each surfaced id/updated before emitting the block
   JSON. Blocking-the-stop is also a delivery to wingman, so the two channels share one
   "surface once per (id, updated)" rule and never re-surface each other's already-shown
   events. (Because both channels ack, whichever reaches an event first delivers it; the
   other then sees it as acked. A rare simultaneous double-delivery is possible but is a
   single duplicate, never a loop.)

### Behavior after the fix

- `done`/`died` surfaces exactly once; subsequent arms and stops see it acked and stay quiet.
  No stand-down needed to silence it.
- `blocked` surfaces once. When the pilot answers via `bin/crew-say` and the crew resumes,
  its `updated` bumps; if it blocks again later it gets a new `updated` and re-surfaces
  correctly.
- Gap events are still delivered: a second crew finishing between fire and re-arm has an
  `updated` not in the ack store, so the next arm's top-of-loop check surfaces it.
- Both consumers (watcher, Stop hook) read the same ack store, so fixing the query fixes
  both channels at once.

## Follow-ups (not required for the fix)

- **Sub-second `updated` precision.** `now()` (`wm-state.py:57-59`) is second-precision. Two
  state writes within the same wall-clock second (e.g. `blocked -> working -> blocked`)
  would share one `updated` string, so acking the first could suppress the second. Bumping
  `now()` to microsecond precision (`%Y-%m-%dT%H:%M:%S.%fZ`) eliminates the collision and
  improves ordering everywhere. Low effort; recommend doing it alongside the fix.
- **Ack-store pruning.** `acked.json` grows one entry per crew id ever surfaced. It is tiny,
  but pruning entries for crew no longer in the roster (e.g. during `reconcile`) keeps it
  tidy.
- **Explicit pilot dismissal.** If a future need arises to re-show a still-`blocked` crew on
  demand, an explicit `wm-state unack --id <id>` (clear its entry) would force a re-surface
  without a state change. Not needed for the reported bug.

## Reproduction (how to confirm before/after)

1. `wm-state crew-set --id <someid> --status done --summary "test"`.
2. `wm-state needs-attention` -> prints the crew. Run it again -> prints the identical line
   (demonstrates the stateless re-report; no ack consulted).
3. Arm `bin/watch-fleet`: it fires immediately (writes `~/.wingman/wake`, exits). Re-arm it:
   it fires immediately again with the same payload. Repeat -> re-fires every time.
4. Trigger the Stop hook while the crew is `done` -> it blocks with the same event as the
   reason, on every turn.
5. `wm-state standdown --id <someid>` -> `needs-attention` now returns empty; both channels
   go quiet (confirming the status-set dependency).

After the fix: step 2 prints once, then empty on the next call once acked; step 3 fires once
then re-arms stay quiet; step 4 blocks once (per turn guard) then allows.
