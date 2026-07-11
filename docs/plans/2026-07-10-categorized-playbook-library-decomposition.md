# Effort Decomposition: Categorized Playbook Library

Date: 2026-07-10
Owner: lead (`implement-the-approved-plan-at-d-lead`)
Source plan: `docs/plans/2026-07-10-categorized-playbook-library.md` (approved)
Repo: `wingman` (single repo)
Delivery: one PR

## Scope summary

Reorganize `playbook/` into a categorized library (`playbooks/` with per-category subdirectories), ship out-of-the-box role playbooks for each category, and update type resolution and `--list-types` in `bin/spawn-crew` / `bin/lib/common.sh` to work with the category structure, preserving backward compatibility for bare type names.
The approved plan settles every open question, so no design decisions remain open:

- Q1 -> `lead` and `research` live under `common/`.
- Q2 -> directory renamed `playbook/` -> `playbooks/`.
- Q3 -> `biological-research` is a nested sub-domain of `scientific-research`.
- `analyst` -> `software-analyst` rename is in scope, including operating-doc references.

## Phases and sequencing

This is a linear effort; the two roles run in sequence, not parallel.

### Phase 1 — Build (developer, `software-development` scope)

One developer implements the plan end to end, following the plan's build order (section 8):

1. Rewrite resolver + enumeration (`wm_crew_types()`, `spawn-crew` resolution) to search recursively via `find` (bash 3.2 safe, no `globstar`) and accept both bare and `category/role` forms, while files are still flat.
2. Add `tests/playbook-resolution.test.sh` and get it green.
3. Move existing files into `common/` and `software-development/` (rename `analyst.md` -> `software-analyst.md`), move `_status-contract.md` to `playbooks/` root, rename `playbook/` -> `playbooks/`, update all path references plus `analyst` -> `software-analyst` in `CLAUDE.md`/`README.md`. Run full suite.
4. Update `--list-types` to category-qualified, grouped output; update the test.
5. Author the new playbooks per category in the plan's order: `common` (confirm lead/research from new home), then `ai-research`, `data-science`, `scientific-research` (+ `biological-research`), `business-development`, `business-operations`. Each mirrors the existing software playbooks' structure and status-contract wiring and states its handoff.
6. Update prose docs (`README.md`, `CLAUDE.md`) for categories, qualified-name form, and `common` roles.
7. Manual smoke test: spawn one member per category with the stub agent; confirm each resolves, launches, and carries the status contract.

Deliverable: one branch + PR against `main`.

### Phase 2 — Review (reviewer)

Once the PR is open, one reviewer reviews the full result against the plan:
correctness of the resolver (bash 3.2 safety, collision handling, local-over-default, `_`-prefix exclusion), completeness of the shipped role set, migration/backward-compatibility (every bare type name still resolves; `analyst` references fully migrated), test coverage, and doc accuracy.
Reviewer reports findings to the developer directly (peers under this lead); the developer addresses them in the same PR.

### Phase 3 — Integration and roll-up (lead)

Verify resolver, tests, playbooks, and docs cohere; confirm the PR is green and review is resolved; roll up a single status line and surface the PR for sign-off.

## Crew

- 1 `developer` (repo-scoped to `wingman`), opus.
- 1 `reviewer` (repo-scoped to `wingman`), opus, spawned after the PR is open.

## Escalation

The plan settles all design questions, so escalation is reserved for genuine surprises (an unanticipated resolver constraint, a request to deviate from the plan). Routine review feedback is handled peer-to-peer between developer and reviewer.
