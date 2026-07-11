# Implementation design: three PR-6-downstream reliability fixes

- **Date:** 2026-07-10
- **Type:** Consolidated technical design / implementation plan (architect deliverable).
- **Scope:** wingman repo only.
- **Input:** `docs/plans/2026-07-10-pr6-downstream-three-fixes-decomposition.md` (the effort framing and shared-surface conflict map).
- **Fixes covered:** GH #8 (wake handling / handled-marker), GH #11 (dead lead orphans workers + robust teardown), GH #7 (prompt-freeze anchoring).
- **Shared surface:** `bin/watch-fleet`, `bin/lib/wm-state.py`, `hooks/stop-guard.sh`, `bin/crew-standdown`, `bin/spawn-crew`.

This plan is detailed enough that a developer can build all three fixes from it without further design.
It gives a concrete design per fix, the incident reconstruction #8 requires, the exact PR sequence with the shared-surface integration order, and a recommendation on developer allocation.

---

## 0. TL;DR for the developer

- Build **all three fixes sequentially, on one branch chain, by a single developer**, each PR rebased on the prior. Rationale in §6.
- **PR order: C (prompt-freeze) → A (wake handling) → B (dead lead).** C first because it is self-contained *and* because the very act of building A and B (editing `watch-fleet` and reading docs full of prompt phrases) trips the current false-positive detector; landing C first protects the rest of the build.
- **Fix C:** require the **full contiguous option block (anchor included) to hold ≥2 option rows**, treat the `❯` marker as **rejecting-only** (never required - real captures like z10 render none), and add a status-freshness liveness veto that does not fire on the spawn stamp. Verify against real captured dialogs before merge.
- **Fix A:** add a `handled` store distinct from `ack`; `fire()` keeps setting `ack` (closes the re-fire race), the Stop hook enforces one roster-report block per event and marks handled **exactly the per-turn scratch set** (not all unhandled), with a flock serializing the shared stores. The path-1 beacon advisory is **deferred** (no wake channel as designed).
- **Fix B:** `cmd_reconcile --owner ""` detects a dead owner with live descendants, re-parents the orphans to the dead owner's parent (soft re-adopt) and enriches the `died` event so wingman is offered re-adopt / cascade-standdown / takeover; `crew-standdown` gains a worktree-removal fallback keyed on a path recorded at spawn/creation time.

---

## 1. Incident reconstruction for #8 (required first step)

Issue #8 asks that the live incident's actual path be reconstructed from the supervising session's state home before designing the fix, to confirm which of two documented paths occurred:

- **Path 1** - no armed watcher cycle at transition time: after a fire, the owner did not re-arm, so later transitions had nothing to fire through.
- **Path 2** - Stop-hook ack with incomplete handling: the hook acked an event it surfaced, and because handling was incomplete the acked event never re-fired.

### 1.1 What the surviving state home shows

Reconstructed from `~/.wingman` on 2026-07-10 (the supervising session's live state home):

- **Affected member:** `implement-the-approved-consolida-developer`, a developer owned by lead `own-end-to-end-fix-three-wingman-lead` (confirmed in `crew-archive.jsonl`: `parent` = that lead).
  This is the same lead/developer pair named in both `docs/analysis/2026-07-10-prompt-freeze-false-positive.md` and issue #11's motivation.
- **A stale, unconsumed wake file survives:** `~/.wingman/wake-own-end-to-end-fix-three-wingman-lead`, mtime `2026-07-10 18:57` local, containing a single event in the **pre-#6 single-event format** (`# Crew need your attention` + one `- **id** [status] note` line, with none of the `## New events` / `## Full roster` sections the merged `fire()` now writes):

  ```
  # Crew need your attention

  - **implement-the-approved-consolida-developer** [done] frozen on a permission/trust prompt with no one at its terminal; ...
  ```

  For contrast, the current top-level `~/.wingman/wake` is in the post-#6 two-section format, confirming the lead's file is a genuinely older artifact.
- **acked.json today** contains none of these members (it has rotated to five later-effort members), and the developer's and lead's `crew/<id>.json` status files were removed at prune (only their `.launch.sh` / `.sysprompt.md` remain).
  So the granular per-event `acked`-vs-`updated` trail *at incident time* is no longer on disk; the reconstruction rests on the surviving wake file, the archive records, and the mechanism.

### 1.2 The inference: Path 1 (corroborated, not proven, by the surviving artifacts)

The strongest evidence is **mechanistic correlation**, not the wake file alone.
This lead (`own-end-to-end-fix-three-wingman-lead`) is one of the two leads independently root-caused in issue #11's motivation as having had its `watch-fleet` loop die on the pre-#9 SIGURG crash, ending the lead session and silently orphaning its developer.
A dead lead watcher is exactly Path 1: with no armed cycle, the developer's later `working → review` (PR-ready) transition had nothing to fire through, so the ready PR surfaced only on a manual check.
The #8 symptom (missed re-notification) and the #11 symptom (orphaned worker) are two faces of one event - the owner's watcher stopped.

The surviving wake file corroborates but does not prove this.
`fire()` rewrites the owner's wake file on every fire; the lead's `wake-own-end-to-end-fix-three-wingman-lead` is frozen at mtime `18:57` in the **pre-#6 single-event format**, and no later fire advanced it.
That is consistent with "no fire occurred after the watcher died," but a pre-#6-format file is equally consistent with "a stale artifact from a fire that predated the incident" (this lead was developing PR #6, so its own watcher ran pre-#6 code throughout).
So the mtime is corroborating, not decisive; the mechanistic correlation with the #9/#11 root cause is what carries the conclusion.
This uncertainty does not affect the fix: per §1.3 the design closes **both** paths regardless of which one the incident took.

### 1.3 Consequence for the design

- Path 1's **concrete cause** (the watcher process crashing on SIGURG) is already fixed on `main` by #9 (`trap '' URG` in `watch-fleet`).
- Path 1's **consequence for a lead's workers** (orphaned, unwatched, invisible) is closed by **Fix B** (dead-owner detection + re-adopt).
- Path 1's **generic residual** (an owner that never re-arms because it never attempts to stop) is addressed by a light watcher-beacon-staleness surfacing, folded into Fix B (§4.3).
- **Path 2 was not the incident**, but it is a real latent gap the §9.1 follow-up targets, and it cannot be pinned out from the surviving data with certainty. Because both paths produce the identical symptom and the granular acked-vs-status trail is unrecoverable, the robust posture is to close **both**: the handled-marker (Fix A, path 2) and the dead-owner/beacon detection (Fix B + §4.3, path 1). The plan does not bet on one path.

Record this reconstruction verbatim in the Fix A PR description so the closing of #8 is auditable.

---

## 2. Ground-truth notes that shaped the design

Read from the current code so the design fits the real system:

- **`fire()` already sets a fire-time `ack`** (`bin/watch-fleet:272-274`) and writes the two-channel wake (deltas + owner-scoped roster). The re-fire race Fix A must respect is that removing this ack lets a freshly-armed cycle's top-of-loop `needs-attention` re-fire the still-unacked event.
- **`needs-attention` suppresses on `acked[id] == updated`** (`wm-state.py:609`); every `crew-set` mints a fresh microsecond `updated` (`now()`, `wm-state.py:97-102`), so a new state always re-surfaces. Both `watch-fleet` and `hooks/stop-guard.sh` call `needs-attention` and share `acked.json`.
- **The Stop hook acks what it surfaces** (`stop-guard.sh:96-98`) and exits early on `stop_hook_active` (`:25-27`). This is the premature-ack that path 2 describes.
- **`cmd_reconcile` is global, not owner-scoped** (`wm-state.py:312-332`): it scans the whole roster and flips any live-state member whose window is gone to `died`. `watch-fleet` calls it every loop (`:285`). So **wingman's watcher reaches a dead lead through `reconcile`** - the natural home for Fix B's dead-owner detection.
- **Worktrees are created by the developer, not `spawn-crew`.** The developer playbook (`playbook/developer.md:12-17`) has the member run `git worktree add ../<repo>-<slug> -b <branch>` itself and states "Wingman does not manage worktrees; you own this step." `crew-standdown` explicitly "does not touch worktrees" (`:4-6`). So the decomposition doc's "worktree path recorded at spawn time" cannot be taken literally for global scope (spawn does not know which repo, and the slug is the member's choice); §5.2 resolves this.
- **`crew-add` writes a fixed record shape** (`wm-state.py:207-225`); adding a `worktree` field is a one-line addition plus a `--worktree` arg.
- **`prune` already drops `acked.json` entries** for removed members (`wm-state.py:439-443`); a new `handled.json` must be pruned the same way.
- **The prompt detector today** (`watch-fleet:162-235`) uses `WM_PERM_LEAD_RE` (`^[^[:alnum:]]*([0-9]+\.[[:space:]])?`) - the optional option-row prefix is exactly what admits the residual (a numbered list item beginning with a question phrase). The tail window is `WM_PERM_TAIL=25`, adjacency `WM_PERM_ADJ=3`, options `WM_PERM_OPTION_RE`.

---

## 3. Fix C - prompt-freeze anchoring (#7)

### 3.1 Goal and constraints

Stop flipping a parked (byte-static) pane that shows a verbatim, column-zero quote of a full dialog block to `blocked`, **without** regressing the true-positive coverage the detector must keep:

- per-tool permission gates (`Do you want to proceed?`, `Do you want to make this edit to <file>?`, `Do you want to create <file>?`);
- the one-time workspace-trust dialog (matched via its `Yes, I trust this folder` option row);
- the one-time Bypass Permissions acceptance (matched via its `Yes, I accept` / `Yes, and don't ask` rows).

Everything stays overridable for other harnesses (the `WM_PERM_*` env knobs).

### 3.2 Design: full-option-block matching (primary) + liveness veto (secondary), marker rejecting-only

The review (B1) established that the repo's own real capture contradicts a marker requirement: the z10 trust-dialog fixture (`tests/watch-fleet.test.sh:238`, captured from live v2.1.206) renders **no `❯` glyph at all** - it signals the selected option by *indentation* (` 1. Yes, I trust this folder` vs `   2. No, exit`) - and for both the trust and Bypass gates the matched phrase is *itself an option row* (`WM_PERM_PROMPT_RE` matches `Yes, I trust this folder` / `Yes, I accept`), so a forward-only `n+1 ..` window sees only the *remaining* option and zero markers.
So a required-exactly-one-marker check over a forward-only window would fail z10 and stop flipping the highest-value real freeze (the one-time startup gate). Both defects are corrected below.

Add these cumulative conditions to the existing phrase/stability checks. All are cheap and local to `bin/watch-fleet`.

**Condition 1 - the full contiguous option block, anchor included (the content discriminator).**
For a phrase-line hit at line `n`, do **not** search a forward-only window.
Instead determine the **contiguous option block** around the anchor by scanning **both directions** from `n` to the option-block boundaries:

- if the anchor line `n` itself matches `WM_PERM_OPTION_RE` (the trust/Bypass case, where the phrase *is* an option row), the block starts at `n` and extends downward through consecutive option rows;
- otherwise (the per-tool case, where the phrase is a header) the block is the run of consecutive option rows that begins within `WM_PERM_ADJ` lines below `n`.

"Consecutive" tolerates blank lines between rows (the z10 capture has a blank line before `Enter to confirm`); treat a run broken only by blank lines as contiguous, and stop at the first non-blank non-option line.

Require the block to contain **at least `WM_PERM_MIN_OPTS` (default 2) option rows, counting the anchor if it is one**.
This is the real strengthening and it holds for every true positive: z10 = anchor `1. Yes, I trust this folder` + `2. No, exit` = 2 rows ✓; per-tool z8/z9 = header + `1. Yes` + `2. No` = 2 rows ✓; Bypass = its ≥2 acceptance rows ✓.
It rejects the PR-#6 residual variant of a *single* stray numbered item whose text begins with a question phrase (only one option row → fails).

```sh
# A real gate offers at least this many options (block includes the anchor row).
WM_PERM_MIN_OPTS="${WM_PERM_MIN_OPTS:-2}"
```

**Marker - rejecting-only, never required (N1).**
The `❯` selection marker is **optional**: real captures may render none (z10), so requiring it is fatal.
Use it only to *reject*: if the option block contains **more than one** marker row, reject (a real dialog highlights at most one; a loose verbatim quote may duplicate).
Zero or one marker passes.

```sh
# The highlighted-option glyph, if the CLI renders one. Used only to REJECT a
# block bearing more than one; never required to accept (real captures render none).
WM_PERM_MARK_RE="${WM_PERM_MARK_RE:-^[[:space:]]*❯[[:space:]]*[0-9]+\.[[:space:]]}"
```

This marker rule is deliberately weak; the discrimination for the trust/Bypass gates comes from the full multi-row option-block match (condition 1) and the liveness veto (condition 2), **not** from the marker - exactly as B1 requires when the real captures render no marker.

**Condition 2 - negative-liveness veto (the actively-working guard).**
A genuinely frozen session cannot run `crew-set`, so its status file goes stale.
Before flipping, re-read the member's `crew/<id>.json`; **veto the flip** if the member has self-reported since spawn (see N2 handling below) *and* its `updated` is fresher than `WM_PERM_LIVENESS_GRACE` (default two poll intervals) - it self-reported too recently to be frozen.

```sh
WM_PERM_LIVENESS_GRACE="${WM_PERM_LIVENESS_GRACE:-$(( INTERVAL * 2 ))}"
```

This directly kills the two live misfires the incident report documented (both were *actively working* sessions grepping/drafting the detector's own strings - their status files were seconds old).
It is a **veto, not a detector**: a legitimately busy member may not self-report for many minutes, so freshness alone cannot flag, but its *recency* can safely acquit.

**N2 - do not let the spawn-time stamp trigger the veto for the startup gate.**
`crew-add` seeds a fresh `updated` at spawn; a member frozen on the one-time trust/Bypass gate *immediately on launch* never runs `crew-set`, so its `updated` stays at (near) the spawn time and would look "fresh," delaying detection of the most common real freeze by a grace window.
Fix: the veto applies only when the member has genuinely self-reported at least once since spawn.
Add an immutable `spawned_at` field in `cmd_crew_add` (never overwritten by `crew-set`), and gate the veto on `status.updated != spawned_at` (i.e. a real self-report has replaced the spawn stamp) in addition to freshness.
Then the startup-gate freeze is never vetoed and fires on the normal shape+stability path.

The stability condition (byte-identical across two polls) is kept as-is; it does not help a parked-and-quiet pane (that is the residual), so condition 1 (full option block) carries the discrimination for a parked pane and condition 2 (liveness) carries it for an actively-working pane.

### 3.3 Residual, true-positive coverage, and the false-negative surface

- **Residual (accepted, documented):** a *parked* pane whose tail holds a verbatim ≥2-row option-block quote with ≤1 marker, that has *also* not self-reported within the liveness grace. This is strictly narrower than PR #6's residual (the single-stray-item variant is now rejected by the ≥2-rows rule) and the actively-working variant is rejected by the liveness veto.
- **True positives preserved:** per-tool gates, the z10 trust dialog (2-row block, no marker), and the Bypass acceptance all satisfy condition 1 and are not vetoed (frozen → stale status). Verified as the §3.5 gate.
- **False-negative surface (N1, must be weighed):** condition 1 leans on the option-block *shape*, which is more version-stable than the marker, so this is low-risk - but any future CLI that renders a single option, or changes the option-row format, would silently degrade to a *missed* freeze. That is arguably worse than the false positive being fixed. Mitigation: the marker stays strictly rejecting-only (done), and a lightweight periodic real-capture canary is recommended as a follow-up (§9) so a future render change is caught actively rather than as a silent miss.

### 3.4 Implementation notes

- Rework `prompt_shape_in` to compute the option block by scanning outward from each phrase-line hit (both the anchor-is-option and anchor-is-header cases), then apply: `option_rows >= WM_PERM_MIN_OPTS` AND `marker_rows <= 1`. bash-3.2-safe: slice the block with `sed -n`, count with `grep -cE "$WM_PERM_OPTION_RE"` and `grep -cE "$WM_PERM_MARK_RE"`.
- Keep the block bounded (a real option block is a handful of lines); cap the outward scan (e.g. at `WM_PERM_TAIL`) so a pathological pane cannot make it walk far.
- The liveness veto reuses the existing `wm_py`/`beat_age` pattern already in `watch-fleet`: a one-liner reading `crew/<id>.json` `updated` (and the roster `spawned_at`) and printing the age in seconds, compared to `WM_PERM_LIVENESS_GRACE`; prefer this over a new subcommand.
- Keep `PFC_SHAPE` semantics intact (the stall-check hold-off in the loop depends on it): `PFC_SHAPE=1` must still be set whenever the *shape* matched (phrase + ≥2-row block, marker ≤1), independent of the stability and liveness outcomes, so a prompt-shaped-but-unconfirmed pane still holds off the stall check.

### 3.5 Testing (must precede merge)

- **Real-capture verification (blocking merge gate):** follow the §7.1 recipe from `docs/plans/2026-07-10-wingman-reliability-consolidated-implementation.md` to capture a live per-tool gate, the workspace-trust dialog, and the Bypass acceptance on the current CLI. Confirm each still fires under the new conditions, **and record whether each renders a `❯` marker** (z10 suggests the trust dialog does not) so the marker rule's rejecting-only posture is validated against reality, not assumption.
- **Existing z4-z10 must stay green** - in particular z10 (2-row trust block, no marker) now passes *because* the marker is not required and the block spans the anchor; this is the direct check that B1 is resolved.
- **New regression fixtures in `tests/watch-fleet.test.sh`:**
  - a parked pane quoting a single stray numbered item beginning with a question phrase → stays `working` (rejected by ≥2-rows);
  - a parked pane quoting a full ≥2-row dialog block with a *duplicated* marker → stays `working` (rejected by marker ≤1);
  - an actively-working member whose pane quotes a full dialog but whose status file is fresh *and post-spawn* → stays `working` (liveness veto);
  - a member frozen on the startup gate whose `updated` is still the spawn stamp → **fires** `blocked` (N2: veto does not apply to the spawn stamp).

### 3.6 Files touched by Fix C

- `bin/watch-fleet` - `prompt_shape_in`, `prompt_freeze_check`, the new `WM_PERM_MARK_RE` / `WM_PERM_MIN_OPTS` / `WM_PERM_LIVENESS_GRACE` knobs and header comment.
- `bin/lib/wm-state.py` - `cmd_crew_add` gains an immutable `spawned_at` field (needed by the N2 veto gate); this small addition lands in PR1 (Fix C) since it is the first consumer.
- `tests/watch-fleet.test.sh` - new regression fixtures (§3.5).

---

## 4. Fix A - wake handling / handled-marker (#8)

### 4.1 Goal

Close path 2: an event that was *surfaced* (acked) but *not fully handled* must be able to re-fire / re-block, rather than being permanently suppressed by a premature ack - **without** reintroducing the re-fire race that the fire-time ack exists to prevent.
This is the §9.1 deferred item: a `handled` marker distinct from `ack`, keyed by `(id, updated)`, respected by both `fire()` and `needs-attention`.

### 4.2 Design: two-store model (`ack` = surfaced, `handled` = completed)

Introduce a second store `handled.json` (id → updated), alongside `acked.json`, with distinct semantics:

- **`ack` ("surfaced"):** this exact `(id, updated)` event has been *delivered* to the owner at least once (by a `fire()` or by a Stop-hook block). Set immediately by `fire()` (unchanged from today) and by the Stop hook when it blocks. **Purpose: suppress the watcher from re-firing** an event that is currently being handled - this is precisely the guard that closes the re-fire race.
- **`handled` ("completed"):** the owner has *completed* handling this `(id, updated)` event (surfaced it and reported the roster). Set only by the Stop hook, only when it lets a stop proceed after enforcing the roster-report block.

`needs-attention` gains a suppression selector plus an acked filter:

```
wm-state needs-attention --owner <o> [--suppress-on ack|handled] [--only-acked]
```

- Default `--suppress-on ack` (back-compatible; the **watcher / `fire()` gate** uses this - suppress if `acked[id] == updated` OR `handled[id] == updated`).
- The **Stop hook** passes `--suppress-on handled` (suppress only if `handled[id] == updated`), so a surfaced-but-unhandled event is still visible to the hook and still blocks once.
- `--only-acked` additionally filters to events whose `(id, updated)` is currently in `acked.json`. `--suppress-on handled --only-acked` therefore enumerates exactly **acked ∩ unhandled** - the set B2 requires. (This primitive exists for completeness/inspection; the Stop hook itself uses the more precise per-turn scratch set below, which is immune to a concurrent mid-turn `ack`.)

Add a subcommand mirroring `ack`:

```
wm-state mark-handled --id <id> --updated <stamp>    # writes handled.json (locked; see §4.5)
```

(`ack` stays as-is.)

### 4.3 The Stop-hook state machine (race-free, with an exact mark-handled set - B2)

The review (B2) showed the drop: if the `stop_hook_active` pass marks handled *all* unhandled events, a **new** transition that appeared mid-turn (member `A` goes `review → blocked` producing `(A, u2)`) - or an event a freshly-armed watcher cycle `ack`s mid-turn - gets marked `handled` and silently dropped, reintroducing #8.
The mark-handled set must be **exactly the `(id, updated)` tuples this turn's block enumerated**, not re-derived at the second pass from the (possibly mutated) stores.

Persist that set in a per-owner, per-turn **scratch file** `$WM_HOME/stop-blocked-<owner-key>.json` (owner-key sanitized like the wake/pid files). The state machine:

1. **`stop_hook_active` not set** (first stop attempt this turn): compute this owner's unhandled events via `needs-attention --owner O --suppress-on handled`.
   - If any exist: **write the scratch file** with their exact `(id, updated)` tuples; **`ack`** each not-yet-acked one (so a freshly-armed watcher cycle will not also re-fire them); **block** with the strengthened roster directive (already present from PR #6). Do **not** mark `handled` yet.
   - If none exist: remove any stale scratch file and fall through to the existing no-watcher / pending-ask branches unchanged.
2. **`stop_hook_active == True`** (we already blocked once this turn): read the scratch file, **`mark-handled` exactly the tuples it lists**, delete the scratch, and allow the stop.
   - A tuple that is no longer the member's current `updated` (the member transitioned again since the block) is marked handled at its *old* `updated` only - harmless, because the member's *new* `(id, updated)` is a distinct key that is neither acked nor handled and re-surfaces normally.
   - Defensive: `stop_hook_active` with no scratch (should not happen) marks nothing and allows the stop.

This yields: **every attention event - whether first seen by a watcher `fire()` or first seen by the Stop hook - gets exactly one enforced Stop-hook block (guaranteeing the roster report) before the owner may stop, and only the events actually blocked that turn are marked `handled`.** A mid-turn new transition or a mid-turn watcher-`ack`ed event is never in the scratch set, so it is never dropped - it re-blocks on the next turn and the watcher will not rapid-re-fire it (it is acked).

### 4.4 Why the re-fire race is closed

Trace the fired-event path with the new model:

1. `fire()` sets `ack`, writes the wake file, exits.
2. Wingman is re-invoked, surfaces the event, reports the roster, **arms a fresh watcher cycle**, tries to stop.
3. The fresh cycle's top-of-loop `needs-attention` runs with the default `--suppress-on ack`: the event is acked → suppressed → **no re-fire.** ✓ (This is the exact guard the fire-time ack provided before; it is retained.)
4. The Stop hook (first attempt) runs `--suppress-on handled`: the event is acked but not handled → writes it to the scratch set → **blocks once** with the roster directive → wingman does the roster report.
5. Wingman tries to stop again (`stop_hook_active`) → hook marks exactly the scratch tuple `handled`, allows the stop.

No window exists in which an armed watcher cycle sees an un-acked event, because `ack` is set synchronously in step 1 and never removed by this change.

### 4.5 Concurrency on the shared stores (B2 spec)

The watcher `fire()` and the Stop-hook chain run in separate processes and both mutate `acked.json`; the hook also mutates `handled.json`.
`write_json` is atomic (`os.replace`), so no file is corrupted, but a read-modify-write of a whole dict from two processes can **lose an update** (last-writer-wins on the merged dict).
Concretely: a freshly-armed watcher cycle can `fire()`-and-`ack` a new event at the same instant the Stop hook is `ack`ing its block set; whichever writes second discards the other's key.

Resolution:

- **Serialize every read-modify-write of the shared stores with a file lock.** Add a small `with_locked(path)` helper in `wm-state.py` (a `fcntl.flock` on `<path>.lock`, held across the read→modify→write) and route `cmd_ack`, `cmd_mark_handled`, and any other store mutation through it. `fcntl.flock` is available on the macOS/Linux hosts wingman targets; a missing-lock fallback (best-effort, no lock) keeps it from hard-failing on an exotic platform.
- **`needs-attention` stays a pure read** (no lock needed); a momentarily stale read only defers an event by one poll, never drops it.
- **The drop is prevented structurally, not just by the lock:** because the Stop hook marks handled from the **scratch set** (captured at block time), a concurrent `ack` of a *different* event cannot cause that event to be marked handled - it was never in the scratch. The lock guarantees the two `ack` writers do not clobber each other's keys; the scratch guarantees the mark-handled set is exactly the blocked set.

### 4.6 Path-1 backstop: explicitly deferred (N3)

Per §1.3 the incident was path 1, whose concrete cause is fixed (#9) and whose lead-worker consequence is closed by Fix B (dead-owner detection + re-adopt).
The originally-proposed light "watcher-beacon-staleness advisory" for a *live* lead whose watcher died is **deferred, not shipped**, for the reason the review raised (N3): as designed it has **no delivery channel**.
`watch-fleet` only wakes wingman when `needs-attention` returns an `ATTENTION_STATES` hit; a `working` lead with a stale beacon is not in an attention state, so a note living only in the wake-file roster render is seen only if wingman is woken for some *other* reason - the very path-1 gap it was meant to cover.
Giving it a real wake channel (a new watcher trigger for stale-beacon owners) is more design than warranted now, so it is a documented follow-up (§9); shipping the channel-less version would masquerade as coverage.
This removes the beacon advisory from Fix A and Fix B entirely; **wingman's own watcher** dying remains the accepted top-level single point of failure, re-armed by the existing Stop-hook no-watcher branch whenever wingman stops.

### 4.7 Testing

- **`tests/handled-marker.test.sh` (new):**
  - a surfaced-but-unhandled event re-blocks on the next stop attempt and is suppressed from watcher re-fire (the core race-free property);
  - the two-pass path: first attempt writes the scratch set + acks + blocks; second attempt (`stop_hook_active`) marks exactly the scratch tuples handled and allows the stop;
  - **the B2 drop test:** an event blocked in pass 1, then a *new* transition on the same member (new `updated`) appears before pass 2 → pass 2 marks only the old tuple handled; the new `(id, updated)` re-surfaces on the next turn and is not dropped;
  - a new `updated` (state change) is neither acked nor handled → re-fires and re-blocks;
  - the hook-first path (no watcher) blocks once, acks, then marks handled on the second attempt;
  - `--suppress-on handled --only-acked` enumerates exactly acked ∩ unhandled.
- **Concurrency (B2):** a stress test that runs a `fire()`-style `ack` and a Stop-hook `ack`/`mark-handled` against the same stores concurrently and asserts no key is lost (the flock critical section holds).
- **Regression:** the existing "a new updated re-surfaces" (`tests/ack-dedup.test.sh`) and "a later status change re-surfaces" (`tests/stall-check.test.sh`) invariants must stay green.
- Confirm `prune` drops `handled.json` entries for removed members (extend the prune test).

### 4.8 Files touched by Fix A

- `bin/lib/wm-state.py` - new `handled.json` path helper, `cmd_mark_handled`, `--suppress-on {ack,handled}` and `--only-acked` on `cmd_needs_attention`, the `with_locked(path)` flock helper routing `cmd_ack`/`cmd_mark_handled`, `prune` also drops `handled.json`, arg-parser entries, header docstring.
- `hooks/stop-guard.sh` - the two-pass scratch-set state machine (§4.3), reading/writing `$WM_HOME/stop-blocked-<owner-key>.json`.
- `bin/watch-fleet` - `fire()` and the top-of-loop `needs-attention` call keep `--suppress-on ack` (the default; make it explicit for clarity). No beacon advisory (deferred, §4.6).
- Tests as above.

---

## 5. Fix B - dead lead orphans its workers + robust teardown (#11)

### 5.1 Dead-owner detection and re-adopt (in `cmd_reconcile`)

`cmd_reconcile` already flips any windowless live-state member to `died` and is called every loop by wingman's watcher **and** by each lead's watcher (`watch-fleet:285`). Extend it:

**N4 - scope the orphan mutation to wingman's watcher.** The basic death-flip stays global and idempotent (unchanged). But the new orphan re-parent + `died`-note enrichment must run only under **wingman's** watcher, for two reasons: orphans always re-parent to `""` (wingman) since a dead owner is always a top-level lead (depth cap 2), and running the mutation from every lead's watcher too would needlessly widen the already-racy global read-modify-write of `crew.json` (a pre-existing lost-update hazard mitigated only by atomic replace). Add `--owner` to `cmd_reconcile`; `watch-fleet` already passes `--owner "$OWNER"` context, so gate the orphan pass on `owner == ""`. This keeps the enlarged critical section single-writer. If cross-watcher `crew.json` contention proves real in practice, a `with_locked` wrapper (the same flock helper from §4.5) around the reconcile write is the follow-up; not required now given the single-writer scoping.

After the existing death-flip pass, and only when `owner == ""`, in the **same** reconcile call:

1. **Compute orphans:** live-state members (`status in LIVE_STATES`) whose **window is still alive** but whose `parent` is a member now in a **terminal state** (`died`, `stood-down`) - i.e., the owner died/left but the worker did not.
   Follow only the direct `parent` link (depth cap is 2, so a worker's owner is either a lead or wingman; wingman never dies).
2. **Re-adopt (re-parent):** set each orphan's `parent` to the dead owner's own `parent` (the grandparent; `""` = wingman when the dead owner was top-level, which is always the case for a lead). Record the prior parent in an `orphaned_from` field for auditability and for the surfaced note.
   Re-parenting immediately restores a live watcher: wingman's owner-scoped watcher (`--owner ""`) now sees the orphan as a direct report and resumes watching it for attention transitions. **This is the core robustness win: no orphan runs unwatched.**
3. **Surface once, via the dead owner's `died` event:** the dead lead already produces a `died: <lead-id>` attention event (a fresh `updated`, not yet acked) that fires to wingman on this same cycle. Enrich its note/summary to enumerate the re-adopted workers and name the three dispositions:
   > lead `<id>` died; its N live workers (`<w1>`, `<w2>`) were re-adopted to you and are now visible. Choose: keep supervising them; `bin/crew-standdown <lead-id>` to cascade-stand-down the whole sub-crew; or `bin/crew-takeover <worker>` to hand one off.

   The `died` event is the single wake that carries the orphan surface; after it, the re-adopted workers ride wingman's normal `needs-attention` for any real transition.

**Why re-parent rather than a synthetic "orphaned" attention state:**
re-parenting reuses the existing owner-scoping, ack/handled dedup, and watcher machinery unchanged - an orphan's later `review`/`blocked` fires to wingman for free. A synthetic status would either clobber the worker's real status (the anti-pattern Fix C exists to kill) or require new dedup keys. Re-parent is the lower-complexity, more robust choice.

**Cascade-standdown interaction (important):**
after re-parenting, `crew-standdown <dead-lead>` no longer cascades to the (now re-parented) workers via the `parent` chain. To keep the doc's "cascade-stand-down" disposition working, use `orphaned_from`: `cmd_standdown` (or `descendants_inclusive`) must treat a member as a descendant of `X` if **either** `parent == X` **or** `orphaned_from == X`. That preserves "stand down the dead lead and everything it owned" while the live re-parent keeps the workers watched in the meantime. Add a test for this.

### 5.2 Robust teardown: worktree removal fallback

Resolve the "worktree path recorded at spawn time" intent against the reality that the **developer** creates the worktree (§2):

- **Record the path.** Add a `worktree` field to the roster record and a `--worktree` arg to `crew-add`/`crew-set`. Populate it two ways:
  - **Repo scope (primary, matches the decomposition doc):** `spawn-crew` computes a deterministic worktree path from the crew id - `WORKTREE="$(dirname "$REPO")/$(basename "$REPO")-$ID"` - records it at spawn (`crew-add --worktree "$WORKTREE"`), and **exports `WINGMAN_WORKTREE`** in the generated launch script. Update `playbook/developer.md` to create the worktree at exactly `$WINGMAN_WORKTREE` (`git worktree add "$WINGMAN_WORKTREE" -b <branch>`) instead of a self-chosen `../<repo>-<slug>`. The branch name stays the developer's choice; only the *path* is fixed, and `git worktree remove <path>` needs only the path.
  - **Global scope (follow-up, path not knowable at spawn):** spawn cannot predetermine the repo, so the member self-registers via `wm-state crew-set --worktree <path>` the moment it creates the worktree. Recording-at-creation is close enough to spawn to cover the orphan case (the path is recorded before any work that could crash mid-way). Ship this as a small follow-up if global-scope developers are in scope; the repo-scope path is the common case and the one #11 observed.
- **Remove on teardown.** In `crew-standdown`, after closing each affected window, if the member's roster record has a `worktree` path that still exists as a git worktree, run `git worktree remove --force "$WORKTREE"` (swallow errors; a member that cleaned up gracefully leaves nothing to remove). The graceful path (developer removes its own worktree on merge/close, per its playbook) stays the agent's responsibility; this fallback only fires when a non-graceful exit left the worktree behind.
  - Determine the repo for the `git -C` invocation from the roster `repo` field (repo scope) or from the recorded worktree's own git dir (global scope).
  - Use `git worktree remove --force` (not `rm -rf`) so git's worktree metadata is also cleaned; fall back to pruning (`git worktree prune`) if the directory was already deleted by hand.
  - **Data-loss note (N5):** `git worktree remove --force` discards any uncommitted work in the tree. This is acceptable and intended - the member is being torn down (dead/orphaned/stood-down) - but state it explicitly in the code comment and the PR description so it is a deliberate contract, not a surprise. A gracefully-exiting member has already removed its own worktree, so the force-remove only ever hits a tree left behind by a non-graceful exit.

### 5.3 Testing

- **Dead-owner detection (scoped, N4):** a lead flipped to `died` with a live-windowed worker → reconcile run with `--owner ""` re-parents the worker to `""`, sets `orphaned_from`, and the `died` event note enumerates the worker + dispositions. Verify a reconcile run with a non-empty `--owner` does **not** perform the orphan mutation. Verify the worker is thereafter visible to `crew-list --owner ""` and `needs-attention --owner ""`.
- **Cascade after re-adopt (N5 - this test guards teardown too):** `crew-standdown <dead-lead>` still stands down the re-parented worker (via `orphaned_from`), closing its window **and removing its worktree**. This single test protects both the reap and the teardown fallback: if the `orphaned_from` cascade regresses, `crew-standdown <dead-lead>` no longer reaches the re-parented worker, so its worktree leaks again - the original #11 symptom. Assert the worktree is gone, not just the window.
- **Teardown:** a developer force-reaped (window killed, worktree left behind) has its recorded worktree removed by `crew-standdown`; a developer that removed its own worktree first triggers a harmless no-op. Add to `tests/spawn-scope.test.sh` / a standdown test; guard against an unset `WINGMAN_WORKTREE`.
- **Spawn recording:** `crew-add --worktree` persists the path; `spawn-crew` exports `WINGMAN_WORKTREE` for repo scope (assert in `tests/spawn-scope.test.sh`).

### 5.4 Files touched by Fix B

- `bin/lib/wm-state.py` - `cmd_reconcile` (`--owner` arg; orphan detection + re-parent + `died` note enrichment gated on `owner == ""`, per N4), `cmd_crew_add` / `cmd_crew_set` (`worktree` field, `orphaned_from` field; `spawned_at` already added in PR1), `descendants_inclusive` / `cmd_standdown` (honor `orphaned_from`), arg parser, header docstring. No beacon advisory (deferred, §4.6).
- `bin/spawn-crew` - compute + record + export `WINGMAN_WORKTREE` (repo scope).
- `bin/crew-standdown` - worktree-removal fallback; update the header comment (it currently says "does not touch worktrees").
- `playbook/developer.md` - create the worktree at `$WINGMAN_WORKTREE`.
- Tests as above.

---

## 6. PR sequence and shared-surface integration

### 6.1 Conflict map (from ground truth, refining the decomposition doc)

| Fix | `wm-state.py` | `watch-fleet` | `stop-guard.sh` | `crew-standdown` | `spawn-crew` | `developer.md` |
|-----|---------------|---------------|-----------------|------------------|--------------|----------------|
| C #7 | `crew-add` (`spawned_at`) | detector fns (`prompt_shape_in`, `prompt_freeze_check`) | - | - | - | - |
| A #8 | `needs-attention`, new `handled` store/cmd, `ack`/`mark-handled` flock, `prune` | `fire()` + loop-top call (explicit `--suppress-on ack`) | two-pass scratch-set state machine (§4.3) | - | - | - |
| B #11 | `reconcile` (`--owner`), `crew-add`/`crew-set` (`worktree`/`orphaned_from`), `standdown`/`descendants` | (none; logic in `reconcile`) | - | teardown | worktree export | worktree path |

Key observation: within `watch-fleet`, **C touches the detector functions, A touches `fire()` and the loop-top, and B touches essentially nothing** (its logic lives in `wm-state.py cmd_reconcile`, reached by the unchanged `wm_state reconcile` call). Within `wm-state.py`, **A touches `needs-attention`/`ack`/`handled` and B touches `reconcile`/`crew-add`/`standdown`** - different functions, sharing only `cmd_crew_add` (C adds `spawned_at`, B adds `worktree`/`orphaned_from` - distinct fields, additive), the header docstring, and the arg parser (all append-only). With the beacon advisory deferred (§4.6), **no function is co-edited by two fixes**; textual conflicts are fully avoidable on a single-context sequential build.

### 6.2 Recommended order: C → A → B

1. **PR1 = Fix C (prompt-freeze).** Most self-contained (no state-layer change), lowest risk, and it **protects the rest of the build**: a developer editing `watch-fleet` and reading these very docs/issues (all dense with prompt phrases) will trip the current false-positive detector - exactly the recursive hazard the incident report documents. Landing C first removes that noise for PRs A and B.
2. **PR2 = Fix A (wake handling).** Builds the `handled` store and the Stop-hook state machine. Rebased on C. Establishes the reconcile-pass edit point that B will also touch, and the ack/handled semantics B's `died`-event surfacing rides on.
3. **PR3 = Fix B (dead lead + teardown).** Rebased on A. Its orphan surfacing flows through the `died` event via the `fire()`/`needs-attention` path A just hardened - so B lands cleanly on top of A. Also carries the worktree/teardown/playbook changes, which touch files none of the others do.

No ordering is strictly *forced* by a compile-time dependency (with the beacon advisory deferred, the fixes are orthogonal in function), so the order is chosen to minimize shared-surface churn and to sequence B's orphan surfacing after A hardens the `died`-event path it rides. Building on one branch chain means even the additive `cmd_crew_add` field additions (C's `spawned_at`, B's `worktree`/`orphaned_from`) never conflict.

### 6.3 Integration verification (after all three merge)

Compose the three on the shared surface and verify end-to-end:

- Kill a lead's window mid-flight with a live worker → wingman's next reconcile re-adopts the worker, the `died` event fires through the hardened path with the enriched note, and the worker remains watched (transition it to `review` and confirm wingman is woken).
- Force-reap that worker via `crew-standdown` → its worktree is removed.
- Park a member with a verbatim dialog quote on its pane → it is **not** flipped to `blocked`; park a real frozen gate → it **is** flipped.
- Interrupt handling of a fired event (stop without reporting) → it re-blocks on the next stop (handled-marker), and the watcher does not rapid-re-fire it.
- Run the full `tests/run.sh` green on the deployment host.

Roll the three merged PRs up as one combined delivery per the decomposition doc's phase 4.

---

## 7. Developer allocation recommendation

**One developer builds all three sequentially, on one branch chain, each PR rebased on the prior.**

- The three share `bin/watch-fleet` and all touch `bin/lib/wm-state.py`; a single coherent context eliminates cross-PR merge churn on those files (even the additive `cmd_crew_add` field additions stay conflict-free on one branch chain).
- The fixes are conceptually coupled: the #8 incident (path 1), #11, and the already-merged #9 are three faces of "the owner's watcher stopped," and Fix B's dead-owner detection closes that failure's lead-worker consequence. One mind holding all three produces a more coherent result than three parallel developers negotiating the `reconcile` and `fire()` seams.
- Cost is bounded: three PRs, sequential, each small-to-moderate. Parallel developers would save little wall-clock (they'd serialize on the shared files anyway) at the cost of an integration-conflict tax.

**Follow-up (not recommended now):** splitting into per-PR developers would only pay off if the three were independent, which the shared surface and the coupled path-1 design contradict.

---

## 8. Risks and open questions

- **Fix C true-positive coverage is the top risk (B1 resolved in-design).** The design no longer *requires* a marker (real captures render none - z10), so the trust/Bypass gates fire on the full-option-block match, not the marker; the §3.5 real-capture verification remains a **hard merge gate** to confirm the block shape and to record whether any gate renders a marker. The residual concern is the *false-negative* surface (§3.3, N1): a future CLI that changes the option-row format could silently degrade to a missed freeze. Mitigated by keeping the marker rejecting-only and by the §9 canary follow-up.
- **Fix A double-block on the fire path is intended, not a defect.** Every fired event is blocked once by the Stop hook to *enforce* the roster report (per the short-circuit analysis change 3). If this proves too chatty in practice, the fallback is to have the Stop hook treat "already surfaced by a fire + wingman reached a clean stop" as sufficient (mark handled without a block); this is a tuning knob, documented, not a blocker.
- **Fix A mid-turn drop (B2 resolved in-design).** The Stop hook marks handled exactly the per-turn scratch set (§4.3), not a set re-derived from the stores, so a mid-turn new transition or a mid-turn watcher-`ack` cannot be marked handled and dropped; the flock (§4.5) prevents the two `ack` writers from clobbering each other. The B2 drop test and the concurrency stress test (§4.7) pin both.
- **Re-parent vs cascade-standdown** (Fix B §5.1) is the one subtle interaction; the `orphaned_from` field resolves it and must be tested explicitly (the §5.3 cascade test, which also guards worktree teardown per N5), or standing down a dead lead would silently leave its re-adopted workers - and their worktrees - behind.
- **Global-scope worktree recording** cannot be done at spawn; the self-registration follow-up (§5.2) covers it. Repo scope - the case #11 observed - is fully handled at spawn.
- **Wingman's own watcher** dying remains the top-level single point of failure; the beacon advisory and a full heartbeat are deferred (§4.6, N3) now that #9 fixed the SIGURG crash. Documented, accepted.
- **Incident forensics are partial:** the granular acked-vs-status trail at #8 incident time is gone from disk (§1.1); the path-1 conclusion rests on the mechanistic correlation with #9/#11, corroborated (not proven) by the frozen wake-file mtime. The design closes both paths, so this uncertainty does not affect correctness of the fix.

---

## 9. Deferred / follow-up items (explicit)

- **A real wake channel for the watcher-beacon-staleness advisory (N3, §4.6)** - a live lead whose watcher died with no attention-state member to fire needs its own watcher trigger; deferred until designed, rather than shipped channel-less.
- **A periodic real-capture canary for Fix C (N1, §3.3)** - guards against a future CLI render change silently turning the detector into a missed-freeze; the one-time §3.5 gate cannot.
- Global-scope worktree self-registration (§5.2).
- Full wingman-own-watcher heartbeat beyond the Stop-hook nudge (§4.6).
- Cleaning up `pane-<id>.hash` files on stand-down (noted in the PR #6 review as harmless accumulation; natural to fold into Fix B's teardown if convenient).
- Routing individual permission decisions up as real blockers instead of blanket bypass (pre-existing `spawn-crew` follow-up, unrelated but adjacent).
