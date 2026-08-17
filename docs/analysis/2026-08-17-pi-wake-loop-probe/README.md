# Probe: does `pi` have the primitives wingman's wake loop is built from?

**Date:** 2026-08-17
**Answer:** yes, demonstrated end to end. Three runs, two independent operators, all matching.
**Scope:** this is a proof of *primitives*, not a continuity transport. See "What this does not show".

Kept in the repo because it is the executable evidence behind the most consequential claim in
`docs/plans/2026-08-17-orchestrator-guard-transports.md` (§3.2.1), and because it is the natural seed
of the continuity follow-on that plan records. Prose alone is not auditable; this is.

## Why it was run

An earlier draft of that plan asserted that no non-Claude agent CLI could host wingman's wake loop,
reasoning from the absence of two Claude Code harness features: `asyncRewake` on a Stop-hook entry,
and `run_in_background` on a Bash tool call. Plan review challenged the claim as doc-absence rather
than verification, pointing at `pi`'s shipped `ExtensionAPI`. The challenge was correct.

## The primitives, from the installed declarations

`@earendil-works/pi-coding-agent@0.84.1`, `dist/core/extensions/types.d.ts`:

```ts
/** Fired after an agent run has fully settled and no automatic retry, compaction,
 *  or queued continuation will run. */
export interface AgentSettledEvent { type: "agent_settled"; ... }
on(event: "agent_settled", handler: ExtensionHandler<AgentSettledEvent>): void;

/** Send a user message to the agent. Always triggers a turn. */
sendUserMessage(content: string | (TextContent | ImageContent)[],
                options?: { deliverAs?: "steer" | "followUp" }): void;
```

Handlers may be async (`ExtensionHandler<E,R> = (event, ctx) => Promise<R|void> | R | void`).

## Method

`wake-loop-probe.js` (this directory) registers an `agent_settled` handler that runs a **blocking
subprocess** (`sleep 3`, standing in for a `bin/watch-fleet` arm) and then calls `sendUserMessage`
instructing the model to `touch` a marker file. Capped at one rewake so it can never loop.

Loaded into a **real interactive `pi` pane** under tmux against a live provider credential
(`openai-codex`), then given one ordinary opening turn:

```
PI_WAKE_PROBE_DIR=<probe-dir> pi --provider openai-codex --approve --no-session \
    --no-context-files --no-extensions -e docs/analysis/2026-08-17-pi-wake-loop-probe/wake-loop-probe.js
```

`--no-extensions` alongside `-e` is deliberate: it confirms the explicit path still loads while
discovery is off. The startup pane confirmed `[Extensions] wake-loop-probe.js`.

**The pane must be a real TTY.** Piping `pi` through `tee` (or anything else) to capture output kills
it at startup with no error and an empty log - the run simply never happens. Capture the pane with
`tmux capture-pane` instead of a pipe. Both people who have run this probe hit that trap on their
first attempt, which is why it is written down here: it is the same silent-tolerance behaviour the
plan's §3.2 already documents for a broken or missing extension path, where `pi` also exits 0 and
says nothing. Assume no news is bad news with this binary, and assert on a positive signal.

## Result

| marker | observed | what it establishes |
|---|---|---|
| `settled.marker` | `settled rewakes=0` then `settled rewakes=1` | `agent_settled` fired after the first turn **and again after the woken turn** - the cycle re-arms |
| `watcher.marker` | `blocked_ms=3008` | the blocking wait was genuinely held **inside the extension**, not by a model-issued tool call |
| `sent.marker` | `sendUserMessage called` | the rewake was issued |
| `rewoke.marker` | created | **the model executed a bash tool call in the woken turn** |

Pane transcript (`pane-transcript.txt`, paths substituted):

```
 Reply with exactly the word ACK and nothing else. Do not use any tools.
 ACK
 WAKE EVENT. Use the bash tool once to run exactly: touch <probe-dir>/rewoke.marker  -- then reply DONE.
 $ touch <probe-dir>/rewoke.marker
 (no output)
 Took 0.0s
 DONE
```

Run three times on 2026-08-17 with matching results (`blocked_ms` 3007, 3008, 3008). The third
was an independent reproduction by plan review, on a separate invocation, from this README's command
verbatim - so this finding is independently confirmed rather than singly attributed.

## What this shows

The three primitives wingman's wake loop is made of all exist in `pi`'s shipped, documented API:

1. a settled-signal to hang the arm on (`agent_settled`),
2. a way to hold a blocking wait **without a model-issued tool call** - which is what dissolves the
   `run_in_background` half of the original argument entirely, since the extension holds it,
3. a way to re-invoke the session when that wait exits, re-armable across cycles.

## What this does not show

That a `pi` continuity transport exists. `hooks/stop-continuity.sh` is roughly 950 lines of
accounting this probe does not touch: the singleton claim, the spurious-failure budget, standdown
markers and their run-scoping, blocked-owner re-assertion, and the kill switch. Building that is
recorded as a follow-on in the plan, not done here.

It also says nothing about `codex`, `grok`, or `opencode`. Those remain **not built and not probed**:
each has plausible-looking surface (a `Stop` event; opencode's bus `event` hook at
`@opencode-ai/plugin` `dist/index.d.ts:175` plus its SDK `client`), and nobody has driven any of it.
