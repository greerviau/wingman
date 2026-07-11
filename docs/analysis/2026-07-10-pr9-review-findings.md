# PR #9 review findings - harden watcher, test harness, delivery, and reporting

- **PR:** [#9](https://github.com/greerviau/wingman/pull/9) `fix/harden-wingman-tooling` -> `main` (head `8d191bb`)
- **Reviewed:** 2026-07-10
- **Method:** empirical (this repo has no CI). Full suite run under a bounded outer watchdog, targeted stress harnesses, and a live throwaway spawn. Verification was done against the PR branch checked out in a worktree.
- **Verdict: APPROVE.** All four fixes hold under direct testing. Two minor, non-blocking robustness notes are recorded for follow-up; neither is a regression and neither needs to gate this merge.

## Scope

Four defects introduced/surfaced after #6 (commit `7024f6a`):

1. `bin/watch-fleet` intermittently exits 144 (SIGURG) shortly after arming.
2. `tests/ack-dedup.test.sh` can hang the whole suite via a foreground `watch-fleet` that never fires.
3. Self-reported crew status conflated with verified external (GitHub) state.
4. `bin/spawn-crew` delivery unreliable: the opening objective's submit Enter swallowed during a fresh session's startup.

## Fix 1 - watch-fleet SIGURG immunity: VERIFIED

Change: `trap '' URG` set unconditionally at the top of `bin/watch-fleet`, before any subprocess is spawned.

Evidence:

- **Shell honors it.** `bin/watch-fleet` runs under `/usr/bin/env bash` = macOS bash 3.2.57. Confirmed `trap '' URG` is accepted by bash 3.2 and that the process survives a self-delivered `kill -URG`.
- **Inherited by children.** Confirmed SIG_IGN for SIGURG is inherited across `fork` by child processes (a child `sleep` survives `kill -URG`), so the whole probe subprocess tree (pane capture, `ps` scan, the stall probe's blocking child) is immunized as the PR claims.
- **Rapid arm/exit stress.** 20 rapid arm -> fire -> exit cycles, each with a terminal event pending in the wake file so the arm fires immediately, while bombarding the watcher parent + children + grandchildren with SIGURG: **`exit144=0`, all 20 fired correctly** (`done: sN` in every cycle's output). No non-zero exit of any kind.
- **In-suite regression (authoritative blocking case).** `tests/watch-fleet.test.sh` sends a 40x SIGURG burst to a *blocking* watcher and its children, then confirms it (a) keeps blocking and (b) still fires on the genuine `done` event afterward. All four SIGURG assertions pass in the full-suite run.
- **Sanity - nothing legitimate is suppressed.** SIGURG carries no meaning for `watch-fleet` or any process it spawns: `tmux`, `ps`, `sleep`, `cksum`, `date` are C tools that do not rely on SIGURG; `uv` is Rust; `wm-state.py` is Python (no default SIGURG handler). The one runtime that uses SIGURG (Go's async goroutine preemption) is not present in the subprocess tree, and even if a Go binary were added later it re-installs its own SIGURG handler at startup, overriding an inherited SIG_IGN. The wake channel is the process *exit*, not a signal, so ignoring SIGURG cannot affect it.

Note: as the PR itself states, the original crash could not be reproduced deterministically (default SIGURG disposition is already "ignore", so an externally delivered SIGURG does not kill the loop). The fix is a sound, correctly-scoped defense against the confirmed symptom (termination by signal 16); the residual "confirm over time in a live managing session" is inherently observational and outside what a review can force.

## Fix 2 - test suite no longer hangs: VERIFIED

Change: portable `wm_timeout` helper + `wm_track`/`wm_kill_tracked` EXIT-trap reaping in `tests/lib.sh`; every foreground `watch-fleet` wrapped and every backgrounded one tracked.

Evidence:

- **Full suite completes, no hang.** `bash tests/run.sh` under a bounded outer watchdog: **45 test files, 0 failed, "ALL SUITES PASSED", 0 `FAIL` lines anywhere**, in ~310s. It terminates on its own.
- **`ack-dedup.test.sh` still tests what it should.** Its 16 assertions pass, including the core dedup guarantees: "re-arm keeps blocking on the already-acked done event", "re-arm did not re-fire the acked event", and "watcher exits after a NEW member becomes actionable". The only functional change is wrapping the first arm in `wm_timeout 30` and tracking the backgrounded re-arm; the dedup behavior under test is unchanged.
- **Coverage is complete.** Every command-substitution `watch-fleet` invocation across the suite is now wrapped by `wm_timeout` (6 sites in `watch-fleet.test.sh` and `ack-dedup.test.sh`); no unwrapped foreground call remains. Backgrounded launches (11) are covered by `wm_track` (13 calls) plus the EXIT trap.
- **`wm_timeout` behaves as specified.** A fast command returns immediately and preserves its exit status (rc=7); a hanging `sleep 60` is bounded (~3s, rc=143) with a diagnostic on stderr; inside command substitution only the command's stdout is captured (the watchdog's stdout is detached so it never holds the pipe open).

## Fix 3 - reliable objective delivery: VERIFIED

Change: `wm_tmux_send_message` now waits for the TUI to settle (`wm_tmux_pane_ready`: pane non-empty and byte-stable across two reads), then confirms the submit registered (pane advances from the composed snapshot) and re-presses Enter until it does, bounded by `WM_SUBMIT_TRIES`.

Evidence:

- **New `tests/submit-delivery.test.sh` passes.** It drives a real tmux pane running a raw-mode stub that faithfully emulates a TUI input box and swallows the first Enter. All three assertions pass: the message submits despite a swallowed first Enter; a ready session submits on the first Enter; and a successful submit is not repeated (exactly one submission - the retry never double-submits).
- **Live E2E against a real Claude Code TUI.** Spawned a throwaway crew member through the PR-branch `bin/spawn-crew` with a benign self-contained objective. The fresh session received the objective as a *submitted* user message and produced its reply (`DELIVERY_CONFIRMED_9`), leaving the input box empty - i.e. the objective was delivered *and* submitted, not left sitting unsent. The throwaway member was stood down afterward.

## Fix 4 - self-report vs ground-truth norm: VERIFIED (wording is clear and correct)

Change: `CLAUDE.md` (Report step and "Deliverable ready") and a new `playbook/_status-contract.md` section codify that a member's status/artifact/verdict is that member's own claim, not verified external state.

Assessment:

- The wording is clear, correct, and actionable. It instructs the reader to either verify against the system of record before asserting an external fact (`gh pr view <pr> --json state,mergeStateStatus,reviewDecision,statusCheckRollup` - all valid `gh pr view` JSON fields), or attribute the claim explicitly as a self-report, with concrete phrasings ("my review verdict is approve", not "the PR is approved").
- Audience is right in each file: `CLAUDE.md` addresses wingman ("do not relay it as settled fact"); `_status-contract.md` addresses the crew member ("your own report"), and that contract is appended to every crew brief.
- It names the concrete failure it prevents (a PR surfaced as approved while GitHub showed `REVIEW_REQUIRED` and merge `BLOCKED`), which makes the instruction unambiguous.

## Minor, non-blocking notes (follow-up, not required for merge)

1. **Delivery confirm heuristic can false-positive on ambient TUI repaint.** `wm_tmux_send_message` decides "the Enter took" when the pane cksum differs from the composed snapshot. If a TUI element repaints for a reason unrelated to the submit (spinner, clock, token/context meter) within the poll window, the loop could return "submitted" without the Enter having registered. In practice the risk is low - a swallowed Enter typically leaves an idle, byte-stable prompt (which is why the stub test and the live spawn both succeed) - and it is no worse than the pre-PR fixed-delay behavior, so it is not a regression. If it ever surfaces, a more specific readiness signal (e.g. detecting the input box cleared vs. merely "pane changed") would harden it further.
2. **`trap '' URG` inheritance and future Go children.** The inherited SIG_IGN is safe for the current subprocess tree (documented above). This is recorded only so that if `watch-fleet` ever shells out to a Go binary (e.g. `gh`), the reasoning is on record; Go re-installs its own SIGURG handler at startup, so no action is needed.
