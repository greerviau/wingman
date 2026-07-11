# PR #14 review - `crew-ask` synchronous ask-and-capture-reply channel

- **PR:** [#14](https://github.com/greerviau/wingman/pull/14) `feat(wingman): crew-ask synchronous ask-and-capture-reply channel`
- **Branch:** `feat/crew-ask` @ `e16cf5c`
- **Reviewed:** 2026-07-10
- **Verdict: APPROVE.** No required changes. Two non-blocking observations recorded below.

## Scope

Adds `bin/crew-ask`, a synchronous request/response channel between a caller (the top orchestrator or a lead) and one of its delegates: the caller poses a direct question, the delegate authors a bounded answer, and the caller is woken to read it - all on a dedicated file-based channel that never touches the status/needs-attention channel and never scrapes panes.
Also extracts the `crew-say` team guardrail into a shared helper and wires both commands through it, adds a Stop-hook guard for pending asks without a live waiter, and documents the flow.

Reviewed the full diff (12 files, +823/-24) and verified behaviour empirically against an isolated state home and tmux session (never touching the live `~/.wingman` or the `wingman` session).

## Verification performed

### 1. End-to-end reply capture - PASS

Drove the real `bin/crew-ask` end-to-end with a seeded roster:

- `crew-ask <id> "<question>"` minted a request id, recorded a `pending` record under `~/.wingman/ask/<req>.json`, and delivered a framed question into the delegate's live tmux window via the shared `wm_tmux_send_message` primitive.
- Arming `crew-ask await --id <req>` as a background (harness-tracked-style) task **blocked** while the request was pending - confirmed the waiter stayed alive across several seconds with no busy-exit.
- When the delegate ran `crew-ask reply --id <req> --answer "..."` (the exact command a real delegate runs), the waiter woke and exited within ~1 poll interval, printing the single reason line `answered: <req> <answer>` plus the directive to read `~/.wingman/ask/<req>.json` and the explicit "captured reply, not a crew status event" marker.
- The record transitioned to `status: answered` with the answer, responder, and timestamp persisted.

The answer is captured via the file-based protocol (the delegate authors it into the record; the caller reads the file). Confirmed **no pane scraping**: `grep` for `capture-pane`/`pipe-pane` across `bin/crew-ask` and `bin/lib/wm-state.py` returns nothing. Confirmed **no busy-polling**: the `await` loop sleeps `WM_ASK_WATCH_INTERVAL` (default 3s) between evaluations and the wake is the harness-tracked background-task exit, mirroring `watch-fleet`/`pr-watch`.

### 2. Timeout / no-answer path - PASS

Armed `crew-ask await --id <req> --timeout 4` against an unanswered request. It returned after ~4s (bounded) with `unanswered: <req> no reply within 4s` and resolved the record to `status: timeout` with an explanatory note. No hang. The compare-and-set in `ask-resolve` means an answer landing in the same tick still wins over the timeout transition. A vanished-delegate path (`undeliverable`) is covered by the automated suite; the "no session to check against" case correctly declines to fire `undeliverable` on absence alone.

### 3. Team guardrail - PASS

The `crew-say` guardrail logic is extracted verbatim into `wm_team_guardrail` (`lib/common.sh`) and both commands call it; the unchanged `tests/crew-say-guardrail.test.sh` still passes, confirming the refactor is behaviour-preserving. Independently reproduced with a correctly-registered roster (`crew-add --parent`):

- worker -> worker under a different lead: **DENY** (guardrail message).
- worker -> its own lead: **ALLOW** (passes guardrail, then hits the no-live-window backstop).
- caller with no relation -> a two-layers-down worker: **DENY**.
- `crew-say` parity: the same cross-team pair is denied identically via `crew-say`.
- `--force` and `WM_TEAM_FORCE` both bypass (covered by the automated suite). `crew-say` also still honours the legacy `WM_CREW_SAY_FORCE`.

So `crew-ask` honours exactly the same policy: a caller may reach only its own reports, a sibling under the same lead, or its own lead.

### 4. Suite health and CI - PASS

- Full local suite: `bash tests/run.sh` -> **ALL SUITES PASSED** (14 suites), exit 0, ~5m29s wall clock. The new `crew-ask.test.sh` (23 assertions), `crew-ask-guardrail.test.sh` (10), and the extended `stop-guard.test.sh` (12, including the pending-ask-without-waiter branch) all pass.
- Every blocking watcher in the suite is bounded by `wm_timeout` and reaped on exit; the timeout/answer tests use short `WM_ASK_TIMEOUT`/`WM_ASK_WATCH_INTERVAL` overrides, so the suite cannot hang.
- PR #14 CI (verified via `gh pr checks 14`): `ci` **pass**, `shellcheck` **pass**, `test` **pass** (5m29s). `mergeStateStatus: CLEAN`.

## Design / correctness notes (all sound)

- The ask channel is fully isolated: distinct files (`ask/<req>.json`, `.pid`, `.beat`), never writes `crew/<id>.json`, `needs-attention`, `acked.json`, `board.md`, or the wake file - so a side answer cannot masquerade as a roster event or perturb the delegate's lifecycle. Confirmed in code and behaviour.
- `ask-new` refuses to overwrite an existing record; `ask-reply` enforces the char cap (reject, never truncate), an anti-spoof check (responder must equal the addressed delegate), and refuses a closed request; `ask-resolve` is compare-and-set on `pending`. All exercised by the suite.
- The Stop-hook guard reuses the established `$WM_UV python` / `$STATE_PY` / `$OWNER` idioms and the same beacon-freshness test as the watcher branch; it is scoped to the current layer's own pending asks (`ask-list --from "$OWNER"`) and sits below the attention branch, above the no-watcher branch.
- `crew-prune` sweeps closed asks time-based (never event-based), so cleanup can never race a caller reading a just-landed answer.
- Docs (`CLAUDE.md`, `playbook/lead.md`, `playbook/_status-contract.md`) accurately describe the flow, the guardrail, the "captured answer, not a roster event" property, and the turn-cost consideration, in neutral engineering language.

## Non-blocking observations

1. **`no-target` is treated as allow, not deny** (inherited unchanged from `crew-say`). If a target id is absent from the roster index, `wm_team_guardrail` prints `no-target`, and both commands only refuse on `deny` - so the guardrail does not itself block an unknown id. For `crew-ask` this is backstopped immediately by the "no live window for '<id>'" check, so no phantom ask can actually be sent; it is behaviour-preserving and not a regression. Worth being aware of if the guardrail is ever reused somewhere without a downstream liveness check.

2. **Live-agent turn-boundary pickup remains unproven** (already flagged by the author under "Additional testing required"). The E2E exercises `crew-ask reply` invoked directly with the delegate's id - the exact command a delegate runs - but does not drive a live `claude` agent, so it does not prove an agent reliably notices the framed `[crew-ask <req>]` inject at its next turn boundary and replies promptly. The delivery mechanism itself (`wm_tmux_send_message`) is the same primitive `crew-say` uses in production, so the residual risk is behavioural (does the agent comply), not a code defect. Recommend the author's follow-up: a real-world exercise with a live delegate and tuning of the default `WM_ASK_TIMEOUT` (300s) once turn-latency is observed.

## Recommendation

Approve and merge. The implementation is correct, well-isolated, thoroughly tested, and CI is green. The two observations are informational; neither blocks merge.
