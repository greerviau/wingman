# Review: PR #29 - watch-fleet reliability Track B (#12, #22, #23)

Reviewer: crew member `review-pr-29-github-com-greervia-reviewer`.
Date: 2026-07-12 (initial review); 2026-07-12 (first fix re-verification, `07c3bdb`/`2d54617`); 2026-07-12 (final re-verification, `9c970c0`).
Scope: `feat/watch-fleet-reliability-track-b` against `docs/plans/2026-07-11-watch-fleet-reliability-track-b-design.md` and issues #12, #22, #23.

## Final verdict: no outstanding findings - ready to merge from this review's perspective

All three issues raised across two rounds of review are fixed and independently re-verified:

1. **`bin/crew-resume` concurrent-launch race** (must-fix, `07c3bdb`): 15/15 fresh iterations of the original two-racer reproduction - exactly one window, correct `working` status, every time.
2. **`#12` claim-lock trap-timing gap** (should-fix, `07c3bdb`): 40/40 arm-race iterations, zero double-arms, zero leaked lock directories.
3. **`--all-died` batch claim-leak regression** (found during round 1 re-verification; fixed in `9c970c0`): re-ran the exact batch scenario at larger scale (4 members, not 2) - **zero leaked `<id>.resuming` directories across the whole batch**, and re-verified the specific failure mode is closed: re-dying the first- and third-processed members of that batch and resuming them again both succeed cleanly (`2 resumed, 0 skipped`, both flip back to `working`). The developer also added direct regression coverage for this in `tests/crew-resume.test.sh`, which I confirmed present and passing.
4. **Full suite**: `tests/run.sh` - **ALL SUITES PASSED**, 0 failures, including all new coverage.

No further issues found. Round-1 findings and the empirical mkdir-hardening validation are retained below for the record.

## New finding (from fix re-verification): `--all-died` leaks the resume claim directory for every id but the last

**Status: fixed and re-verified (`9c970c0`).** The fix factors release into a `release_claim()` helper redefined per id (right after the claim is taken, so it always closes over the *current* `$_claim`) and calls it explicitly from every exit path - the two existing skip paths plus the success and verify-timeout paths that previously fell through to only the deferred trap. Re-ran the batch scenario at 4 members (larger than my original 2-member repro): zero leaked claim directories across the whole batch, and re-dying two different members from that batch (the first- and third-processed) both resume cleanly on a second attempt. The developer additionally landed direct regression coverage for this exact case in `tests/crew-resume.test.sh`. Original finding retained below for the record.

**File:** `bin/crew-resume`, `resume_one()` (commit `07c3bdb`).

The atomic claim added to fix must-fix #1 (below) is a directory at `$WM_HOME/crew/<id>.resuming`, released via `trap 'rm -f "$_claim/owner" ...; rmdir "$_claim" ...' EXIT`. That trap string is single-quoted, so `$_claim` is resolved at *trap-firing* time, not at registration time. `_claim` is an ordinary (non-`local`) shell variable reassigned on every call to `resume_one()`. For a single-id invocation this is invisible - the trap fires at script exit with `_claim` still holding that one id's path, so it cleans up correctly. For `--all-died` processing N ids in one script invocation (the primary use case the design names for a mass-death event - the exact scenario with the most ids in one batch), only the **last** id processed has its claim directory removed; every earlier id's `<id>.resuming/` directory is left on disk permanently, because nothing calls `release_claim`/`rm`/`rmdir` for it before `_claim` gets reassigned to the next id.

The explicit release added on the "window already exists" skip path (`rm -f "$_claim/owner"; rmdir "$_claim"; trap - EXIT`) shows the developer was aware release needed to happen per-id - it's just missing on the two paths after a relaunch attempt (the `resumed` success path and the `skip: resume failed` verify-timeout path).

**Reproduced end-to-end:**

```
=== first --all-died (2 members) ===
✓ 'lk1': resumed in window 'wm-lk1'
✓ 'lk2': resumed in window 'wm-lk2'
2 resumed, 0 skipped
=== claim dirs left behind after the run ===
drwxrwxr-x 2 agents agents  60 Jul 12 07:14 lk1.resuming
=== simulate lk1 dying again, try to resume it alone ===
! 'lk1': could not claim the resume lock - another crew-resume may be relaunching it
right now, or a stale claim was left by a crashed run (remove .../lk1.resuming by
hand if none is running). Not relaunching.
0 resumed, 1 skipped: lk1 (skip: could not claim resume lock)
=== lk1 status after the retry ===
  "status": "died",
```

`lk1` (resumed successfully, then died again later) can now **never be resumed again** without a human manually finding and removing the stale `lk1.resuming` directory - `bin/crew-resume`'s core guarantee (idempotent, retriable recovery) is broken for exactly the batch case `#22` exists to serve. This is not caught by the existing test suite: `tests/crew-resume.test.sh` only exercises single-id resumes and a 2-died `--all-died` batch checked once, immediately after the run, before anything could die again - it never re-triggers a second resume for an id that was part of a multi-id batch, so the leak has no failing assertion to surface it.

**Suggested fix:** release the claim explicitly on all exit paths from `resume_one()` (success and verify-timeout), the same way the existing-window skip path already does - or, more robustly, make `_claim` a per-call `local` variable and capture its value into the trap string at registration time (e.g. `trap "rm -f '$_claim/owner' 2>/dev/null; rmdir '$_claim' 2>/dev/null" EXIT`, double-quoted so `$_claim` expands immediately) so a lingering trap always targets the right directory regardless of what `_claim` holds later in the loop.

## Must-fix (original review; verified fixed - see re-verification note above)

### 1. `bin/crew-resume`'s "existing window" guard does not close the race it claims to close

**Status: fixed and re-verified.** Commit `07c3bdb` replaces the check-then-act with an atomic `mkdir`-based per-id claim, exactly mirroring `#12`'s pattern. I re-ran the original two-racer reproduction against the fixed code: 15/15 fresh iterations produced exactly one window and a correct `working` status, versus the original bug's reliable double-launch. Original description of the bug retained below for context.

**File:** `bin/crew-resume`, idempotency guard 2 (`wm_tmux_windows | grep -qx "$_window"` before `wm_tmux new-window ...`).
**Design claim (§5.2, point 3):** "closes the residual race window between two concurrent `crew-resume` invocations (or a retry) that guard 1 alone wouldn't catch if they read the roster in the same instant."

This claim is false for the reason the design itself should have caught: **tmux does not enforce unique window names within a session.** Two windows with the identical name can coexist; `tmux new-window -n X` never fails or dedupes against an existing `X`. Verified directly:

```
$ tmux new-session -d -s dupetest -n base
$ tmux new-window -d -t dupetest: -n samename 'sleep 300'
$ tmux new-window -d -t dupetest: -n samename 'sleep 300'
$ tmux list-windows -t dupetest -F '#{window_index}: #{window_name}'
0: base
1: samename
2: samename
```

Guard 2's check-then-create (`grep -qx` the window list, then `wm_tmux new-window`) has an unclosed TOCTOU gap identical in shape to the one `#12` closes for the watcher's own singleton arm - except here nothing closes it. I reproduced the double-launch end-to-end against the actual script: two `bin/crew-resume crx1` invocations racing against the same `died` member both pass guard 1 (`status == died`) and guard 2 (window not yet present), and both proceed to create it:

```
--- windows named wm-crx1 in session ---
wm-crx1 window count: 2
!!! DOUBLE-LAUNCH: 2 windows named wm-crx1 exist simultaneously !!!
```

Both windows run `claude --resume sess-crx1` concurrently against the identical session id - two live processes fighting over one conversation, real API calls duplicated, exactly the failure mode `#22`'s idempotency requirement exists to prevent. This is squarely in the task's stated blast-radius-sensitive category (concurrent process management, tmux window lifecycle) and squarely contradicts the design's own idempotency guarantee.

**Suggested fix:** the guard needs the same treatment `#12` gave the watcher's arm - an atomic claim before creating the window, not a check-then-act. The cheapest correct fix: use `wm_tmux new-window` itself as the atomic claim by giving the launch a unique, collision-checkable side effect *before* the tmux call - e.g. an `mkdir`-based per-id claim directory (`$WM_HOME/crew/<id>.resuming/`) taken immediately after guard 1 and released after the verify step, mirroring `#12`'s pattern exactly. A `tmux new-window` retry-checking its own success is not sufficient since tmux happily creates the duplicate rather than failing.

**Likelihood in practice:** the design's own text treats concurrent/retried `crew-resume` invocations as a real scenario worth guarding ("two concurrent `crew-resume` invocations (or a retry)"), so this isn't a hypothetical the design dismissed - it's exactly the case the design claims to have covered and didn't.

## Should-fix (verified fixed)

### 2. `#12`'s hardened claim lock can wedge permanently if its own verification ever fails for the actual lock-directory owner

**Status: fixed and re-verified.** Commit `07c3bdb` registers `trap release_claim EXIT` the instant `mkdir` succeeds (clearing it with `trap - EXIT` only if the internal write-race is then lost to a genuine concurrent winner) - exactly the suggested fix. Re-ran the watcher's own arm-race scenario 40/40 iterations: zero double-arms, and no `*.pid.lock` directories left behind afterward. Original description of the gap retained below for context.

**File:** `bin/watch-fleet`, the claim-lock block (commit `f137099`, lines around `CLAIMLOCK="$PIDFILE.lock"`).

```sh
while :; do
  if mkdir "$CLAIMLOCK" 2>/dev/null; then
    echo "$$" > "$CLAIMLOCK/owner" 2>/dev/null
    sleep 0.1
    [ "$(cat "$CLAIMLOCK/owner" 2>/dev/null)" = "$$" ] && break
  fi
  _claim_tries=$((_claim_tries+1))
  [ "$_claim_tries" -ge 50 ] && wm_die "..."
  sleep 0.1
done
release_claim() { rm -f "$CLAIMLOCK/owner" 2>/dev/null; rmdir "$CLAIMLOCK" 2>/dev/null; }
trap release_claim EXIT
```

`trap release_claim EXIT` is registered only *after* the loop `break`s - i.e., only once this process's own write-then-read-back verification succeeds. If a process's `mkdir` succeeds (so it, and only it, owns `$CLAIMLOCK`) but its own read-back somehow doesn't match its own pid - a slow/short write under I/O pressure, not necessarily a second claimant - it falls through to the retry branch having created a directory it will now never remove: no trap is registered yet, and no other process can remove it either, since every subsequent claimant's `mkdir` now permanently fails against the existing directory. The eventual `wm_die` at 50 tries is loud (matches the design's stated goal for a *stuck concurrent arm*), but here there is no stuck process to blame - the wedge is self-inflicted by this process's own code path, and recovery requires a human to `rmdir` the stale directory by hand. This is a strictly worse failure mode than the plain design's documented one (a lock left behind by an externally-killed process), because nothing killed anything here.

I could not force this exact interior race directly, but I can say confidently that the ambient race conditions this lock exists to defend against are real and reproducible in at least one environment (see the validation note below), so this residual gap is not purely theoretical.

**Suggested fix:** register the cleanup unconditionally the moment `mkdir` succeeds (before the verification sleep/read-back), e.g.:

```sh
if mkdir "$CLAIMLOCK" 2>/dev/null; then
  trap 'rm -f "$CLAIMLOCK/owner" 2>/dev/null; rmdir "$CLAIMLOCK" 2>/dev/null' EXIT
  echo "$$" > "$CLAIMLOCK/owner" 2>/dev/null
  sleep 0.1
  [ "$(cat "$CLAIMLOCK/owner" 2>/dev/null)" = "$$" ] && break
  trap - EXIT   # lost the internal race; let the presumed winner's own trap clean up
fi
```

## Validated, not a defect: the mkdir-lock hardening beyond the approved design

The PR's #12 commit (`1efaa1a`) implements the approved design's mkdir lock verbatim - a plain `mkdir`/`rmdir` claim, no verification, matching §4.2 exactly. The *hardening* on top of it (write-your-pid-then-read-it-back verification, `f137099`) is **not** in the approved design and is justified in the commit message / PR description by a claim ("a plain mkdir-based mutual exclusion was found, under stress testing, to occasionally let two near-simultaneous callers both observe mkdir succeed") that sounds, on its face, like it contradicts `mkdir`'s POSIX atomicity guarantee.

I tested this two ways before concluding the developer's practice was sound:

1. **Raw `mkdir` atomicity**, isolated from the rest of the script: 100-way concurrent `mkdir` on the same path, repeated across multiple runs. Exactly one winner every time - no evidence `mkdir` itself is non-atomic in this environment.
2. **The actual race the design targets** (two full `bin/watch-fleet` invocations racing to arm), using the project's own race scenario, 50 iterations each:
   - The **plain, approved-design lock** (commit `1efaa1a`'s version, no hardening): **12/50 iterations (24%) produced two simultaneous "armed" winners** - a genuine, reproducible double-arm.
   - The **PR's hardened lock** (final code): **0/50** - the double-arm never recurred.

So while `mkdir` itself is not the non-atomic component (test 1), something in the full check-then-claim-then-verify sequence genuinely races under real concurrent load in this environment, and the hardening the PR added - which the approved design does not call for - measurably closes it (test 2). I was not able to pin down the exact underlying mechanism (candidates include the `cycle_live()` liveness probe's `kill -0` check racing against a not-yet-fully-visible fresh pidfile/beacon write under contention), but the empirical result is unambiguous enough that reverting to the literal approved design would reintroduce a real, frequent double-arm.

**Process note, not a code defect:** this deviation from the approved design should have been called out explicitly as a deviation requiring the lead/architect's sign-off (it changes a documented performance property of §4.2 - "adds no contention for the common case... microseconds" is no longer true; every arm now pays a fixed ~100ms), rather than folded silently into the `#22` commit and presented as settled fact in the commit message, PR description, and `docs/architecture.md`. The technical call itself, on the evidence, was correct.

## Confirmed correct (per the review's checklist)

- **`group-attention` is a pure display filter.** `fire()`'s ack loop iterates the raw `$_attention` (real ids, real `updated` stamps) throughout; only the two *display* loops (wake-file "New events", stdout reason lines) are switched to `$_grouped`. A synthetic `correlated:*` row is never acked. Confirmed by reading `bin/watch-fleet`'s `fire()` and by `tests/group-attention.test.sh` / the new `watch-fleet.test.sh` mass-death case (all passing).
- **`api_error_check` cannot false-positive into a state mutation.** It's gated behind `_idle >= STALL_IDLE` (the same staleness gate `stall-check` itself requires), so a working session's transcript merely mentioning error-like text is never even examined. Its match only (a) triggers a nudge (cheap, reversible, gated further by `PANE_STABLE`) and (b) selects `stall-check`'s reason template *after* `stall-check`'s own independent gates/probe have already decided to flip - the flag never causes a flip by itself.
- **`wm_pane_snapshot` refactor is behavior-preserving.** Same hash-file naming convention, same read-before-write-of-hash ordering, called once per member per poll and shared between `prompt_freeze_check` and `api_error_check` (not doubled). All pre-existing permission-freeze assertions in `tests/watch-fleet.test.sh` pass unmodified against the refactored code.
- **`bin/crew-resume`'s single-invocation idempotency and tree preservation are correct.** Guard 1 (`status != died` skip) is solid. `parent` is never touched (the roster record is reused as-is), verified for both a top-level member and a lead+worker pair in `tests/crew-resume.test.sh`. The verify-not-optimistic relaunch-confirmation logic is correct for the single-caller case; it is guard 2 specifically (concurrent callers) that fails, per the must-fix above.
- **Full test suite is green.** `tests/run.sh`: `ALL SUITES PASSED`, 0 failures, including all new coverage (`group-attention.test.sh`, `crew-resume.test.sh`, the extended `stall-check.test.sh` and `watch-fleet.test.sh` cases) and the pre-existing permission-freeze suite.

## Scope not covered

I did not re-verify `shellcheck` cleanliness or re-derive the `WM_MASS_MIN_COUNT`/`WM_MASS_MIN_RATIO` threshold calibration (the design itself flags these as a first-pass, unmeasured estimate - not a regression to catch here).
