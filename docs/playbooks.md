# Playbooks and local overrides

How crew types are defined - plain-prose playbooks under `playbooks/`, grouped by category, with gitignored local overrides.
Part of the [architecture reference](architecture.md); for a quick tour see the [README](../README.md#playbooks-customize-the-crew).

A crew type is defined entirely by a playbook - plain prose in `playbooks/<category>/`:

- `playbooks/software-development/software-analyst.md` - gather requirements and turn a problem into a plan (or, in report mode, an investigation report).
- `playbooks/software-development/architect.md` - turn an approved spec into a detailed technical design / implementation plan.
- `playbooks/software-development/developer.md` - a purpose prompt: implement the assigned work and see it through to delivery, following the project's/human's own development workflow (the shared `_delivery.md` fragment carries only what coordination needs plus a default git/PR flow used when the environment defines none).
- `playbooks/software-development/reviewer.md` - review a plan or a PR and report findings; its verdict travels over wingman's own channel by default, with GitHub-native review posting opt-in via `pr_comments`.
- `playbooks/common/lead.md` - manage an effort end-to-end: decompose it, hire and sequence its own crew, integrate, and roll one status line up. Domain-neutral, so it lives outside any one category.
- `playbooks/common/research.md` - example non-dev type: gather evidence, write a cited report. Also domain-neutral.
  Shows the shape a `scientist`/`pm` role takes.

Five further categories ship alongside `software-development`, each a domain-specific pipeline of roles: `ai-research` (research-analyst → experiment-designer → ml-engineer → research-reviewer), `data-science` (data-analyst → data-engineer → data-scientist → analytics-reviewer), `scientific-research` (experimental-designer → experimentalist → analysis-scientist → peer-reviewer, with a nested `biological-research` sub-domain: assay-designer, bioinformatician), `business-development` (market-analyst → gtm-strategist → partnerships-rep), and `business-operations` (ops-analyst → finance-analyst / process-designer).
A role name is unique across every category, so a bare `--type` (e.g. `developer`) always resolves unambiguously; a category-qualified name (`software-development/developer`) is available to break a future collision.

There is no hardcoded list of types; a type exists iff its playbook does.
`bin/spawn-crew --list-types` enumerates them, grouped by category.

`playbooks/<category>/<type>.local.md` overrides the tracked `<type>.md` when present.
`*.local.md` is gitignored, following the same pattern as Claude Code's `settings.json` / `settings.local.json`: customizations and private crew types can't be accidentally committed and survive `git pull` of new defaults.
Example: to make the software-analyst crew follow your own planning skill or checklist, write `playbooks/software-development/software-analyst.local.md` saying so.

Project-discovery hints follow the same story: an optional gitignored `config.local.sh` in this repo can set extra roots, pinned paths, or an ignore list (`WM_ROOTS`, `WM_PINS` as newline `name|path` entries, `WM_IGNORE`).
It is absent by default; the defaults cover the common case.

The state model every playbook reports through - `working`/`blocked`/`review`/`done` and the wake-loop mechanics - is defined once in the shared status contract (`playbooks/_status-contract.md`), appended to every crew brief, so a playbook describes only the work. See [the deliverable lifecycle](architecture.md#the-deliverable-lifecycle-and-review).
