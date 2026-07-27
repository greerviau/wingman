# Rule inventory: CLAUDE.md before the slim

Working instrument for `2026-07-26-slim-claude-md.md`, step 1. Every normative statement in `CLAUDE.md` at `37b2967`, with its line range and its destination after the rewrite.

`Destination` is filled in during step 4 and audited in the testing step. Legend: **inline** = still stated in `CLAUDE.md`; **/watch** = `.claude/commands/watch.md`; **/prefs** = `.claude/commands/prefs.md`; a `docs/…` or `playbooks/…` path = moved reference material with a pointer from `CLAUDE.md`.

| # | Rule | Now | Destination |
| --- | --- | --- | --- |
| 1 | Activates only when the pilot starts `claude` from this repo; not a skill, not globally registered, no other agent can trigger it | 3-5 | inline |
| 2 | Job: take directives, delegate to crew, track status, surface real decisions; a conductor, not a worker | 7 | inline |
| 3 | Never do heavy work yourself — no large files, long investigations, or implementation code | 14-15 | inline |
| 4 | If about to open a big file or trace a bug, stop and spawn instead | 16 | inline |
| 5 | Consume distilled status via `bin/crew-list`; never attach to or scrape panes; never paste crew file contents | 17 | inline |
| 6 | State lives on disk; `crew.json` + `board.md` are the source of truth; re-read on demand | 18-20 | inline |
| 7 | Push detail down: crew output goes to a file, crew reports path + one line, you relay the pointer | 21-22 | inline |
| 8 | A directive that would violate these means "spawn a crew member", not "do it myself" | 24 | inline |
| 9 | On first launch or anything missing, run `bin/doctor`; do not proceed until green | 30, 34 | inline |
| 10 | What `bin/doctor` checks and which user-level hooks it registers | 31-33 | docs/guards.md |
| 11 | Run `bin/discover-projects` to build the project cache | 36 | inline |
| 12 | Point the pilot at the playbooks; `.local.md` overrides | 37 | inline |
| 13 | Arm `bin/watch-fleet` as a harness-tracked background task | 38-39 | inline |
| 14 | `~/.wingman/` is created automatically; source of truth on every startup | 42 | inline |
| 15 | Ask preferences first in a fresh run — before onboarding, before the directive | 47 | inline |
| 16 | Run `prefs-list`, diff against the five required keys | 49 | /prefs |
| 17 | Nothing missing → nothing to do | 50 | /prefs |
| 18 | If missing and run id set: say the lead-in phrase, one batched `AskUserQuestion`, cache each with `pref-set` | 51 | /prefs |
| 19 | `remote` question text and options | 52 | /prefs |
| 20 | `artifact_linking` question text and options | 53 | /prefs |
| 21 | `verbosity` question text and options | 54 | /prefs |
| 22 | `direct_spawn_visibility` question text and options | 55 | /prefs |
| 23 | `pr_comments` question text, options, and the auto-merge dependency | 56 | /prefs |
| 24 | Run id unset → skip silently | 57 | /prefs |
| 25 | An unattended launch needs no special handling | 59-60 | docs/guards.md |
| 26 | The guard denies every other tool call while any preference is unanswered | 62 | inline |
| 27 | `$WINGMAN_STATE` is the supported shape; run what the denial prints | 63-65 | inline |
| 28 | The guard fails open if it cannot name a way out, and records why | 66-67 | docs/guards.md |
| 29 | Only place these are asked; crew inherit the run id and read the cache | 69-70 | inline |
| 30 | Every directive: intake → scope → spawn → supervise → report → escalate | 74 | inline |
| 31 | Keep the voice lean: say what, not why; one-line announcement | 76-78 | inline |
| 32 | `verbosity=detailed` relaxes that default | 79 | inline |
| 33 | Intake: restate the directive in one line | 81 | inline |
| 34 | Resolve a referenced document's exact path; ask if ambiguous; never guess | 83-84 | inline |
| 35 | Never invent history; state only what is readable from `~/.wingman/`; never fabricate | 85-87 | inline |
| 36 | The lead test: a third role, or >1 developer/delivery, or spans repos | 88 | inline |
| 37 | If it passes, say so in the restatement and offer the choice; the pilot decides | 89-90 | inline |
| 38 | Re-run the lead test when the pilot expands an in-flight effort | 91 | inline |
| 39 | Scope: smallest crew that does the job; do not over-spawn | 92, 94 | inline |
| 40 | The built-in types; `--list-types` shows every category | 93 | inline |
| 41 | Act on the lead test's verdict rather than re-deciding | 95 | inline |
| 42 | Pick repo scope intelligently; default to global over interrogating the pilot | 96-98 | inline |
| 43 | Spawn via `bin/spawn-crew`; announce in one line, no reasoning | 99-100 | inline |
| 44 | Under `summary-only` an intermediate spawn is absorbed; a new-effort spawn is always announced | 101 | inline |
| 45 | Arm the watcher whenever crew are in flight; it is event-driven, so do not poll | 102 | inline |
| 46 | The watcher also catches prompt-freeze (`blocked`) and silent idle (`stalled`); remedy is takeover or stand-down | 103 | /watch |
| 47 | On a wake, or when the pilot asks, read `bin/crew-list` | 104 | inline |
| 48 | Report a compact status; never dump transcripts | 105-106 | inline |
| 49 | A member's status/artifact/verdict is a claim, not verified state; verify with `gh` or attribute explicitly | 107 | inline + docs/reporting.md |
| 50 | The same applies to your own volunteered claims; never offer an action premised on unverified state | 108 | inline + docs/reporting.md |
| 51 | Report altitude: results and actionables, never mechanics; no ids, session ids, window names, pids; describe by repo + objective; self-resolved hiccups are never narrated | 109 | inline + docs/reporting.md |
| 52 | Routine lifecycle bookkeeping is never a report; if a turn's only news is housekeeping, say nothing | 110 | inline + docs/reporting.md |
| 53 | Direct revise-loop visibility is gated by `direct_spawn_visibility`; default `each-round` | 112 | inline |
| 54 | It applies only to a loop wingman runs itself, without a lead | 113 | inline |
| 55 | `each-round`: report each substantive round as it lands | 114 | inline |
| 56 | `summary-only`: absorb routine intermediate narration only; it does not shrink what is surfaced; a wake caused solely by an absorbable round ends silently after re-arming | 115 | inline |
| 57 | Never absorbed: `blocked` and `stalled` | 118 | inline |
| 58 | Never absorbed: `died`, including a correlated batch | 119 | inline |
| 59 | A pilot-facing `review` is never suppressed and is announced with its pointer; it triggers the open-questions flow | 120-121 | inline |
| 60 | A loop-internal `review` is absorbable, but always still handled — absorbed never means ignored | 122 | inline + docs/reporting.md |
| 61 | `summary-only` never delays past the loop's conclusion or skips the pilot's sign-off gate | 124 | inline |
| 62 | A `done` reviewer's reap still happens in the same turn even when its verdict is absorbed | 125 | inline |
| 63 | Never send a message whose entire content is "no update this turn" | 127-129 | inline |
| 64 | Never restate something already reported; compare against your last report and cut it if nothing changed | 130 | inline |
| 65 | The preference does not touch how a lead's own workers are reported | 132 | docs/reporting.md |
| 66 | `direct_spawn_visibility` is orthogonal to `verbosity` | 134 | inline + docs/reporting.md |
| 67 | Escalate: surface the exact decision a `blocked` member needs; relay the answer with `crew-say` | 135-136 | inline |
| 68 | Only a genuine pilot-only decision is escalated; an owner-fixable problem is routed to the owner | 137 | inline |
| 69 | Then return control; do not keep talking or working | 139-140 | inline |
| 70 | If crew are in flight, arm exactly one watcher cycle before stopping | 141 | inline |
| 71 | The only reliable wake is the completion of a harness-tracked task | 145 | inline |
| 72 | `watch-fleet` blocks and exits on an attention state; one run is one cycle | 148 | docs/architecture.md |
| 73 | Arm it as a harness-tracked background task, on its own, never bundled onto another command | 150-151 | inline |
| 74 | On each wake run `/watch`; it classifies into six outcomes and handles each; re-arm on `spurious`, not on `spurious-repeated` or `stopped` | 152 | inline (pointer) + /watch |
| 75 | On `fire` the roster report is the Report step; under `summary-only` an absorbable round produces no report | 153 | /watch |
| 76 | Use the same command for the first arm of a fresh run | 154 | inline |
| 77 | While preferences are unanswered, use the raw `bin/watch-fleet` Bash forms instead of `/watch` | 155-156 | inline |
| 78 | An `outage-detected`/`outage-cleared` reason is an ordinary `fire`, not a new outcome | 157 | /watch |
| 79 | A `usage-limit-approaching`/`usage-limit-reset` reason is likewise an ordinary `fire` | 158 | /watch |
| 80 | Read the arm's status line as truth (`armed`/`healthy`/reason); do not churn extra arms while `healthy` | 159-160 | inline |
| 81 | `healthy` is run-scoped; a foreign orphan cycle is stopped automatically; no extra step needed | 161 | docs/architecture.md |
| 82 | The watcher checks pending events on arming, so nothing is lost in the gap | 162 | docs/architecture.md |
| 83 | Never run the watcher detached | 163 | inline |
| 84 | Never `kill` a watch-fleet process; only `--stop`, and that is manual/testing only | 164-166 | inline |
| 85 | `remote-control-dropped` is your own connection; tell the pilot to run `/remote-control`, then re-arm | 167-169 | /watch |
| 86 | A crew member's own dropped connection is auto-recovered and needs no pilot action | 170 | /watch |
| 87 | `/watch` is shared and self-scopes via `$WINGMAN_CREW_ID` | 172 | /watch |
| 88 | Every crew member is an independent session in its own tmux window; use the script, never hand-roll tmux | 176-177 | inline |
| 89 | The `bin/spawn-crew` command shape and flags | 179-183 | inline |
| 90 | What the script does; it prints the crew id, and that is all you remember | 185-186 | inline |
| 91 | The git/branch/PR workflow is conditional: a `software-development` role, or any confirmed git repo; otherwise plain files | 188-190 | inline |
| 92 | `spawn-crew` detects git-ness mechanically and exports `WINGMAN_IS_GIT`/`WINGMAN_HAS_REMOTE` | 191 | docs/configuration.md |
| 93 | Unset means "not yet known, detect it yourself" and must never be treated as `false` | 192 | inline |
| 94 | `--scope global` for cross-repo or unclear work; a single repo is the default | 194-196 | inline |
| 95 | Crew launch with `bypassPermissions` so a gated call auto-approves | 198 | docs/configuration.md |
| 96 | Two interactive gates remain; `spawn-crew` preflights both and refuses the spawn with the exact remedy | 199-201 | docs/guards.md |
| 97 | The watcher's dialog-freeze detection is the backstop; the first crew pauses until the pilot approves once | 202 | docs/guards.md |
| 98 | Crew are Remote-Control-visible by default; fails soft; the `wm-` prefix matches the window name | 204-206 | docs/configuration.md |
| 99 | `--model`/`--effort` are per-spawn and affect only that one session | 208 | inline |
| 100 | Omit both and the existing default chain stands | 209 | docs/configuration.md |
| 101 | A crew member never merges its own PR by default; a guard denies it | 212 | inline |
| 102 | Only pass `--allow-merge` when the pilot explicitly said so — never as a default, never because a PR looks done | 213 | inline |
| 103 | It is per-spawn and visible; grant it after spawn with `crew-set`, not a respawn | 214 | inline |
| 104 | A merge from a crew session is attributed automatically; never rely on the member to do it | 215 | docs/guards.md |
| 105 | Compose crew-facing text in neutral language — "the human", never "pilot" | 217 | inline |
| 106 | A crew type is just a playbook; the categories and built-ins | 221-222 | inline |
| 107 | Discover what exists with `--list-types` | 223 | inline |
| 108 | When a directive fits a custom type better, spawn that type | 224 | inline |
| 109 | The handoff and depth cap are conventions of specific built-ins; a custom type is standalone | 225 | docs/playbooks.md |
| 110 | Never edit playbooks yourself; the pilot owns them | 226 | inline |
| 111 | "Implement feature X": lead test → analyst → relay on pilot-facing review → developer with `--input` on approval → stand down the analyst; feedback routes to the same analyst | 230-233 | inline |
| 112 | "Investigate issue Y": lead test → analyst in report mode; a bug is reproduced E2E first; relay the path | 234-236 | inline |
| 113 | "Take the lead"/"ship it all the way" appoints a lead | 237 | inline |
| 114 | A named model/effort is passed through verbatim on that one spawn; a lead's phase preference is relayed in the objective, not applied by you | 238-241 | inline |
| 115 | Merge autonomy is granted by the pilot alone, per effort, never inferred | 242-245 | inline |
| 116 | "Status": `crew-list` summarized compactly with each status; describe by repo + objective; `--tree`/`--owner`; current only; history only on request | 246-250 | inline |
| 117 | "What's blocked?": `crew-list --status blocked`; surface the blocker and the decision | 251 | inline |
| 118 | Crew `stalled`: always post-nudge; relay once with the remedy and leave it running; do not nudge again; distinct from `died`; lead with plain language; the invalid-`--model` cause | 252-258 | /watch |
| 119 | Mass death / correlated outage: the four sub-cases and their distinct responses | 259-262 | /watch |
| 120 | `usage-limit-approaching`: the full procedure, including that "wait" holds only new spawns | 263-269 | /watch |
| 121 | `usage-limit-reset`: relay only if the prior decision was "wait" or unanswered | 270-271 | /watch |
| 122 | "Take over X": `crew-takeover`, relay the command; you cannot hand over your own terminal; you cannot resume a live member | 272-275 | inline |
| 123 | Deliverable ready: announce once with the pointer and leave it running; pilot-facing only; run the open-questions flow first; `review` is not a cue to reap; announce as the member's own report | 276-281 | inline |
| 124 | Feedback on in-flight work routes to the owning member; never spawn a new member to revise | 282-283 | inline |
| 125 | `/say` and its guardrails; relay a refusal verbatim rather than retrying with `--force` | 284-285 | inline |
| 126 | `/ask` for a specific answer back; the flow; a captured answer is not a roster event; it consumes a turn | 286-291 | inline |
| 127 | Crew `done`: relay and reap in the same turn; the reap happens even when the relay is absorbed | 292-294 | inline |
| 128 | "Stand down X": `crew-standdown`; cascades for a lead | 295 | inline |
| 129 | "Prune": `crew-prune` archives first; reserve it for clutter or an explicit ask | 296-297 | inline |
| 130 | Your job with a status is to recognize it and surface what matters; the playbook owns lifetime | 301-302 | inline |
| 131 | Spin a member down in exactly two cases: it reports `done`, or the pilot says so | 305-310 | inline |
| 132 | Every other status: leave it running; never reap because it delivered, opened a PR, or went quiet | 312-313 | inline |
| 133 | Surface `blocked`/`review`/`stalled`, then leave the member be | 315 | inline |
| 134 | The `stalled` remedy is always the post-nudge response, never a first one | 316 | inline |
| 135 | A member that self-heals produces no fire and needs no mention | 317 | inline |
| 136 | Pilot feedback goes to the owning member, matched by repo + artifact; one session carries work start to `done` | 320-321 | inline |
| 137 | The handoff contract: analyst writes the plan to a file and reports it as `artifact` with `--status review`; the developer is spawned with `--input` | 325 | inline |
| 138 | You move the pointer, never the plan's contents | 326 | inline |
| 139 | Relay the plan for review; iterate in the same analyst session via `crew-say` | 327 | inline |
| 140 | On approval, spawn the developer and stand down the analyst | 328 | inline |
| 141 | The `wingman-questions` block schema | 332 | playbooks/_status-contract.md |
| 142 | It plugs into the existing deliverable-ready moment; not a new state; a loop-internal `review` is not this moment | 333 | inline |
| 143 | On a pilot-facing `review` with a markdown artifact, run the parser before announcing anything | 335-339 | inline |
| 144 | `found: false` → announce the pointer and wait, unchanged | 341 | inline |
| 145 | Malformed block → same fallback, plus relay the section as prose; never block the handoff, never drop the questions | 342 | inline |
| 146 | `choice` → `AskUserQuestion` mapping rules; batch ≤4; `free_text: false` is informational only | 344 | inline |
| 147 | `open` → relay as plain prose in the same turn | 345 | inline |
| 148 | Announce the plan pointer in the same turn regardless of type | 346 | inline |
| 149 | Relay answers back as one compact `crew-say` mapping `id -> answer`; label without the suffix; free text verbatim with the constraint noted; `open` verbatim | 348-350 | inline |
| 150 | That relay is itself a never-suppressed pilot-facing handoff | 351 | inline |
| 151 | Re-run the flow against a revised artifact on a new round | 353 | inline |
| 152 | The local path is always what you report first | 357 | inline |
| 153 | `artifact_url` is read from `crew-list`/`board.md`, never parsed from a chat reply | 358-359 | inline |
| 154 | When present, relay both; the URL supplements the pointer and is never stripped | 360 | inline |
| 155 | The `remote` preference governs link phrasing; check with `pref-get`; unanswered defaults to local | 362 | docs/reporting.md |
| 156 | `remote=true` → markdown links with short descriptive text | 363 | inline |
| 157 | Local, unanswered, or unaskable → plain URLs | 364 | docs/reporting.md |
| 158 | Presentation-only; reuses the one cached answer | 365 | docs/reporting.md |
| 159 | What a lead is and what it does | 369 | inline |
| 160 | Suggest one at intake; appoint on confirmation | 371 | inline |
| 161 | "Take the lead on X" appoints one directly, with no suggestion step | 372 | inline |
| 162 | Spawn it with the full objective; it builds its own team; you do not spawn its workers | 373 | inline |
| 163 | Surface its rollup, not its crew; relay the pilot's answer down via `crew-say` | 374 | inline |
| 164 | Offer drill-down on demand (`--owner`, `--tree`, `board.md`) | 375 | inline |
| 165 | Depth cap: 2 crew layers; a lead spawns workers, not further leads | 377 | inline |
| 166 | Spawning is the expensive act | 381 | inline |
| 167 | Spawn the smallest crew that does the job | 383 | inline |
| 168 | Sequential by default; parallel only when the work is genuinely independent | 384 | inline |
| 169 | Announce intended crew size before spawning more than ~2 at once | 385 | inline |
| 170 | Reserve large fan-outs and `Workflow` for an explicit request | 386 | inline |
| 171 | An idle fleet costs no context; every spawn does | 387 | inline |
| 172 | The tmux server owns the windows, so killing you does not kill the crew | 391 | docs/architecture.md |
| 173 | On any startup: read `crew.json`, reconcile, re-arm if crew are in flight, report the roster | 392 | inline |
| 174 | A `died` member is recoverable; `crew-takeover` prints the exact command | 393 | inline |
| 175 | A `died` member's Remote Control entry is stale; `crew-list` is always the source of truth | 395 | docs/architecture.md |
| 176 | The crew coordination layer does not depend on any one harness | 399-400 | docs/architecture.md |
| 177 | The launch recipe is the single place to change for a different harness | 400 | docs/architecture.md |
| 178 | Never reach for a harness's native background/attach/resume for crew; tmux attach is the neutral path | 401 | inline |
| 179 | The wake mechanism is the one legitimately harness-specific piece | 403-405 | docs/architecture.md |
| 180 | Never read large files or run long investigations in your own session | 409 | inline |
| 181 | Never attach to or scrape a pane for status | 410 | inline |
| 182 | Never activate outside this repo, and never expose yourself to other agents | 411 | inline |
| 183 | Never hardcode a skill or CLI into crew behavior; that lives in the playbooks | 412 | inline |

## Audit result

Filled in during the testing step.

- **Total rules:** 183
- **Inline:** to be counted
- **Mechanically loaded (`/watch`, `/prefs`):** to be counted
- **Behind a pointer:** must match the two-row exposure table in the plan's "Risks"
