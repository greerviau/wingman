# Plan: an `infrastructure` playbook category for dev-ops / infra-operations work

Date: 2026-07-12
Status: proposed, awaiting review
Author: software-analyst crew member (scope-a-new-playbook-category-fo-software-analyst)

## Problem

Wingman's only categories with a designed handoff are `software-development` (git repo, PR lifecycle) and the domain-neutral `common` types (`research`, `lead`). Neither is scoped for a fundamentally different kind of target: a live remote system reached over SSH (a physical/virtual server, network gear, a hypervisor) rather than a git checkout.

Two crew members were recently run for exactly this kind of work, off-label from playbooks not written for it:

- A `research` (common) crew member investigated a Proxmox host's random-crash reports: SSHed in, ran `journalctl`/`dmesg`/`smartctl`/`ethtool` forensics, and wrote a root-cause report.
- A `reviewer` (software-development) crew member independently verified that diagnosis against external sources (kernel bug trackers, forum threads) and produced a consolidated fix recommendation.

Both delivered useful results, which is why this plan treats `reviewer` as reusable as-is rather than replacing it (see below). But the fit was awkward in ways that matter for repeat use:

- `research.md` is written for "gather evidence, synthesize a report" from documents/web/repo data. It says nothing about a live target: no mention of SSH/access, no distinction between read-only diagnostics and a state-changing action, no guidance on what "ground truth" means when the source is a running machine instead of a corpus. A crew member following it literally would have no playbook basis for the access step it actually had to take (see "Credentials and access" below).
- Neither `research.md` nor any existing type addresses the question this plan is actually about: what happens when the next step isn't "write a report" but "change the live system." `software-development/developer.md`'s entire safety model is built on git + GitHub: isolate in a worktree, open a PR, let CI and a human reviewer gate the merge, and even then `git revert`/`checkout` bounds the blast radius. None of that exists for `ssh host 'systemctl restart X'` or a BIOS/firmware change: there is no repo to isolate work in, no CI gate, no code review before the change takes effect, and often no clean revert.
- `bin/spawn-crew --repo` requires the target to resolve to a git checkout (`git -C "$REPO" rev-parse --git-dir`). An infra crew member's *target* (the Proxmox host) is never a git repo, so the existing repo-scoping only works today because the crew member's *artifact home* (where it writes its markdown report) happens to be some git repo, unrelated to the host it's investigating. This distinction needs to be explicit in the new playbooks or it will keep being rediscovered ad hoc.

This plan proposes the smallest addition that closes those gaps for the two operations already demonstrated - diagnose, and apply a fix - without inventing a speculative catalog of infra roles.

## Proposed category: `infrastructure`

Name follows the existing convention of naming categories after the *domain*, not the practice (`software-development`, `data-science`, `business-operations`, `scientific-research` - all nouns for the target domain, not "devops" or "engineering"). `infrastructure` reads correctly next to those and describes the target (servers, network gear, hypervisors) the same way `software-development` describes its target (a git repo).

Directory: `playbooks/infrastructure/`.

## Recommended minimal starting set: two new types

Mirrors the `software-analyst` → `developer` handoff shape, because the underlying problem shape is the same (investigate/design, then a separate, riskier "make it real" step) - but the second step's safety model is materially different, which is the whole point of this plan.

### 1. `infra-analyst` - investigate and (optionally) propose a fix

Nearest analogue: `software-analyst`. Same dual-mode structure (investigate-only report, or a plan that hands off to the next role), same "explore before deciding, write it to a file" posture. What's different:

- **Target is a live host, not a checkout.** No `--input` diff, no repo to read cold - the ground truth is the running system's current state (`journalctl`, `dmesg`, `smartctl`, `ethtool`, service/process state, config files on the host), gathered by SSHing in. Read-only by construction, exactly like `software-analyst` never edits code: this role runs diagnostics, never a mutating command. If a fix looks trivially obvious mid-investigation, it still writes up the proposal for a separate `infra-operator` engagement rather than applying anything itself - "you judge/diagnose; you do not implement" carries over unchanged from the `software-analyst`/`reviewer` posture.
- **Access is a precondition it checks, not something it provisions.** See "Credentials and access" below - if it cannot reach the target, that is a `blocked`, not something to route around.
- **Two output shapes, same as `software-analyst`:**
  - *Investigate-only* directive → a root-cause report under `docs/analysis/`, terminal at `done` once delivered (same as `research`/`software-analyst` report mode) - no downstream role.
  - *Diagnose-and-propose-a-fix* directive → in addition to the diagnosis, a concrete **remediation proposal**: the exact commands/config changes to run, current-state snapshot, expected post-state, blast radius (services/VMs/users affected, expected downtime, whether a reboot is needed), and an explicit rollback procedure for each step. Written to `docs/plans/` (mirrors `software-analyst`'s plan file), parked in `review` awaiting the requester's approval exactly like a `software-analyst` plan - no watcher, since approval arrives as a `bin/crew-say` message, not an external signal.
- **Handoff:** on approval, the proposal is handed to an `infra-operator` with `--input <proposal-path>`, same mechanic as `software-analyst` → `developer`.

### 2. `infra-operator` - apply an approved fix to a live system

Nearest analogue: `developer`. Same "take an approved plan, see it through to a terminal condition" shape. Everything about *how* it's safe to see through is different, because there is no git/PR/CI substrate to lean on. This is the centerpiece of this plan - see "Safety and confirmation model" below for the full design; summarized here:

1. Reads the approved proposal at `--input`.
2. Runs its own pre-flight checks against the live target (confirms the proposal's assumptions about current state still hold - the system may have changed since the analyst's investigation).
3. Writes/confirms the exact command sequence about to run and **enters `blocked`**, naming the exact action(s), their risk level, and the rollback path - and waits. It does not execute anything mutating until the requester explicitly confirms via `bin/crew-say`.
4. On confirmation, applies the steps one at a time, capturing before/after evidence for each into the same artifact file, stopping immediately (back to `blocked`) if any step's actual outcome doesn't match the proposal's expected outcome.
5. Re-runs the original diagnostic checks (the ones that surfaced the problem) to verify the fix actually resolved the symptom.
6. `done` once verified and the change log is complete - there is no PR to merge, so the completed-and-verified change is this role's terminal condition, exactly as "merged" is `developer`'s.

### Verification role: reuse `reviewer` as-is - no new type

The precedent already shows `software-development/reviewer.md` works unmodified for this: "review a deliverable... report findings... don't fix it" is domain-neutral prose that reads correctly whether the deliverable is a PR, a plan, or (as demonstrated) a diagnosis report checked against kernel bug trackers and forum threads. It needed no infra-specific access, no SSH, no state-changing capability - it verified a *document* against *external sources*, which is exactly its existing job description. Adding an `infra-reviewer` type would duplicate `reviewer.md` almost verbatim for no behavioral gain. If the same `--input <path>` handoff (a diagnosis or a remediation proposal) fits the existing type, use it unchanged.

## Safety and confirmation model (the core design question)

The developer role's safety net is entirely git/GitHub-shaped: worktree isolation bounds blast radius, `git revert`/`checkout` makes almost everything reversible, CI gates merge, and human PR review is a checkpoint *before* the change is authoritative (merge). None of these exist for a command run over SSH against a running host - the "merge" moment and the "the change took effect" moment are the same moment, with no automated or reviewable gate in between.

The proposed model moves the review gate to **before execution**, and makes it an explicit human confirmation rather than an automated one, using the existing crew status contract's `blocked` state exactly as it's defined - "you need a decision or input that only a human can give, and you cannot proceed without it." This is a deliberate, meaningful distinction from `review`:

- `review` (what `developer` uses while its PR is up) means "delivered, watching an external condition I don't control, no action needed from anyone to unblock me" - CI and reviewer feedback arrive on their own schedule, and the loop is designed to absorb that asynchronously.
- `blocked` means "I am stopped and will not proceed without a specific human decision." For `infra-operator`, that decision is "yes, run these exact commands against this host, now." There is no automated substitute for it, so the role must never treat a proposed mutating action as self-approved just because a plan document exists - unlike a developer's PR, which *is* allowed to auto-progress through CI and even auto-merge conventions if the repo has them.

Concrete rules:

1. **Every distinct change requires its own propose → `blocked` → confirm cycle.** Confirming one proposal authorizes only the commands enumerated in *that* proposal - it is not a standing license for the rest of the engagement. If execution reveals the fix needs a different or additional action than what was confirmed, stop and write a fresh proposal; do not improvise on a live system, ever, even to something the operator believes is safe.
2. **Read-only diagnostics never require confirmation.** Pre-flight checks, verification re-checks, and anything the analyst does are unconfirmed by design - the gate exists specifically for state-changing actions, not for looking.
3. **The confirmation request names the risk, not just the action.** "Restart networking service on host X (expected ~2s interruption, no VM impact)" and "apply firmware update to host X (requires reboot, all VMs on this host go down, no live migration configured)" are both `blocked` requests, but the second must say so explicitly so the requester isn't confirming blind. Actions that are hard to reverse or affect running workloads (reboot, firmware/BIOS changes, storage/disk operations, anything touching HA/quorum state, or a network change that could sever the SSH session doing the work) are flagged as high-risk in the same sentence as the ask.
4. **Prefer reversible, staged mechanisms where the target supports them**, and say so in the proposal: a hypervisor snapshot before a risky change, a network "commit-confirm" pattern (auto-rollback if the new config drops the session), a tool's own dry-run/plan mode. Where no such mechanism exists, the proposal says so plainly rather than implying a safety net that isn't there.
5. **Fail-fast during apply.** Steps execute one at a time; the moment an actual result diverges from the proposal's expected result, stop, capture what happened, and return to `blocked` with the updated situation - do not continue down the step list hoping it self-corrects.
6. **The operator's own "verified" is a self-report, not external proof** (same principle the status contract already states for a developer's "CI green" or a reviewer's "approve"): its verification step is running the same diagnostics the analyst used and observing they now look healthy, which is real evidence but is this crew member's own read of the system, not an independent gate. State it as such in the artifact and status summary.

This gives dev-ops work the equivalent rigor of the PR lifecycle - a mandatory checkpoint before an unreviewable action takes effect - without pretending a git-shaped gate exists where it doesn't.

## Credentials and access

In the precedent case, SSH key setup for the target host was done ad hoc, directly in a wingman conversation. That is worth stopping doing, for the same reason wingman avoids doing heavy work itself: it puts credential/access provisioning - a decision with real security weight - inside an orchestration session rather than treating it as a deliberate, auditable, one-time step.

Proposed convention:

- **Access is provisioned once, ahead of any crew spawn, as a human/setup step - never inline in a crew or wingman session.** The expected mechanism is an SSH config alias (`~/.ssh/config` `Host` entry) with a key already deployed/authorized on the target, set up by the requester (or scripted separately, analogous to `bin/doctor`'s onboarding role, but out of scope for this plan).
- **The objective given to an `infra-analyst`/`infra-operator` names the target by its SSH alias/hostname only** - never raw key material or credentials in objective text, conversation, or a written artifact.
- **Reachability is a precondition each role checks for itself at the start of its work**, e.g. a trivial `ssh <alias> true`. If that fails - no alias configured, auth failure, host unreachable - the role goes `blocked` with the exact failure ("cannot SSH to `<alias>`: <error>"), surfacing it up the escalation chain rather than attempting to generate keys, edit `known_hosts`, or otherwise provision access itself.
- This keeps the same shape as the rest of wingman's escalation model: a crew member surfaces what it cannot decide/do unilaterally; a human decides. Provisioning SSH access to a production hypervisor is squarely a decision with security weight, not a routine unblock.

## Artifact home (repo-anchoring)

`bin/spawn-crew --repo` hard-requires the target to be a git checkout (`git -C "$REPO" rev-parse --git-dir`); there is no code change proposed here to relax that; that would be a follow-up. The consequence for this category: **the `--repo` argument names where the crew member's *artifacts* (reports, proposals, change logs) live, never the infrastructure target itself.** The target host is named only in the objective text and any SSH alias, and is unrelated to the git repo the member is spawned "in."

This plan does not designate which repo should hold those artifacts - that is a real open decision (below), not something to default silently. A reasonable option once decided: a lightweight existing or new "ops notes" / runbook repo, so infra reports and remediation proposals accumulate in one place across engagements rather than landing in whichever unrelated repo happened to be handy.

## What this plan does *not* propose

- **No infra-specific `lead` pipeline.** `common/lead.md` is already domain-neutral (its default pipeline is explicitly swappable via `lead.local.md`); neither precedent case needed more than two flat crew members, so wiring an infra pipeline into the lead role is a follow-up if this repeats at that scale, not part of the minimal set now.
- **No infra-specific reviewer type**, per above - reuse `software-development/reviewer.md` unchanged.
- **No tooling/script changes** (`spawn-crew`, `wm-state.py`, the watcher). Everything above is pure playbook content, exactly like every other category addition; the category resolves through the existing `wm_crew_types`/`wm_resolve_playbook` machinery with zero code changes, the same way `ai-research` or `business-operations` did.
- **No access-provisioning helper script** (an `infra-doctor`-style reachability checker). Worth doing eventually, but the analyst/operator's own `ssh <alias> true` precondition check is sufficient for the minimal set and doesn't require new tooling.

## Concrete deliverables (for the follow-up developer engagement)

Not created by this plan - listed here so the implementation step is unambiguous:

1. `playbooks/infrastructure/infra-analyst.md` - per "1. `infra-analyst`" above, following the same structure as `playbooks/software-development/software-analyst.md` (posture, investigate-only mode, handoff contract), adapted for a live-host target and the access precondition.
2. `playbooks/infrastructure/infra-operator.md` - per "2. `infra-operator`" above and the full safety model, following the same structure as `playbooks/software-development/developer.md` (a numbered cycle, then "seeing it through," then a terminal condition), substituting the propose → `blocked`-confirm → apply → verify → `done` lifecycle for the worktree/PR lifecycle.
3. A one-line addition to `README.md`'s categories list (the line currently reading "Several other categories ship too (`ai-research`, `data-science`, `scientific-research`, `business-development`, `business-operations`)") to include `infrastructure`.
4. No changes to `playbooks/_status-contract.md`, `playbooks/common/lead.md`, or `playbooks/software-development/reviewer.md`.

## Testing strategy

Playbooks are prose, not executable code, so "testing" here means dry-running the two roles against a real (or realistic) target before calling the category done:

- Spawn an `infra-analyst` against a real reachable host with a real or seeded issue; confirm it produces a diagnosis report (or plan-mode proposal) without ever running a mutating command, and confirm it goes `blocked` cleanly (not silently working around it) if given an unreachable target.
- Spawn an `infra-operator` with a deliberately simple, low-risk approved proposal (e.g., restart a non-critical service); confirm it stops at `blocked` before executing anything, executes only after an explicit `bin/crew-say` confirmation, and reaches `done` only after its own verification step passes.
- Confirm `bin/spawn-crew --list-types` surfaces both new types once the `.md` files exist, with no code changes required.

## Open questions / risks

1. **Which repo is the artifact home?** This plan deliberately does not decide it (see "Artifact home" above) - needs the requester's call: an existing ops/runbook repo, a new dedicated one, or "decide per engagement."
2. **Naming: `infrastructure` vs. an alternative.** `devops`/`infra-ops` were considered and set aside in favor of matching the existing domain-noun convention; flag if the requester prefers a different name.
3. **Role naming: `infra-operator` vs. alternatives** (`infra-engineer`, `ops-engineer`). `infra-operator` was chosen to connote "acts on production infrastructure," distinct from `developer`'s "writes code," but this is a naming call the requester may want to weigh in on.
4. **Escalation chain for `blocked` on a live system.** The status contract already routes `blocked` up to the owner/pilot; for `infra-operator` specifically, that means a human is in the loop for every mutating action by design (per the safety model) - worth the requester explicitly confirming this is the intended cost/friction tradeoff versus, e.g., a pre-approved allowlist of low-risk actions (an idea intentionally not adopted here, to keep the model uniform and simple rather than introduce a second, weaker gate).
5. **Multi-host/fleet-wide changes** (the same fix across many hosts) are out of scope for this minimal set; the two demonstrated operations were both single-host. If that need arises, it's a natural `infra-operator` extension (or a `lead`-orchestrated fan-out) to design later rather than now.
