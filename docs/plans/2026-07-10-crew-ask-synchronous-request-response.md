# Implementation plan: `crew-ask` — synchronous ask-and-capture-reply between an orchestrator and its delegates

- **Date:** 2026-07-10
- **Type:** Implementation plan (analyst deliverable, for a developer to build from)
- **Repo:** `wingman`
- **Components touched:** `bin/crew-ask` (new), `bin/lib/wm-state.py`, `bin/lib/common.sh`, `bin/crew-say`, `hooks/stop-guard.sh`, `playbook/_status-contract.md`, `CLAUDE.md`, `playbook/lead.md`, `bin/doctor` (optional), `tests/`

## 1. Problem

The only downward channel today is `bin/crew-say`: a one-way, fire-and-forget inject.
It types a message into a delegate's live session over tmux and returns `delivered`; it captures nothing.
Any answer only ever comes back *asynchronously* and *lossily* through the distilled status/artifact/board channels, which are deliberately low-bandwidth (`crew-list` shows a truncated one-line summary; `needs-attention` surfaces a status transition, not a reply).

There is no way for a caller — wingman, or a lead asking one of its workers — to **pose a direct question and capture that delegate's answer back into the caller's own context**.
Concretely: a lead cannot ask a developer "did you end up changing the public signature of `foo`, yes/no?" and get the answer back into its reasoning; it can only inject the question and hope the answer eventually shows up, paraphrased, in a status summary it happens to read.

We need a request/response path that:

- lets the caller ask and receive a distilled answer back into context;
- does **not** attach to or scrape the delegate's pane (the answer is authored by the delegate, not screen-scraped);
- keeps all state in files under `~/.wingman/`, managed only through `wm-state.py` (so shell stays bash-3.2-safe);
- returns a **bounded, distilled answer**, never a transcript;
- wakes an idle caller when the answer lands, by **reusing the existing harness-tracked watcher/wake arming primitive** rather than busy-polling;
- honours the same **team guardrail** as `crew-say` (who may ask whom);
- stays **harness-agnostic** and composes cleanly with the recently merged wake-handling changes.

## 2. Design overview

Introduce a dedicated **ask channel** parallel to (not overloading) the status channel.
An ask has its own request record, its own response file, and its own single-shot wait-watcher.
It never touches `needs-attention`/`acked.json`/`board.md` or a delegate's own `crew/<id>.json` status, because an answer to a side question is **orthogonal to the delegate's own lifecycle** — the delegate is still `working` on its task; it merely replies on the side.

Three actors, three phases, one new script (`bin/crew-ask`) with three subcommands plus a small set of new `wm-state.py` subcommands:

1. **Send** (caller → delegate). `crew-ask <id> "<question>"`
   Runs the team guardrail, mints a request id, records the request via `wm-state ask-new`, and delivers a *framed* question into the delegate's live session using the same tmux primitive `crew-say` uses. Prints the request id and the exact `await` command to arm. Foreground and quick; happens exactly once.

2. **Reply** (delegate → caller). `crew-ask reply --id <req-id> --answer "<distilled>" [--answer-file <path>]`
   The delegate, on seeing the framed message, writes a **bounded** answer via `wm-state ask-reply`. Enforced cap keeps it distilled; a `--answer-file` pointer carries fuller detail without inlining it, mirroring the artifact discipline.

3. **Await** (caller waits). `crew-ask await --id <req-id> [--timeout <sec>]`
   A **blocking, single-shot wake-loop watcher**, armed by the caller as a harness-tracked background task exactly like `pr-watch`/`watch-fleet`. It polls the response record, and exits with one reason line the instant the answer lands, the delegate dies, or the timeout elapses. That exit re-invokes the idle caller.

```
caller                         ~/.wingman/ask/<req>.json          delegate session
  |  crew-ask <id> "Q"                                                   |
  |------ ask-new (pending) ------->[ record written ]                   |
  |------ tmux send framed Q --------------------------------------------> (queued; picked up
  |                                                                         at next turn boundary)
  |  arm: crew-ask await --id <req>  (harness-tracked background task)     |
  |  ...caller turn ends, idle...                                         |
  |                                                  crew-ask reply -------|
  |                                 [ record: answered, answer, file? ] <--|
  |  <== await exits: "answered: <req> <answer>" (re-invokes caller)       |
  |  reads ~/.wingman/ask/<req>.json, continues the work that was waiting  |
```

### Why a dedicated channel and not the existing status/needs-attention path

Reusing `watch-fleet`/`needs-attention` for the reply is tempting (one wake mechanism) but wrong:

- A delegate's `crew/<id>.json` holds a **single** status. Flipping it to signal "I answered" would corrupt the delegate's own lifecycle signal (it is `working`, and must stay `working`).
- `needs-attention` is owner-scoped and deduped by `(id, updated)`; an answer is not naturally a status transition and would either be missed or masquerade as one.
- A worker answering a lead's question must not read as "the worker needs the lead's attention" in the roster sense.

So the ask channel is deliberately separate. This separation is also what makes it compose safely with the merged wake-handling work (see §7): the ask channel does not write `$WAKEFILE`, does not call `ack`, and does not appear in `needs-attention`, so it cannot perturb the roster-report discipline that channel now enforces.

The single-shot nature is the other key difference from `watch-fleet`: `watch-fleet` is a **re-armed chain** (each fire is followed by a fresh arm). An `await` fires **once** — the question is answered, the caller consumes it, done. The caller does not re-arm it.

## 3. State: schema and new `wm-state.py` subcommands

All JSON stays in `wm-state.py` (consistent with the codebase rule that shell stays bash-3.2-safe and jq-free).

### 3.1 New state directory and file

`~/.wingman/ask/<req-id>.json` — one file per request:

```json
{
  "id": "ask-3f2a1b9c",
  "from": "the-lead-id",
  "to": "worker-id",
  "question": "did the public signature of foo() change? yes/no + one line",
  "status": "pending",
  "answer": null,
  "answer_file": null,
  "responder": null,
  "created": "2026-07-10T18:22:04.123456Z",
  "answered": null
}
```

- `from` — caller crew id (`""` = wingman, the top orchestrator, mirroring the `parent`/owner convention).
- `to` — addressed delegate crew id.
- `status` — one of `pending`, `answered`, `timeout`, `undeliverable`.
- `answer` — the bounded inline distilled answer (set on reply).
- `answer_file` — optional absolute path to fuller detail the delegate wrote (a pointer, not inlined content).
- `responder` — the id that actually replied; `ask-reply` requires it to equal `to` (anti-spoof).
- `created` / `answered` — `now()` stamps (same UTC-microsecond format as the rest of the state layer).

Liveness beacons for the `await` watcher live alongside, keyed by request id, mirroring `watch-fleet`:
`~/.wingman/ask/<req-id>.pid` and `~/.wingman/ask/<req-id>.beat`.

Ask records are **not** archived by `prune` initially (they are ephemeral and small); §9 covers cleanup. Add a `WM_HOME/ask/` create to `ensure_home()`.

### 3.2 New subcommands

Add to `build_parser()` and implement as `cmd_ask_*`:

- **`ask-new --id <req> --from <caller> --to <target> --question <q>`**
  Writes the request record with `status: "pending"`. Refuses if the file already exists (idempotency guard against a double-send). Prints `<req>`.

- **`ask-reply --id <req> --responder <id> --answer <text> [--answer-file <path>] [--max-chars N]`**
  Loads the record; refuses if not found, if `status != "pending"` (already answered/closed), or if `responder != record.to` (anti-spoof, printed as a clear error). Enforces the bound: if `len(answer) > max-chars` (default `WM_ASK_MAX_CHARS`, e.g. 4000), **reject** with a message telling the delegate to summarize or move detail into `--answer-file` and keep `--answer` short. If `--answer-file` is given, validate the path exists and store the absolute path (never read its bytes into state). Sets `status: "answered"`, `answer`, `answer_file`, `responder`, `answered = now()`. Prints `<req>`.

- **`ask-get --id <req>`**
  Prints the record JSON. Used by `await` to poll and by the caller to read the landed answer. Exit non-zero if missing.

- **`ask-resolve --id <req> --status <timeout|undeliverable> [--note <text>]`**
  Terminal non-answer transition, set by `await`. No-ops if already `answered` (an answer that landed in the same tick wins over a timeout — resolve must not clobber a real answer; implement as compare-and-set: only transition when current status is `pending`). Prints the resulting status.

- **`ask-list [--from <caller>] [--status <s>]`** *(observability / cleanup)*
  Prints matching records (tab-separated `id status from to created`). Used by the Stop-hook guard (§7) and cleanup (§9).

Reject-vs-truncate decision for oversized answers: **reject**, do not silently truncate. Truncation would produce a subtly wrong distilled answer; rejecting forces the delegate to actually distil (or use `--answer-file`), preserving correctness. This is the higher-quality choice and costs the delegate one retry.

## 4. `bin/crew-ask` (the new script)

Modelled on `crew-say` (guardrail + tmux delivery) and `pr-watch` (blocking single-shot watcher). bash-3.2-safe, sources `lib/common.sh`.

### 4.1 `crew-ask <id> "<question>"` — send (default subcommand)

1. Team guardrail (see §5): refuse unless the caller may reach `<id>`.
2. Window liveness: refuse fast if there is no live `wm-<id>` window (mirror `crew-say` lines 57-59) — do not create a dangling request for a dead delegate.
3. Mint `req-id`: `ask-$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-8)` (fall back to the Python uuid path like `spawn-crew`). Short, collision-safe enough for concurrent asks.
4. `wm-state ask-new --id "$req" --from "${WINGMAN_CREW_ID:-}" --to "$id" --question "$q"`.
5. Deliver the **framed** message via `wm_tmux_send_message` (the same settle-delay paste-then-Enter primitive `crew-say` uses):

   ```
   [crew-ask $req] $q

   This is a direct question from ${caller:-wingman}. Answer it now, before resuming your
   own work, by running:
     $WINGMAN_BIN/crew-ask reply --id $req --answer "<your distilled answer, <=N chars>"
   (add --answer-file <path> if you need to point at fuller detail). Keep the answer bounded;
   it is captured verbatim into the asker's context. Then continue what you were doing.
   ```

6. Print the `req-id` and the exact arm command, so it is copy-pasteable and unmissable (mirroring how `spawn-crew` prints its `attach` line):

   ```
   ✓ asked <id> (request <req>)
   arm the wait: bin/crew-ask await --id <req> --timeout <sec>
   ```

`send` is foreground and returns immediately. It performs the one-time delivery; `await` (below) is what blocks.

### 4.2 `crew-ask reply --id <req> --answer "..." [--answer-file <path>]` — the delegate's reply

Thin wrapper over `wm-state ask-reply --responder "$WINGMAN_CREW_ID"`, surfacing the reject/anti-spoof errors cleanly. Requires `$WINGMAN_CREW_ID` (a delegate always has one). Prints `✓ replied to request <req>`.

### 4.3 `crew-ask await --id <req> [--timeout <sec>]` — the caller's wait watcher

A blocking loop, structurally identical to `pr-watch`/`watch-fleet`, keyed by `req-id`:

- Interval `WM_ASK_WATCH_INTERVAL` (default ~3s — answers can arrive within one delegate turn, faster than PR/CI cadence).
- Timeout `--timeout` (default `WM_ASK_TIMEOUT`, e.g. 300s). The "delegate did not answer" bound.
- Singleton guard + liveness beacon keyed by `req-id` (`ask/<req>.pid`, `ask/<req>.beat`), touched every iteration, so the Stop hook (§7) can tell a pending ask has a live waiter.
- **Top-of-loop check** (at-least-once, mirroring the existing watchers): evaluate before sleeping so an answer already present the instant the cycle arms fires immediately.

Each iteration, in priority order:

1. `ask-get`: if `status == answered` → **fire** `answered: <req> <inline-answer>` (append ` (detail: <answer_file>)` when present).
2. If the delegate is gone — its `wm-<to>` window is absent, or its merged status is `died`/`stood-down` — and the ask is still `pending`: `ask-resolve --status undeliverable` then **fire** `undeliverable: <req> delegate <to> is <died|gone>`.
3. If elapsed ≥ timeout: `ask-resolve --status timeout` then **fire** `unanswered: <req> no reply within <sec>s`.
4. Else `sleep "$INTERVAL"`.

`fire()` prints the single reason line to stdout and exits (that stdout is the wake the harness delivers back to the caller). Following the primary recommendation of the merged wake-handling work (make the surfaced line an instruction, not bare data), the reason line ends with a short directive:

```
answered: ask-3f2a1b9c yes; foo() now takes an extra optional `verbose` kwarg, callers unaffected
--
Read ~/.wingman/ask/ask-3f2a1b9c.json for the full answer, then continue the work that was
waiting on it. This is a captured reply, not a crew status event — do not report it as roster status.
```

The last sentence is deliberate: it prevents the caller from conflating an ask-reply wake with a `watch-fleet` roster-delta wake (which *does* mandate a roster report). See §7.

Provide `crew-ask await --id <req> --once` (poll exactly once, print an event if pending else nothing) for tests, mirroring `pr-watch --once`.

### 4.4 Ergonomic note (send + await in one)

A combined `crew-ask <id> "<q>" --wait` that sends then blocks in a single armed background task is more convenient but harder to make restart-idempotent (a harness restart of the background task would re-mint a req-id and re-deliver). The two-step (foreground `send` that delivers once, background `await` that only reads) is the robust design and is the recommendation. **Follow-up:** a combined one-shot form that writes the req-id to a known path before blocking, so a restart resumes the same request rather than re-asking.

## 5. Team guardrail (who may ask whom)

Identical policy to `crew-say`: the caller may ask only its own direct reports, a sibling under the same lead, or its own lead.
Rather than duplicate the verdict logic, **extract `crew-say`'s guardrail into a shared helper** `wm_team_guardrail <caller-id> <target-id>` in `lib/common.sh` (it prints `ok`/`deny`/`no-target`), and have both `crew-say` and `crew-ask` call it. This is a behaviour-preserving refactor of `crew-say` (its current inline Python block, lines 28-55, moves into the helper) plus a new consumer. `crew-ask` honours the same `--force` / `WM_CREW_SAY_FORCE`-style override (use a shared `WM_TEAM_FORCE`, with the existing env var still respected for `crew-say`) so a human operator can bypass.

The `reply` direction needs no separate guardrail: the request was authorised at send time, and `ask-reply` already refuses a responder that is not the addressed `to`.

## 6. Status contract and playbook changes

### 6.1 `playbook/_status-contract.md` (appended to every crew brief — the right place, since any member can be asked)

Add a short section **"Answering a direct question (`crew-ask`)"**:

> Occasionally a message will arrive framed as `[crew-ask <req-id>] <question>`.
> This is a direct question from your owner, your lead, or a sibling, and it expects a captured answer.
> Answer it promptly, before resuming, by running:
> `$WINGMAN_BIN/crew-ask reply --id <req-id> --answer "<distilled answer>"` (add `--answer-file <path>` to point at fuller detail).
> Keep the answer bounded and distilled — it is captured verbatim into the asker's context, so it must be an answer, not a transcript.
> **Answering does not change your own status.** It is orthogonal to your lifecycle: stay in whatever state you were in (`working`, `blocked`, …) and continue your own work after replying.

### 6.2 `CLAUDE.md` (wingman's own operating doc) and `playbook/lead.md` (the other caller)

Add `crew-ask` to the command vocabulary as the **synchronous counterpart to `crew-say`**, and draw the line between them:

- `crew-say <id> "<msg>"` — one-way inject; use it to course-correct, hand off, or relay the pilot's answer. Captures nothing.
- `crew-ask <id> "<question>"` — ask-and-capture; use it when you need a *specific answer* back in your own context (a fact, a yes/no, a decision input), not a status. Flow: `send` → arm `crew-ask await --id <req>` as a harness-tracked background task → end the turn → on wake, read `~/.wingman/ask/<req>.json` and continue.

Note the cost/discipline framing consistent with the rest of `CLAUDE.md`: an ask consumes a delegate turn, so ask when you genuinely need the answer to proceed; prefer reading distilled status when that suffices.

## 7. Composition with the merged wake-handling changes, and the Stop hook

The recently merged wake-handling work changed `watch-fleet`'s `fire()` so its stdout carries state-change **deltas plus a directive naming the wake file**, and the wake file now holds the new events **and** the full roster for the owner's scope (attention states are now `blocked`, `review`, `done`, `died`, `stalled`).

`crew-ask` composes with this by **staying entirely off that channel**:

- It never writes `$WAKEFILE`, never calls `wm-state ack`, and never appears in `needs-attention`. So it cannot re-introduce the short-circuit that channel was hardened against, and a landed answer never masquerades as a roster event.
- Its own reason line **borrows the lesson** (surfaced line = instruction, not bare data) and explicitly tells the caller *not* to treat the reply as roster status — the one place the two channels could be confused.
- The caller can legitimately have both watchers armed at once: `watch-fleet` (persistent, re-armed chain, watches crew state) and one or more `crew-ask await` (single-shot, watches a response file). They use distinct pidfiles/beacons (`watch*.pid` vs `ask/<req>.pid`) and never contend.

**Stop hook (`hooks/stop-guard.sh`) extension.** Today the hook blocks wingman from going idle "blind" when crew need attention or crew are in flight with no live watcher. A pending ask with no live `await` watcher is the exact same failure shape: the caller asked, did not arm the wait, and would sleep forever with the answer never waking it. Add a third guard:

- Compute pending asks owned by this layer: `wm-state ask-list --from "$OWNER" --status pending`.
- For each, check whether a live `await` cycle exists (its `ask/<req>.pid` names a live pid **and** `ask/<req>.beat` is fresh within the grace — reuse the existing beacon-freshness check already in the hook).
- If any pending ask has no live waiter, block the stop with a reason: *"You have a pending question to `<id>` (`<req>`) with no live waiter. Arm `bin/crew-ask await --id <req>` as a harness-tracked background task so its exit wakes you when the answer lands, then you may stop."*

This mirrors the existing "crew in flight but no live watcher cycle" branch and makes forgetting the wait a caught error rather than a silent hang. The corresponding guard belongs in a lead's own stop path too if/when leads gain a Stop hook; today the same instruction lives in `lead.md` prose (§6.2).

## 8. Harness-agnostic considerations

`crew-ask` introduces no new harness coupling:

- **Message delivery** goes through `wm_tmux_send_message` in `common.sh` — the single already-isolated tmux boundary (the paste-then-Enter settle-delay lives there and is shared with `crew-say`/`spawn-crew`). Swapping harness/backend is the same localized change it already is.
- **The wake** is the harness's tracked-background-task exit, exactly as for `watch-fleet` and `pr-watch`. Arming `crew-ask await` through the harness's background mechanism is the one harness-specific act, and it is the caller's responsibility (documented), not baked into the script.
- Everything else is POSIX shell, files under `~/.wingman/`, and `wm-state.py` (run via the managed `uv` interpreter). No jq, no bashisms beyond 3.2.

The framed-message text assumes the delegate is an agent that reads injected input as a prompt (true for the default `claude` `WM_AGENT`). That assumption already exists for `crew-say`; `crew-ask` inherits it and adds nothing new.

## 9. Risks and edge cases

- **Delegate busy / mid-turn.** Injected keystrokes queue in the delegate's input and are picked up at its next turn boundary, so an answer to a busy delegate arrives after its current turn completes. Latency ≈ up to one delegate turn. The default 300s timeout accommodates a delegate deep in a long tool run; make it tunable and document the tradeoff.
- **Delegate blocked.** A `blocked` delegate is at its input prompt, so it sees the ask promptly; replying pulls it into a brief turn and then it returns to `blocked`. Answering does not disturb its `blocked` status (contract §6.1). Acceptable and useful.
- **Delegate dead / window gone.** `send` refuses up front if no live window (no dangling request). If the delegate dies after send, `await` detects the missing window / `died` status and fires `undeliverable` — the caller is woken with a real outcome, never left hanging.
- **Delegate never answers (ignores the ask).** `await` fires `unanswered: <req> …` at timeout after `ask-resolve --status timeout`. The caller decides what to do (re-ask, escalate, proceed without).
- **Answer too large.** `ask-reply` rejects over the cap and instructs the delegate to distil or use `--answer-file`; state never ingests a transcript. The caller reading `answer_file` is the caller's own choice (and its own context cost) — the *channel* stays bounded.
- **Answer/timeout race.** `ask-resolve` is compare-and-set on `pending`, so an answer that lands in the same tick as the timeout wins; `await` re-reads and fires `answered`, not `unanswered`.
- **Concurrent asks.** Each request is a distinct `req-id` → distinct file → distinct `await` watcher/beacon. A caller may ask several delegates at once (several `send`s, several armed `await`s). One delegate may hold several pending asks; each framed message carries its own `req-id`, so replies never cross. No shared mutable state beyond per-request files, which `wm-state` writes atomically (temp-file + `os.replace`, as elsewhere).
- **Double-send / background restart.** `ask-new` refuses to overwrite an existing record; the two-step split keeps the one-time delivery in the foreground `send`, so a restarted `await` (read-only) never re-delivers. (The combined one-shot form is deferred precisely because it complicates this — §4.4.)
- **Spoofed reply.** `ask-reply` requires `responder == to`; a different session cannot answer on the delegate's behalf.
- **Guardrail regression.** Extracting `crew-say`'s guardrail into a shared helper must be behaviour-preserving; the existing `tests/crew-say-guardrail.test.sh` guards against regression, and a new test exercises the same matrix through `crew-ask`.
- **Stale ask files.** Answered/timeout/undeliverable records accumulate under `~/.wingman/ask/`. Add best-effort cleanup: `await` deletes the request file after firing an `answered`/terminal event **once the caller has consumed it** — but since the caller reads it *after* the wake, `await` must not delete before the read. Simplest correct approach: leave the file; add a `wm-state ask-prune [--older-than-hours N]` swept opportunistically (e.g. by `crew-prune` or on `spawn-crew`/`init`). Cleanup is non-critical (files are tiny) and must never race the caller's read, so deletion is time-based, not event-based.

## 10. Suggested build order

1. **Shared guardrail refactor.** Extract `wm_team_guardrail` into `lib/common.sh`; rewire `crew-say` to use it. Confirm `tests/crew-say-guardrail.test.sh` still passes (behaviour-preserving). *(Enables reuse; no new behaviour.)*
2. **State layer.** Add `ask/` to `ensure_home()` and implement `ask-new`, `ask-reply` (with cap + anti-spoof + compare-and-set), `ask-get`, `ask-resolve`, `ask-list` in `wm-state.py`. Unit-test in isolation (pure files/Python, no tmux).
3. **`bin/crew-ask`.** Implement `send`, `reply`, `await` (with `--once`), reusing `wm_tmux_send_message`, the shared guardrail, and the new state subcommands. Model `await` on `pr-watch` (singleton beacon keyed by `req-id`, top-of-loop check, single fire).
4. **Contracts.** Add the delegate section to `playbook/_status-contract.md`; add the caller vocabulary and the `crew-say` vs `crew-ask` distinction to `CLAUDE.md` and `playbook/lead.md`.
5. **Stop-hook guard.** Add the "pending ask without live waiter" branch to `hooks/stop-guard.sh`.
6. **Tests.** Add `tests/crew-ask-guardrail.test.sh` (deny cross-team), and a stub-agent E2E (`tests/crew-ask.test.sh`) covering: happy path (stub auto-replies → `await` fires `answered`), timeout (no reply → `unanswered`), dead delegate (kill window → `undeliverable`), oversized answer (rejected), spoofed responder (refused), and two concurrent asks (independent). Reuse the `WM_AGENT` stub pattern already used by `tests/spawn-scope.test.sh`/`watch-fleet.test.sh`, and `WM_ASK_WATCH_INTERVAL`/`WM_ASK_TIMEOUT` overrides to keep tests fast. Wire into `tests/run.sh`.
7. **Docs.** Update `bin/doctor` only if a new dependency were introduced (none is) — otherwise no change. Review `CLAUDE.md`/playbook prose touched above for internal consistency.

## 11. Open questions

- **Default timeout.** 300s is a starting point; the right value depends on how long delegates typically stay mid-turn. Tunable via `WM_ASK_TIMEOUT`; revisit after real use.
- **Should a lead's Stop path guard pending asks?** Leads run the same loop one layer down but do not currently have their own Stop hook (the guard is `CLAUDE.md`/`lead.md` prose for them). If leads gain a Stop hook later, fold the same pending-ask guard in there. Out of scope for this plan.
- **Combined one-shot `crew-ask --wait`.** Deferred (§4.4) pending a restart-idempotent request-id handshake. Follow-up, not part of this build.
- **Ask-record retention/audit.** Whether answered asks should be archived (like `crew-archive.jsonl`) for later inspection, or purely ephemeral. This plan treats them as ephemeral with time-based cleanup; promote to archived if an audit need emerges.
