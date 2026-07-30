# A raised `WM_USAGE_WARN_THRESHOLD` has no effect on an already-latched usage-limit state

**Date:** 2026-07-29
**Mode:** investigation (report only; no code change made)
**Components:** `bin/lib/wm-state.py` (`usage-update`), `bin/watch-fleet`, `hooks/usage-limit-spawn-guard.sh`
**Filed as:** [#206](https://github.com/greerviau/wingman/issues/206)
**Status:** investigation closed. Both open questions have been decided by the requester; the recommended fix below is settled and implementable as written.

## Summary

The fleet usage-limit state machine evaluates `--warn-threshold` **only while the persisted state is `clear`**. Once it has flipped to `approaching`, the threshold is never consulted again for the remainder of the window. Raising `WM_USAGE_WARN_THRESHOLD` therefore cannot release an already-latched pause: the new value is correctly read from the settings file, correctly passed to `usage-update` on every subsequent poll, and then ignored.

The requester's description of the defect is accurate in every material respect. Two effects beyond that description were found, both stemming from the same line of code, and one detail of the description is refined below.

## Confirmation against the code

### The threshold is only consulted from `clear`

`bin/lib/wm-state.py`, `cmd_usage_update`:

- Line 1944-1954: if the state is not `clear`, the only exit checked is `now_epoch >= state["resets_at"]`. If that has not passed, the function falls through.
- Line 1956: `if state["state"] == "clear":` — **the entire threshold comparison lives inside this branch.**
- Line 1962-1965: `c[1] >= args.warn_threshold and c[2] > now_epoch` — the crossing test, reachable only from `clear`.
- Line 1978: the state is rewritten unchanged and `none` is printed.

There is no code path by which a non-`clear` state is re-tested against the current threshold. The persisted record (line 1968-1975) stores `state`, `window`, `used_percentage`, `resets_at`, `since`, `decided_at` — **it does not store the threshold that produced the flip**, so nothing downstream can detect that the threshold has since changed.

This matches the documented contract in `docs/fleet-resilience.md`, which states that `approaching` leaves that state only via `usage-decide` or automatically once `resets_at` passes. The defect is that the contract itself does not account for the threshold being a mutable input.

### The configuration plumbing is correct — it is not the cause

An obvious alternative hypothesis is that a long-lived watcher process held a stale environment. It does not:

- `bin/lib/common.sh:83-90` evaluates `wm_config.py env-exports` at the top of every `bin/` script, applying the settings file's `[env]` table to that process.
- `bin/watch-fleet:121` sources `common.sh`; line 265 reads `WM_USAGE_WARN_THRESHOLD="${WM_USAGE_WARN_THRESHOLD:-80}"`; line 1267 passes it as `--warn-threshold`.
- Each watcher cycle is a fresh `watch-fleet` process, so each cycle re-reads the settings file.

Verified live: `bin/config` reports `env.WM_USAGE_WARN_THRESHOLD = 90`, attributed to `config.local.toml`, and the variable is absent from the ambient environment (so the file's value is not being shadowed by an inherited one). The raised threshold **was** reaching `usage-update` on every poll after 23:09:18 UTC. The state machine discarded it.

### The recorded timeline

The live state file corroborates the reported timeline:

```json
{
  "state": "acknowledged",
  "window": "seven_day",
  "used_percentage": 80.0,
  "resets_at": 1785646800.0,          // 2026-08-02T05:00:00Z
  "since": "2026-07-29T21:44:32.403016Z",
  "decided_at": "2026-07-29T23:26:57.621476Z"
}
```

`config.local.toml` has mtime `2026-07-29 23:09:18 UTC`. So the flip preceded the configuration change by ~85 minutes, and the state remained latched across the change until the requester issued `usage-decide --decision continue` at 23:26:57 (which is why the state now reads `acknowledged` rather than `approaching`; this is the requester's manual intervention, not the defect resolving itself).

Note that the crossing test is `>=`, so a reading of exactly `80.0` trips a threshold of `80`. That is why a reading sitting precisely on the boundary latched the state.

### Reproduction

Run against an isolated `WINGMAN_HOME`; the live state file was not modified.

```
$ WINGMAN_HOME=<sandbox> wm-state.py usage-update --owner "" \
    --seven-day-pct 80.0 --seven-day-resets-at <+4d> --warn-threshold 80
usage-limit-approaching
    state=approaching  used_percentage=80.0

# the human raises the threshold to 90; same reading, every subsequent poll:
$ WINGMAN_HOME=<sandbox> wm-state.py usage-update --owner "" \
    --seven-day-pct 80.0 --seven-day-resets-at <+4d> --warn-threshold 90
none
    state=approaching  used_percentage=80.0      # unchanged, and unchanged after repeated polls
```

The spawn guard, fed this state, denies `bin/spawn-crew` with:

> The 7-day usage-limit window is approaching its cap (issue #24) — used 80%, resets at epoch …

## Two additional effects found

Both follow from the same "only re-evaluated from `clear`" structure.

### 1. `used_percentage` is frozen at flip time, so the guard message can under-report

Because the whole reading-ingestion block is inside the `clear` branch, the stored `used_percentage` is never refreshed while latched. Feeding a 95.0 reading into a state latched at 80.0 leaves the record at 80.0, and the guard message continues to say "used 80%".

This refines the requester's description: the guard quotes the **stored `used_percentage`**, not the threshold. In this incident the two coincided (the reading was exactly 80.0 and the default threshold was 80), which is why the message read as though it were quoting the stale threshold. The underlying staleness is real, but it is a stale *reading*, and it errs toward under-reporting how close the fleet actually is to the cap.

### 2. An `acknowledged` state suppresses any further ask for the rest of the window

`acknowledged` also only clears at `resets_at`. So a "continue anyway" decision taken at 80% suppresses detection entirely even if usage subsequently climbs to 99%. The requester is never asked again, at any threshold. This is latent today and is not what the requester hit, but the same fix addresses it.

### The reverse direction already works

Lowering the threshold mid-window takes effect on the very next poll, because a `clear` state re-evaluates the crossing test every time. Verified: a reading of 85.0 sits below a threshold of 90 (state stays `clear`); lowering the threshold to 80 flips it to `approaching` on the next poll.

The behavior is therefore **asymmetric**: lowering the threshold is live, raising it is not. That asymmetry is the sharpest statement of the bug, and it is the opposite of the intuitive expectation — a requester raising the threshold is trying to *relax* a pause that is actively obstructing them, and that is precisely the direction that does not work.

## Recommended fix

**Re-evaluate the crossing condition against the current threshold on every poll, in every state, and self-clear when a fresh reading for the latched window no longer crosses it.**

Two policy calls within this design were put to the requester and have been decided; both are settled and are stated as such below:

- **Decision 1 — an explicit `wait`/`continue` decision does *not* survive a threshold change.** Self-clearing applies uniformly to `approaching`, `paused` and `acknowledged`. (Rationale in "The two settled decisions" below.)
- **Decision 2 — the latched state is compared against a within-window high-water mark of the reading**, not against the raw current aggregated reading.

Concretely, in `cmd_usage_update`, after the existing `resets_at` auto-clear check and before the `clear` branch:

1. **Track the reading as a within-window high-water mark** (decision 2). When a fresh reading for the latched window is present, store `max(stored used_percentage, current reading)`. Usage within a window is monotonically non-decreasing, so the high-water mark is the physically correct figure, and it fixes effect 1 above — the guard stops quoting a stale number.
2. **Self-clear when the high-water mark no longer crosses the current threshold.** With the stored mark at 80.0 and the threshold raised to 90, `80.0 >= 90` is false, so the state clears on the next poll and spawns unpause automatically.
3. **Only when a fresh reading for that window exists.** `cmd_usage_update`'s own docstring notes that either window's flags may be entirely absent on a given poll (no fresh `usage/*.json` at all). An absent reading must **hold** the latched state, exactly as today — clearing on absence would unpause a quiet fleet spuriously and then re-trip when a session next reports, producing flap.
4. **Store the threshold in the record** (e.g. `warn_threshold`) — not as the clearing mechanism, but so `bin/crew-list`, the guard message, and anyone debugging can see which policy produced the flip.
5. **Print `usage-limit-reset` when self-clearing from `approaching` or `paused`**, matching the existing `resets_at` path: a pause is being lifted and the requester should be told spawns are unpaused. Self-clearing from `acknowledged` prints `none`, again matching the existing path (the fleet was never paused, so there is nothing to announce). `bin/watch-fleet`'s fire logic needs no change.

Using the high-water mark rather than the raw current reading also guards a real edge case: if the highest-usage session's `usage/*.json` goes stale or is swept, the aggregated maximum can legitimately drop, and comparing the raw reading would clear a pause that should still hold. The high-water mark holds it.

**Why this over the other candidate directions:**

- *Store the threshold and invalidate only when it changes.* This fixes exactly this incident and nothing else. It leaves effect 2 (an `acknowledged` state suppressing a worse reading) in place, and it is really a narrower, special-cased form of the same re-evaluation. Storing the threshold is still worth doing for observability — hence step 4 — but it should not be the clearing mechanism.
- *Treat a threshold change as a state-clearing event.* This couples the state machine to settings-file change detection, and it would discard a legitimately-earned `paused` whenever the requester edits an unrelated `[env]` key. Rejected.

### The two settled decisions

**Decision 1 — an explicit `wait`/`continue` decision does not survive a threshold change.** Self-clearing applies uniformly to `approaching`, `paused` and `acknowledged`:

- A `paused` state exists because the requester chose to wait *under the old policy*. Raising the threshold above the current reading is the requester revising that policy. Without self-clear, `paused` is the worst case of this bug: the fleet stays hard-blocked until `resets_at` with no recovery path short of `usage-decide` or an override on every spawn.
- An `acknowledged` state is already non-blocking, so clearing it changes nothing operationally except re-arming detection at the new threshold — which is the desired behavior and fixes effect 2.
- Under a static threshold this introduces no re-ask churn: readings are monotonic within a window, so an `acknowledged` state whose mark stays above the threshold never self-clears and never re-asks.

The rejected alternative was to preserve an explicit decision and self-clear only an undecided `approaching`. That treats the recorded decision as deliberate, but it leaves a `paused` fleet blocked for the rest of the window with no recovery path — the single worst symptom of this defect.

**Decision 2 — compare against a within-window high-water mark, not the raw current reading.** The mark matches the monotonic nature of usage within a window, and it prevents a pause from lifting spuriously when the highest-usage session's `usage/*.json` goes stale or is swept and the aggregated maximum consequently drops for reasons unrelated to real usage. The rejected alternative — comparing the raw current aggregated reading — is simpler and strictly reflects what the fleet reports right now, but it can clear a pause that should still hold.

**Testing.** `tests/usage-limit-state.test.sh` should gain: a raised threshold clearing a latched `approaching`; a raised threshold clearing a latched `paused`; a latched state *holding* when the window's reading is absent from a poll; a lowered threshold still tripping from `clear` (regression guard); and an `acknowledged` state re-arming and re-asking once usage crosses the new threshold. The existing case "a continued signal while already approaching prints `none`" (feeding 90 at threshold 80 into a state latched at 85) stays green under this design: 90 still crosses 80, so the state holds and `none` is printed; only the stored `used_percentage` refreshes, which that case does not assert.

## Relationship to existing issues

- **#24** (closed) introduced the whole detect-and-pause mechanism and is referenced by the guard message. The threshold-mutability case was not in its scope.
- **#204** (open) asks for `WM_USAGE_WARN_THRESHOLD` to be *discoverable* in the settings file. That work is what enabled the requester to set the value at all; this defect is what happened next, when the newly discoverable knob turned out not to govern an already-latched state. Related but distinct: #204 is about surfacing the knob, this is about the knob being ineffective once latched.

No existing issue covers the latching behavior. This is not a duplicate.

## Open questions

None. Both questions this investigation raised have been decided by the requester and are recorded as settled decisions under "The two settled decisions" above:

- **decision-survives** — "Clear all states uniformly", accepted as recommended.
- **hwm-vs-live** — "High-water mark", accepted as recommended.

Nothing further is outstanding; a developer can implement the fix from this document and [#206](https://github.com/greerviau/wingman/issues/206) without further input.

## A second defect found while publishing this document

Publishing this file as a hosted Artifact was skipped because `bin/lib/artifact-scan.sh` returned:

```
fail:matches an internal IP/hostname pattern (RFC1918 address or .internal/.corp/.local hostname)
```

This is a false positive. The document contains no hostname and no IP address; the matching text is the filename `config.local.toml`, which the scan's `INFRA_RE` alternative `[A-Za-z0-9.-]+\.(internal|corp|local)\b` (`bin/lib/artifact-scan.sh:72`) reads as an internal `.local` hostname. The same pattern also matches `settings.local.json` and the `playbooks/<type>.local.md` override convention.

Filed separately as [#207](https://github.com/greerviau/wingman/issues/207). It is unrelated to the usage-limit defect and was not fixed as part of this investigation.
