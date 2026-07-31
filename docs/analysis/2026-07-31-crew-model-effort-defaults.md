# Per-crew-type model/effort defaults for the software-development pipeline

Date: 2026-07-31

## Question

For each software-development crew playbook (`software-analyst`, `architect`,
`developer`, `reviewer`, `lead`) plus the domain-neutral `common/lead` and
`common/research`, which Claude model and reasoning effort level is the best
fit — so sensible defaults can be set in `config.local.toml` instead of
passing `--model`/`--effort` by hand on every spawn?

## Method

Read every playbook under `playbooks/software-development/` and
`playbooks/common/` to characterize what each role actually does (breadth of
reading, depth of multi-step reasoning, how mechanical the work is, typical
session length). Checked current model facts (IDs, pricing, capabilities,
effort semantics) against the `claude-api` skill's cached reference
(`shared/models.md`, `shared/model-migration.md`, cached 2026-06-24) rather
than assuming. Read `bin/spawn-crew`, `bin/lib/common.sh`
(`wm_config_for_type`), and `docs/configuration.md` to confirm whether
per-crew-type defaults are already supported and to get the exact config
syntax, and ran `bin/spawn-crew --list-types` to confirm the category-qualified
type strings.

## Ground truth on models (as of this writing)

| Model | ID | Input/output $ per MTok | Notes |
|---|---|---|---|
| Claude Opus 5 | `claude-opus-5` | $5 / $25 | Current Opus-tier flagship. Thinking on by default. Full `low`–`max` effort ladder. |
| Claude Sonnet 5 | `claude-sonnet-5` | $3 / $15 (intro $2/$10 through 2026-08-31) | "Near-Opus quality on coding and agentic work" per Anthropic's own migration notes. Adaptive thinking on by default. Full `low`–`max` effort ladder. |
| Claude Haiku 4.5 | `claude-haiku-4-5` | $1 / $5 | Fastest/cheapest; not effort-tunable in the same way, weaker on deep multi-step reasoning. |

`xhigh` effort is "the best setting for most coding and agentic use cases" and
is Claude Code's own default there; `high` is the API default and a good
default for reasoning-heavy but less tool-call-heavy work; `low`/`medium` are
appropriate for narrow, bounded tasks. Opus 5 in particular "stays accurate at
lower effort" for code review specifically, which matters for the reviewer
split below.

## Config mechanism: already supported, syntax below

**This is not a gap — per-crew-type model/effort defaults already exist.**
`bin/spawn-crew` resolves `--model`/`--effort` in this order (most specific
wins): explicit CLI flag → `config.local.toml`'s `[models]`/`[effort]` entry
for that crew type (`bin/lib/common.sh`'s `wm_config_for_type`, reading
`config.local.toml` via `bin/lib/wm_config.py for-type`) → `$WM_MODEL`/`$WM_EFFORT`
→ the agent CLI's own default.

Table keys accept either the bare role name (`developer`) or the
category-qualified name (`software-development/developer`) — use the
qualified form only to break a collision with another category's role of the
same name (e.g. two categories both defining `reviewer`). A bare `default` key
applies to every spawn that doesn't have a more specific entry.

Exact syntax to add to `config.local.toml`:

```toml
[models]
default = "sonnet"
"software-development/software-analyst" = "sonnet"
"software-development/architect"        = "opus"
"software-development/developer"        = "sonnet"
"software-development/reviewer"         = "opus"
lead     = "sonnet"
research = "sonnet"

[effort]
default = "high"
"software-development/software-analyst" = "high"
"software-development/architect"        = "high"
"software-development/developer"        = "xhigh"
"software-development/reviewer"         = "high"
lead     = "medium"
research = "medium"
```

(`bin/spawn-crew --list-types` confirms the exact qualified strings; `lead`
and `research` live under the `common/` category, but since no other category
currently defines a `lead` or `research` role, the bare key is unambiguous.)

`bin/spawn-crew` passes these straight through as `--model`/`--effort` to the
underlying `claude` invocation, so any alias the CLI itself accepts (`opus`,
`sonnet`, `haiku`) or an exact model ID works as the value.

## Per-role recommendations

### `software-analyst` — requirements, exploration, general spec

**Model: Claude Sonnet 5. Effort: high.**

The role explores code and docs, then designs and writes a plan — real
judgment (picking one approach, not presenting a menu) but not the
deepest multi-file implementation reasoning; it produces a *general* spec, not
the detailed *how*. Sonnet 5 at `high` effort is priced for a role that runs
early and often in a pipeline, and Anthropic's own guidance is that Sonnet 5 at
`high` is roughly comparable in intelligence to the prior Sonnet generation's
`max` — plenty for synthesizing requirements into a coherent spec. Bump to
`xhigh` for a genuinely large, ambiguous, multi-repo requirements effort.

### `architect` — approved spec → detailed implementation plan

**Model: Claude Opus 5. Effort: high (xhigh for large/multi-repo plans).**

This is the deepest pure-reasoning role in the pipeline: turning a settled
*what* into an exact *how* — files touched, interfaces, sequencing, data/schema
impact, edge cases — detailed enough that a developer builds from it with no
further design. Mistakes here propagate into every downstream developer
session, so this is exactly the "genuinely needs deep reasoning" case the
cost-tradeoff should favor Opus for. Sessions are typically single-pass
(explore, then write one plan file) rather than long agentic tool-call loops,
so `high` effort is the right default; reserve `xhigh` for plans spanning many
repos or with real architectural risk.

### `developer` — implement, validate, deliver, shepherd to merge

**Model: Claude Sonnet 5. Effort: xhigh.**

This is the longest-running, most tool-call-heavy role (edit, run tests,
iterate on review feedback, watch CI, shepherd a PR to merge) — squarely
"agentic coding," which is exactly the profile `xhigh` effort is tuned for on
both Sonnet 5 and Opus 5. Given Anthropic's own characterization that Sonnet 5
reaches "near-Opus quality" specifically on coding and agentic work, and that
this role is both the highest-volume spawn and the longest session in the
pipeline (cost compounds across many tool calls, not just one request),
Sonnet 5 at `xhigh` is the better default than Opus 5 everywhere: it matches
capability to need rather than defaulting to the priciest tier for routine
implementation work.

**This role's work genuinely splits by task difficulty, not by phase within
one session** (model/effort are fixed at spawn time, so this is a per-task
routing decision the human/lead makes when spawning, not something the
playbook itself does mid-session): a small, well-scoped fix or a mechanical
review-feedback iteration fits the Sonnet 5 default fine; a large or
architecturally risky build (the kind that would otherwise have gone to a
software-analyst+architect pipeline) is worth spawning with `--model opus`
explicitly, keeping `xhigh` effort either way.

### `reviewer` — review a plan or PR, report findings

**Two distinct workloads, worth two different defaults — this is the clearest
split of any role here:**

- **First / adversarial review pass** (a plan's soundness, or a PR's
  correctness bugs, missing tests, regressions): **Claude Opus 5, effort
  high.** This is the last check before human review, and the playbook is
  explicit that "must-fix" findings gate approval — false negatives here are
  expensive downstream. Opus 5's code-review characterization ("high precision
  and high recall... a high rate of real bugs per pass, with the extra
  findings mostly real rather than false positives") plus its ability to stay
  accurate even at lower effort makes it the right fit for the pass that
  actually has to find things.
- **Confirmation / re-verification pass** (checking that a specific,
  previously-flagged fix was applied correctly, after a developer's revision):
  **Claude Sonnet 5, effort medium.** The scope is narrow and specific — verify
  one change against one known finding, not an open-ended search for new
  problems — so a cheaper model at lower effort is the right match. Anthropic's
  own guidance that Opus 5 "stays accurate at lower effort" also means a
  cost-sensitive team could instead run *both* passes on Opus 5 (`high` for
  the first, `medium`/`low` for the confirm) rather than switching models; the
  Sonnet 5 confirm-pass default here optimizes for the common case where
  confirmation happens often and per-pass stakes are low.

Since `[models]`/`[effort]` in `config.local.toml` are per-crew-*type*, not
per-invocation-purpose, this split can't be expressed as two config table
rows — it has to be applied by whoever spawns the reviewer (typically a
`lead`), passing `--model sonnet --effort medium` explicitly for a confirm-only
round and leaving the config default (Opus 5 / `high`) in place for the real
first pass. Document this as a spawning convention rather than expecting the
config table alone to capture it.

### `common/lead` — orchestrates a team, never does heavy work itself

**Model: Claude Sonnet 5. Effort: medium.**

The playbook's own "prime directive" is to *not* do heavy work: no
implementing, no long investigations, no reading large files — every
substantial task is delegated, and the lead itself only reads distilled status
files, decomposes work, makes spawn/escalation decisions, and rolls up a
one-line summary. This is real judgment (deciding what's genuine churn vs. a
decision to escalate, sequencing phases, catching stalled `review` workers)
but it is shallow and fast per decision, and a lead session runs continuously
in the background across a whole effort's lifetime — cost compounds by
duration far more than by per-decision difficulty. Sonnet 5 at `medium`
effort is the right match; there's no coding or deep multi-file reasoning here
to justify Opus or `high`/`xhigh`.

### `common/research` — gather evidence, synthesize a cited report

**Model: Claude Sonnet 5. Effort: medium (high for genuinely hard/ambiguous
questions).**

Research is breadth-first (multiple sources, triangulation) with a synthesis
step at the end (weighing conflicting evidence, stating confidence), and the
role explicitly does not change the project — no coding, no agentic tool-call
loops beyond search/read. This is a good match for Sonnet 5 at `medium`,
scaling to `high` when the question is genuinely hard to adjudicate (weighing
contested or sparse evidence) rather than a straightforward lookup-and-report.

## Summary table

| Role | Model | Effort | One-line why |
|---|---|---|---|
| `software-analyst` | Sonnet 5 | high | Broad exploration + one synthesized approach, not deep multi-file design |
| `architect` | Opus 5 | high (xhigh for large/multi-repo) | Deepest pure-reasoning role; mistakes propagate to every downstream developer |
| `developer` | Sonnet 5 | xhigh | Longest, most agentic role; Sonnet 5 is "near-Opus" specifically on coding/agentic work; escalate to Opus per-task for hard builds |
| `reviewer` (first pass) | Opus 5 | high | Last gate before human review; Opus 5 has the best precision/recall on bug-finding |
| `reviewer` (confirm pass) | Sonnet 5 | medium | Narrow, specific re-check, not open-ended search |
| `lead` | Sonnet 5 | medium | Pure orchestration by design; cost compounds by session duration, not per-decision depth |
| `research` | Sonnet 5 | medium (high for hard questions) | Breadth + synthesis, no coding, no long agentic loops |

## Cost framing

Applying the above instead of a blanket "Opus everywhere" default: of the
seven role/workload rows, only two (`architect`, and the reviewer's
first-pass) default to Opus 5 — the two places a missed defect or a wrong
design decision is expensive to unwind downstream. The remaining five
(`software-analyst`, `developer`, `reviewer`-confirm, `lead`, `research`)
default to Sonnet 5, priced at 60% of Opus 5's per-token rate (further
discounted through 2026-08-31 under Sonnet 5's introductory pricing) — and
`developer`, the highest-volume and longest-running role in the pipeline,
still gets `xhigh` effort so agentic-coding quality isn't traded away for
model tier. This is deliberately not "cheapest possible everywhere" either:
`lead` and `research` still get real reasoning capability (Sonnet 5, not
Haiku), because both roles make judgment calls (what counts as escalation-
worthy churn; how to weigh conflicting evidence) that Haiku 4.5 is not
well-suited to.

## Limitations

- These are defaults for *typical* task difficulty per role; a human spawning
  a crew member for an unusually hard or unusually trivial instance of a role
  should still override with an explicit `--model`/`--effort` on that one
  spawn — the config table sets the common case, not a hard ceiling.
- The reviewer split (adversarial vs. confirm) cannot be expressed purely in
  `config.local.toml`, since defaults are keyed by crew type, not by
  invocation purpose; it has to be applied as an explicit override at spawn
  time by whoever requests the confirm-only round.
- Pricing and effort-level guidance reflect the `claude-api` skill's cached
  reference (dated 2026-06-24) as of this writing; if Anthropic revises
  Sonnet 5's introductory pricing after 2026-08-31 or ships a new model in
  this tier, re-check before treating this table as current.
