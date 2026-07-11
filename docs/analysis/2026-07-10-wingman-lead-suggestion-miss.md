# Analysis: why wingman failed to suggest a lead for a directive that met the lead heuristic

**Date:** 2026-07-10
**Repo examined:** `wingman` (orchestrator instructions, playbooks, commands, `bin/` scripts)
**Mode:** investigation report; no developer handoff.

## Summary

Wingman never suggested a lead because the lead heuristic is encoded only as prose, buried mid-paragraph in one sub-bullet of the Scope step, with no checkpoint that forces it to be evaluated at intake.
Three structural problems make the miss likely rather than unlucky: the command vocabulary routes common directives straight to a crew type without ever touching the heuristic; the heuristic's literal threshold is contradicted by the documented analyst→developer default path, so it cannot be applied as written; and the surrounding cost-discipline language repeatedly pushes against spawning a lead while nothing distinguishes the free act of *suggesting* one from the expensive act of *spawning* one.
The recommended fix is to encode an explicit, named "lead test" as a mandatory intake step with a crisp threshold, a visible one-line verdict to the user, cross-references from the command vocabulary, and a re-evaluation rule for scope that grows mid-flight.

## The incident, as observable from wingman state

The roster in `~/.wingman/crew.json` records the sequence for the "slow platform REST API endpoints" effort:

1. `review-the-analysis-at-users-gvi-developer` (type `developer`, top-level): objective "Review the analysis at .../2026-07-09-rest-api-slow-platform-endpoints..." - the user's "review an analysis and fix it" directive was routed to a single developer.
2. `create-an-implementation-plan-fr-analyst` (type `analyst`, top-level, now stood down): an implementation plan from the same analysis - the user's follow-up asking for an analyst plan handed to a developer plus review.
3. `own-end-to-end-fix-the-slow-plat-lead` (type `lead`, top-level): appears only after the two direct spawns, consistent with the user having to demand the lead explicitly; it is now running its own sub-crew (`verify-the-root-cause-findings-i-analyst` has `parent` set to the lead).

So by the time the lead existed, wingman had already committed two top-level members to one effort spanning multiple roles in sequence and multiple deliverables - exactly the shape the heuristic names - without a suggestion.
The transcript itself is not inspectable, but the state on disk is sufficient to confirm the reported behavior: multiple roles were spawned directly for one effort and the lead came last, not first.

A note on reproduction: this is a behavioral miss by an LLM orchestrator following prose instructions, not a code defect, so a deterministic reproduction is not possible.
The analysis therefore grounds on two things: the recorded state above (what actually happened) and the exact instruction text (what the orchestrator had to work with).

## Where the heuristic lives today

An inventory of every place the lead-suggestion behavior is encoded:

| Location | What it says | Enforcement |
|---|---|---|
| `CLAUDE.md` operating loop, Scope step (line ~60) | "If it needs more than one role in sequence *and* more than one deliverable, or spans multiple repos ... suggest appointing a `lead`" - followed immediately by "don't reach for it by default." | Prose only; one sub-bullet among several |
| `CLAUDE.md` command vocabulary (line ~134) | Lead entry is keyed on the trigger phrases "Take the lead on X" / "ship it all the way" / "a large end-to-end effort" | Phrase matching; fires only if the user uses lead-ish words |
| `CLAUDE.md` "Appointing a lead" (line ~187) | Restates the same criterion, tagged "(Heuristic tunable here.)" | Prose, in a section read when already appointing |
| `.claude/commands/lead.md` (`/lead`) | Spawns a lead on request | User-invoked only; no role in wingman's own decision |
| `playbook/lead.md` | Instructions for the lead itself | Irrelevant to the suggestion decision |
| `bin/spawn-crew`, `bin/wingman`, other scripts | No scope-assessment or lead-suggestion logic of any kind | None |

There is no checklist, no gate, no script, and no state that ever forces the question "does this directive pass the lead test?" to be asked and answered.
The entire mechanism is one conditional sentence the orchestrator must spontaneously recall at the right moment.

## Root causes: why the heuristic is easy to miss

### 1. The command vocabulary short-circuits the Scope step

The operating loop is intake → scope → spawn, and the heuristic lives in Scope.
But `CLAUDE.md` also provides a "Command vocabulary" that maps directive shapes directly to actions: "Implement feature X" → spawn an analyst; feedback → `crew-say`; and so on.
These entries are lookup rules, and none of them (except the lead's own trigger-phrase entry) references the lead test.
A directive like "review this analysis and fix it" pattern-matches a vocabulary entry ("fix" → developer path) and proceeds straight to spawn; the Scope-step heuristic in a different section never enters the decision.
The vocabulary is the fast path, and the heuristic is not on it.

### 2. The heuristic's literal threshold is contradicted by the documented default

The heuristic says a lead is warranted at "more than one role in sequence *and* more than one deliverable."
But the analyst→developer handoff - two roles in sequence, two deliverables (a plan, then a PR) - is documented as the *lean, non-lead default* with its own dedicated section, and the "Implement feature X" vocabulary entry prescribes it without a lead.
Taken literally, the heuristic classifies wingman's most common workflow as lead-worthy, which is plainly not intended.
An orchestrator that notices this contradiction has to discount the heuristic and substitute judgment about "big enough to warrant a manager" - and once the crisp rule is replaced by vibes, a directive that is "the normal handoff plus a reviewer" reads as an incremental extension of the default path rather than a category change.
The user's directive (analyst plan → developer → review) sits exactly in that blind spot: past the written threshold, but only one role past the normalized default.

### 3. Asymmetric rhetoric: every incentive points away from the lead

The instruction text warns against spawning repeatedly: "Do not over-spawn", "spawn the smallest crew that does the job", "spawning is the expensive act", "a lead running a whole team is the most expensive thing in the system" (in the lead playbook), and, attached directly to the heuristic itself, "The lead is for efforts big enough to warrant a manager - don't reach for it by default."
Against this, exactly one sentence says to suggest a lead.
Crucially, the text never separates the cost of *suggesting* (one sentence to the user, who decides) from the cost of *spawning* (a full session tree).
An orchestrator weighing "suggest a lead" against five cost warnings resolves the ambiguity by staying quiet - even though the suggestion itself is free and the decision belongs to the user.

### 4. The heuristic is framed as a one-shot intake test, but scope grew incrementally

The incident arrived in two steps: first "review an analysis and fix it" (one role, plausibly), then "analyst plan handed to a developer plus review" (three roles).
The heuristic is written as a property of "the directive" assessed once during intake.
Nothing tells wingman to re-run the assessment when the user expands an in-flight effort, so each increment is judged in isolation and each looks small.
By the time the effort objectively passed the threshold, intake - the only moment the heuristic is attached to - was already over.

### 5. Zero mechanical reinforcement

`bin/spawn-crew` records every member with a `parent` field and could observe "this is the third top-level member attached to the same effort," but it performs no such check and prints no nudge.
The suggestion depends entirely on prose recall; there is no backstop at the moment of spawn, which is the last point the miss could have been caught.

A related observation: a session memory (`suggest-lead-at-intake.md`, "test every directive against the lead heuristic before spawning") now exists in the orchestrator's memory directory.
That is the current mitigation, and it lives outside the repo - it protects one user's sessions on one machine and is invisible to the playbook/instruction files that define wingman's behavior for everyone.
The durable fix belongs in the repo.

## Recommendations

### Recommended: encode an explicit "lead test" at intake in `CLAUDE.md`

One coherent change to the instruction text, in four parts:

1. **Make the test a named, mandatory intake step.**
   Move the assessment from the Scope sub-bullet into the Intake step's grounding checklist (which already forces artifact resolution and no-invented-history) as "the lead test", phrased as a binary question that must be answered for every directive before scoping.
2. **Fix the threshold so it can be applied literally.**
   The line must exclude the plain analyst→developer handoff it currently captures. Concretely: *suggest a lead when the effort needs a third role beyond the standard analyst→developer pair (e.g. a reviewer or architect in the same sequence), or more than one developer/delivery, or spans multiple repos.*
3. **Make the verdict visible.**
   Require the one-line intake restatement to include the lead-test verdict when it passes ("this crosses the lead threshold - want me to appoint a lead, or run it as direct spawns?").
   A stated verdict makes a miss immediately observable and correctable by the user, instead of silent.
   Pair this with one sentence severing the cost conflation: *suggesting a lead costs nothing; only spawning is expensive - when the test passes, always say so; the user decides.*
4. **Add a re-evaluation rule and vocabulary cross-references.**
   When the user expands an in-flight effort with another role or deliverable, re-run the lead test before spawning and, if it now passes, suggest promoting the effort to a lead.
   In the command vocabulary, prefix the entries that can absorb large directives ("Implement feature X", "Investigate issue Y" when a fix will follow) with "apply the lead test first."

This is the lowest-effort change that addresses all five root causes: the test is forced onto the fast path (1, 4), it becomes literally applicable (2), the anti-suggestion bias is neutralized and misses become visible (3), and mid-flight growth is covered (4).
The "Appointing a lead" section should be updated in the same pass so both statements of the heuristic stay identical.

**Verification:** replay the incident's directive shape ("review this analysis and fix it", then "I want an analyst plan handed to a developer plus review") against the revised instructions in a scratch session and confirm the lead suggestion appears at intake of the second message; also confirm a plain "implement feature X" still takes the direct analyst path with no lead suggestion.

### Follow-ups (not required for the fix)

- **Mechanical backstop in `bin/spawn-crew`:** print a reminder line when a top-level spawn (`parent=""`) would put three or more active top-level members in flight, or when the type is `reviewer`/`architect` at top level - the shapes that usually mean an unled multi-role effort. A printed nudge at spawn time is the last-chance catch for any future prose miss; detecting "same effort" precisely is fuzzy, so keep it a heuristic warning, not a block.
- **Retire the session-memory mitigation once the repo encoding lands,** so behavior does not depend on one machine's memory files.
- **Reconcile the lead playbook's cost warning** ("the most expensive thing in the system") with the suggest-freely rule, so the same asymmetry does not re-emerge from the lead's side of the docs.

## Files examined

- `wingman/CLAUDE.md` - operating loop (Intake/Scope), command vocabulary, "Appointing a lead", cost discipline.
- `wingman/playbook/lead.md`, `wingman/playbook/analyst.md` (via crew brief) - role definitions and handoff conventions.
- `wingman/.claude/commands/lead.md`, `spawn.md` - user-invoked commands; no orchestrator-side logic.
- `wingman/bin/spawn-crew`, `bin/wingman`, `bin/crew-list`, `bin/watch-fleet` - confirmed no scope-assessment or lead-suggestion logic.
- `wingman/docs/architecture.md` - hierarchy design; describes the lead machinery, not the suggestion trigger.
- `~/.wingman/crew.json` - the incident's spawn record.
