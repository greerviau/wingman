# False-positive prompt-freeze detection in `bin/watch-fleet` (2026-07-10)

## Summary

On 2026-07-10 the owner-scoped watcher of lead `own-end-to-end-fix-three-wingman-lead` flipped developer `implement-the-approved-consolida-developer` to `blocked` with the blocker "frozen on a permission/trust prompt with no one at its terminal".
The session was not frozen: when the user attached via `bin/crew-takeover`, it was working normally with no prompt on screen.

Root cause, confirmed by reproducing the detector's exact pipeline against the live pane: the prompt-freeze detector in `bin/watch-fleet` does a case-insensitive substring grep of the entire visible pane, and the developer's pane legitimately contained the string `Do you want to proceed?` inside a diff of test code it was writing.
The developer is implementing the stall-detection plan, and the matching line is its own E2E test fixture that simulates a frozen permission prompt.
The detector detected the source code of a test for the detector.

The defect then reproduced itself a second time during this investigation: the same detector flipped the analyst session writing this report (`investigate-report-mode-no-devel-analyst-3`) to `blocked` while it was actively working, with pane output age of about 1 second at the time of the check.
That session's pane contained the signature strings because it was grepping for them and drafting this report.
Two misfires in one day, both on sessions whose pane content *discusses* permission prompts, and neither showing an actual prompt.

## How the detector works today

The detection lives in the watcher's blocking loop (`bin/watch-fleet:131-195`):

1. For every direct report currently in status `working`, it captures the pane of the member's tmux window with `wm_tmux_pane_text`, which is `tmux capture-pane -p -t <window>` (`bin/lib/common.sh:95`).
   Without `-S`, this captures only the currently visible screen; Claude Code runs in the alternate screen buffer, so there is no scrollback to capture either way (verified: `capture-pane -p` and `capture-pane -p -S -` both return the same 68 lines for this window).
2. It greps that text with `grep -qiE "$WM_PERM_PROMPT_RE"`, where the default pattern is
   `Do you want to |trust this folder|Bypass Permissions mode|Yes, I accept|Yes, and don.t ask` (`bin/watch-fleet:135`).
3. On any match it immediately rewrites the member's status file to `blocked` with the frozen-on-prompt blocker (`bin/watch-fleet:190-194`), which flows through `needs-attention` and fires the watcher, waking the owner.

There is no anchoring, no confirmation, and no liveness cross-check: a single snapshot, a single case-insensitive substring hit anywhere on the screen, one poll, one flip.

## Reproduction

The false positive is still live and reproducible right now against the running developer session:

```
$ tmux capture-pane -p -t "wingman:wm-implement-the-approved-consolida-developer" \
    | grep -niE "Do you want to |trust this folder|Bypass Permissions mode|Yes, I accept|Yes, and don.t ask"
18:      134 +tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z4 'echo "Do you want to proceed?"; sleep 600'
```

The matching line is mid-screen transcript content: a diff hunk of `tests/watch-fleet.test.sh` that the developer is writing, in which a fake frozen prompt is simulated exactly so the new stall detector can be tested against it:

```
130 +# --- permission freeze stays the more specific diagnosis ----------------------
...
134 +tmux new-window -d -t "$WM_TMUX_SESSION" -n wm-z4 'echo "Do you want to proceed?"; sleep 600'
...
137 +assert_contains "permission prompt fires as blocked, not stalled" "$out6" "blocked: z4"
```

Meanwhile the bottom of the same pane, where a real prompt would render, shows a healthy working session: the animated status line (`✽ Tinkering… (12m 20s · ↓ 43.5k tokens)`), an empty input box (`❯`), and the `auto mode on` footer.
No dialog, no options list, nothing awaiting input.

The flip is recorded in the member's status file (`~/.wingman/crew/implement-the-approved-consolida-developer.json`, `updated: 2026-07-10T20:25:10Z`, written by the lead's watcher since it owns this member) and in the lead's wake payload (`~/.wingman/wake-own-end-to-end-fix-three-wingman-lead`).

### Second occurrence: the investigating session itself

While this report was being written, the watcher flipped the investigating analyst session (`investigate-report-mode-no-devel-analyst-3`) to `blocked` with the identical frozen-on-prompt blocker.
That session was mid-turn with pane output about 1 second old at the time of the check, and had self-reported progress moments earlier.
Its pane necessarily contains the signature strings: the reproduction grep, the detector's pattern quoted from `bin/watch-fleet:135`, and this report's own text.
This is an independent confirmation of the same root cause, and it demonstrates the feedback hazard concretely: any session that reads, writes, tests, or *investigates* the detector triggers it.
Expect repeated re-flags on such sessions until the fix lands; their owners should treat frozen-on-prompt flips on wingman-repo crew as suspect in the interim.

## Root cause

The trigger is confirmed: pane content that merely *mentions* a prompt phrase satisfies the detector, because it matches generic substrings anywhere on the visible screen.
Several design properties compound into this:

1. **Substring patterns over arbitrary transcript content.** `Do you want to ` (note the trailing space, no anchor) is ordinary English.
   Claude Code's transcript area displays everything a crew member reads or writes, so diffs, plan text, and file contents flow through the pane.
   Any crew member working on wingman itself is near-guaranteed to trip it: the signature strings appear verbatim in `bin/watch-fleet:135`, in the reliability plans under `docs/plans/`, and now in the test suite being written.
2. **Case-insensitive matching** (`grep -i`) widens the patterns further, although it was not needed for this hit.
3. **No positional anchoring.** A real prompt renders as a dialog at the bottom of the screen; this match was mid-screen scrollback-of-the-transcript at line 18 of 68.
4. **No prompt-shape corroboration.** A real Claude Code prompt pairs the question with a numbered options list (`❯ 1. Yes`, `2. No, …`); the detector requires only the question phrase.
5. **No input-idle or stability requirement.** A frozen prompt is static; a working session's pane changes every few seconds (the spinner glyph and the elapsed-time counter tick continuously).
   The detector fires on a single snapshot, so a string scrolling past during active work is indistinguishable from a stuck dialog.
6. **No liveness cross-check.** A genuinely frozen session cannot run `crew-set`, yet the detector ignores how recently the member's own status file was updated.

A note on the "excluding scrollback" idea from the directive: scrollback is not the culprit.
Claude Code's alternate screen means `capture-pane` already sees only the live screen; the problem is the transcript region *within* the visible screen.

## Consequences beyond the wake

The false flip has a second-order cost worth naming: the watcher rewrites the member's status file, so the member's true state (`working`, with its real summary) is masked until the member's next `crew-set` self-heals it.
As of this writing the status file still reads `blocked` while the session works.
If the member had been carrying a real `blocker` string, it would have been overwritten.
The owner also burns a wake and possibly an escalation to the user on a non-event.

## Recommended fix

Recommended: harden the detector with three cumulative conditions, all cheap and all local to `bin/watch-fleet`.
Each one independently would have prevented this incident; together they make the check robust rather than coincidental.

1. **Require pane stability across consecutive polls (input-idle).**
   Keep the last capture's hash per member; flip only when the regex matches *and* the full pane text is byte-identical to the previous poll's capture (one extra `INTERVAL`, ~5s of added latency on a real freeze, which is acceptable for a one-time-per-repo gate).
   This is the strongest single discriminator: a working Claude Code pane is never identical across polls because the status-line timer ticks every second, while a frozen prompt is pixel-static.
2. **Anchor to the prompt UI shape at the bottom of the screen.**
   Search only the last ~25 lines of the capture (`tail -25`), and require both the question phrase *and* a numbered-options line (`^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]`) within that window.
   Transcript diffs mid-screen stop matching entirely; a real dialog always renders both parts at the bottom.
3. **Tighten and de-genericize the patterns.**
   Match the full fixed phrasings case-sensitively (`Do you want to proceed\?`, `Do you trust the files in this folder\?`, `Bypass Permissions mode`), keeping `WM_PERM_PROMPT_RE` overridable as today.
   This alone is insufficient (the test fixture contains the exact full phrase, which is precisely why conditions 1 and 2 matter), but it shrinks the accidental-match surface.

Implementation sketch: replace the single `grep -qiE` at `bin/watch-fleet:190` with a small helper that (a) captures the pane, (b) compares against `$WM_HOME/pane-<id>.hash` from the prior iteration and updates it, (c) applies the anchored two-part match to the tail of the capture, and (d) flips only when both hold.
State files keyed per member under `$WM_HOME` fit the existing pidfile/beacon pattern; stale hashes are harmless and can be cleaned by `crew-standdown`.

Follow-ups (not required to close this incident):

- **Status-file freshness veto**: skip the check for members whose status file was updated within the last poll interval or two, since a frozen session cannot run `crew-set`.
  Necessary-but-not-sufficient on its own (a busy member may legitimately not update for many minutes), which is why it is a veto, not a detector.
- **Spinner veto**: a pane whose bottom region contains the animated activity line is demonstrably alive; treat its presence as a negative signal.
  Fragile against harness UI changes, so lower value than the stability check, which captures the same signal generically.
- **tmux activity metadata**: consult `#{window_activity}` and require N seconds of no pane activity before flagging; roughly equivalent to condition 1 but coarser.
- **Coordinate with the in-flight stall-detection work**: the flagged developer is implementing pane-based stall detection in the same file (its test asserts "permission prompt fires as blocked, not stalled"), so these hardening conditions should land as part of, or rebased onto, that work rather than as a parallel edit to `bin/watch-fleet`.

## Immediate remediation for the affected member

No action strictly required: the developer's next `crew-set` overwrites the false `blocked` state.
If the lead wants the roster clean sooner, a `bin/crew-say implement-the-approved-consolida-developer "your status file was falsely flipped to blocked by a watcher false positive; refresh it"` prompts an immediate self-heal.
The false event has already been acked by the watcher's fire path, so it does not re-fire.

## Evidence index

- Detector code: `bin/watch-fleet:131-195` (pattern at 135, grep-and-flip at 190-194).
- Pane capture helper: `bin/lib/common.sh:95` (`tmux capture-pane -p`, visible screen only).
- Live reproduction: grep of the flagged window's pane matches at line 18 of 68 (test-fixture diff), while the pane bottom shows an active session with no dialog.
- False flip record: `~/.wingman/crew/implement-the-approved-consolida-developer.json` (`blocked`, updated 2026-07-10T20:25:10Z) and `~/.wingman/wake-own-end-to-end-fix-three-wingman-lead`.
