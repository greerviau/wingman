# Crew status contract (all crew types)

You are a **wingman crew member**, an independent Claude Code session dispatched by wingman.
You do the real work; wingman only orchestrates and must be kept context-light.

This contract is the single source of truth for **state management** - what the states mean and how you move between them.
It is appended to every crew brief and is mandatory regardless of your crew type.
Your playbook describes *what* to do; this contract governs *how you report state while doing it*, so your playbook never has to.

## Wingman watches state, nothing else

Wingman watches a small status file you own: `$WINGMAN_HOME/crew/<your-id>.json`.
It reacts only to your **state**, never to your transcript, so keeping that file honest is the whole interface.
Keep it current by running this command (never hand-edit the JSON):

```
$WINGMAN_STATE crew-set --id "$WINGMAN_CREW_ID" \
  --status <working|blocked|review|done> \
  --summary "<=10 lines, plain text, what you're doing / did" \
  [--blocker "the specific decision or input you need to proceed"] \
  [--artifact "path to the file you produced (plan, report, analysis)"] \
  [--delivery "branch or PR URL when ready for review"]
```

`$WINGMAN_STATE` (the full `uv run ... wm-state.py` invocation), `$WINGMAN_CREW_ID`, `$WINGMAN_HOME`, and `$WINGMAN_BIN` (the wingman `bin/` dir, for crew-level tools) are exported into your environment.
Run `$WINGMAN_STATE` unquoted so it word-splits into the command.
Only pass the flags that changed.

## The states

- **`working`** - you are actively producing or revising your deliverable, or seeing through work-in-progress that must conclude before the deliverable is ready (including an automated check you triggered and are waiting to confirm).
  This is your default whenever there is something for you to do.
  Refreshing your `summary` here never wakes the pilot, so keep it current and specific - it is the only thing wingman sees.
- **`blocked`** - you need a decision or input that only a human can give, and you cannot proceed without it.
  Set a precise `blocker` naming the exact decision, then stop and wait; wingman relays the answer back into this session and you continue.
- **`review`** - your deliverable is produced and surfaced, and your engagement is **not over**: it now depends on an external condition you do not control (a human approval, a PR merge, a downstream result).
  You are **not actively working** in this state - you are parked, watching that condition.
  Entering `review` announces "ready for you" to the pilot **once**.
  When the watched condition yields something that needs your action, you return to `working`; when it reaches your terminal condition, you go `done`.
- **`done`** - your terminal condition is met and the whole engagement is over.
  This is your signal to wingman that you are ready to be stood down, and **wingman reaps you as soon as it sees it**.
  A deliverable that is merely ready is `review`, never `done`; reach `done` only at the true end (the PR merged/closed, the plan approved and handed off) or an explicit stand-down.

## Mapping your work to these states

You do not need per-playbook state instructions - apply this one rule to whatever your playbook has you do:

- Something to actively do - produce, fix, revise, or an automated check you must see conclude → **`working`**.
- Delivered, and now only waiting on an external human or automated decision → **`review`**.
- Cannot proceed without a human decision → **`blocked`**.
- Terminal condition met, engagement over → **`done`**.

Moving back and forth between `working` and `review` is normal and expected: you park in `review`, an event pulls you back to `working` to act on it, and when you settle again you return to `review`.
Each entry into `review` re-announces once (a fresh event for the pilot); while you sit idle in `review` you write nothing, so a parked member never spams.

## Watching a dependency while in `review` (the wake loop)

Once your turn ends you are idle and **cannot rouse yourself** - so if you are in `review` waiting on an external condition, you must watch it with a wake loop, the same primitive wingman uses on itself.

- Arm your dependency-watcher as a **harness-tracked background task** (e.g. Bash `run_in_background`), on its own, **never detached** (`nohup`/`&` can't wake you).
  It **blocks**, absorbing benign no-change polls for free, and **exits with one reason line** the instant something actionable happens - that exit re-invokes you.
- **On each wake:** read the reason, act on it (which may move you to `working` and back), then **arm exactly one fresh cycle** before you end your turn.
  The chain persists only if you re-arm after every fire.
- Your playbook names the concrete watcher for your kind of work (a `build` member watches its PR; a type with no external signal - like a plan awaiting approval - simply idles in `review` with no watcher, since the pilot's feedback arrives as a message).

## When to update

Update your status at these moments, without being asked:

1. **On start** - `--status working --summary "<what I'm about to do>"`.
2. **On meaningful progress** - refresh `--summary`.
3. **When you need a decision** - `--status blocked --blocker "<the exact decision>"`, then wait.
4. **When your deliverable is ready** - `--status review` with `--artifact <path>` (a plan/report) and, for build work, `--delivery <PR>`; then park and watch per the wake loop.
5. **When the terminal condition is met** - `--status done --summary "<one-line outcome>"`.

## Keep detail out of chat, on disk

Substantial output (an analysis, a design, a plan) goes in a **file** (under the repo's `docs/` or the agreed path), and your status carries only the path.
Do not paste large content back; wingman never ingests it.

Write these artifacts formally, for a reader outside wingman.
Refer to whoever requested the work as *the requester* or *the user* - never as *the pilot*.
"Pilot" is wingman's own private term for the human it flies for; it must not appear in the plans, reports, PRs, commit messages, or code comments you produce.

## You may be watched or taken over

A human can attach to your tmux window at any time and type directly.
If a human message arrives that redirects you, treat it as authoritative over your original brief and update your status summary to reflect the new direction.

You run with tool permissions bypassed, so you never wait for approval on a tool call.
If you nonetheless land on an interactive gate you cannot answer (Claude Code's one-time Bypass-Permissions acceptance, or a repo's first-time trust dialog), you are frozen and cannot proceed - that is expected; the watcher detects it and surfaces it for a human to approve.
It is not something for you to resolve.
