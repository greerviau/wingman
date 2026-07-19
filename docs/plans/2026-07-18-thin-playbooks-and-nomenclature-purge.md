# Thin playbooks and purge orchestration nomenclature

**Date:** 2026-07-18
**Status:** proposed

## Problem

The playbooks have drifted into two overlapping jobs. Each role playbook now
re-explains things that are already universal - how to report state, how agents
talk to each other, what the states mean - and each is soaked in wingman's
private orchestration vocabulary (*pilot*, *crew*, *wingman*, *lead*, *stand
down*). Two costs follow:

1. **Redundancy.** "How you report state is governed by the crew status contract
   appended to this brief" appears in nearly every playbook, restating something
   the appended contract already owns. Inter-agent communication mechanics
   (`bin/crew-say` review loops, who-gets-woken) are re-described per playbook
   instead of living once in the shared contract.
2. **Nomenclature leakage.** The role vocabulary is orchestration-internal - it
   exists only for the wingman<->human channel and wingman's own operating docs.
   Every playbook and shared fragment that names *pilot*/*crew*/*wingman* is a
   surface an agent reads and can mirror into a PR body, a commit message, a
   plan, or a GitHub comment. The safest defense is to never expose the words to
   the agents at all.

The user's directive: playbooks must be **thin** - describe only *what the role
is* - and the orchestration nomenclature must appear in **exactly one place**,
`CLAUDE.md`, which only the interactive wingman session ever reads.

## Design principles

Three rules govern every edit below.

- **A playbook describes a role, nothing else.** Who you are, what you deliver,
  how you approach the work, what shape the deliverable takes. It does not
  re-teach state reporting, the wake loop, escalation, or inter-agent messaging -
  those are appended contracts.
- **Mechanics live in the shared contracts, once.** `_status-contract.md`
  (state protocol, wake loop, escalation, peer messaging, artifact publishing)
  and `_delivery.md` (isolate/publish/shepherd/merge) remain the single home for
  the "how." Playbooks reference a capability by its plain name when they must
  (e.g. "your terminal condition"), never by re-explaining its mechanics.
- **No orchestration nomenclature in anything an agent reads.** Purge the prose
  vocabulary *pilot*, *crew* (as a role noun), *wingman*, *lead* (as a role
  noun), *stand down*/*reap* from every file under `playbooks/`, including the
  shared contracts. Replace with neutral terms (mapping below). This is the
  decision confirmed with the user: the contracts are purged too, not just the
  role playbooks.

### What is NOT nomenclature (stays unchanged)

These are code identifiers and environment contracts, not prose vocabulary, and
renaming them would require code changes out of scope here:

- Tool/script names: `bin/crew-say`, `bin/crew-list`, `bin/crew-ask`,
  `crew-set`, `bin/spawn-crew`, `bin/watch-fleet`, `bin/pr-watch`, etc.
- Environment variables: `$WINGMAN_STATE`, `$WINGMAN_CREW_ID`, `$WINGMAN_HOME`,
  `$WINGMAN_BIN`, `$WINGMAN_RUN_ID`, `$WINGMAN_IS_GIT`, `$WINGMAN_HAS_REMOTE`,
  `$WINGMAN_WORKTREE`.
- Status protocol values: `working`/`blocked`/`review`/`done`/`stalled`.
- Hook filenames, `CLAUDE.md`, and everything under `hooks/`, `bin/`, `tests/`
  except the two test assertions listed under "Test impact."

`CLAUDE.md` keeps the full nomenclature - it is wingman's own operating doc and
is the one place the vocabulary is defined.

## Neutral-term mapping

| Internal term (remove from playbooks) | Neutral replacement |
|---|---|
| the pilot | the human / the requester |
| a crew member / crew (role noun) | an agent / a session / a role name (`developer`, `reviewer`, ...) |
| wingman (the orchestrator, in prose) | your owner / the orchestrator (only where a relationship must be named) |
| a lead (role noun) | the owner who commissioned you / your owner |
| stand you down / reap you | end your engagement / close you out |
| "crew status contract" (heading/prose) | "status contract" |
| "wingman crew member" (titles) | drop the qualifier |

Where a playbook currently names *who* an escalation or a message goes to
("surfaces to wingman -> the pilot"), collapse it to the role-neutral fact the
agent actually needs ("your owner answers, or escalates further if needed") -
the routing chain is the contract's concern, not the role's.

## Per-file changes

### Shared contracts

**`playbooks/_status-contract.md`** (largest single edit)
- Retitle `# Crew status contract (all crew types)` -> `# Status contract (all
  roles)`.
- Rewrite the opener ("You are a **wingman crew member**...") to name the agent
  neutrally: an independent Claude Code session dispatched to do real work,
  reporting state through the status file its owner watches.
- Purge *pilot*/*crew*/*wingman*/*lead* prose throughout, keeping every
  mechanism (states, `--silent` re-entry, `stalled`, wake loop, escalation,
  peers, `crew-ask`, freshness check, artifact publishing, structured open
  questions, PR-facing rules, register). Escalation/peers keep their *mechanics*
  but describe relationships as owner/sibling/report, not lead/pilot.
- **Collapse the "Communication register" section.** Today it is a long
  explanation of when *pilot* may vs. must not appear. Once the vocabulary is
  gone from every file an agent reads, most of that section is moot. Reduce it to
  the durable rule: everything you author for a human reader (code, comments,
  commits, PR text, GitHub comments, plans, inter-agent messages) uses "the
  human"/"the requester"; status-file protocol fields keep their literal values.
  Drop the "exception - internal orchestration reference is legitimate" carve-out
  and the "flag a playbook that says pilot" defect rule - they only existed
  because the words used to be present.
- The "Keep detail out of chat" line "never as *the pilot*" becomes just the
  positive rule (refer to the requester/human).

**`playbooks/_delivery.md`**
- Purge the handful of *pilot*/*crew* prose mentions (mostly already "the
  human"/"the requester" - it is one of the cleaner files). Verify no
  "crew"-as-role prose remains; keep `bin/crew-say`, `$WINGMAN_*`, status values.
- Remove any residual re-explanation of the review-over-wingman's-channel
  mechanic that duplicates the status contract; keep only what is
  delivery-specific (PR body shape, merge authorization, pr-watch reasons,
  cleanup).

### `common/`

**`common/lead.md`** (second-largest edit; heavily nomenclature-laden)
- This playbook *is* the role that manages a sub-crew, so it legitimately needs
  to talk about spawning/supervising other agents - but it must do so without the
  *pilot*/*crew*/*wingman* vocabulary. Retitle, drop "crew member" qualifier.
- Replace "the same loop wingman runs" / "one layer down" framing with a
  self-contained description of the manager role: you own an effort end to end,
  you decompose it, you hire and sequence your own agents, you integrate and roll
  up one status line to your owner.
- "roll up to wingman" -> "roll up to your owner"; "escalates to wingman -> the
  pilot" -> "escalate to your owner, who escalates further only as needed";
  "the pilot's sign-off" -> "the human's sign-off" (relayed through your owner).
- Keep all *mechanics* (spawn recipe, owner-scoped watcher, peer introduction,
  depth cap, phase gates) - these are the role's actual substance - but strip the
  vocabulary. The `/watch` and watch-fleet mechanics stay (they are tool usage,
  and already reference reading wingman's `watch.md` by path).
- Remove the redundant "Follow the crew status contract (appended)" framing in
  "Status updates" - keep only the lead-specific note that its `summary` is
  always the rollup.

**`common/research.md`**
- Drop "crew member" from title; remove the whole "How you report state is
  governed by the crew status contract appended to this brief" sentence and the
  "Wingman surfaces the report... wingman routes that separately" mechanics.
  Replace with a one-line role fact: a report has no external dependency, so its
  completion is the terminal condition. The rest (framing, gathering, writing) is
  already clean role prose.

### `software-development/`

**`software-analyst.md`**, **`architect.md`**, **`developer.md`**,
**`reviewer.md`**
- Drop "crew member" from every `# Playbook: ...` title.
- Remove every "How you report state ... is governed by the crew status contract
  appended to this brief" line (universal - it is the appended contract's job).
- Replace *pilot* with the human/requester; replace "downstream `developer`
  member" / "a fresh `developer` session" phrasing to just name the role
  (`developer`) without "member".
- **reviewer.md** carries the most inter-agent-comms prose. Trim the "your
  verdict travels over wingman's own channel" explanation to the role-specific
  minimum and lean on `_status-contract.md` + `_delivery.md` for the shared
  mechanics; keep the PR-verdict-on-GitHub (`pr_comments=on`) section since that
  is genuinely reviewer-specific mechanics, but purge *pilot*/*crew* prose from
  it. Cross-references to `playbooks/_status-contract.md` sections stay (they
  point at the shared home, which is the whole point) but should reference by
  the new section titles.
- **developer.md** references "the human presses merge - see Merge
  authorization" which is fine (human, not pilot); verify and keep.

### All other category playbooks (batchable, ~3 mentions each)

`ai-research/*`, `data-science/*`, `scientific-research/**`,
`business-development/*`, `business-operations/*`, `infrastructure/*`.

Each shares the same three touch-points:
1. `# Playbook: \`<role>\` crew member` title -> drop "crew member".
2. One "How you report state ... crew status contract appended to this brief"
   sentence -> remove (or, where it adds a genuine role-specific terminal-
   condition note like ml-engineer/research, keep only that note, phrased
   neutrally).
3. Stray *pilot*/*wingman* prose (e.g. "wait for the requester's acceptance via
   `bin/crew-say`" is fine - `bin/crew-say` is a tool, "requester" is neutral;
   "wingman surfaces..." is not) -> neutralize.

These are mechanical and near-identical; do them in one pass, reading each to
confirm no role-specific mechanic is lost.

## Test impact

`tests/playbook-resolution.test.sh` asserts on prose that this refactor changes:

- L47 `grep -q 'Playbook: \`developer\` crew member'` -> update to the new title.
- L54 `grep -q 'Playbook: \`lead\` crew member'` -> update to the new title.
- L99 `grep -q 'Crew status contract'` -> update to the new heading
  (`Status contract`).

Update these assertions to match the new strings. No other test asserts on
playbook prose (comment-only references in `ack-dedup.test.sh` and
`artifact-link-guard.test.sh` need no change). Run the full `tests/` suite after.

## Out of scope

- Renaming any `bin/`, `hooks/`, env var, or status value.
- Changing `CLAUDE.md` (it is the sanctioned home of the vocabulary).
- Any behavioral change to the state protocol, wake loop, or delivery flow -
  this is a wording/structure refactor only; every mechanism stays.

## Risks and open questions

The nomenclature purge in `_status-contract.md` is the delicate part: it is a
337-line protocol doc and a careless neutral-term substitution could blur a
routing rule (who escalates to whom). Mitigation: preserve every mechanic
sentence's *meaning*, only swapping the noun; re-read the escalation/peers
sections against `CLAUDE.md` to confirm the chain still reads correctly one layer
at a time.

```wingman-questions
{
  "questions": [
    {
      "id": "owner-term",
      "type": "choice",
      "question": "When a playbook must name the party an agent reports/escalates to, which neutral term should be the standard?",
      "options": [
        { "label": "your owner", "recommended": true,
          "detail": "Matches the status contract's existing 'owner' concept (wingman or a lead, mechanically identical); already the term the escalation machinery uses internally, so it stays accurate one layer down." },
        { "label": "the orchestrator",
          "detail": "Clearer as a standalone word but less precise - a lead is also an orchestrator, so 'the orchestrator' is ambiguous about which layer." }
      ],
      "free_text": true
    }
  ]
}
```
