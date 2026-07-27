# Slim CLAUDE.md to the always-needed behavioral contract

## Problem

`CLAUDE.md` is 66,164 bytes / 412 lines (~17k tokens), loaded in full at the start of every wingman session and never unloaded. It is the single largest fixed cost on the context of a session whose entire prime directive is protecting its own context.

The size is not earned. Three things are inflating it:

1. **Rare-incident runbooks held in always-on context.** The API-outage, usage-limit, mass-death, and `stalled` procedures are ~6KB of step-by-step response to events that fire rarely, yet they are resident for every session that never sees one.
2. **Duplication of reference material that already exists elsewhere, better.** `docs/architecture.md` already documents the wake loop, the deliverable lifecycle, survival/reconciliation, and harness-agnosticism. `docs/fleet-resilience.md` already documents outage and usage-limit detection in more depth than CLAUDE.md does. `docs/configuration.md` already documents the spawn recipe. `docs/guards.md` already documents every hook. CLAUDE.md restates their *mechanism* prose without adding instruction.
3. **Rationale, provenance, and internal duplication.** Issue numbers (#17, #23, #24, #46, #64, #75, #96, #109), `docs/analysis/*` citations, "this is measured behavior, not assumption", "verified empirically" — none of it changes what wingman does. Separately, the same rule is restated up to five times: the pilot-facing vs loop-internal `review` distinction (5x), reap-on-`done`-in-the-same-turn (3x), the `summary-only` carve-outs (2x at length).

The preference block is a fourth, sharper case: the five preference questions exist as authoritative data in `hooks/lib/pilot-prefs.sh` (`WM_PREF_KEYS` + prompt text), and are *also* transcribed into `.claude/commands/prefs.md` and *again* into CLAUDE.md. The `/prefs` copy has already drifted — it lists four keys and is missing `pr_comments`, so a session driven by `/prefs` alone never asks the fifth question and stays blocked by `hooks/pilot-preferences-guard.sh`. This is a live defect the duplication caused.

## Requirements

**Outcome.** `CLAUDE.md` lands at ~18.5KB (a ~72% reduction) with wingman's observable behavior unchanged: every normative rule in force today is still in force, and no rule reachable on a routine turn depends on wingman choosing to open another file.

**Success criteria.**
- `wc -c CLAUDE.md` ≤ 19,000.
- The rule inventory (step 1 below) shows 1:1 coverage: every rule enumerated from today's file maps to a location in the new arrangement.
- `tests/run.sh` passes (it did not cover CLAUDE.md prose before and does not after; this only proves nothing incidental broke).
- `/prefs` asks all five preference keys.

**Scope boundaries — explicitly out.**
- No changes to `bin/`, `hooks/`, `tests/`, or any `.py`/`.sh` file. This change is markdown-only.
- No extraction of preference question text into a new data file. The authoritative copy already exists in `hooks/lib/pilot-prefs.sh`; consolidating the three copies onto it is a follow-up, not this change.
- No rewrite of `playbooks/`. `_status-contract.md` (34KB) and `_delivery.md` (12KB) have the same disease and are appended to every crew brief, but they are a separate, larger effort.
- No new behavior, no new rules, no "while we're here" tightening. A rule that is wrong today stays wrong today and gets its own issue.

**Constraints.**
- **Behavior-preserving is the hard constraint.** Where condensing a rule risks changing it, keep the longer wording.
- Rules that fire under pressure (an incident, a blocked pilot decision) must be *mechanically* loaded at that moment, not left to wingman choosing to follow a pointer.
- Honor the existing docs split (`architecture` / `configuration` / `guards` / `fleet-resilience` / `playbooks`); do not invent a parallel structure.

## Scope

Single repo: `wingman`. Files touched:

| File | Change |
| --- | --- |
| `CLAUDE.md` | Rewritten; 66KB → ~17KB |
| `.claude/commands/watch.md` | Gains the per-fire-reason routing list (+1.2KB) |
| `docs/runbooks/incidents.md` | **New.** The per-fire-reason response procedures |
| `.claude/commands/prefs.md` | Gains the missing `pr_comments` question |
| `docs/reporting.md` | **New.** The reporting contract's full rules and rationale |
| `docs/architecture.md` | Absorbs the handful of mechanism paragraphs CLAUDE.md holds that it does not |
| `docs/guards.md` | Absorbs the preferences-guard fail-open behavior and the spawn preflight gates |
| `docs/configuration.md` | Absorbs the `WINGMAN_IS_GIT`/`WINGMAN_HAS_REMOTE`/`--allow-merge`/`--model` detail |
| `docs/UBIQUITOUS-LANGUAGE.md` | **New.** The load-bearing terms this arrangement depends on |
| `README.md` | Add `reporting.md` to the docs index |

No cross-repo coordination.

## Approach

**The organizing principle: CLAUDE.md states what wingman *does*; `docs/` explains how the system *works*; a slash command carries what wingman does *at one specific moment*.**

Applied strictly, that principle does most of the cutting on its own. Every sentence in today's file gets classified:

- **An imperative that applies on a routine turn** → stays inline, condensed to the rule itself.
- **An imperative that applies only at a specific triggered moment** → moves into the thing already loaded at that moment (`/watch` for a fire, `/prefs` for onboarding).
- **A description of how a mechanism works** → moves to `docs/`, or is deleted if `docs/` already says it.
- **A justification for why a rule exists** → deleted. Provenance lives in git and in `docs/plans/`.

### The move criterion

A pointer is only as good as the certainty that it gets followed, and the failure shape is bad: wingman sees a pointer, believes it already knows the rule, and never opens the file. Nothing errors — the rule just quietly stops applying. So relocation is gated on a deliberately narrow test.

**An imperative may leave `CLAUDE.md` only if one of these holds:**

1. **It loads mechanically at its moment** — it lives in a slash command wingman is already required to run at exactly that point (`/watch` on every wake, `/prefs` at onboarding). No judgment is involved; the content simply arrives.
2. **Its moment of need is rare and self-announcing** — an event that cannot be mistaken for a routine turn, where the pointer is right in front of wingman when it fires.

**Anything reachable on a routine turn stays inline, regardless of length.** Two rules that an earlier draft of this plan moved fail this test and are explicitly kept inline:

- **The structured open-questions flow.** It fires on most analyst hand-offs — routine, not rare. The parser invocation and the `found: false` / malformed / `choice`-vs-`open` branches stay inline; only the block's *schema* stays where it already is in `playbooks/_status-contract.md`, since wingman never authors one.
- **The `WINGMAN_IS_GIT` / `WINGMAN_HAS_REMOTE` "unset means detect it yourself, never treat as false" rule.** It applies at spawn time, and getting it wrong is silent. Stays inline; only the variables' mechanical derivation moves to `docs/configuration.md`.

Reference material — case analysis, mechanism description, rationale — is not an imperative and moves freely.

**Why the incident runbooks route through `/watch`.** CLAUDE.md already mandates running `/watch` on every wake, and every incident this plan moves is reachable *only* through a watcher fire — so `/watch` is where the routing belongs.

The procedures themselves live in `docs/runbooks/incidents.md` rather than inline in `/watch`. Inlining them was the original design and was measured during implementation: it took `/watch` from 6,433 to 12,715 bytes, and **`/watch` reloads on every wake**, so +6.3KB × ~15 wakes in a busy session comfortably exceeds the ~48KB saved once from CLAUDE.md. That inverts the whole point of the change. Routing instead — `/watch` carries a one-line list of the eight reason strings that have a specific procedure, plus the file to read — costs 1,171 bytes per wake and loads the 5.7KB of procedure only on the wakes that actually need it.

This still satisfies the move criterion's second clause: the moment is rare, and `/watch` names the exact reason strings, so it is unmissable rather than merely pointed at.

`/watch` is shared with leads (it self-scopes via `$WINGMAN_CREW_ID`), so each moved runbook must be marked wingman-only where it is. This is factually safe: outage and usage-limit state are tracked for owner `""` only, so a lead can never see those reasons — the same restriction `remote-control-dropped` already documents in that file.

**Why a new `docs/reporting.md`.** The reporting contract (report altitude, self-report-is-a-claim, `direct_spawn_visibility`, remote link formatting) is ~9KB spread across three CLAUDE.md sections and has no home in `docs/` today. Its *rules* are routine and stay inline; its extensive case analysis — which `review` states are absorbable, why housekeeping is never a report, how `verbosity` and `direct_spawn_visibility` interact — is reference material. Splitting it needs a destination, and none of the four existing docs fits.

**Why not touch the preference question text.** Three copies exist and one has drifted. The correct fix is one authoritative copy in `hooks/lib/pilot-prefs.sh` that `/prefs` renders, but that is a code change with test impact, outside this change's markdown-only boundary. Here, CLAUDE.md's copy is deleted (replaced by a pointer to `/prefs`) and `/prefs` is corrected to five keys — which reduces three copies to two and fixes the live defect. Collapsing the last two is a follow-up.

## Steps

### 1. Build the rule inventory (before any edit)

Read the current `CLAUDE.md` and enumerate every normative statement — anything that constrains what wingman does — as a numbered list, written to `docs/plans/2026-07-26-slim-claude-md-rules.md`. Expected scale: 90–130 rules. Each entry records the rule in one line plus its current line range. This file is the verification instrument and the working checklist for every step that follows; it is not a deliverable and is deleted once the change lands.

Do not begin editing until it is complete. A cut this aggressive without it is unreviewable.

### 2. Move the incident runbooks into `.claude/commands/watch.md`

Under the existing `fire` bullet in step 1 of `watch.md`, add a nested "if the fire reason is one of these" block carrying the procedures now at `CLAUDE.md:252-271`:

- `stalled` — always post-nudge; relay once with `bin/crew-takeover <id>` / `bin/crew-standdown <id>` and leave running; lead with plain language, not the id; the invalid-`--model` cause.
- `correlated:mass-death` (no outage tag) — relay, confirm with the pilot before `bin/crew-resume --all-died`.
- `correlated:api-outage` / `correlated:api-outage-death` / `outage-detected` — relay; do not resume; wait for `outage-cleared`.
- `outage-cleared` — the one pre-authorized auto-recovery: run `bin/crew-resume --all-died` immediately if it names died members, then relay.
- `usage-limit-approaching` — relay with concrete numbers; `AskUserQuestion` wait-vs-continue, stating plainly that "wait" holds only *new* spawns; record with `$WINGMAN_STATE usage-decide`.
- `usage-limit-reset` — relay only if the prior decision was "wait" or unanswered.

Mark the outage and usage-limit entries "wingman's own top-level session only — a lead never sees these reasons." Keep each procedure's wording verbatim from CLAUDE.md rather than paraphrasing; this step is a move, not a rewrite.

In `CLAUDE.md`, these six bullets collapse to one line under Command vocabulary: a fire reason naming an outage, a usage-limit window, a mass death, or a `stalled` member is handled by `/watch`, which carries the procedure.

### 3. Write `docs/reporting.md`

New file, following the existing docs' front-matter convention (one-line purpose, a link back to `architecture.md`). Sections:

- **Report altitude** — results and actionables, never mechanics; the ids/pids/window-names prohibition; housekeeping is never a report. From `CLAUDE.md:109-110`.
- **Self-report is a claim, not verified state** — including wingman's own volunteered claims. From `CLAUDE.md:107-108`. Cross-link `playbooks/_status-contract.md`'s "Self-report is a claim" so the two sides of the same rule reference each other.
- **`direct_spawn_visibility`** — the full case analysis from `CLAUDE.md:112-134`, including the pilot-facing vs loop-internal `review` distinction, the never-absorbed list, and the orthogonality to `verbosity`.
- **Never repeat and never send an empty update** — from `CLAUDE.md:127-130`.
- **Formatting links for a remote pilot** — from `CLAUDE.md:356-365`.

Add it to `README.md`'s docs index.

### 4. Rewrite `CLAUDE.md`

Work section by section against the inventory. Target budget:

| Section | Now | Target | Where the removed content goes |
| --- | --- | --- | --- |
| Preamble | 578 | 578 | — |
| The prime directive | 1,156 | 900 | condense |
| First run (onboarding) | 2,338 | 500 | hook-registration detail → `docs/guards.md` |
| Confirm onboarding preferences | 5,640 | 400 | pointer to `/prefs`; fail-open behavior → `docs/guards.md` |
| The operating loop | 14,011 | 3,500 | Report's case analysis → `docs/reporting.md` |
| The wake loop | 6,394 | 900 | pointer to `/watch` + `docs/architecture.md#the-wake-loop` |
| Spawning crew (the recipe) | 5,795 | 1,800 | preflight gates → `docs/guards.md`; flag mechanics → `docs/configuration.md`. The `WINGMAN_IS_GIT`/`WINGMAN_HAS_REMOTE` unset rule stays inline |
| Crew types are open-ended | 1,240 | 500 | `docs/playbooks.md` (already covers it) |
| Command vocabulary | 15,144 | 4,000 | incidents → `/watch` (step 2); dedupe against Member lifecycle |
| Member lifecycle | 2,669 | 800 | dedupe against Command vocabulary |
| analyst → developer handoff | 593 | 400 | condense |
| Structured open questions | 3,329 | 1,200 | rationale and the block schema → `playbooks/_status-contract.md`; the parser call and all three branches stay inline |
| Remote-aware reporting | 1,966 | 500 | `docs/reporting.md` |
| Appointing a lead | 1,825 | 800 | `docs/architecture.md#the-crew-hierarchy-leads` |
| Cost discipline | 618 | 618 | — |
| Survival & reconciliation | 1,187 | 300 | `docs/architecture.md#survival--reconciliation` (already covers it) |
| Harness-agnostic by design | 1,261 | 200 | `docs/architecture.md#harness-agnostic-by-design` (already covers it) |
| What you never do | 421 | 421 | — |
| **Total** | **66,164** | **~18,600** | |

Three rules govern every edit:

- **State each rule exactly once.** The pilot-facing `review` distinction gets one canonical sentence under Report; the four other sites say "a pilot-facing `review` (see Report)". Same for reap-on-`done`.
- **Delete every issue number, `docs/analysis/` citation, and "this is measured, not assumed" clause.** If a fact matters to a future reader, it belongs in the `docs/` page for that mechanism.
- **Every pointer names the exact section it points to,** so a reader lands on the rule, not the file.

### 5. Absorb the mechanism paragraphs `docs/` does not already have

Most of what CLAUDE.md describes, `docs/` already says. Diff before appending — a paragraph already covered is deleted, not moved. The known gaps:

- `docs/guards.md` — the preferences guard's fail-open behavior and the `prefs-guard-failopen-<session_id>` marker (`CLAUDE.md:66-67`); the two non-bypassable interactive gates and `spawn-crew`'s preflight (`CLAUDE.md:198-202`).
- `docs/configuration.md` — the `WINGMAN_IS_GIT`/`WINGMAN_HAS_REMOTE` "unset means detect it yourself" rule (`CLAUDE.md:191-192`); `--allow-merge` grant-after-spawn via `crew-set` (`CLAUDE.md:214`).
- `docs/architecture.md` — the `died`-member stale Remote Control entry (`CLAUDE.md:395`), if `docs/architecture.md#remote-control` does not already carry it.

### 6. Fix `/prefs` and add the glossary

Add the `pr_comments` question to `.claude/commands/prefs.md` (question text from `hooks/lib/pilot-prefs.sh`, options `off` default / `on`), update its `description` front-matter to name five keys, and update step 2's key list. Write `docs/UBIQUITOUS-LANGUAGE.md` with the terms this arrangement makes load-bearing (see below).

## Testing & verification

**Primary: the rule-inventory diff.** Walk the step-1 inventory entry by entry and annotate each with where the rule now lives — an inline `CLAUDE.md` line, a `/watch` branch, a `docs/` section, or a `playbooks/` section. The change is done when every entry has a location. Any entry that cannot be placed is a rule that was silently dropped: restore it. Any entry placed in a `docs/` file with no pointer from CLAUDE.md is a rule wingman will never read: add the pointer or bring the rule back inline.

The inventory is walked twice — once by the implementer, once fresh against the rewritten file, since it is easy to mark an entry covered by the text you just wrote.

**Secondary checks:**
- `wc -c CLAUDE.md` ≤ 18,000.
- `tests/run.sh` green. No test asserts on CLAUDE.md prose (`tests/spawn-wm-repo-note.test.sh` and `tests/pilot-preferences-guard.test.sh` only mention it in comments and in a marker string that is not affected), so this proves only that nothing incidental broke — it is not evidence the behavior contract survived. The rule inventory is the real evidence.
- Every markdown link resolves, and every "see X" names a heading that exists.
- **The move-criterion audit.** Every pointer out of `CLAUDE.md` to a *rule* (not to reference material) is listed with the criterion that licenses it — mechanically loaded, or rare and self-announcing. A pointer that satisfies neither means the rule comes back inline. The expected result is the two-row table in "Risks" and nothing else; a longer list means the criterion drifted during the rewrite.
- `grep -nE '#[0-9]+|docs/analysis/' CLAUDE.md` returns nothing.
- `/prefs` lists all five keys and matches `WM_PREF_KEYS` in `hooks/lib/pilot-prefs.sh`.

**Live smoke run** was considered and deliberately not required: it can only exercise the common path (spawn → review → stand down), which is the part of the file changing least, and cannot reach the rare-incident paths that are the bulk of what moves.

## Risks and open questions

- **The real risk is a silently dropped rule, not a broken script.** Nothing mechanical fails if a rule vanishes; wingman just quietly stops honoring it, possibly weeks later. The rule inventory exists solely for this, and the double-walk is not optional.
- **Pointer-following is a behavior assumption, and the size target is the softer constraint.** A rule moved to `docs/` is only in force if wingman opens the file. The move criterion above exists to bound this, and after applying it the residual exposure is small and enumerable — these are the only paths where an imperative sits behind a pointer:

  | Path | Frequency | Consequence if the pointer is not followed |
  | --- | --- | --- |
  | An ambiguous `summary-only` judgment call → `docs/reporting.md` | occasional | Over- or under-reports one round. Self-correcting; the pilot sees it. |
  | A `died` member's stale Remote Control entry → `docs/architecture.md` | rare | Wingman trusts Remote Control's display over `crew-list`. Visible and correctable. |

  Everything else either stays inline or arrives mechanically via `/watch` or `/prefs`. If any specific rule turns out to sit awkwardly on the line, it stays inline and the file lands above 19KB — behavior preservation outranks the byte target every time.
- **`/watch` reloads on every wake, so growth there is multiplied.** Resolved during implementation by routing rather than inlining (see Approach): `/watch` grows 1,171 bytes and `docs/runbooks/incidents.md` carries the 5.7KB of procedure, read only on the wakes that need it. Re-check this ratio if the runbook ever moves back inline.
- **`playbooks/_status-contract.md` is 34KB and appended to every crew brief** — a larger version of this same problem, and out of scope here. It should get its own spec.
- **Open:** should `CLAUDE.md` eventually become a skill so it loads on demand rather than at session start? That would change wingman's activation model (today: "you are running because the pilot started `claude` from the wingman repo"), so it is a design question well beyond this cut. Noted, not proposed.

## Follow-ups

1. Consolidate the preference questions onto `hooks/lib/pilot-prefs.sh` as the single source, with `/prefs` rendering from it — removes the last duplicate and the drift class that produced the `pr_comments` defect.
2. Spec the same treatment for `playbooks/_status-contract.md` (34KB, loaded per crew member).
3. File an issue for the `pr_comments` drift so the fix in step 6 is traceable.
