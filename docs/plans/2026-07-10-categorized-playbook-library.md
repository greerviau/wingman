# Scoping: A Categorized Playbook Library

Date: 2026-07-10
Status: Draft for review
Type: Scoping document (the *what* and *why*; a detailed implementation plan follows on approval)
Repo: `wingman`

## 1. Problem and goal

Wingman's crew are defined entirely by their playbooks.
A crew type is valid if and only if a playbook file exists for it, so the set of things wingman can staff is exactly the set of files under `playbook/`.
Today that directory is a flat set of six files, all describing software delivery: `analyst`, `architect`, `developer`, `reviewer`, `lead`, and `research` (plus the shared `_status-contract.md` partial).

Wingman's own design goal is to be domain-neutral: the coordination machinery (tmux windows, status files, the watcher, the board) carries no domain, and only the playbooks carry domain, so the same machinery could run a science lab or a business team by swapping playbooks.
The flat, software-only library does not yet realize that goal.
There is no organizing structure for playbooks beyond a single directory, no first-class notion of a *domain*, and nothing shipped out of the box for the non-software disciplines wingman is meant to be able to run.

This document scopes an **expanded, categorized playbook library**: a taxonomy of domains, the agent roles worth shipping in each, and the reorganization of the `playbook/` directory (and the small amount of resolution code behind it) into per-category subdirectories.
It is a scoping deliverable only; no code is written here.
The output is a design a downstream implementer can build from.

## 2. How playbook resolution works today (grounding)

Three pieces of code define the entire type system.
Any reorganization must keep them working.

- **Type enumeration.**
  `wm_crew_types()` in `bin/lib/common.sh` globs `playbook/*.md` and `playbook/*.local.md`, strips the extensions, drops any basename beginning with `_` (shared partials), and prints the remainder sorted and de-duplicated.
  This is what `bin/spawn-crew --list-types` prints.
  The glob is **non-recursive**: it only sees files directly inside `playbook/`.

- **Type-to-file resolution.**
  `bin/spawn-crew` resolves a type to a file by a single flat join: `PLAYBOOK="$WM_REPO/playbook/$TYPE.md"`, preferring `playbook/$TYPE.local.md` when that sibling exists.
  A type name maps directly and only to a filename in the top-level directory.

- **Shared partial.**
  `bin/spawn-crew` unconditionally concatenates `playbook/_status-contract.md` onto every crew member's system prompt, after the resolved playbook.

Two constraints bind any redesign:

1. **Stock macOS `bash` 3.2.57.**
   `bin/lib/common.sh` is explicitly written for bash 3.2: no associative arrays, no `${x,,}`, no `mapfile`, and critically **no `globstar` (`**`)**.
   Recursive discovery across subdirectories cannot use `**`; it must use `find` or explicit per-directory iteration.

2. **`.local.md` overrides are gitignored globally.**
   `.gitignore` contains a bare `*.local.md`, which matches at any depth, so overrides placed inside category subdirectories remain ignored without any gitignore change.

References to the `playbook/` path outside the resolver live in `README.md` and `CLAUDE.md` (prose), and the `.gitignore` comment.
The test suite under `tests/` exercises spawning through a stub agent (see `tests/spawn-scope.test.sh`), which is the pattern a resolution test would follow.

## 3. Category taxonomy of domains

### 3.1 Proposed set

| Category (directory) | Discipline it staffs |
| --- | --- |
| `software-development` | Building and shipping software: specs, designs, code, review. |
| `ai-research` | ML/AI research and experimentation: hypotheses, experiment design, training runs, result analysis. |
| `data-science` | Analytics and data products: data questions, pipelines, modeling, statistical analysis. |
| `scientific-research` | Experimental science end to end: hypothesis, experimental design, execution, analysis, peer review. Hosts `biological-research` as a sub-domain. |
| `business-development` | Growth-facing work: market and opportunity analysis, go-to-market strategy, partnerships and proposals. |
| `business-operations` | Internal operations: finance, people/process, reporting, standard operating procedures. |
| `common` | Domain-neutral roles reused across every category: the `lead` and the evidence-`research` role. |

`biological-research` is scoped as a **sub-domain of `scientific-research`** (a nested directory `scientific-research/biological-research/`) rather than a seventh top-level category.
Rationale: biological research uses the same orchestration scaffold as any experimental science (hypothesis, design, execution, analysis, peer review); what is distinct is the *tooling and expertise at the role level* (wet-lab assays, omics, bioinformatics, the ChEMBL / ClinicalTrials / PubMed / bioRxiv data sources already connected to this workspace), not the shape of the effort.
Modeling it as specialized roles under a shared scientific scaffold avoids duplicating the whole scientific method into a parallel top-level tree.
Promoting it to a top-level category later is cheap once its role count justifies a standalone discipline; that is noted as a follow-up.

### 3.2 Rationale for the final set

- **Organize by discipline of work, not by artifact type.**
  Each category corresponds to a distinct mode of reasoning and a distinct deliverable shape: software ships code behind a PR, ai-research ships experiment results, data-science ships an analysis, scientific-research ships findings backed by a protocol, business-development ships strategy and proposals, business-operations ships models and SOPs.
  A category boundary is where the *deliverable and its acceptance criteria* change, which is exactly the boundary at which role playbooks must differ.

- **The categories match capability the workspace already carries.**
  The connected MCP servers foreshadow these domains almost one to one: ChEMBL, ClinicalTrials, PubMed, and bioRxiv ground `scientific-research`/`biological-research`; QuickBooks and Ramp ground `business-operations`; Salesforce and Slack ground `business-development`.
  Shipping playbooks for these domains lets a crew member actually reach for the tools its discipline needs.

- **A `common` category prevents duplication of domain-neutral roles.**
  A `lead` manages an effort as an org regardless of domain, and an evidence-gathering `research` role produces a cited report regardless of domain.
  Duplicating either into every category would be a maintenance liability (the depth-cap and handoff conventions would drift per copy).
  Housing them once under `common` keeps a single source of truth.
  This is a reasoned refinement of the directive, which framed the existing files (including `lead` and `research`) as software roles; see Open Questions Q1 for the alternative of keeping them inside `software-development`.

- **The set is deliberately small.**
  Six disciplines plus a shared bucket cover the stated needs (software, AI research, data science, scientific/biological research, business development, internal operations) without fragmenting into narrow sub-disciplines prematurely.
  Finer domains (for example `design`, `legal`, `marketing`) are follow-ups, added the same way a role is: create the directory and drop in playbooks.

## 4. Roles per category

Each role below lists a one-line mandate, its typical deliverable, and the intra-category handoff.
Handoffs mirror the existing software `software-analyst -> developer` contract: an upstream role writes a file, reports its path as `--status review` with an `artifact`, and a downstream role is spawned with `--input <that-path>` and told to consume it.
Only `software-development` ships today; every other category's roles are new and are the substance of the build.

### 4.1 `software-development` (existing, retained)

> **Rename: `analyst` -> `software-analyst`.**
> The bare `analyst` name is too vague for its actual mandate (turn a directive into requirements and a reviewed implementation plan, hand off to a developer, and iterate the plan on feedback).
> `software-analyst` is the primary recommendation because it snaps into the `<domain>-analyst` pattern every other category already uses for its upstream problem-framing role (`research-analyst`, `data-analyst`, `market-analyst`, `ops-analyst`), so the whole library reads consistently and the framing role is instantly recognizable across domains.
> Candidates weighed and rejected: `planner`/`spec-writer` break the cross-category `-analyst` pattern and narrow the role to plan-writing (it also gathers requirements and iterates); `tech-lead`/`project-manager` collide conceptually with the domain-neutral `lead`, which is the role that actually manages a crew; `product-manager` implies product ownership the role does not have.
> Ripple effects: the handoff becomes `software-analyst -> developer` (and `software-analyst -> architect`); the playbook file is `software-analyst.md`; and the operating docs (`CLAUDE.md`, `README.md`) that use "analyst" both as this role's name and as the generic name of the plan-producing step update to `software-analyst`, taking care that the generic handoff description points at the renamed role.

| Role | Mandate | Deliverable | Handoff |
| --- | --- | --- | --- |
| `software-analyst` | Turn a request into a reviewed implementation plan (or an investigation report); iterate it on feedback. | Plan/report file under `docs/plans/` or `docs/analysis/`. | Hands its plan to `architect` (large efforts) or directly to `developer`. |
| `architect` | Turn an approved spec into a detailed implementation plan. | Implementation plan file. | Hands to `developer`. |
| `developer` | Implement and ship the change. | Branch and PR. | Terminal; a `reviewer` may review its PR. |
| `reviewer` | Review a plan or a PR and report findings. | Findings report / inline PR comments. | Feeds findings back to the owning `developer`/`software-analyst`. |

Chain: `software-analyst -> architect -> developer -> reviewer`.

### 4.2 `ai-research`

| Role | Mandate | Deliverable | Handoff |
| --- | --- | --- | --- |
| `research-analyst` | Frame the research question, survey prior art and baselines, propose experiments. | Experiment proposal / spec. | Hands to `experiment-designer`. |
| `experiment-designer` | Turn the proposal into a concrete, reproducible experiment design (datasets, metrics, ablations). | Experiment design doc. | Hands to `ml-engineer`. |
| `ml-engineer` | Implement and run the experiments; capture metrics and artifacts. | Results (metrics, logs, code branch). | Hands to `research-reviewer`. |
| `research-reviewer` | Critique methodology, reproducibility, and statistical validity. | Review report. | Feeds back to `research-analyst`/`ml-engineer`. |

Chain: `research-analyst -> experiment-designer -> ml-engineer -> research-reviewer`.

### 4.3 `data-science`

| Role | Mandate | Deliverable | Handoff |
| --- | --- | --- | --- |
| `data-analyst` | Frame the data question and scope the exploratory analysis. | Analysis spec + initial EDA. | Hands to `data-engineer`. |
| `data-engineer` | Build the pipeline/dataset the analysis needs. | Reproducible dataset/pipeline. | Hands to `data-scientist`. |
| `data-scientist` | Model or analyze; answer the question quantitatively. | Analysis report / notebook. | Hands to `analytics-reviewer`. |
| `analytics-reviewer` | Validate methodology, leakage, and interpretation. | Review report. | Feeds back to `data-scientist`. |

Chain: `data-analyst -> data-engineer -> data-scientist -> analytics-reviewer`.

### 4.4 `scientific-research` (with `biological-research` sub-domain)

| Role | Mandate | Deliverable | Handoff |
| --- | --- | --- | --- |
| `experimental-designer` | Turn a hypothesis into an experimental design and protocol. | Protocol document. | Hands to `experimentalist`. |
| `experimentalist` | Execute or simulate the protocol; collect data. | Results dataset + methods log. | Hands to `analysis-scientist`. |
| `analysis-scientist` | Analyze results; test the hypothesis statistically. | Findings report. | Hands to `peer-reviewer`. |
| `peer-reviewer` | Critique design, execution, and conclusions. | Peer-review report. | Feeds back to `analysis-scientist`. |

Chain: `experimental-designer -> experimentalist -> analysis-scientist -> peer-reviewer`.

Sub-domain `scientific-research/biological-research/` adds biology-specialized roles that slot into the same chain:

| Role | Mandate | Deliverable |
| --- | --- | --- |
| `assay-designer` | Design wet-lab or in-silico assays for a biological hypothesis. | Assay protocol (a specialized `experimental-designer`). |
| `bioinformatician` | Analyze omics/sequence/compound data; query domain databases. | Bioinformatics findings (a specialized `analysis-scientist`; reaches ChEMBL/ClinicalTrials/PubMed/bioRxiv). |

### 4.5 `business-development`

| Role | Mandate | Deliverable | Handoff |
| --- | --- | --- | --- |
| `market-analyst` | Research a market or opportunity; size and segment it. | Market brief. | Hands to `gtm-strategist`. |
| `gtm-strategist` | Turn the brief into a go-to-market or growth strategy. | GTM/strategy plan. | Hands to `partnerships-rep`. |
| `partnerships-rep` | Produce outreach materials, proposals, and partnership decks. | Proposal / deck / outreach kit. | Terminal. |

Chain: `market-analyst -> gtm-strategist -> partnerships-rep`.

### 4.6 `business-operations`

| Role | Mandate | Deliverable | Handoff |
| --- | --- | --- | --- |
| `ops-analyst` | Analyze an internal process or financial question. | Operations analysis report. | Hands to `finance-analyst` or `process-designer`. |
| `finance-analyst` | Build financial models and reporting. | Financial model / report (reaches QuickBooks/Ramp). | Terminal. |
| `process-designer` | Design a standard operating procedure or workflow. | SOP / workflow document. | Terminal. |

Chain: `ops-analyst -> {finance-analyst | process-designer}`.

### 4.7 `common` (domain-neutral, reused everywhere)

| Role | Mandate | Deliverable | Handoff |
| --- | --- | --- | --- |
| `lead` | Own a large, end-to-end effort as an org: build a crew, sequence phases, roll a single status line up. | Coordinated effort outcome; rolls up crew status. | Spawns and sequences any category's roles. |
| `research` | Produce a cited, adversarially verified evidence report on any topic. | Evidence report. | Terminal (standalone). |

## 5. Directory reorganization

### 5.1 Target layout

Rename `playbook/` to `playbooks/` (plural reads correctly for a library and matches the directive's examples), and nest role files under a category directory:

```
playbooks/
  _status-contract.md                 # shared partial, unchanged location semantics
  common/
    lead.md
    research.md
  software-development/
    software-analyst.md               # renamed from analyst.md
    architect.md
    developer.md
    developer.local.md                # existing local override, moved with its role
    reviewer.md
  ai-research/
    research-analyst.md
    experiment-designer.md
    ml-engineer.md
    research-reviewer.md
  data-science/
    data-analyst.md
    data-engineer.md
    data-scientist.md
    analytics-reviewer.md
  scientific-research/
    experimental-designer.md
    experimentalist.md
    analysis-scientist.md
    peer-reviewer.md
    biological-research/
      assay-designer.md
      bioinformatician.md
  business-development/
    market-analyst.md
    gtm-strategist.md
    partnerships-rep.md
  business-operations/
    ops-analyst.md
    finance-analyst.md
    process-designer.md
```

`_status-contract.md` stays at the `playbooks/` root as a shared partial; its `_` prefix keeps it out of type enumeration, and `spawn-crew` continues to concatenate it onto every system prompt (only its path string changes).

### 5.2 Type resolution with categories

**Contract: flat unique names are primary; a category-qualified form disambiguates.**

- `--type developer` continues to work: the resolver searches all category subdirectories for a role file named `developer`.
  Because role names are unique across categories in the proposed set, every existing and proposed bare name resolves unambiguously.
  This preserves 100% backward compatibility for every current `spawn-crew` call, the `crew-say "/model opus"` conventions, and the command vocabulary in `CLAUDE.md`.

- `--type software-development/developer` is accepted as an explicit fully-qualified form.
  It is required only to break a genuine collision (two categories shipping the same role name).

- **Collision handling.**
  If a bare name matches role files in more than one category, the resolver exits with an error that lists the qualified `category/role` forms and asks the caller to pick one.
  This is deterministic and never silently guesses.
  Design guidance for the library: keep role names unique across categories so the qualified form is rarely needed.

Resolution algorithm (bash 3.2 safe; uses `find`, not `**`):

1. If `$TYPE` contains a `/`, treat it as `category/role`: check `playbooks/$TYPE.local.md` then `playbooks/$TYPE.md`.
2. Otherwise `find playbooks -type f \( -name "$TYPE.md" -o -name "$TYPE.local.md" \)`, excluding basenames beginning with `_`.
   Collapse a `.local.md` over its sibling `.md` in the same directory (local override still wins).
   Zero matches is an unknown-type error; more than one distinct directory is the collision error above; exactly one is the resolved playbook.

### 5.3 `--list-types` with categories

`wm_crew_types()` is rewritten to discover recursively with `find` and to emit **category-qualified names** grouped by category, for example:

```
common/lead
common/research
software-development/architect
software-development/developer
software-development/software-analyst
...
```

- The output stays greppable one-per-line for scripting.
- A grouped, human-friendly rendering (category headers with indented roles) is a presentation nicety layered on top; the machine-readable `category/role` lines are the contract.
- The `_`-prefixed exclusion is preserved (it filters on the file basename, so `_status-contract.md` and any future `_category.md` partials stay hidden).

### 5.4 `.local.md` overrides

Overrides move next to the role they override: `playbooks/<category>/<role>.local.md` (and the sub-domain equivalent).
The existing `playbooks/software-development/developer.local.md` is the first such case.
No `.gitignore` change is needed: the bare `*.local.md` pattern already matches at any depth.
The resolver's local-over-default preference is unchanged; it simply applies per resolved directory.

### 5.5 Migration and backward compatibility

- **Clean cut, one commit.**
  Move all six existing files (`analyst` renamed to `software-analyst`, plus `architect`, `developer`, `developer.local`, `reviewer` into `software-development/`; `lead`, `research` into `common/`) and `_status-contract.md` to the `playbooks/` root in a single change, alongside the resolver update.
  No flat top-level role files remain, so there is no dual-location ambiguity to maintain.

- **Caller compatibility is preserved by the resolver, not by leaving files behind.**
  Every existing invocation uses a bare type name (`--type developer`, `--type architect`, `--type reviewer`, `--type lead`, `--type research`); the recursive-search resolver keeps all of these working unchanged, since those roles keep their names.
  This is the property that makes the flat-unique-name contract worth its slightly more complex resolver: no caller, doc, or memory that says "spawn a developer" has to change.
  The single exception is the deliberately renamed `analyst` (see the operating-docs bullet below): `--type analyst` stops resolving and callers move to `--type software-analyst`.

- **Prose and config references** to `playbook/` update to `playbooks/`: `bin/lib/common.sh` (the glob and any path), `bin/spawn-crew` (the three path joins and the `_status-contract.md` cat), `README.md`, `CLAUDE.md`, and the `.gitignore` comment.
  `CLAUDE.md`'s statement that "a type exists iff its playbook does" stays true; only the location the resolver searches changes.

- **The `analyst` -> `software-analyst` rename touches the operating docs.**
  `CLAUDE.md` and `README.md` use "analyst" both as this role's name and as the generic name of the plan-producing step in the command vocabulary ("spawn an analyst crew member", the `analyst -> developer` handoff).
  Those references update to `software-analyst`.
  Unlike the bare-name resolver compatibility, this is a genuine type rename: any caller or memory that spawns `--type analyst` must move to `--type software-analyst`, so audit for stray references (this repo's docs, playbook cross-references, and any saved `spawn-crew` invocations).

- **Optional transitional alias.**
  If the risk of an out-of-tree caller referencing the old path is a concern, a one-release symlink `playbook -> playbooks` bridges it.
  Recommended only if such callers are known to exist; otherwise omit it to avoid a lingering compatibility shim.

## 6. Testing strategy

The existing suite (`tests/*.test.sh`, driven by `tests/lib.sh` assertions and a stub `WM_AGENT` in an isolated tmux session, per `tests/spawn-scope.test.sh`) is the model.
Add a `tests/playbook-resolution.test.sh` that:

- Resolves a bare unique name to the correct category file (`--type developer` -> `software-development/developer.md`).
- Resolves a category-qualified name (`--type common/lead`).
- Prefers a `.local.md` over its sibling `.md` in the resolved directory.
- Rejects an unknown type with a non-zero exit and a helpful message.
- Errors deterministically on a simulated cross-category name collision, listing the qualified forms (set up by creating two temporary same-named role files in a test fixture).
- Confirms `--list-types` emits category-qualified names and excludes `_`-prefixed partials.
- Confirms `_status-contract.md` is still concatenated onto a spawned member's system prompt from its new path.

Run the full suite to confirm no regression in `spawn-scope`, `owner-scope`, and the other spawn-dependent tests.
Manually spawn one member per new category with the stub agent to confirm each new playbook resolves and launches.

## 7. Open questions

- **Q1. Where do `lead` and `research` live?**
  Recommended: a `common/` category, because both are domain-neutral and should have a single source of truth.
  Alternative (literal reading of the directive): keep them inside `software-development/`.
  This is the one place the design departs from the directive's framing and needs a decision.

- **Q2. Directory rename `playbook/` -> `playbooks/`.**
  Recommended for clarity and to match the directive's examples.
  If minimizing churn is preferred, the entire design works unchanged with the singular `playbook/` retained; only the directory name differs.

- **Q3. `biological-research` as sub-domain vs top-level category.**
  Recommended as a sub-domain now (nested directory), promotable later.
  A decision to make it top-level immediately only changes the directory depth, not the resolver.

- **Q4. Category-level shared partials.**
  A future `playbooks/<category>/_category.md` prepended to every role in a category (mirroring the global `_status-contract.md`) would let a domain share a common preamble.
  Out of scope for this build; flagged as a natural follow-up the `_`-prefix convention already accommodates.

- **Q5. Role-set completeness.**
  The per-category roles here are a starting set sized to cover each discipline's core handoff chain, not an exhaustive org.
  Each category can grow roles the same way software did; the build should treat the listed roles as the v1 shipping set.

## 8. Suggested build order

1. **Resolver and enumeration first, no content move.**
   Update `wm_crew_types()` and `spawn-crew`'s resolution to search recursively (`find`-based) and to accept both bare and `category/role` forms, while the files are still flat.
   With flat files, bare-name search still resolves; this de-risks the mechanism before any file moves.

2. **Add the resolution test** (`tests/playbook-resolution.test.sh`) and get it green against the new resolver.

3. **Move the existing files** into `common/` and `software-development/` (renaming `analyst.md` to `software-analyst.md`), move `_status-contract.md` to the `playbooks/` root, rename `playbook/` -> `playbooks/`, and update all path references plus the `analyst` -> `software-analyst` references in `CLAUDE.md`/`README.md`.
   Run the full suite; fix any path or type-name regressions.

4. **Update `--list-types` output** to category-qualified, grouped form; update the test.

5. **Author the new playbooks**, one category at a time, in this order: `common` (confirm `lead`/`research` behave from their new home), then `ai-research`, `data-science`, `scientific-research` (+ `biological-research`), `business-development`, `business-operations`.
   Each new playbook mirrors the structure and status-contract wiring of the existing software playbooks and states its handoff explicitly.

6. **Update prose docs** (`README.md`, `CLAUDE.md`) to describe categories, the qualified-name form, and the domain-neutral `common` roles.

7. **Manual smoke test**: spawn one member per category with the stub agent; confirm each resolves, launches, and carries the status contract.
