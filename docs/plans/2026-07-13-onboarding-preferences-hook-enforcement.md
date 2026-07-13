# Plan: a general onboarding-preferences step, enforced by a hook

## Problem

`CLAUDE.md`'s "Confirm the pilot's location (once per run)" section documents a mandatory first step: before touching the pilot's directive, a fresh wingman session must check `pilot-location-get`, and if unanswered, ask the pilot via `AskUserQuestion` and cache the result with `pilot-location-set`.
This section itself exists because an earlier version of the same check - a clause buried inside `playbooks/_status-contract.md`'s Artifact-publish gate - was observed being skipped in practice (see `docs/plans/2026-07-13-eager-pilot-location-ask.md`), so it was promoted to a dedicated, unconditional, top-level `CLAUDE.md` section positioned before onboarding and before the operating loop.

That promotion has itself now been observed failing the same way.
Concrete repro evidence from a live session: `WINGMAN_RUN_ID` was set, `wm-state.py pilot-location-get` returned exit 1 (no cached answer), and the session proceeded through multiple turns of unrelated work before the check ever ran.
It only ran because the pilot asked directly why it hadn't been.
Nothing in the tool-call path was ever blocked, denied, or flagged; the session simply never happened to prioritize that paragraph of `CLAUDE.md` over the directive in front of it.

This is the second failure of the same shape, at two different placements (a playbook clause, then a top-level `CLAUDE.md` section).
Both placements share the same underlying weakness: they are prose that a session can act correctly on if it reads and prioritizes it, but nothing prevents a turn's tool calls from proceeding if it doesn't.
The fix is to make the check something the harness enforces mechanically, so a session cannot take any real action while required preferences are unanswered, regardless of what it reads or remembers - the same move already made for two other reliability problems in this repo (`hooks/no-direct-edit-guard.sh` for delegation, `hooks/stop-guard.sh` for watcher/attention).

**A third occurrence surfaced while this plan was in review, in a sibling location.**
The software-analyst session producing this very plan reported its first revision as `review`-state with a markdown `--artifact`, while the pilot was in fact confirmed remote for that `WINGMAN_RUN_ID` - so `playbooks/_status-contract.md`'s condition B should have applied and published it as a hosted Artifact.
It never did: the crew-set call went out with only the local path, and it took the pilot noticing and asking for wingman to publish it after the fact.
This is the identical failure class (a prose contract clause a session can silently skip) occurring at a different enforcement point - not wingman's own onboarding ask, but a crew member's own report-time check - and the pilot asked for it to be closed as part of this same plan, not a separate follow-up.
Section 6 below covers it.

## Scope change from the original draft (per pilot feedback)

The first draft of this plan built a single-purpose remote/local hook.
The pilot asked to broaden it: rather than a one-question mechanism, this becomes a general **onboarding-preferences** step - a small, extensible set of questions asked once per wingman session, framed to the pilot as *"Before I start working, I need to ask you some preference questions:"*.
Remote/local becomes one preference among several, not the only one.
Two more are designed in now, with room left for more later without restructuring the mechanism again:

1. **Location** (carried over from the original draft) - is the pilot watching this session locally, or over Remote Control right now.
2. **Deliverable linking** - for a markdown deliverable (a plan, a report, an analysis), does the pilot want it also published as a hosted Artifact link, or the local file path only.
3. **Explanation verbosity** - how much wingman narrates its own reasoning and routing decisions to the pilot in conversation (not roster/status-report altitude specifically, though related) - i.e. whether `CLAUDE.md`'s "Keep your voice to the pilot lean" default (state *what*, never *why*, no narrated internal routing) is what the pilot wants, or whether they'd rather wingman explain more of its reasoning as it goes.

This changes the design in three concrete ways, each resolved below: the state layer generalizes from a single boolean to a per-run preference store; the `PreToolUse` guard's "unanswered" check gates on the full required set, not one flag; and the `SessionStart` nudge names the full question set.

## Recommended approach

### 1. State layer: `wm-state.py` gains a generic per-run preferences store

Replace the single-purpose `pilot-location-get`/`pilot-location-set` subcommands and `pilot-location.json` file with a generic key/value store scoped by `WINGMAN_RUN_ID`, so adding a fourth or fifth preference later never touches this layer again:

- **File:** `preferences.json` (replaces `pilot-location.json`), shape `{"wingman_run_id": "<id>", "prefs": {"<key>": "<value>", ...}}`.
  Exactly like today's run-id scoping: a `pref-get`/`prefs-list` for a `wingman_run_id` that doesn't match the file's stamped run id is treated as fully unanswered (a fresh run never sees a prior run's stale answers), and the first `pref-set` for a new run id replaces the whole file with a fresh dict rather than merging across runs.
- **`pref-set --run-id <id> --key <name> --value <val>`** - merge-writes one key into that run's `prefs` dict (read-modify-write under the existing `with_locked` pattern, same as today's `pilot-location-set`).
- **`pref-get --run-id <id> --key <name>`** - prints the value and exits 0 if set for that run; exits 1 if unset or the run id doesn't match. Used by any single consumer that only cares about one preference (e.g. `playbooks/_status-contract.md`'s link-formatting section, which only needs `remote`).
- **`prefs-list --run-id <id>`** - prints every currently-set `key<TAB>value` pair for that run, one per line (or nothing if the run id doesn't match / nothing is set yet). Used by the guard and nudge hooks so checking "are all N required preferences answered" costs one subprocess call and one file read, not N.
- Values stay plain strings (`"true"`/`"false"` for `remote`, `"artifact"`/`"local"` for the linking preference, `"concise"`/`"detailed"` for verbosity) - no schema beyond string values is needed, keeping the store agnostic to what any given preference means.

`tests/pilot-location.test.sh` is replaced by `tests/preferences.test.sh`, covering `pref-get`/`pref-set`/`prefs-list` (including the run-id-scoping behavior the old test already proved) and multi-key merge behavior (setting `remote` then `artifact_linking` for the same run and confirming `prefs-list` returns both, `pref-get` for either individually still works).

### 2. `hooks/pilot-preferences-guard.sh` - the enforcement (`PreToolUse`, all tools)

Renamed and generalized from the original draft's `pilot-location-guard.sh`.
A `PreToolUse` hook registered with an empty/wildcard matcher (confirmed against the installed CLI build that `"matcher": ""` matches every tool), active only for wingman's own top-level session:

- **Activation:** `WINGMAN_CREW_ID` unset AND `$CLAUDE_PROJECT_DIR` resolves to this wingman checkout (the same `wm_is_wingman_repo_session` helper `no-direct-edit-guard.sh` already defines) - not for `WINGMAN_CREW_TYPE=lead`, since per the existing design a lead never reads this section of `CLAUDE.md` and never does its own eager ask; only wingman's own top-level session does.
- **No-op (exit 0):** `WINGMAN_RUN_ID` unset (not launched via `bin/wingman`); or every key in the **required-preferences list** is present in `prefs-list --run-id "$WINGMAN_RUN_ID"`.
- **The required-preferences list is the one piece of "room to grow" this design needs**, and it lives in exactly one place: a small shared shell fragment, `hooks/lib/pilot-prefs.sh`, defining an ordered list of keys and a one-line human-readable prompt per key, e.g.:

  ```sh
  WM_PREF_KEYS="remote artifact_linking verbosity"
  wm_pref_prompt() { case "$1" in
    remote)          echo "Are you watching this session locally, or over Remote Control right now?" ;;
    artifact_linking) echo "For markdown deliverables (plans/reports), also publish as a hosted Artifact link, or local file path only?" ;;
    verbosity)       echo "How much should I narrate my own reasoning/routing as I work - concise, or more detailed explanations?" ;;
  esac; }
  ```

  Both the guard and the nudge (below) source this one file, so adding preference #4 later means adding one line to `WM_PREF_KEYS`, one `case` arm, and one question in `CLAUDE.md`'s prose - never touching the guard's or nudge's own logic, and never touching `wm-state.py`.
- **When one or more required keys are missing:** deny every tool call except a small set of narrow exceptions, so the session can still resolve the gate itself and an in-flight fleet doesn't go unsupervised while it does:
  - `tool_name == "AskUserQuestion"` - always allowed through unconditionally (this is how the gate gets satisfied).
  - `tool_name == "Bash"` where the command resolves (see "The command-resolution helper" below) to `wm-state.py prefs-list` or `wm-state.py pref-get` - always allowed, since these are read-only and cannot themselves satisfy or fake the gate.
  - `tool_name == "Bash"` where the command resolves to `wm-state.py pref-set` - allowed **only if** an `AskUserQuestion` call has already completed this session (see "Closing the self-answer gap" below); otherwise denied with a reason explaining that an answer must come from an actual question to the pilot first.
  - `tool_name == "Bash"` where the command resolves to `bin/crew-list`, arms `bin/watch-fleet` as a background watcher, or arms `bin/crew-ask await --id <req>` as a background waiter - allowed, so a session restarting mid-effort (fresh `WINGMAN_RUN_ID`, crew already in flight, possibly a pending ask) can still supervise its existing fleet while preferences are pending; see "Interaction with `stop-guard.sh` and an in-flight fleet" below.
    `bin/crew-say` (relaying an answer to a blocked member) is deliberately **not** added to this list: unlike the three read/supervise commands above, sending a message is closer to "acting," the pilot is necessarily present in the moment that action is taken anyway (they just answered something), and deferring it one turn until the gate clears costs little - a deliberate exclusion, not an oversight.
  - `tool_name == "Read"` where the target is exactly `$WINGMAN_HOME/wake` - the file `stop-guard.sh`'s own block reason tells the session to read; allowed for the same supervision reason as `crew-list`/`watch-fleet` above.
  - A command mixing an allowed invocation with anything else (chained via `&&`/`;`/`|`) does not qualify for any of the above - the segment must be *exactly* one of the allowed shapes.
  - Every other tool call is denied with a reason that lists the still-missing preferences by their `wm_pref_prompt` text and says plainly that nothing else proceeds until `AskUserQuestion` has answered all of them and each has been cached with `pref-set`.

This remains the load-bearing piece - the reason a stale prose-only version failed twice is exactly the reason a hard deny, not a reminder, is what has to sit in front of every other tool call.

#### The command-resolution helper

Both this guard and section 6's need to recognize a target invocation (`wm-state.py <subcommand>`, `bin/crew-list`, `artifact-scan.sh <path>`, ...) regardless of how it's actually typed - a relative path, an absolute path, or wrapped in `uv run --no-project --quiet <path>`, since that last form is the literal, non-negotiable shape `$WINGMAN_STATE` expands to (`bin/spawn-crew`'s `WINGMAN_STATE=$(quote "$WM_UV $WM_STATE_PY")`, `WM_UV` defaulting to `uv run --no-project --quiet`) - the exact string `CLAUDE.md` and this plan's own prose tell every session to run.

`no-direct-edit-guard.sh`'s existing tokenizer almost handles this (splitting on `;`/`&&`/`||`/`|`, unwrapping `env`/`sudo`/`bash -c`), but its `uv` case is insufficient for this reuse: it recurses on `tokens[2:]` after `uv run` without skipping `uv`'s own option flags, so for `uv run --no-project --quiet <path>/wm-state.py pref-set ...` it lands on `--no-project` as the "command" and never reaches the script name.
That gap is latent today only because `no-direct-edit-guard.sh` never needs to recognize a `uv`-wrapped invocation as an *allowed* shape (its own allowlist is untouched by this), but it becomes load-bearing the moment a guard's allowlist must recognize `$WINGMAN_STATE`'s real form - as this plan's guards do.
Denying the exact command `CLAUDE.md` mandates would wedge every fresh session on its own happy path: told to run `$WINGMAN_STATE pref-set ...` by both `CLAUDE.md` and the guard's own deny reason, and denied for running it.

**Fix, applied once in the shared helper, inherited by every caller:** extract a generic `resolve_command(tokens) -> (basename, args)` from `no-direct-edit-guard.sh`'s embedded tokenizer into `hooks/lib/cmd_match.py`, and in its `uv` case, skip every leading token starting with `-` after `run` before resolving the basename of the first non-flag token.
**Caveat, not a gap in what actually matters here:** this correctly handles the literal `$WINGMAN_STATE` shape (`uv run --no-project --quiet <path>`, both flags value-free), but a value-taking `uv run` flag (e.g. `uv run -p 3.12 pytest`) would misparse - `-p` gets skipped, then `3.12` is treated as the command, so the whole invocation fails to resolve rather than reaching `pytest`.
That is a false negative only, and only in the *deny* direction for `no-direct-edit-guard.sh`'s own test-runner detection (a non-standard invocation shape could dodge that guard) - it does not weaken this plan's allowlists, since the one form they must recognize (`$WINGMAN_STATE`) is flag-value-free and already handled.
Fixing the general case (a small table of known value-taking `uv` flags) is a reasonable follow-up, not required for this plan's guarantees.
`no-direct-edit-guard.sh` becomes a caller of this shared helper for its own test-runner detection rather than keeping a private copy - it is therefore a **modified file** in this plan (along with `tests/no-direct-edit-guard.test.sh`, which must keep passing unchanged against the refactor), not just a donor whose logic is duplicated elsewhere.
Every guard's own test suite must include the *literal* `$WINGMAN_STATE` string (`uv run --no-project --quiet <abs-path>/wm-state.py <subcommand> ...`), not just a bare relative-path invocation, so a regression here is caught by the exact shape the real system produces, not a simplified stand-in.

#### Closing the self-answer gap

As specified so far, `pref-set` sits on the allowlist unconditionally while the gate is unsatisfied - which means a session under deny pressure could simply invent plausible answers to all three questions and `pref-set` its way past the gate without `AskUserQuestion` ever firing.
That would make "the values come from the pilot" prose again, exactly the failure class this plan exists to close.
Close it the same way section 6 closes its own analogous gap: a `PostToolUse` hook, `hooks/pilot-preferences-ask-tracker.sh` (matcher `AskUserQuestion`), writes a marker (`$WINGMAN_HOME/prefs-asked-<session_id>`, existence-only) the instant any `AskUserQuestion` call completes this session.
`pilot-preferences-guard.sh` allows a `pref-set` Bash call only once that marker exists.
This proves a real question was put to the pilot at some point this session before any answer is accepted - it does not verify the *content* of that question matched the required preferences, which is a residual, explicitly-accepted gap (see Open Questions).

#### Interaction with `stop-guard.sh` and an in-flight fleet

"Survival & reconciliation" is a supported flow: wingman can restart mid-effort with crew already in flight, and a restart mints a fresh `WINGMAN_RUN_ID` - so every preference is unanswered again, on a session that may already own live crew needing supervision.
Until the pilot re-answers, an unqualified deny-everything gate would also deny every command `hooks/stop-guard.sh` itself directs the session to run in each of its three block reasons, while that same hook simultaneously blocks wingman's own stop - a real conflict between two hooks, not a hypothetical:

1. Attention events pending: read `$WINGMAN_HOME/wake`, run `bin/crew-list`.
2. A pending ask with no live waiter: arm `bin/crew-ask await --id <req>`.
3. Crew in flight with no live watcher: arm `bin/watch-fleet`.

This is resolved deliberately, not left implicit: the allowlist above names all three reasons' commands - `bin/crew-list`, arming `bin/watch-fleet`, arming `bin/crew-ask await`, and reading `$WINGMAN_HOME/wake` - as exceptions, on the reasoning that supervising an already-running fleet is not "acting on the pilot's directive" (which is what the gate exists to hold back) - it is keeping existing commitments alive while a new decision is pending.
`bin/crew-say` (stop-guard's reason 1 also mentions it, for relaying an answer to a blocked member) is deliberately left off this list - see the note beside the allowlist above.
The turn still terminates either way (`stop-guard.sh`'s two-pass design, or a pending `AskUserQuestion`, both end a turn without looping), so this exception only affects *what the session can do while parked*, not whether it can stop.

### 3. `hooks/pilot-preferences-nudge.sh` - front-loaded visibility (`SessionStart`, all sources)

Renamed and generalized from the original draft's `pilot-location-nudge.sh`.
Sources `hooks/lib/pilot-prefs.sh` for the same key list and prompts.
Under the same activation condition as the guard, when one or more required keys are missing, it emits `hookSpecificOutput.additionalContext` with the full list of still-missing questions, phrased so the agent's very next action is naturally the batched `AskUserQuestion` call - not the enforcement mechanism itself (context injection is exactly the class of thing that has already failed twice here as static `CLAUDE.md` prose), but it means the guard below rarely has to actually deny anything in practice.

#### Registration channel: project-level for the onboarding trio, user-level for section 6

The three onboarding-trio hooks (`pilot-preferences-guard.sh`, `pilot-preferences-nudge.sh`, `pilot-preferences-ask-tracker.sh`) were originally planned for `bin/doctor`'s user-level registration, styled after the existing delegation guard.
That channel is consent-gated - and this very planning effort found `hooks/no-direct-edit-guard.sh` **not currently registered** on the machine it ran on, despite `CLAUDE.md` describing `bin/doctor` as the thing that registers it (see Open Questions' adjacent finding).
Shipping this plan's central mechanism through that same demonstrably-silent-skip channel would reproduce, at the install layer, the exact failure class the plan exists to close: a mechanism that is correct on paper and never actually turned on.

This is avoidable for the onboarding trio specifically, because its activation condition is already narrower than "any repo": all three fire only when `$CLAUDE_PROJECT_DIR` is this wingman checkout and `WINGMAN_CREW_ID` is unset - precisely the sessions for which this repo's own project-level `.claude/settings.json` already loads.
`hooks/stop-guard.sh` is registered exactly that way today (`.claude/settings.json`'s `Stop` entry) - a proven pattern already living in this repo, not a new one.
Project-level registration ships automatically with a `git pull` of this repo, needs no consent prompt, and cannot silently be "off" the way a user-level opt-in can.

**Fix (applies to sections 2, 3, and this one):** register `pilot-preferences-guard.sh` (`PreToolUse`), `pilot-preferences-nudge.sh` (`SessionStart`), and `pilot-preferences-ask-tracker.sh` (`PostToolUse`) in this repo's `.claude/settings.json`, alongside the existing `Stop` entry - not via `bin/doctor`/`install-user-hook.py` at all.
**Section 6's pair is different and correctly stays user-level:** `artifact-publish-tracker.sh` and `artifact-link-guard.sh` must fire inside a crew member's session, which commonly has its project root in some *other* repo entirely - a project-level entry in wingman's own `.claude/settings.json` would never load there.
The plan's original reasoning for user-level registration was correct for that pair, and only that pair; `bin/doctor`'s registration block should register just those two hooks, not five.

### 4. `CLAUDE.md`: one batched ask, framed as the pilot requested

Rename the "Confirm the pilot's location (once per run)" section to **"Confirm onboarding preferences (once per run)"**, and change its content from a single check to:

1. Run `$WINGMAN_STATE prefs-list --run-id "$WINGMAN_RUN_ID"` and diff against the required key list (`remote`, `artifact_linking`, `verbosity`) to find what's still missing.
   Nothing missing (e.g. continuing after `/clear` or compaction) - nothing to do.
2. If anything is missing and `$WINGMAN_RUN_ID` is set: say *"Before I start working, I need to ask you some preference questions:"* and call `AskUserQuestion` **once**, batching every still-missing question (the tool supports multiple questions in one call), then `pref-set` each answer.
   Suggested phrasing per question:
   - **Location:** "Are you watching this session locally, or over Remote Control right now?" - options *Local at this machine* / *Remote Control*.
   - **Deliverable linking:** "For markdown deliverables (plans/reports), do you want them also published as a hosted Artifact link, or just the local file path?" - options *Also publish as Artifact* / *Local path only*.
   - **Explanation verbosity:** "How much should I narrate my own reasoning and routing decisions as I work?" - options *Concise (state what, not why - today's default)* / *Detailed (explain reasoning and tradeoffs as I go)*.
3. If `$WINGMAN_RUN_ID` is unset, skip silently, exactly as today.

Add one sentence noting this is also mechanically enforced (`hooks/pilot-preferences-guard.sh`, registered project-level in this repo's `.claude/settings.json` - see the registration-channel decision above), so a session that skips it is blocked rather than silently proceeding.
Update "First run (onboarding)" step 1's `bin/doctor` description to mention it registers section 6's user-level pair (`artifact-publish-tracker.sh`, `artifact-link-guard.sh`), alongside the existing delegation-guard mention - the onboarding trio needs no doctor step at all, since it ships via the checked-in project settings file.

Add a short note near "Keep your voice to the pilot lean" (operating loop) that this default is the `verbosity=concise` behavior, and that a cached `verbosity=detailed` preference for the run relaxes it - the pilot may want more of the *why*, not just the *what*.
This plan wires the preference's storage, ask, and gate; it does not rewrite every place in `CLAUDE.md` that currently hardcodes concise behavior - see "Scope boundary" below.

### 5. `playbooks/_status-contract.md`: split condition B, stop inferring linking from location

Condition B currently conflates two independent questions: *is the pilot remote* and *does the pilot want Artifact links*.
Resolving the question the pilot's feedback raised explicitly: **stop inferring the linking behavior from location and make it its own preference**, since a remote pilot may still prefer local-only paths (e.g. wanting to open the file directly rather than a browser tab) and a local pilot may still want a shareable Artifact link.
Update condition B to read the `artifact_linking` preference directly:

```
$WINGMAN_STATE pref-get --run-id "$WINGMAN_RUN_ID" --key artifact_linking
```

Publish only if this prints `artifact`.
The unset case needs one explicit decision, not two contradictory ones - here it is: **`artifact_linking` unset splits into the same two cases `remote` already documents, resolved the same way:**

- **`WINGMAN_RUN_ID` unset, or the preferences file is unreadable** (the true edge case - not launched via `bin/wingman`, or corrupted state): default to `local` without asking - the conservative default, unchanged from today's philosophy (an unnecessary local-only pointer costs nothing; a needless hosted-URL exposure does).
- **`WINGMAN_RUN_ID` is set but `artifact_linking` has no cached value:** ask the fallback `AskUserQuestion` (mirroring `remote`'s own documented fallback), exactly as the intro paragraph already describes.
  After section 2 ships, this second case should be **less common than today, but not rare** - three distinct ways still reach it, and the contract text and the implementer should expect all three, not treat the fallback as dead code:
  - A resumed crew member before finding 4's `crew-resume` fix ships (closed once section 7 lands).
  - Manual interference with `preferences.json` mid-run (a true edge case).
  - **A wingman restart with crew already in flight** - the most common of the three, not an edge case: a restart mints a fresh `WINGMAN_RUN_ID`, and the first `pref-set` under that fresh id replaces `preferences.json` wholesale (per section 1's own run-id-scoping design), so every crew member spawned *before* the restart keeps carrying the *old* run id - its `pref-get`/`prefs-list` against the new file finds nothing, permanently (that member's run id never gains answers, since only the current wingman sit-down answers questions).
    For those pre-restart members, `artifact-link-guard.sh` takes its "preference isn't `artifact`" skip forever, and condition B falls back to exactly this crew-side `AskUserQuestion` - which is the correct, intended degradation (today's existing behavior, not a new failure), but it means a live fleet spanning a restart can have crew members with genuinely different, freshly-re-asked answers to the same preference, and the contract text should say so rather than imply the fallback is a rare corner case.

The intro paragraph's note that "wingman's own `CLAUDE.md` asks this eagerly... the ask below is a fallback for the remaining edge case" still holds, updated to reference `artifact_linking` instead of `remote` and to name all three cases above rather than imply the fallback is rarely reached.

The "Formatting links when the requester is confirmed remote" section is a different, correctly-separate axis (bare URL vs. markdown-link phrasing) and stays gated on `remote` specifically via `pref-get --key remote` - unaffected by this split other than the subcommand rename.

**Scope note carried over from section 6:** condition B's publish check (and this whole section's `artifact_linking` logic) applies to a crew member reporting a markdown deliverable via **either** `--status review` **or** `--status done` - not `review` alone. See section 6's scope note for why (a `reviewer`-type member's delivery is terminal and never passes through `review`).

### 6. Enforcing condition B at report time: gate `crew-set --status review|done --artifact` on proof of publish

This is the newly-required piece: mechanically enforce `playbooks/_status-contract.md`'s condition B (soon `artifact_linking`) at the moment a crew member is about to report a markdown deliverable, the same way section 2 enforces the onboarding ask - deny the tool call itself, don't rely on the crew member reading and remembering the contract.

**Scope note, resolved during review: `review` is not the only delivery status that needs this.**
A `reviewer`-type crew member's delivery shape is terminal, not `review`-then-parked: `playbooks/software-development/reviewer.md` has it carry its findings report as `artifact` and go straight to `done` ("once they are delivered your engagement is over - that is your terminal condition," never entering `review` at all).
The contract text this plan is already rewriting (`playbooks/_status-contract.md`'s condition B, scoped today to "a `review`-state `--artifact` deliverable") shares the same gap - it's a joint contract-and-hook decision, and this is the moment to close both together rather than leave a reviewer's markdown findings report (the same rendering-sensitive deliverable class that motivated this whole section) permanently exempt.
The fix: both condition B's scope and `artifact-link-guard.sh`'s trigger cover `--status review` **or** `--status done` carrying a resolvable markdown artifact - the same two call shapes (explicit `--artifact` on this call, or a bare status change with the artifact resolved from the crew record) apply unchanged to `done` as they do to `review`; every mention of "`--status review`" in the rest of this section should be read as "`--status review` or `--status done`."

#### What's actually inspectable from a `PreToolUse` hook

The concrete question to resolve first: can a hook reliably tell "has this session already called the `Artifact` tool for path X" before allowing a `crew-set` call through?

**What is inspectable, confirmed by reading the installed CLI build (`2.1.207`) and this session's own transcript file:** every hook invocation's stdin JSON carries a `transcript_path` field, and that path is a real, readable JSONL file on disk - `~/.claude/projects/<sanitized-cwd>/<session_id>.jsonl` - containing one JSON object per line, including `type: "assistant"` messages whose `content` array holds `tool_use` blocks with `name` and `input` (e.g. `{"type":"tool_use","name":"Artifact","input":{"file_path": "..."}}`).
So a hook can, in principle, open that file and scan backwards for a prior `Artifact` tool call whose `file_path` matches the deliverable path in the pending `crew-set --artifact` call.

**Why this is not the recommended mechanism, despite being technically readable:**

- A `tool_use` block alone doesn't say whether the call *succeeded* - that requires pairing it (by `id`) with its corresponding `tool_result` entry and inspecting that result for an error indicator, whose exact shape is not part of any documented, stable hook-input contract (it's internal transcript format, observed empirically on this build, not a guaranteed API).
- Path matching requires normalizing relative-vs-absolute forms between what the agent typed to the `Artifact` tool and what it typed to `--artifact`, with no built-in help from the transcript for that.
- Whether the transcript file is guaranteed to already contain an earlier tool call from the *same* assistant turn (multiple `tool_use` blocks in one message, before any of that message's tool calls have executed) is an assumption about internal write-ordering, not a documented guarantee.
- It is reading an internal, undocumented log format to reconstruct a fact the harness already knows authoritatively at the moment it happens (a `PostToolUse` fire) - reconstructing it later from a side channel is strictly more fragile than recording it directly.

**Recommended alternative: record the fact automatically via `PostToolUse`, gate on that record via `PreToolUse`.**
Rather than reverse-engineering "was Artifact called for X" after the fact from the transcript, have the harness's own `PostToolUse` hook mechanism - a documented, stable contract, unlike the transcript's internal shape - write a small marker the instant the relevant tool call actually completes.
This needs no cooperation from the crew member's own prose-following at any point: the marker is written by a hook, not by an instruction the agent might skip.

- **`hooks/artifact-publish-tracker.sh`** (new, `PostToolUse`, matcher `"Artifact|Bash"`), active whenever `$WM_HOME` resolves (no crew-id restriction needed - harmless no-op elsewhere; see minor finding 9 in Open Questions for the marker-accumulation consequence of that breadth):
  - On a completed `Artifact` tool call: if the tool's response shows success (verify the exact success/error field empirically against a live call at implementation time - not yet confirmed here), append/update a record for `realpath(tool_input.file_path)` with `{"status": "published", "url": <resulting URL>, "sha256": <hash of the file's contents at that moment>}` in `$WINGMAN_HOME/artifact-markers/<session_id>.json` (so a later edit to the same path without republishing is detected as stale - see below).
    **If the response instead shows failure or refusal** (the tool errored, was refused by its own built-in categories, or hit a transient failure), record `{"status": "publish-failed", "reason": <best-effort extracted message>, "sha256": <hash of the file's contents at the moment of the attempt>}` for that path instead - the `sha256` field is required here too, not just for `"published"`, since the guard's staleness check (below) applies identically to both statuses. This closes finding 3 below, so a failed attempt is a recorded, escapable state rather than silence.
  - On a completed `Bash` call whose command (resolved via the shared `hooks/lib/cmd_match.py` helper - see section 2) is exactly an invocation of `$WM_BIN/lib/artifact-scan.sh <path>`: read the script's own documented stdout verdict line (`pass`, `pass-soft:...`, or `fail:...`) directly from the hook's `tool_response` - this is the one place condition C's outcome needs recording too, since a `fail:` verdict is a legitimate reason to skip publishing and the gate must not deadlock on it. Record `{"status": "scan-failed"}` for `realpath(<path>)` on a `fail:` verdict; a `pass`/`pass-soft:` verdict needs no separate record since the subsequent `Artifact` call (if made) records `"published"` (or `"publish-failed"`) itself.
  - Marker file is a flat per-session JSON array/dict keyed by resolved path; a session may publish multiple deliverables over its lifetime (an analyst revising a plan and re-entering `review` more than once), so entries accumulate rather than overwrite wholesale.

- **`hooks/artifact-link-guard.sh`** (new, `PreToolUse`, matcher `"Bash"`), active whenever `WINGMAN_CREW_ID` is set (any crew type, any repo - this is the crew-status-contract's own gate, not wingman's onboarding gate, so it must work for a crew member spawned into an entirely different repo):
  - Fires on any `Bash` command whose resolved invocation is `wm-state.py crew-set ...` **containing `--status review` or `--status done`**, whether or not `--artifact` is also present in this particular call - not only the narrower "`--artifact` on the same call" shape.
    Two things make this broader trigger necessary, both surfaced in review: `playbooks/_status-contract.md`'s own "only pass the flags that changed" convention means the *normal* way a member re-enters `review` after revising an already-reported deliverable is a bare `crew-set --status review ...` with no `--artifact` at all; and a `reviewer`-type member's delivery is terminal (`--status done --artifact <path>` in one call, or a bare `--status done` after an earlier `--artifact`), never passing through `review` at all. Both are the exact staleness/unpublished case this gate exists to catch, so the gate must not require a status value or a redundant flag the contract doesn't ask for.
  - Resolve the artifact path to check: if this command's own tokenized argv includes `--artifact <path>`, use that value; otherwise read the `artifact` field from this member's own `$WINGMAN_HOME/crew/<id>.json` (the `--id` value is always present in a `crew-set` call and is already how the hook locates the right record; `cwd` from the hook's own input resolves a relative `--artifact` or record path the same way `realpath` resolves the `Artifact` tool's own `file_path`, so both sides of the comparison land on the same absolute path).
    If no artifact path is resolvable either way (never reported one), allow - nothing to gate.
  - Skip (allow) if the resolved artifact value doesn't look like markdown (approximated by a `.md` extension - a coarser check than condition A's actual "has headers/tables/code fences" test, stated as an approximation, not exact parity, since a hook can't reasonably render-sniff markdown structure).
  - Skip (allow) if `$WINGMAN_STATE pref-get --run-id "$WINGMAN_RUN_ID" --key artifact_linking` isn't `artifact` (condition B doesn't call for publishing - nothing to enforce).
  - Otherwise, check `$WINGMAN_HOME/artifact-markers/<session_id>.json` for the resolved path:
    - A `"published"` record whose stored `sha256` matches the file's *current* contents: allow.
    - A `"scan-failed"` record: allow (the agent already correctly determined, via `artifact-scan.sh`, not to publish).
    - A `"publish-failed"` record whose stored `sha256` matches the file's *current* contents (same staleness check as `"published"` - a fresh edit after a failed attempt still needs a fresh attempt): allow, closing finding 3 - a genuinely failed publish is not a permanent deadlock, it is one recorded, escapable attempt.
    - Missing, or present but stale (the file changed since the recorded status): deny, with a reason naming all four legitimate resolutions - call the `Artifact` tool for `<path>`; if that fails, retry once or report the failure and proceed local-only; if `artifact-scan.sh` already returned `fail:`, report local-only and say why; or, if the `Artifact` tool is unavailable in this session at all (never exposed, so no call can ever complete and no marker can ever appear), report `blocked` instead of retrying indefinitely - and that retrying `crew-set` after any of the first three will succeed.

This closes the loop without ever asking the crew member to remember a rule: it either does the work it already needs to do (publish, check-and-skip, or record a genuine failure) and the marker appears as an automatic side effect, or it is denied with the exact next step named, including the last-ditch escape if the tool itself is unreachable.
The open question in the original draft about an ambiguous success signal forcing an "optimistic record" fallback is no longer needed - a failed/ambiguous `Artifact` response now has its own explicit, escapable recorded state (`publish-failed`) rather than needing to be treated as success to avoid a deadlock.

#### Files and tests for section 6

- `hooks/artifact-publish-tracker.sh` (new) - `PostToolUse` marker writer.
- `hooks/artifact-link-guard.sh` (new) - `PreToolUse` gate on `crew-set --status review|done --artifact`.
- `hooks/lib/cmd_match.py` (shared with section 2's guard - same tokenizer, one more caller).
- `bin/doctor` - register both, user-level, same pattern used for `no-direct-edit-guard.sh` (this pair activates on `WINGMAN_CREW_ID`, i.e. crew sessions in any repo, so it genuinely needs user-level registration, unlike the onboarding trio - see the registration-channel decision below).
- `tests/artifact-publish-tracker.test.sh` (new) - `PostToolUse` fires: a successful `Artifact` call records `published` with a matching hash; a failed/refused `Artifact` call records `publish-failed` with its own hash; a `fail:`-verdict `artifact-scan.sh` call records `scan-failed`; a `pass`/`pass-soft:` verdict records nothing (deferred to the `Artifact` call); an unrelated `Bash`/tool call writes nothing.
- `tests/artifact-link-guard.test.sh` (new) - covering **both** call shapes finding 1 requires, for **both** `--status review` and `--status done`:
  - `crew-set --status review --artifact plan.md` (artifact given explicitly): denied with no marker present; allowed once a matching `published` marker with a current hash exists; denied again (stale) after the file's content changes post-publish; allowed once a `scan-failed` or current `publish-failed` marker exists instead.
  - `crew-set --status review` **with no `--artifact`**, for a member whose on-disk crew record already has `artifact: plan.md`: denied when the record's path has no current marker or is stale (the normal contract-following re-entry after revising a deliverable); allowed once a current marker exists for that record's path.
  - `crew-set --status done --artifact report.md` in one call (the reviewer-type terminal delivery shape) and `crew-set --status done` with no `--artifact` after an earlier `--artifact` call (the bare terminal-status-flip shape): both denied absent a current marker, both allowed once one exists - proving the `review`/`done` symmetry.
  - Allowed unconditionally when the resolved artifact value isn't markdown, when `artifact_linking != artifact`, when `WINGMAN_CREW_ID` is unset, or when neither the command nor the crew record names any artifact at all.
- Manual validation: reproduce this session's exact incident end-to-end - a fresh crew member with `artifact_linking=artifact` cached, writing a markdown deliverable and calling `crew-set --status review --artifact <path>` without ever calling `Artifact` first, confirming the call is denied with the corrective reason, then confirming it succeeds immediately after an `Artifact` call for that same path; then reproduce the second call shape - revise the deliverable, re-enter `review` with a bare `--status review` (no `--artifact`, per the contract's own convention), and confirm the stale marker still denies it; then reproduce the reviewer-type shape - a fresh reviewer session going straight to `--status done --artifact <findings-path>` without publishing, and confirm it is denied the same way `review` is.

### 7. `bin/crew-resume`: restore the environment a resumed member needs for both guards

`bin/crew-resume`'s launch script (lines 147-151) exports `WINGMAN_HOME`, `WINGMAN_CREW_ID`, `WINGMAN_STATE`, `WINGMAN_BIN`, and `WINGMAN_WORKTREE` - but not `WINGMAN_RUN_ID` or `WINGMAN_CREW_TYPE`.
`bin/spawn-crew`'s own launch script *does* export both correctly (`WINGMAN_RUN_ID` from `${WINGMAN_RUN_ID:-}` in its own calling environment; `WINGMAN_CREW_TYPE` from `--type`), so this gap is specific to the resume path, which was written before either mattered and was not revisited when this plan introduced two hooks that key off them.

Left as specified, a resumed crew member silently loses:
- **The section 6 gate** - `pref-get --run-id "$WINGMAN_RUN_ID" --key artifact_linking` cannot succeed without `WINGMAN_RUN_ID`, so `artifact-link-guard.sh` takes its "preference isn't `artifact`" skip path unconditionally after any resume, and condition B's publish behavior itself silently degrades to local-only (the crew-side fallback ask in section 5 can't fire either, for the same missing-env reason).
- **The delegation guard's lead activation** - `no-direct-edit-guard.sh` checks `WINGMAN_CREW_TYPE = lead` to stay active unconditionally for a lead; without it, a resumed lead is only covered by the fallback `WINGMAN_CREW_ID` unset check, which is false for any crew member (leads included), so a resumed lead loses delegation enforcement entirely.

**Fix:** `bin/crew-resume`'s launch-script generation gains two more lines, mirroring `bin/spawn-crew`'s own pattern rather than inventing a new one:
- `export WINGMAN_RUN_ID=$(quote "${WINGMAN_RUN_ID:-}")` - captured from `crew-resume`'s own calling environment at the moment of resume (i.e. whichever wingman sit-down is doing the resuming), exactly as `spawn-crew` captures it at spawn time. This is the semantically correct choice, not a shortcut: `WINGMAN_RUN_ID` identifies "one wingman sit-down," and a resume is fundamentally an action taken by the *current* sit-down (the one running `crew-resume`), not a continuation of whatever sit-down originally spawned the member - so preferences answered for the resuming session are the ones that should govern the resumed member, matching how a freshly-spawned member already works.
- `export WINGMAN_CREW_TYPE=$(quote "$_type")`, where `$_type` is read from the crew record's already-stored `type` field (`crew-add`'s schema already persists `"type": args.type` per member - no schema change needed; `crew-resume` already loads this record for `repo`/`session_id`/`window`, so reading one more field is free).

**Worth stating explicitly, not fixing:** markers in section 6 are keyed by `session_id`, and a resumed session gets a new Claude Code session id distinct from the one that crashed/was replaced - so any `"published"`/`"scan-failed"`/`"publish-failed"` markers recorded before the resume are orphaned under the old id and invisible to the resumed session.
This degrades safely (the guard denies once, prompting a single re-publish or re-scan after resume, not a permanent block), so it is a documented consequence for the implementer to expect, not a bug to chase.

**Fix:** add `bin/crew-resume` to files touched (the two-line launch-script addition above), and extend `tests/crew-resume.test.sh` to assert both new exports appear in the generated resume script.

### Scope boundary: verbosity is wired, not fully propagated, in this plan

The pilot clarified that "verbosity" means wingman's general conversational narration style (how much it explains its own reasoning/routing), not specifically status-roundup detail level - though the two are related, the latter is governed by the separate, more fixed "report results, not mechanics" fleet-wide contract (`docs/plans/2026-07-13-report-results-not-mechanics-reporting-contract.md`), which is a convention about *what a status report contains*, not a per-pilot dial.
This plan adds the `verbosity` preference's storage, the batched ask, and the gate, and touches the one clearest consumption point (`CLAUDE.md`'s "Keep your voice to the pilot lean" note above).
Auditing every place in `CLAUDE.md` and the playbooks where narration style could flex under `verbosity=detailed` is broader than "generalize the mechanism" - flagged as a follow-up in Open Questions rather than folded in here, so this plan's diff stays reviewable.

## Files touched

- `bin/lib/wm-state.py` - replace `pilot-location-get`/`pilot-location-set` with `pref-get`, `pref-set`, `prefs-list`; replace `pilot_location_path()`/`pilot-location.json` with a generic `preferences_path()`/`preferences.json`.
- `hooks/pilot-preferences-guard.sh` (new, replaces the unshipped `pilot-location-guard.sh` from the prior draft) - the `PreToolUse` enforcement hook, including the `bin/crew-list`/`bin/watch-fleet`/wake-file exemptions and the `pref-set`-requires-`AskUserQuestion` check.
- `hooks/pilot-preferences-nudge.sh` (new, replaces the unshipped `pilot-location-nudge.sh`) - the `SessionStart` context-injection hook.
- `hooks/pilot-preferences-ask-tracker.sh` (new) - `PostToolUse` hook (matcher `AskUserQuestion`) writing `$WINGMAN_HOME/prefs-asked-<session_id>` so the guard above can require a real question before accepting `pref-set`.
- `hooks/lib/pilot-prefs.sh` (new) - the single shared required-key list + prompt text, sourced by both hooks above.
- `hooks/lib/cmd_match.py` (new) - a generic `resolve_command(tokens) -> (basename, args)` helper (segment splitting, `env`/`sudo`/`bash -c` unwrapping, and a correct `uv run` case that skips `uv`'s own leading flag tokens before the script), extracted from `no-direct-edit-guard.sh`'s embedded Python and shared by every guard in this plan.
- `hooks/no-direct-edit-guard.sh` (modified, not just a donor) - refactored to call the shared `cmd_match.py` helper for its own test-runner detection instead of keeping a private copy.
- `tests/no-direct-edit-guard.test.sh` (modified) - must keep passing unchanged against the refactor above; this is the regression check that the extraction didn't change its existing behavior.
- `bin/lib/install-user-hook.py` - add `--event` (default `PreToolUse`, preserving current behavior for the delegation guard); generalize `is_registered()` (and the write path) to check under `settings["hooks"][event]` rather than a hardcoded `"PreToolUse"` key, so re-running `bin/doctor` under a non-default event is idempotent, not just the default one.
- `bin/doctor` - register only section 6's pair (`artifact-publish-tracker.sh`, `artifact-link-guard.sh`), styled after the existing delegation-guard block; the onboarding trio does **not** go through `bin/doctor` (see the registration-channel decision in section 3).
- `.claude/settings.json` (this repo, project level) - add `PreToolUse`/`SessionStart`/`PostToolUse` entries for `pilot-preferences-guard.sh`/`pilot-preferences-nudge.sh`/`pilot-preferences-ask-tracker.sh`, alongside the existing `Stop` entry for `stop-guard.sh`.
- `bin/crew-resume` - export `WINGMAN_RUN_ID` and `WINGMAN_CREW_TYPE` in the generated resume launch script (finding 4/section 7).
- `tests/crew-resume.test.sh` - extend to assert both new exports.
- `CLAUDE.md` - rename and rewrite "Confirm the pilot's location" to "Confirm onboarding preferences," batch the three questions, add the "First run (onboarding)" mention, add the verbosity note near "Keep your voice to the pilot lean."
- `playbooks/_status-contract.md` - split condition B into its own `artifact_linking` preference check (with the explicit unset-case resolution from section 5); update the link-formatting section's subcommand reference from `pilot-location-get` to `pref-get --key remote`.
- `tests/preferences.test.sh` (new, replaces `tests/pilot-location.test.sh`) - `pref-get`/`pref-set`/`prefs-list`, including run-id scoping and multi-key merge.
- `tests/pilot-preferences-guard.test.sh` (new) - E2E hook test, styled after `tests/no-direct-edit-guard.test.sh`, covering the exemption list and the ask-tracker-gated `pref-set`.
- `tests/pilot-preferences-nudge.test.sh` (new) - E2E hook test for the `additionalContext` injection, asserting all missing prompts are named.
- `tests/pilot-preferences-ask-tracker.test.sh` (new) - the `AskUserQuestion`-completion marker write.
- `tests/install-user-hook.test.sh` - extend coverage for `--event`, including the idempotency case (re-registering under a non-default event is a no-op).
- `hooks/artifact-publish-tracker.sh` (new, section 6) - `PostToolUse` hook recording successful/failed `Artifact` publishes and `artifact-scan.sh` fail-verdicts to `$WINGMAN_HOME/artifact-markers/<session_id>.json`.
- `hooks/artifact-link-guard.sh` (new, section 6) - `PreToolUse` hook gating `crew-set --status review|done` (with or without an explicit `--artifact`) on that marker.
- `tests/artifact-publish-tracker.test.sh` (new, section 6).
- `tests/artifact-link-guard.test.sh` (new, section 6).
- No changes to `bin/wingman`, `bin/spawn-crew` - `WINGMAN_RUN_ID`/`WINGMAN_CREW_TYPE` stamping/export at spawn time is already correct and unaffected by generalizing what gets cached under it; the gap is confined to the separate `crew-resume` path (finding 4).

## Testing strategy

`tests/preferences.test.sh` (state layer): unanswered run has no keys; `pref-set` for one key then `pref-get` for that key round-trips; `prefs-list` after setting two keys returns both as `key<TAB>value`; a different run id sees nothing (no stale carry-over, mirroring the existing `pilot-location.test.sh` proof); overwriting a key's value works; the on-disk file shape matches the documented `{"wingman_run_id", "prefs": {...}}` structure.

`tests/pilot-preferences-guard.test.sh` (enforcement), using the existing `tests/lib.sh` harness style (`test_new_home`, direct JSON-on-stdin invocation):
- Zero of three required prefs set + `WINGMAN_RUN_ID` set + wingman-repo session + no `WINGMAN_CREW_ID`: `AskUserQuestion` allowed (no output); `prefs-list`/`pref-get` `Bash` invocations allowed in relative-path, absolute-path, and the **literal exported `$WINGMAN_STATE` form** (`uv run --no-project --quiet <abs-path>/wm-state.py ...`) - this is the regression test for finding 2, and must use the real flag-bearing string, not a simplified stand-in; every other tool (`Edit`, `Write`, `Read` of an unrelated path, `Task`, an unrelated `Bash` command, a chained `pref-set ... && rm -rf /tmp/x`) denied, with the denial reason naming all three still-missing prompts.
- `pref-set`, before any `AskUserQuestion` has completed this session (no `prefs-asked-<session_id>` marker): denied, per the self-answer-gap fix - this is the regression test for should-fix finding 5.
- `pref-set`, after an `AskUserQuestion` call and its tracker marker: allowed.
- `bin/crew-list`, arming `bin/watch-fleet`, arming `bin/crew-ask await --id <req>`, and a `Read` of `$WINGMAN_HOME/wake`: allowed even while prefs are unanswered - the regression test for the `stop-guard.sh` interaction (round-1 finding 6 and round-2 should-fix finding 3); a `bin/crew-say` call in the same state is still denied, proving the deliberate exclusion.
- Two of three set, one missing: denial reason names only the one missing prompt; the allowed-Bash exceptions still apply.
- All three set: every tool allowed, no output, regardless of which tool.
- `WINGMAN_RUN_ID` unset: no-op regardless of cache state.
- `WINGMAN_CREW_ID` set (worker or `lead`): no-op - this hook never activates for crew.
- Non-wingman `CLAUDE_PROJECT_DIR`: no-op.

`tests/pilot-preferences-ask-tracker.test.sh`: a completed `AskUserQuestion` call writes the marker; any other tool call does not.

`tests/pilot-preferences-nudge.test.sh`: missing prefs + active conditions emits `additionalContext` naming every still-missing prompt, for each `SessionStart` `source` value (`startup`, `resume`, `clear`, `compact`); fully-answered or inactive conditions produce no output.

`tests/install-user-hook.test.sh`: extend to register under a non-default `--event` and assert it lands under that key in `hooks`, independent of any existing `PreToolUse` entry; also assert re-registering the same hook under that same non-default event is a no-op (the idempotency check must key off `--event` too, not just the write path - minor finding 9).

`tests/no-direct-edit-guard.test.sh`: rerun unchanged after the `cmd_match.py` extraction to prove the refactor preserved existing behavior exactly; add one new case exercising a `uv run --no-project --quiet <path> pytest` form to confirm the fixed `uv`-flag-skipping logic still correctly identifies a wrapped test-runner invocation (this is the same fix as finding 2, exercised from the donor's own test suite too).

`tests/crew-resume.test.sh`: extend to assert the generated resume launch script contains `export WINGMAN_RUN_ID=...` (matching the resuming session's own current value) and `export WINGMAN_CREW_TYPE=...` (matching the crew record's stored `type`) - the regression test for finding 4.

Manual validation: a fresh `bin/wingman` sit-down with no cached answers confirms a single batched `AskUserQuestion` covering all three questions fires before any other tool call proceeds (or, if answered out of order via the nudge's guidance, the guard's denial reason correctly narrows to only what's left), answering all three resolves it for the rest of that run, and a crew member spawned afterward reads `artifact_linking`/`remote` from the cache without re-asking.

For section 6 (`tests/artifact-publish-tracker.test.sh`, `tests/artifact-link-guard.test.sh`): see the per-file breakdown at the end of section 6 above - covering marker writes on `Artifact` success and `artifact-scan.sh` fail-verdicts, the `crew-set` deny/allow transitions (including the staleness case where the file changes after publish), and the no-op cases (non-markdown artifact, `artifact_linking != artifact`, no `WINGMAN_CREW_ID`).
The manual validation for this section is the literal repro from this plan's own review cycle: a crew member reports `review` with a markdown `--artifact` while `artifact_linking=artifact` is cached, without having called `Artifact` first, and confirms the `crew-set` call is denied rather than silently succeeding.

## Open questions / risks

- **Unattended launches now hard-stall instead of soft-degrading.** Same risk as the original draft, sharpened by the broader gate: an unattended `bin/wingman` launch with no human to answer now has *three* required answers blocking every tool call indefinitely, not one. `CLAUDE.md` currently documents every launch as pilot-initiated, so this isn't a supported use case yet, but any future unattended/scheduled launch path needs an explicit escape hatch (e.g. pre-set env vars honored by both the ask step and the guard) before it can ship. Flag explicitly to whoever approves this plan.
- **`AskUserQuestion`'s per-call question limit.** The tool accepts up to four questions in one call; three fits comfortably now, but a future fourth or fifth preference either still fits (four) or needs two sequential `AskUserQuestion` calls in the same turn. Worth a one-line note in `CLAUDE.md` when a preference set grows past four, not a concern today.
- **The `AskUserQuestion`-before-`pref-set` check proves a question was asked, not that it was the right one.** `hooks/pilot-preferences-ask-tracker.sh` marks "some `AskUserQuestion` call completed this session," which closes the "invent answers with no question at all" gap (finding 5) but cannot verify the question's *content* matched the three required preferences - a session could technically ask something unrelated and then `pref-set` plausible values. Accepted explicitly here rather than left implicit: closing that remaining gap would require inspecting the question text itself, which reintroduces the same transcript-parsing fragility section 6 already argued against, for a much smaller remaining risk (a session going this far out of its way to satisfy the letter of the gate while ignoring its purpose is a much narrower failure mode than "forgot to ask at all," which is the failure this plan's repro evidence actually shows).
- **Verbosity propagation is intentionally partial in this plan** (see "Scope boundary" above) - a follow-up pass should audit where else in `CLAUDE.md` and the playbooks narration style could flex under `verbosity=detailed`, once the mechanism itself has shipped and the pilot has lived with the two options for a while.
- **Matcher/event-name syntax is CLI-version-dependent.** The empty-matcher-matches-all-tools behavior and the `SessionStart`/`PreToolUse` event names were confirmed against the currently-installed CLI build (`2.1.207`); reverify against the CLI's own hook documentation at implementation time in case matcher syntax changes in a future release.
- **Adjacent finding, not fixed here:** `~/.claude/settings.json` on the machine this investigation ran on does not currently have `hooks/no-direct-edit-guard.sh` registered, despite `CLAUDE.md` describing `bin/doctor` as registering it - registration is consent-gated, so this is a real instance of "a mechanism can be correct and still never get turned on if nobody runs the install step." Not a defect in this plan's hooks (which follow the identical, correctly consent-gated pattern), but worth the pilot re-running `bin/doctor` once these hooks ship, and worth a future look at whether `bin/doctor`'s one-time y/N prompt is loud enough.
- **Section 6's `Artifact`/`Bash` `tool_response` success signal is unverified.** The plan assumes a `PostToolUse` hook can distinguish a successful `Artifact` publish from a refused/failed one, and can read `artifact-scan.sh`'s stdout verdict line, from `tool_response` - both are very likely true (the hook input schema documents a `tool_response` field), but the exact field names/shapes were not empirically confirmed against a live `Artifact` tool call during this planning pass (no live publish was performed as part of writing this plan). Confirm both at the start of implementation.
  This is now a lower-stakes gap than in the original draft: since both success and failure get their own recorded, escapable marker (`published` vs. `publish-failed`), a misread of the signal at worst mislabels which of the two markers gets written - either way the crew member's next `crew-set` attempt is unblocked, and it is no longer possible for an unrecognized response shape to cause a silent, permanent deadlock. Still worth getting right so the *reason text* on a denial matches what actually happened.
- **Section 6 activates machine-wide, like the delegation guard.** `artifact-link-guard.sh` and `artifact-publish-tracker.sh` are registered at user level (they must fire for a crew member in any repo), so once installed they run for every `Bash`/`Artifact` call in every Claude Code session on the machine that happens to set `WINGMAN_CREW_ID` (crew) or has `$WINGMAN_HOME` resolvable (the tracker) - keep both hooks' own no-op paths cheap (a single narrow command-shape check before doing any real work), matching the performance discipline `no-direct-edit-guard.sh` already applies.
- **Marker file cleanup.** `$WINGMAN_HOME/artifact-markers/<session_id>.json` files are small and harmless left indefinitely, but `bin/crew-standdown`/`bin/crew-prune` could optionally delete a session's marker file when reaping it, purely as housekeeping - not required for correctness, left as a minor follow-up.
  `artifact-publish-tracker.sh` activates "whenever `$WM_HOME` resolves," which with `common.sh`'s `~/.wingman` default is *every* Claude Code session on the machine, not just crew ones - so a marker file also accumulates for a plain, non-crew session that happens to publish an Artifact, and the crew-standdown/crew-prune cleanup above only ever reaches crew sessions' markers. Harmless (still just a small orphaned file), but worth the same follow-up covering both cases rather than only the crew one.
