# Design review: three PR-6-downstream reliability fixes

- **Date:** 2026-07-10
- **Reviewer role:** independent design review (no implementation, no revision of the plan).
- **Artifact under review:** `docs/plans/2026-07-10-pr6-downstream-three-fixes-implementation-design.md`
- **Issues:** GH #7 (prompt-freeze anchoring / Fix C), #8 (wake handling / Fix A), #11 (dead-lead orphans + teardown / Fix B).
- **Ground truth read:** `bin/watch-fleet`, `bin/lib/wm-state.py`, `hooks/stop-guard.sh`, `bin/crew-standdown`, `bin/spawn-crew`, `tests/watch-fleet.test.sh`.

## Verdict: approve-with-changes

The plan is thorough and mostly sound.
It grounds every design decision in the real code, self-identifies its top risk (Fix C true-positive regression) and makes real-capture verification a hard merge gate, and it closes both documented #8 paths rather than betting on the partial incident forensics.
The C→A→B sequencing and single-developer allocation are the right calls.

However, two **blocking** correctness holes must be resolved before the build, and several non-blocking items should be addressed.
Neither blocking issue invalidates the approach; both are localized to a single function.

---

## Blocking findings

### B1. Fix C's marker requirement + forward-only window regresses the trust and Bypass captures (§3.2)

This is the exact true-positive regression the plan names as its top risk, and the design as written will trigger it.

Two independent problems:

**(a) The forward-only adjacency window mis-anchors the one-time gates.**
§3.2 specifies that for a phrase-line hit at line `n`, the window `n+1 .. n+WM_PERM_ADJ` must contain `≥ WM_PERM_MIN_OPTS` option rows and exactly one marker row.
This is correct for a *per-tool* gate, where the phrase (`Do you want to proceed?`) is a header line with its options below it.
It is **wrong** for the trust dialog and the Bypass acceptance, because for those the matched phrase is *itself an option row*.
`WM_PERM_PROMPT_RE` matches the trust dialog via its option text `Yes, I trust this folder` and the Bypass gate via `Yes, I accept` / `Yes, and don't ask` (the code comment at `bin/watch-fleet:167-169` states the question text varies across versions and is matched via the option row deliberately).
So the phrase anchor line *is* option row 1; only the remaining option(s) lie in the forward window.
The window therefore sees one option row (not ≥2) and, if the marker sits on the anchor line, zero markers in `n+1..` — failing both new conditions.

**(b) The real trust dialog in the repo's own fixture has no `❯` marker at all.**
`tests/watch-fleet.test.sh:238` (case z10), captured from a live v2.1.206 trust dialog, renders:

```
...
 1. Yes, I trust this folder
   2. No, exit

Enter to confirm
```

There is no `❯` glyph anywhere. Under "exactly one line matching `WM_PERM_MARK_RE`" this fixture matches **zero** markers and fails outright.
§3.5 requires z4–z10 to stay green; z10 **cannot** stay green under the marker requirement as specified.

**Failure scenario:** a session genuinely frozen on the one-time workspace-trust or Bypass-acceptance gate (the highest-value, most common real freeze, hit once per repo at first spawn) is no longer flipped to `blocked`. The first crew in every new repo hangs invisibly — the precise failure the pane backstop exists to catch.

**Why this survives to a blocking severity:** the plan's §3.5 real-capture gate is the thing that *would* catch it, which is good — but the design is likely to fail that gate, so the fix belongs in the design now, not at the gate. The marker/`≥2`-rows logic must be evaluated over a window that **includes the anchor line and spans the full contiguous option block** (scan backward and forward from the anchor to the option-block boundaries), and the marker must be treated as **optional-but-at-most-one** rather than **required-exactly-one** unless the real trust/Bypass captures on the target CLI are re-verified to render a marker. If the real captures render no marker (as z10 suggests), the marker requirement is fatal to trust/Bypass detection and cannot be the primary discriminator for those two gates — the discrimination for them has to come from elsewhere (e.g. the liveness veto, or matching the full multi-row option block).

### B2. Fix A's "mark handled" step is under-specified and can silently drop a mid-turn event (§4.3 step 1)

§4.3 step 1 (the `stop_hook_active` branch) says: allow the stop and "mark `handled` every currently-surfaced (`acked`) unhandled event this owner has."
The intent — mark handled only the **acked ∩ unhandled** set (the events actually blocked on) — is correct.
But the only query primitive the plan defines is `needs-attention --suppress-on handled`, which yields **all** unhandled events, acked or not.
There is no selector for the acked-∩-unhandled intersection.

**Failure scenario:** wingman is woken, the Stop hook blocks once on event E1 (member A, `updated=u1`), wingman reports the roster. While handling, member A transitions `review→blocked`, producing E2 (A, `u2`) — unacked (no fire yet), unhandled. Wingman attempts to stop again; `stop_hook_active` is true. If the hook marks handled everything from `needs-attention --suppress-on handled`, it writes `handled[A]=u2`. E2 is now suppressed from the Stop hook (`--suppress-on handled`) **and** from the watcher (default `--suppress-on ack` = ack OR handled). E2 never surfaces. This is exactly the drop class #8 exists to close, reintroduced.

**Required change:** specify the mark-handled set precisely as the intersection of acked and unhandled (or, equivalently, mark handled only events whose `(id, updated)` was in the block this turn), and give `wm-state` a way to enumerate that set — the current `--suppress-on handled` alone is insufficient. The design should also state the intended interaction between a freshly-armed watcher cycle firing (and acking) a new event mid-turn and the Stop-hook chain that is concurrently running on the same `acked.json`/`handled.json`; as written, that concurrency is unaddressed and is where the drop hides.

The rest of the two-store model is sound: `fire()` keeps setting `ack` synchronously (the re-fire race guard is retained — §4.4 steps 1–3 are correct), the `stop_hook_active` early-exit bounds blocking to once per turn (no deadlock/infinite loop), and keying `handled` by `(id, updated)` correctly re-surfaces genuine new states. B2 is the single hole in an otherwise correct machine.

---

## Non-blocking findings

### N1. Fix C's marker requirement increases version-coupling on the true-positive side; the one-time capture gate does not guard against it (§3.3, §3.5)

Even after B1 is fixed, requiring/parsing the `❯` glyph and its spacing couples true-positive detection to a CLI-render detail that PR #6 deliberately avoided depending on for trust/Bypass. §3.5's real-capture verification is a one-time, pre-merge, manual check; it cannot catch a *future* CLI version that changes marker rendering, which would silently degrade to a missed-freeze (false negative) — arguably worse than the false positive being fixed. Recommend either keeping the marker strictly secondary (a false-positive discriminator that can only *reject*, never be *required* to accept) or adding a lightweight periodic canary. The plan's framing that the residual is "strictly narrower than PR #6's" is true for false positives but does not account for the enlarged false-negative surface.

### N2. The liveness veto interacts badly with the startup trust/Bypass gate (§3.2 condition 2)

`crew-add` stamps a fresh `updated` at spawn (`wm-state.py:224`). A member that hits the one-time trust/Bypass gate immediately on launch never runs `crew-set`, so its `updated` stays at the spawn time and is "fresh" for up to `WM_PERM_LIVENESS_GRACE` (2×INTERVAL). The veto therefore delays detection of precisely the most common real freeze by a grace window. Detection still eventually fires (once the spawn stamp ages out), so this is latency, not a miss — but the veto should arguably apply only after the member has self-reported at least once (i.e. distinguish a spawn stamp from a genuine self-report), or the grace kept tight.

### N3. Fix A's path-1 beacon-staleness advisory has no delivery channel as designed (§4.5)

The advisory for a *live* lead with a stale watcher beacon is explicitly **not** an attention-state flip ("do not invent a new attention status"). But `watch-fleet` only wakes wingman when `needs-attention` returns a hit (an `ATTENTION_STATES` member). A working lead with a stale beacon is not in an attention state, so it never appears in `needs-attention`, so the watcher never fires, so the advisory — living only in the wake-file roster render — is delivered only if wingman is woken for some *other* reason. When nothing else fires, the advisory is never seen, which is the same path-1 gap it is meant to mitigate. The plan already de-prioritizes this sub-item and permits deferral to a follow-up PR; recommend deferring it (or giving it a real wake channel) rather than shipping it as designed, so it is not mistaken for working coverage. This does not affect A or B.

### N4. `cmd_reconcile` is invoked by every owner's watcher; Fix B enlarges its racy global read-modify-write (§5.1)

`reconcile` is global (scans the whole roster) and is called every loop by wingman's watcher **and** by each lead's watcher (`watch-fleet:285`). It already does a read-modify-write of `crew.json` from multiple concurrent processes (a pre-existing lost-update hazard, mitigated only by atomic file replace, not by locking). Fix B adds re-parent + `orphaned_from` + `died`-note enrichment to that critical section, widening the window for a concurrent reconcile to clobber the mutation. Functionally the re-parent is idempotent and the target (grandparent = `""`) is correct regardless of which watcher performs it, and the enriched `died` event correctly surfaces only under owner `""` (wingman) since leads are top-level — so correctness is preserved in the common case. But the enlarged racy section is worth noting; consider scoping the orphan mutation to wingman's watcher, or a lightweight lock around the reconcile write.

### N5. Worktree teardown correctness depends entirely on the `orphaned_from` cascade fix (§5.1 / §5.2)

The teardown fallback removes an orphan's worktree only when `crew-standdown <dead-lead>` actually cascades to the re-parented worker — which works only if `descendants_inclusive`/`cmd_standdown` honor `orphaned_from` (the §5.1 coupling). If that half regresses, the worktree leaks again (the original #11 symptom). The plan puts both in Fix B, which is correct; flagging so the test in §5.3 ("cascade after re-adopt") is treated as guarding the teardown too, not just the reap. Also note `git worktree remove --force` discards any uncommitted work in a crashed member's tree — acceptable given the member is being torn down, but worth an explicit line in the design.

### N6. The Path-1 incident evidence is mildly self-undermining (§1.2)

The reconstruction infers Path 1 from a wake file frozen at 18:57 in the **pre-#6** single-event format. A pre-#6-format wake file is evidence of a fire that occurred *before* #6 merged; it is therefore as consistent with "a stale artifact predating the incident" as with "the last fire before the watcher died at incident time." The conclusion may still be right, and it does not matter to correctness because the plan closes both paths — but the wake-file-format argument should not be presented as decisive. This is a documentation nuance, not a design defect.

---

## Summary of what must change before build

| # | Fix | Severity | Change |
|---|-----|----------|--------|
| B1 | C | blocking | Evaluate marker/`≥2`-rows over a window that includes the anchor line and the full option block; do not *require* a marker for trust/Bypass unless real captures on the target CLI are re-verified to render one (z10 has none). |
| B2 | A | blocking | Precisely define the `stop_hook_active` mark-handled set as acked-∩-unhandled and give `wm-state` a way to enumerate it; specify the watcher-fire vs Stop-hook-chain concurrency on the shared stores. |
| N1 | C | non-blocking | Keep the marker strictly rejecting-only, or add a canary against future CLI render changes. |
| N2 | C | non-blocking | Don't let a spawn-time `updated` stamp trigger the liveness veto for the startup gate. |
| N3 | A | non-blocking | Give the beacon advisory a real wake channel, or defer it (plan already permits). |
| N4 | B | non-blocking | Note/mitigate the enlarged concurrent read-modify-write in `reconcile`. |
| N5 | B | non-blocking | Treat the `orphaned_from` cascade test as guarding worktree teardown; document the force-remove data-loss. |
| N6 | — | non-blocking | Soften the Path-1 wake-file-format evidence claim. |

The approach, sequencing, and allocation are approved. Resolve B1 and B2, then this is ready to build.
