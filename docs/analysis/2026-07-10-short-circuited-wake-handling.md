# Investigation: short-circuited wake handling

- **Date:** 2026-07-10
- **Mode:** Investigation / report (no developer handoff)
- **Component:** wingman supervisor wake loop (`bin/watch-fleet`, `hooks/stop-guard.sh`, `CLAUDE.md` wake-loop contract)
- **Status:** Root cause identified; concrete remediation recommended.

## Summary

When a `watch-fleet` cycle fires on a `review` event, the wake signal wingman actually receives is a single self-contained line of the form `review: <id> <artifact>`.
That line carries exactly the payload wingman needs to relay that one event, so the economical response is to relay it and end the turn.
Nothing in the runtime signal, and nothing in the enforcement layer, requires wingman to then read `~/.wingman/wake` and `bin/crew-list` for the full roster picture, even though `CLAUDE.md` prescribes that step.
The result is the observed bug: the pilot gets the single event announced, but no roster status.

The prescribed "read the full picture" step is easy to skip for four compounding structural reasons:

1. The surfaced reason line looks self-sufficient (it embeds id + status + artifact path).
2. The wake file is never referenced by the watcher's own output; the only pointer to it is prose in `CLAUDE.md`.
3. The wake file is a byte-for-byte re-format of the reason line, so opening it adds nothing, reinforcing the skip.
4. No hook enforces the roster read; the Stop hook's gate is already satisfied by the time wingman finishes relaying, because the fire path acks the event before wingman ever acts.

The recommendation is to move the instruction into the bytes wingman actually reads on wake, and to make the wake file genuinely carry the full picture rather than a duplicate of the trigger, so that complete handling becomes the path of least resistance rather than a prose rule competing for attention.

## What "complete wake handling" is supposed to be

`CLAUDE.md` specifies the wake loop in two places.

The operating loop ("Supervise" step):

> Arm the watcher... When it wakes you, or when the pilot asks, read `bin/crew-list`.

The wake-loop section ("On each wake"):

> read the reason line, read `~/.wingman/wake` (and `bin/crew-list`) for the full picture, surface the blocker/done/PR to the pilot (or answer via `bin/crew-say`), then arm exactly one fresh cycle before you end the turn.

And the "Report" step:

> Give the pilot a compact status: who is on what, what is blocked, what is ready for review.

So the intended sequence on every wake is: **reason line → wake file → `bin/crew-list` → surface a compact roster status → re-arm.**
The "full picture" that distinguishes a good handoff from a bare event relay is the roster status: who is on what, across the whole layer, not just the one member that changed state.

## How the wake is actually delivered (the supporting mechanism)

### `bin/watch-fleet` `fire()` (lines 143-164)

When a member enters an attention state, `fire()` does two independent things:

1. **Writes a human-readable payload to the wake file** (`$WAKEFILE`, i.e. `~/.wingman/wake` at the top level):

   ```
   # Crew need your attention

   - **<id>** [<status>] <note>
   ```

2. **Prints one machine reason line per member to stdout**, with the format:

   ```
   printf '%s: %s %s\n' "$st" "$id" "$note"
   ```

   i.e. `<status>: <id> <note>`. For a review event the `note` resolves (via `cmd_needs_attention`, `wm-state.py:465`) to the artifact path, so the line reads:

   ```
   review: investigate-report-mode-no-devel-analyst /Users/gviau/Documents/github/docs/analysis/2026-07-10-wingman-lead-suggestion-miss.md
   ```

Because `watch-fleet` is armed as a harness-tracked background task, its **exit surfaces its stdout back to wingman** — so the stdout reason line is the wake signal wingman literally reads on re-invocation.
The wake file is a *side* artifact: wingman is told (only in `CLAUDE.md`) to go read it, but nothing in the delivered signal points at it.

### The wake file duplicates the reason line

The two channels carry the same information.
The wake file's list (`- **<id>** [<status>] <note>`) and the stdout line (`<status>: <id> <note>`) are the same `(id, status, note)` tuple in two formats.
Confirmed against the live file at investigation time:

```
# ~/.wingman/wake
# Crew need your attention

- **investigate-report-mode-no-devel-analyst** [review] /Users/gviau/Documents/github/docs/analysis/2026-07-10-wingman-lead-suggestion-miss.md
```

This is the same single event the stdout reason line would carry.
Neither channel contains a roster; the roster only exists via a separate `bin/crew-list` call, which `CLAUDE.md` names but the signal does not.

### `hooks/stop-guard.sh` does not backstop the roster read

The Stop hook is the one enforcement mechanism in the loop.
It blocks wingman from ending a turn "blind" in two cases (lines 58-75):

- `needs-attention` returns a non-empty (unacked) set, or
- crew are in flight while no watcher cycle is live.

Its blocking reason (lines 70-72) says:

> Surface each blocker/PR to the pilot (or answer via bin/crew-say), then you may stop.

Two gaps here:

- The reason **never mentions reading `bin/crew-list` or the full roster** — it only asks wingman to surface each blocker/PR. So even when the hook does fire, it reinforces the "relay the events" framing, not the "report a roster status" framing.
- More fundamentally, **the gate is already satisfied by the time wingman acts.** `fire()` acks every event it surfaces *before it exits* (`watch-fleet` lines 159-161, calling `wm_state ack`). So when wingman is re-invoked, relays the event, and tries to stop, the Stop hook's `needs-attention` check (`wm-state.py:460`) returns empty for that already-acked event. The hook lets the stop proceed without ever injecting a reminder. The redundant ack in the Stop hook (lines 64-66) exists for the case where the hook is the *first* channel to see an event, but for the watcher-fired path the fire-time ack has already closed the gate.

The net effect: the only enforcement in the system is structurally unable to catch a fired event, because the fire path disarms it in advance.

## Reproduction

This is a prompt-adherence defect in how wingman responds to a delivered signal, not a crash, so it reproduces as a deterministic trace of "what bytes wingman receives vs. what it is told to do":

1. A crew member finishes a plan/report and sets `--status review --artifact <path>` (e.g. an analyst reporting a deliverable).
2. The live `watch-fleet` cycle's top-of-loop `needs-attention` check sees the new `(id, updated)` event and calls `fire()`.
3. `fire()` writes `~/.wingman/wake` (the reformatted delta), prints the single stdout line `review: <id> <artifact>`, acks the event, and exits.
4. The harness re-invokes wingman with that stdout line as the wake reason.
5. The line contains id + status + artifact — a complete-looking instruction — so wingman announces "plan ready" with the pointer and ends the turn.
6. The Stop hook runs, finds `needs-attention` empty (already acked in step 3), and permits the stop.

Outcome: the pilot receives the one event, and no roster status. Steps 2-4 of the prescribed handling (read wake file, read `bin/crew-list`, report a compact roster) are silently skipped, and no mechanism objects.

The current roster contains other members (per `~/.wingman/crew.json` and the `acked.json` history) whose state the pilot would have seen in a `bin/crew-list` roster but did not see in the bare event relay — which is exactly the situational-awareness loss the "full picture" step is meant to prevent.

## Root cause

The prescribed "read the full picture" step lives **only in `CLAUDE.md` prose**, while every runtime affordance points the other way:

- The signal wingman reads on wake (the stdout reason line) is shaped like a finished instruction, not a trigger to investigate.
- The one artifact that `CLAUDE.md` tells wingman to read (`~/.wingman/wake`) is not referenced by the signal and contains nothing beyond the signal, so reading it is unrewarded.
- The roster — the actual "full picture" — requires a separate `bin/crew-list` call that no signal, file, or hook demands.
- The enforcement layer (the Stop hook) is pre-disarmed by the fire-time ack and, even when it does fire, asks for event relay rather than a roster report.

In short: correct handling depends on wingman remembering and following a prose rule, against a runtime whose every concrete cue says "you already have what you need."
Compaction, a long context, or a busy turn makes the prose rule the first thing to slip, and nothing catches the slip.

## Recommendations

The fix is to relocate the "full picture" requirement out of prose and into the mechanism, so the correct behavior is the one the signal and the artifacts actually lead to.
The three changes below are complementary; the first two are the primary fix and the third is the enforcement backstop.

### 1. (Recommended, primary) Make the surfaced reason line an instruction, not just data

Change `watch-fleet`'s `fire()` so the stdout it emits — the bytes wingman reads on wake — ends with an explicit, unmissable directive that frames the events as a delta and mandates the roster read. For example, after the per-member lines:

```
review: <id> <artifact>
--
These are state-change deltas, not the full picture. Before you surface anything,
read ~/.wingman/wake and run `bin/crew-list`, then report a compact roster status
(who is on what, what is blocked, what is ready), not just the lines above.
```

This puts the requirement in the exact place wingman cannot skip — the wake signal itself — instead of in `CLAUDE.md`, which competes with everything else in context.
It directly closes gaps 1 and 2. Low effort, high leverage.

### 2. (Recommended, primary) Make the wake file carry the actual full picture

Change `fire()` so `$WAKEFILE` contains the **full current roster** (the equivalent of `bin/crew-list` for the owner's scope) with the delta events flagged at the top, rather than a re-format of the same delta the stdout line already carries.

Then "read `~/.wingman/wake`" genuinely yields the full picture, the redundancy that makes the wake file skippable (gap 3) is removed, and wingman has a single canonical artifact to build its roster status from.
`fire()` already runs inside the watcher, which reconciles liveness every loop iteration (`watch-fleet` lines 171-172), so the snapshot written at fire time is current.
`bin/crew-list` remains the live fallback, but the wake file stops being dead weight.

Together, changes 1 and 2 give the two channels distinct, intentional roles: **stdout = terse trigger + directive; wake file = the full roster to report from.**

### 3. (Recommended follow-up) Strengthen and re-arm the Stop-hook backstop

Two sub-changes make the Stop hook actually able to enforce complete handling:

- **Update the block reason** (`stop-guard.sh` lines 70-72) to require the roster report, e.g. "…read `~/.wingman/wake` and `bin/crew-list` and give the pilot a compact roster status (who is on what, what is blocked, what is ready), then you may stop." This aligns the one enforcement message with the prescribed behavior.
- **Move the ack out of the fire path so the hook can see the event.** Today `fire()` acks before wingman acts, pre-disarming the hook. If the fire-time ack is removed and acking becomes the Stop hook's responsibility (it already acks, lines 64-66), then wingman's first attempt to end the turn after a fired event is blocked once, with the strengthened reason injected, and only then acked — so the roster-report step is enforced, not merely suggested.

  **Caveat / open question:** removing the fire-time ack reintroduces a re-fire race. If wingman arms a fresh watcher cycle *before* the Stop hook acks, that cycle's top-of-loop `needs-attention` check can fire again on the still-unacked event, causing a rapid re-fire. The fire-time ack was added precisely to prevent this. A safe version needs a different dedupe key for the "handled" state (for example, the Stop hook writes a `handled` marker keyed by `(id, updated)` that both `fire()` and `needs-attention` respect, distinct from `ack`), so the event is suppressed from re-firing without being marked fully handled until the hook has run. This is why change 3 is a follow-up: it requires care that changes 1 and 2 do not, and changes 1 and 2 already make the correct behavior the path of least resistance.

### Recommended sequencing

Do changes 1 and 2 first: they are self-contained, carry no race risk, and directly convert the prose rule into a mechanism.
Treat change 3 as a follow-up hardening pass, gated on resolving the re-fire dedupe question above, for cases where the signal-level nudge proves insufficient under compaction.

## Risks and open questions

- **Owner scoping of the wake-file roster (change 2).** `fire()` and the wake file are keyed per owner (`watch-fleet` lines 69-78), so a lead's wake file must render *that lead's* scope (`--owner <lead-id>`), and wingman's must render the top level (`--owner ""`). The full-roster render must respect the same `$OWNER` the cycle was armed with, or a lead would surface the wrong crew.
- **Signal verbosity (change 1).** Adding a directive block to every fire slightly enlarges the wake reason. This is negligible against the context wingman already carries and is the point — the instruction must be where it cannot be skipped.
- **The re-fire dedupe question (change 3)** is the one genuinely open design decision; it is documented inline above and should be settled before implementing change 3.
- **Scope of the observed report.** This investigation reproduces the mechanism deterministically from the code and the live state files; it does not include a captured transcript of the specific incident. The mechanism fully accounts for the reported behavior, but if a transcript of the incident is available it would confirm that the single stdout line (rather than some other path) was what wingman acted on.
