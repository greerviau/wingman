# Issue-board hygiene across wingman and skills — report

## Task 1: wingman issue board

### Label taxonomy

Two axes, kept small and reusing what already existed where it fit:

**Type axis** — `bug`, `enhancement`, `documentation` (all pre-existing), plus one new label, `refactor` (structural/code-quality change, no behavior change — created for taxonomy completeness even though no currently-open issue needed it). The pre-existing `todo` and `question` labels were left alone and not treated as part of this axis; `todo` stayed on the two issues that already carried it (#189, #25) alongside the new accurate type label.

**Component axis** — seven new `area:*` labels, derived from reading the actual codebase (`bin/`, `hooks/`, `playbooks/`, `README.md`) rather than inventing plausible buckets:

| Label | Covers |
|---|---|
| `area:watch-loop` | `bin/watch-fleet`: arm/fire/classify, stall detection, spurious-death budget, correlated fleet events (mass-death, outage, usage-limit), `bin/pr-watch` as a wake-loop instance |
| `area:delivery-tmux` | `crew-say`/`crew-ask`, `wm_tmux_send_message`, pane confirmation, the outbox queue, tmux window creation |
| `area:crew-state` | `wm-state.py`/`crew.json`, `crew-list` reconciliation, ownership, id/sidecar lifecycle, `crew-prune`/`crew-standdown` |
| `area:spawning-playbooks` | `spawn-crew` mechanics, playbook prose, depth-cap policy, orchestration discipline |
| `area:reporting-escalation` | the status contract itself: blocked/review/done semantics, stale-blocker bugs, rollup, escalation batching |
| `area:guards-hooks` | the `hooks/*.sh` enforcement layer and `cmd_match.py`'s own correctness |
| `area:onboarding-config` | `bin/doctor`, `bin/config`, settings discoverability |

A handful of issues describe genuinely separate defects spanning two components (e.g. #214's three enumerated defects, #212's rollup gap + depth-cap anomaly) and got two `area:*` labels rather than being forced into one.

One type correction: #204 was re-labeled from the filer's original `enhancement` to `documentation` — its actual ask ("surface `WM_USAGE_WARN_THRESHOLD` in `config.example.sh`... as a commented, documented knob") is about discoverability of an already-working feature, not new functionality.

### Scale

All **39** open issues were read in full and labeled — no sampling. Verified afterward: every open issue carries at least one type label and at least one `area:*` label.

### Stale/superseded/already-fixed check

Cross-checked against the 30 most recently merged PRs and a 2026-07-30 consolidated post-mortem (`docs/analysis/2026-07-30-why-wingman-keeps-crashing.md`) that explicitly re-confirms several of these issues (#175, #196, #197, #198, #206, #207, #209) as still open and unfixed as of the day this work was done. Also confirmed directly: `WM_USAGE_WARN_THRESHOLD` (#204) is absent from the current `config.example.toml`, and no `draft-only`/`no-ready-pr-write-guard.sh` (#200) exists in the codebase. **None of the 39 open issues were found to be stale, superseded, or already fixed.** Nothing was closed.

## Task 2: skills board — deferred candidates filed

Read `docs/plans/2026-07-29-engineering-skills-expansion.md` from `origin/main` (the local checkout was 6 commits behind and had local modifications, so it was not used as the source). Confirmed the five Tier 1 skills (`design`, `tdd`, `tech-research`, `perf`, `mermaid`) are already merged (PRs #18–#22) and excluded them. Checked the skills board first: it had only default GitHub labels and one unrelated closed issue, so no duplicate-checking conflicts.

Two new labels created on `greerviau/skills`: `new-skill` (proposes an entirely new skill) and `deferred-candidate` (sourced from a plan's Deferred candidates section). Applied alongside the existing `enhancement` label to all nine.

Filed one issue per deferred candidate, preserving the plan's own wording for what each skill would do, why it was deferred, and its composition notes, with a link back to the plan file on GitHub:

| # | Skill | URL |
|---|---|---|
| 23 | `triage` | https://github.com/greerviau/skills/issues/23 |
| 24 | `adr` | https://github.com/greerviau/skills/issues/24 |
| 25 | `flake-hunt` | https://github.com/greerviau/skills/issues/25 |
| 26 | `dep-upgrade` | https://github.com/greerviau/skills/issues/26 |
| 27 | `prototype` | https://github.com/greerviau/skills/issues/27 |
| 28 | `map-subsystem` | https://github.com/greerviau/skills/issues/28 |
| 29 | `merge-conflict` | https://github.com/greerviau/skills/issues/29 |
| 30 | `wayfinder` analog | https://github.com/greerviau/skills/issues/30 |
| 31 | `improve-codebase-architecture` analog | https://github.com/greerviau/skills/issues/31 |

Two of these (`adr`, `improve-codebase-architecture`) had their deferral reasons tied to `design` not existing yet ("candidate to fold into design", "blocked on design"). Since `design` has since merged, both issue bodies flag that the original blocker may no longer hold and are worth re-evaluating on that basis.

## Left alone, deliberately

- **All 39 wingman issues stayed open.** Several read as plausibly stale at a glance (audit-generated, older numbers like #169–#180) but the cross-check above found no evidence any were fixed; closing is explicitly not this session's call regardless.
- **The pre-existing `todo`/`question`/`wontfix`/`duplicate`/`invalid`/`good first issue`/`help wanted` labels** on both repos were left untouched — no issue needed them, and removing or redefining them was out of scope for a labeling pass.
- **The skills repo's one existing issue (#9, closed)** was left as-is; it predates this plan and isn't a deferred candidate.
