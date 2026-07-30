# Mechanically exclude wingman's root CLAUDE.md from every crew session

Fixes [#213](https://github.com/greerviau/wingman/issues/213).

## Problem

A crew session spawned by `bin/spawn-crew` must never have wingman's own root `CLAUDE.md` in its context: that file is the first-person operating manual for the top-level orchestrator session, not for a delegate doing work in a target repo. Today the only defense is a prose disclaimer (`bin/spawn-crew:333-335`, added for #69) telling a crew member to disregard the file if it sees it — a mitigation an agent can ignore or misread, not a guarantee.

The disclaimer is gated on `TARGET_IS_WM_REPO` (`bin/spawn-crew:167-168`): true only when scope is `repo` and the resolved target *is* the wingman repo's own root. That gating was believed to bound the hazard to exactly one spawn shape. It does not.

## Grounding

### Before: the hazard is real, and broader than previously believed

Three live probes (run directly by the requester, not delegated) already established:

1. `--scope global` (primary cwd = workspace root, wingman a subdirectory): the marker phrase was **absent** when the probe reported on its own context without touching any file inside the wingman subdirectory.
2. `--repo <unrelated-repo>` (wingman present only via the unconditional `--add-dir "$WM_REPO"` at `bin/spawn-crew:425`): **absent**. This refuted "any `--add-dir` loads CLAUDE.md" as a general hypothesis.
3. `--repo <wingman-repo-path>` (primary cwd = the wingman repo itself): **present**, verbatim, under a `# claudeMd` system-reminder naming the file path — the confirmed, original leak.

This analyst's own session (`--scope global`, primary cwd = workspace root) reproduced a **fourth, previously-uncaught case** live and unprompted, during ordinary research for this plan: reading `bin/spawn-crew` (a file physically inside the wingman repo, which sits as an ordinary subdirectory of this session's own primary cwd) triggered an automatic, full load of `/home/greer/github/wingman/CLAUDE.md` into this session's own context, delivered as the identical `Contents of ... CLAUDE.md (project instructions, checked into the codebase):` block. No crew was spawned to produce this — it is this analyst's own transcript, mid-task.

This matters because it shows probe 1's "absent" result depended on the probe never touching a file inside the wingman subdirectory — it did not prove `--scope global` is safe for the case that matters most: **a crew member whose actual job is to work on wingman's own files** (exactly what every crew member on this effort, including this one, does). "Ground the crew elsewhere" does not help once the crew's legitimate work requires reading or editing files inside the wingman tree.

### Mechanism (confirmed against the official docs and reproduced directly)

Per `code.claude.com/docs/en/memory.md` ("How CLAUDE.md files load"):

- **Ancestor walk at launch**: Claude Code loads `CLAUDE.md`/`CLAUDE.local.md` from the primary cwd and every parent directory, unconditionally, at session start. This is the mechanism behind probe 3 (`--repo <wingman>`: primary cwd *is* the wingman repo root).
- **On-demand subdirectory load**: "Claude also discovers CLAUDE.md and CLAUDE.local.md files in subdirectories under your current working directory... they are included when Claude reads files in those subdirectories." This is the mechanism behind this analyst's own fourth case: primary cwd is the workspace root, wingman is a subdirectory of it, and reading a file inside that subdirectory pulled in its `CLAUDE.md` on demand.
- **`--add-dir` directories are excluded by default**: "By default, CLAUDE.md files from these directories are not loaded," unless the environment variable `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` is set (it is not, anywhere in this project). This is why probe 2 (`--repo <unrelated>`, wingman only via `--add-dir`) came back absent, and it stays absent regardless of this fix.

So the real hazard surface is: **any session whose primary cwd is, or has as an ordinary subdirectory, the wingman repo root, will auto-load wingman's root `CLAUDE.md` the moment any tool call touches a path inside that repo** — regardless of `--scope`. Global scope's primary cwd is the workspace root specifically *because* it is the parent of every discovered repo (`bin/discover-projects --roots`), so this is not a corner case: it is the common case for a `--scope global` spawn whenever the objective is wingman-focused work, which is routine (this effort's own crew, ordinary "fix a wingman bug" work, etc.).

### Verifying the fix mechanism directly (not via a wingman crew spawn)

Rather than rely solely on synthesized docs research, this analyst reproduced both leak shapes and the fix directly with plain `claude -p` invocations against a disposable scratch directory (no `bin/spawn-crew`, no wingman crew spawned):

| Setup | Result |
| --- | --- |
| cwd = workspace root; subdirectory `subrepo/CLAUDE.md` contains a marker phrase; asked to read a file inside `subrepo/` | marker phrase **present** in context (reproduces this analyst's own global-scope leak) |
| Same, with `claude -p --settings '{"claudeMdExcludes":["<abs-path>/subrepo/CLAUDE.md"]}'` | marker phrase **absent** |
| cwd = the directory containing `CLAUDE.md` directly (no file read needed) | marker phrase **present** at session start (reproduces the `--repo <wingman>` leak) |
| Same, with the matching `claudeMdExcludes` entry | marker phrase **absent** |

Both leak shapes reproduce on demand, and `claudeMdExcludes` mechanically suppresses both.

### A fifth leak shape, found on review: the crew's own worktree copy — and where it actually lives

A peer review of this plan (`docs/analysis/2026-07-30-review-mechanical-claude-md-crew-exclusion-plan.md`) identified a gap the original draft missed: **every software-development crew member works its entire session inside its own git worktree, not the shared checkout**, and that worktree holds a byte-identical copy of `CLAUDE.md` at a path none of the original four patterns match.

`bin/spawn-crew:302` computes `WORKTREE="$(dirname "$REPO")/$(basename "$REPO")-$ID"` — for a repo-scope spawn targeting wingman, e.g. `/home/greer/github/wingman-<crew-id>`, a **sibling** of `$WM_REPO`, not a path under it. `playbooks/_delivery.md:33` then has the member `git worktree add "$WINGMAN_WORKTREE" ...` and do all of its work there. `git worktree add` checks out a real copy of every tracked file, including `CLAUDE.md`, into that sibling directory.

A first pass at this finding (reasoning from a decompiled fragment of the on-demand loader, and reproduced against a scratch-directory fixture that didn't distinguish spawn shapes) concluded the leak reaches both repo scope and global scope, via an unanchored string-prefix match. **A second round of review, and this analyst's own independent re-reproduction with a real git repo and a real `git worktree add`, found that conclusion backwards for repo scope.** The primary cwd is what actually matters, and the two scopes put it in very different places relative to the worktree:

- **Repo scope**: the session's primary cwd is `$REPO` itself (the shared checkout) — `bin/spawn-crew`'s generated launch script `cd`s there and never elsewhere; the worktree is a **sibling** of that cwd, not a path under it. The on-demand loader only reaches subdirectories *of* the primary cwd, so it never finds the worktree's `CLAUDE.md` at all — with or without any exclusion. Only the root copy loads there, via the ancestor walk, which the original four root-anchored patterns already handled.
- **Global scope**: the session's primary cwd is the workspace root, and *both* `$WM_REPO` and its worktree sibling are true subdirectories of that root. The on-demand loader reaches both, so the worktree copy genuinely leaks there — and only the `repo-*` glob closes it.

Reproduced directly, on a real git repo with `git worktree add`, with **distinct** markers in the root and worktree copies so the two are unambiguously distinguishable, and the session actually reading a file inside the worktree in each case:

| cwd (spawn shape) | exclusion | which `CLAUDE.md` loaded |
| --- | --- | --- |
| the repo itself (**repo scope**) | none | root only |
| the repo itself (**repo scope**) | root patterns only | none |
| the repo itself (**repo scope**) | root + `repo-*` glob | none |
| the shared parent (**global scope**) | none | **worktree** |
| the shared parent (**global scope**) | root patterns only | **worktree — leak stands** |
| the shared parent (**global scope**) | root + `repo-*` glob | none — glob closes it |

So: **the worktree leak is a global-scope-only phenomenon.** Repo scope was never exposed through its worktree in the first place — there was nothing there for the original four patterns to miss. The `repo-*` glob is still correct and necessary (it is what closes the one shape that does leak), but the reason to keep it is narrower and more specific than the original draft claimed.

**This sharpens rather than shrinks the concern, because global scope is exactly where the hazard is hardest to close.** `bin/spawn-crew:302` gates `WORKTREE` on `[ "$SCOPE" = repo ]`, so a global-scope member never receives a pre-computed `$WINGMAN_WORKTREE`; `playbooks/_delivery.md:37` tells it to "pick a path yourself" instead. The worktree-naming glob covers a global-scope member that happens to follow the same `<repo>-<id>` convention repo scope uses, but not one that names its worktree some other way — and this is not a marginal corner left over after an otherwise-complete fix, it is the entire worktree story for the one scope where the worktree risk exists at all.

Given that, this plan now takes a stronger position than round 1's: rather than only documenting the residual, `playbooks/_delivery.md`'s existing "pick a path yourself" guidance (line 37) gains one clause naming the convention explicitly and why it matters — "...and, if the target happens to be the wingman repo, name it `<repo-path>-<crew-id>` so it stays covered by wingman's own `CLAUDE.md` exclusion (see this plan)." This is a documented convention, not a mechanical guarantee — a member can still deviate, the same way it could disregard the disclaimer itself — but it is a meaningfully more reliable ask than the disclaimer: following a naming template for a path the member was already about to create is a low-stakes, low-friction instruction with no competing pressure, unlike asking an agent to disregard a first-person document it is actively reading. A fully mechanical close (e.g. a guard hook validating `git worktree add` paths against the convention) is a real option but a materially bigger piece of machinery than this fix's scope, would need to distinguish wingman-targeted worktrees from a global-scope member's legitimate worktree in some unrelated repo, and is better left as a named follow-up than folded into this plan.

**The honest statement of the guarantee, after this correction:** mechanical and complete for a repo-scope spawn (the root copy is excluded, and the worktree was never reachable there to begin with); mechanical for the root copy under global scope; and best-effort — now backed by an explicit, motivated naming convention rather than silence — for a global-scope member's self-chosen worktree path specifically, which is the one place this plan cannot make the guarantee airtight without materially more machinery than is warranted here.

### A sixth finding, also from review: the exclusion is lost after a session's first process — at three sites, not one

`--settings` is a per-invocation flag. The original draft applied it only inside the generated `.launch.sh` — the command that starts a crew member's *first* process. A crew session's agent command line is constructed or printed in three places across this repo (confirmed by an exhaustive grep across the whole tree, not only `bin/`, for every `$WM_AGENT`/hardcoded-`claude` exec site and every literal example command a human might copy-paste — no fourth site exists). Two sites correctly stay outside this: `bin/wingman:45` (the orchestrator's own launch, below) and `bin/spawn-crew:236`'s workspace-trust refusal message ("Run `claude` there once, interactively, and accept the trust dialog") — that one tells the human to run the *target* repo's own interactive session, which when the target is wingman is exactly the orchestrator shape that must load `CLAUDE.md`, so it is considered and excluded, not missed.

1. `bin/spawn-crew:402` — the first-launch site. Already covered.
2. `bin/crew-takeover:38–39` — prints a resume command for a *human* to run by hand, for a member whose window has died. Two lines, both without `--settings`: line 38 is a `<your-agent-cli>` placeholder form; line 39 is the concrete, copy-pasteable `claude --resume $SID` example — the one actually likely to get pasted.
3. `bin/crew-resume:206–259` — writes `<id>.resume.sh` and `exec`s it **unattended**, restoring the member's original cwd first. No `--settings` anywhere in the generated script.

Two rounds of review found this class of gap incrementally: round 2 found site 2's line 38; round 3 found that line 39 (same site) was still open, and that site 3 was missing from the plan entirely. `bin/wingman:45` (the orchestrator's own launch) is the one site correctly and deliberately excluded — it must *not* carry the exclusion, per this plan's whole premise.

Reproduced directly at the level of the underlying mechanism both remaining sites share (not by literally invoking `bin/crew-resume` or `bin/crew-takeover`'s own generated scripts, but the identical `claude --resume` pattern each of them currently emits): an initial `claude -p --session-id <sid> --settings '<payload>'` session answered `NONE`; resuming that identical session id with `claude -p --resume <sid>` (no `--settings`) reloaded the root `CLAUDE.md` and answered with its contents — the session explicitly retracted its earlier clean answer once it did. Resuming *with* `--settings '<payload>'` was also verified to genuinely suppress the reload, confirming the remedy itself works, not merely that the hole exists.

Site 3 is the more serious of the two, for reasons independent of mechanism:

- **It is unattended.** `bin/crew-takeover` only prints a command; a human chooses whether to run it. `bin/crew-resume` relaunches sessions itself and flips them back to `working` with nobody in the loop.
- **It is the documented, pre-authorized default remedy for the most common mass failure.** `docs/fleet-resilience.md` calls `bin/crew-resume` "the bulk recovery tool a mass-death bullet names as its default remedy," and `docs/runbooks/incidents.md` (mirrored in `bin/watch-fleet`'s own wake-file text) makes `bin/crew-resume --all-died` the one case that runs "immediately, without asking the pilot first" after an `outage-cleared` fire. A single tmux/host crash routes every currently-`died` crew member through this exact path at once, unattended.
- **A `.launch.sh`-only test would not catch it.** `.resume.sh` is a distinct artifact, written by a distinct script.

This class of miss has a direct precedent in this codebase: `docs/plans/2026-07-13-onboarding-preferences-hook-enforcement.md` records `bin/spawn-crew` exporting an environment variable a guard needed while `bin/crew-resume` did not — the same "second script that constructs a launch line is easy to forget" shape, found and fixed there. `bin/crew-resume` is a known blind spot for this class of change.

The fix for both remaining sites is addressed directly below — the shared `wm_claude_md_excludes()` helper, now used by `bin/spawn-crew`, `bin/crew-takeover` (both printed lines), and `bin/crew-resume` — not merely disclosed as a residual, unlike the global-scope worktree-naming gap above: all three carry a clean, fully mechanical remedy at low cost, so there is no reason to settle for documenting any of them instead.

## Evaluating the three candidate directions

**(a) Split the orchestrator persona out of root `CLAUDE.md`.** Rejected as unnecessary extra engineering. This would require moving persona content to a new file and leaving root `CLAUDE.md` either absent or a harmless stub — but per the docs, `README.md:31` documents *two* equally-supported ways to start the orchestrator ("`bin/wingman` recommended; plain `claude` also works"), and both must keep loading the persona with **zero extra flags**, per the constraint that the orchestrator's own launch must keep working exactly as today. The only way to keep a bare `claude` invocation auto-loading a relocated persona is an `@import` stub left at `CLAUDE.md` — which would *itself* still need to be kept off a crew session's plate (a "see docs/orchestrator-persona.md" stub read by a crew member is still a plausible source of confusion), meaning we'd need the exclusion mechanism from (c) anyway. Since (c) alone fully closes the hazard without touching `CLAUDE.md`'s content, format, or either orchestrator launch path, (a) adds a real refactor for no additional safety margin.

**(b) Ground crew elsewhere, with repo access granted a different way.** Rejected as insufficient for the case that matters. A crew member fixing a wingman issue must read and edit files inside the wingman tree — that is the entire reason `bin/spawn-crew` unconditionally adds `--add-dir "$WM_REPO"` for every spawn. On-demand CLAUDE.md discovery fires on the touched file's own path proximity to a loaded root, not on how the session was grounded; this analyst's own global-scope session proves grounding elsewhere does not prevent the leak once the crew's legitimate work requires touching the repo's own files. This direction only stays true for crew work that never touches wingman's own tree (e.g. an unrelated repo), which is already safe today (probe 2) and is not what this issue is about.

**(c) A genuine harness-level exclusion.** Confirmed to exist: `claudeMdExcludes` (`docs/en/memory.md#exclude-specific-claude-md-files`), settable per-invocation via `--settings '<json>'`. Scoped narrowly to memory-file loading only — it does not touch hooks, permissions, LSP, skills, plugins, or MCP servers, unlike the much blunter `--bare`/`--safe-mode` (which the CLI's own `--help` and docs position as troubleshooting tools, and which would strip every crew guard hook along with CLAUDE.md). It carries no `min-version` annotation in the docs (unlike the neighboring `--setting-sources`/project-rules carve-out, explicitly versioned at 2.1.211+), suggesting it is a long-standing, stable setting rather than a recent addition. **This is the recommended fix.**

### Rejected: `--setting-sources`

`--setting-sources user,local` (excluding `project`) does suppress `CLAUDE.md` loading — confirmed directly: `claude -p --setting-sources user,local` against a fixture that otherwise leaks a marker phrase returns `NONE`. In the installed 2.1.220 build, both the launch-time ancestor walk and the on-demand subtree loader are gated on whether `project` is among the enabled setting sources, so this is a real, working control, not a misreading.

It is rejected on blast radius, not on effectiveness: excluding the `project` settings source for a crew spawn would also drop wingman's own project-level `.claude/settings.json` entries (`hooks/pilot-preferences-guard.sh`, `hooks/stop-guard.sh`, `hooks/pilot-preferences-nudge.sh`, `hooks/pilot-preferences-ask-tracker.sh` — all registered in the checked-in `.claude/settings.json`) for any spawn where those happen to be in scope, and — the more general problem — would suppress the **target** repo's own legitimate project `CLAUDE.md` right alongside wingman's, for every crew member in every repo, not only the ones touching wingman. `claudeMdExcludes` gets the identical result (wingman's `CLAUDE.md` never loads for a crew session) while touching nothing else: no other project's `CLAUDE.md`, no hooks, no settings layer beyond the one glob list — `--settings` is documented as loading *additional* settings, so it adds a layer rather than replacing one.

## Recommended approach

Add a `claudeMdExcludes` entry, scoped to wingman's own repo root, to every `bin/spawn-crew` launch — unconditionally, for both `--scope global` and `--scope repo` regardless of target — via the `--settings` flag. This requires **no change to `CLAUDE.md`'s content, `bin/wingman`, or either orchestrator launch path.** The orchestrator (`bin/wingman` or bare `claude`, run from the wingman repo root) is untouched by this change and keeps loading its own root `CLAUDE.md` exactly as it does today, because the exclusion is only ever added to a *crew* member's generated launch command, never to the orchestrator's own.

Applying it unconditionally (not gated on `TARGET_IS_WM_REPO`) is deliberate: it is what closes the global-scope leak and the global-scope worktree leak alike, costs nothing when the excluded paths don't exist under the crew's actual target (an unrelated `--repo`), and removes any need to keep this new mechanism's conditional in sync with `TARGET_IS_WM_REPO`'s own. The identical payload is also emitted at the other two places a crew session's command line is constructed — both of `bin/crew-takeover`'s printed resume commands, and `bin/crew-resume`'s unattended relaunch script (see the three "Exact change" subsections below) — so the guarantee holds across a crew member's full lifecycle, not only its first process.

The existing prose disclaimer (`bin/spawn-crew:333-335`, `TARGET_IS_WM_REPO`-gated) stays exactly as it is in substance, per the requester's own constraint that it remain — but its wording needs one correction, caught on a second round of review. It opens: *"the file `CLAUDE.md` at this repo's root, **which your harness just loaded automatically as project context**, is written entirely in first person..."* After this fix, in the normal case, the harness did **not** just load it — that clause is now true only when the mechanical exclusion has already failed, which inverts the sentence's reliability exactly backwards from what a disclaimer needs. The constraint is that the disclaimer stay in place, not that its wording be frozen; reword the opening clause so it holds in both states:

> "the file `CLAUDE.md` at this repo's root — if it is anywhere in your context, whether your harness loaded it automatically or you opened it yourself — is written entirely in first person for the **wingman orchestrator** role..."

This is true whether the exclusion is working (the file is simply absent, and the sentence's premise doesn't fire), has failed (the harness did load it automatically), or the member opened it deliberately (per the next paragraph) — no case makes the sentence assert something false.

`claudeMdExcludes` is checked only inside the memory loader, never inside the `Read` tool, so it does not block a crew member from opening `CLAUDE.md` on purpose if it has some reason to — the disclaimer's own framing ("treat CLAUDE.md only as optional background reading... useful if it helps your actual task") stays true after this change; the fix removes the automatic, unrequested load, not the file's availability to a deliberate read.

### File layout: before / after

No existing file is renamed or removed, and only one file is genuinely new (the test). Four existing scripts change behaviorally (`bin/spawn-crew`, `bin/crew-takeover`, `bin/crew-resume`, and `bin/lib/common.sh` gains one small helper), one existing test file and one existing playbook fragment each gain additions, and two doc files gain a short note.

| File | Change |
| --- | --- |
| `bin/lib/common.sh` | New `wm_claude_md_excludes()` helper: the one place the exclusion JSON payload is computed, so `bin/spawn-crew`, `bin/crew-takeover`, and `bin/crew-resume` can never drift apart from each other. |
| `bin/spawn-crew` | Emits `--settings '<json>'` (from the shared helper) in the generated launch script, for every spawn. The line 333–335 disclaimer's opening clause is reworded per should-fix C above; its substance and `TARGET_IS_WM_REPO` gating are unchanged. |
| `bin/crew-takeover` | **Both** printed resume-command forms in the "no live window" branch (the `<your-agent-cli>` placeholder at line 38, and the concrete `claude --resume $SID` example at line 39) gain the same `--settings '<json>'`, so neither is the unpatched one a human might paste. |
| `bin/crew-resume` | The generated `.resume.sh`'s `exec` line gains the same `--settings '<json>'`, alongside its existing `--add-dir` lines — closing the unattended, pre-authorized bulk-recovery path, not only the two human-facing ones. |
| `CLAUDE.md` | **Unchanged.** |
| `bin/wingman` | **Unchanged** — the one launch site that must never carry this exclusion. |
| `playbooks/_delivery.md` | One clause added to the existing "pick a path yourself" line (37) naming the `<repo-path>-<crew-id>` worktree-naming convention for a global-scope member, so the exclusion glob covers it when the target is wingman. |
| `tests/spawn-crew-claude-md-exclude.test.sh` | **New.** Static E2E check (stub agent, no real `claude`) asserting the generated `.launch.sh` contains the exclusion (root and worktree-glob patterns) for a `--repo <wingman>` spawn, a `--repo <unrelated>` spawn, and a `--scope global` spawn, and that `bin/crew-takeover`'s printed output carries the exclusion in *both* resume-command forms. |
| `tests/crew-resume.test.sh` | Extended (it already asserts the generated `.resume.sh`'s contents) with an assertion that the exclusion payload is present there too — the regression guard for the third site, in the test file that already owns that artifact rather than duplicated into the new one. |
| `docs/configuration.md` | "Spawning crew (the recipe)" section gains one sentence noting the mechanical exclusion, alongside the existing flag-semantics description. |
| `docs/guards.md` | A new short bullet under "## Mechanical guards" cross-referencing this exclusion as the mechanical counterpart to the #69 disclaimer — `docs/guards.md` mentions `CLAUDE.md` only once today, in passing, so there is no existing discussion to place this near. |

### Exact change: a shared helper in `bin/lib/common.sh`

Round 2 and round 3's findings together establish that a crew session's agent command line is built or printed at **three** independent sites (an exhaustive whole-repo grep confirms no fourth exists — see "A sixth finding" above). Rather than duplicate the JSON construction three times, add one function to `bin/lib/common.sh`, sourced by all three, so `bin/spawn-crew`, `bin/crew-takeover`, and `bin/crew-resume` can never drift apart from each other — near `quote()` (`bin/lib/common.sh:171-173`) is a natural spot:

```bash
# The claudeMdExcludes payload every crew launch, every printed resume
# command, and every unattended relaunch must carry so wingman's own root
# CLAUDE.md never loads for anyone but the orchestrator (issue #213). A pure
# function of $WM_REPO, so it needs no crew id or objective - one source of
# truth for bin/spawn-crew's generated launch script, bin/crew-takeover's two
# printed --resume commands, and bin/crew-resume's generated relaunch script
# alike (all three source this file already; bin/wingman's own launch is the
# one site that must NOT call this).
# Excludes the repo root's own memory/rules files, and the same set again
# under a $WM_REPO-* glob for a crew member's own worktree checkout (git
# worktree add copies CLAUDE.md verbatim into that sibling directory; the
# on-demand loader only reaches it when the sibling is itself a subdirectory
# of the session's primary cwd - true for a global-scope spawn, never true
# for a repo-scope one, whose primary cwd is $REPO exactly. See
# docs/plans/2026-07-30-mechanical-claude-md-crew-exclusion.md for the full
# grounding). claudeMdExcludes (confirmed in the shipped 2.1.220 settings
# schema, not only in docs) is the one version-stable, memory-file-only
# opt-out - unlike --bare/--safe-mode it never touches hooks, LSP, skills, or
# plugins, and unlike --setting-sources (which also works, but drops
# wingman's own project-level hooks AND every target repo's own legitimate
# CLAUDE.md) it touches only the files named here.
wm_claude_md_excludes() {
  printf '{"claudeMdExcludes":["%s/CLAUDE.md","%s/CLAUDE.local.md","%s/.claude/CLAUDE.md","%s/.claude/rules/**","%s-*/CLAUDE.md","%s-*/CLAUDE.local.md","%s-*/.claude/CLAUDE.md","%s-*/.claude/rules/**"]}' \
    "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO" "$WM_REPO"
}
```

### Exact change to `bin/spawn-crew`

In the launch-script generation block, add one line immediately after the existing `--add-dir "$WM_REPO"` line (`bin/spawn-crew:425`):

```bash
  printf ' --add-dir %s' "$(quote "$WM_REPO")"
  printf ' --settings %s' "$(quote "$(wm_claude_md_excludes)")"
```

No other line in `bin/spawn-crew` changes, beyond the disclaimer's opening clause (should-fix C, above). `quote()` already single-quote-escapes safely for embedding a JSON string containing double quotes into the generated launch script, matching every other flag in this block.

### Exact change to `bin/crew-takeover`

The exclusion must not be lost on `--resume` — and this script prints **two** resume-command forms in its "no live window" branch, both currently exclusion-free, only one of which round 2's revision caught. Line 38 is a `<your-agent-cli>` placeholder the human must edit before running; line 39 is the concrete, already-runnable `claude --resume $SID` example — the one actually likely to get pasted. Patching only line 38 (round 2's mistake) leaves the more copyable command unfixed.

Reproduced directly: a session launched with the exclusion answers cleanly, and the identical session id resumed without it reloads the root `CLAUDE.md`, in both forms. Since takeover is the documented recovery path for a `died` member (`CLAUDE.md`'s own "Survival & reconciliation" section), and that member then keeps working autonomously with whatever the resume command attached, this closes a real hole rather than one worth only disclosing.

Add the same payload to **both** printed lines. The illustrative form (line 39) drops its own stylistic single quotes around the example command rather than nesting them with `quote()`'s real shell-quoting around the JSON payload — keeping both would render as a visually broken `}'' - resume is...` where the payload's closing quote abuts the sentence's own (confirmed by rendering it); dropping the now-redundant stylistic pair leaves `quote()`'s single quotes as the only ones present, with an unambiguous boundary:

```bash
  wm_warn "'$ID' has no live window (it may have finished or died)."
  wm_info "If you want to resume it yourself, from its repo:"
  printf '\n    cd %s && <your-agent-cli> --resume %s --settings %s\n\n' \
    "$(quote "$REPO")" "$SID" "$(quote "$(wm_claude_md_excludes)")"
  echo "(e.g. with Claude Code: claude --resume $SID --settings $(quote "$(wm_claude_md_excludes)") - resume is refused if the session is still live.)"
```

Applied unconditionally, exactly like `bin/spawn-crew`'s own — this script already prints resume commands for *any* crew member, not only ones grounded near wingman, and the payload is a no-op when the excluded paths don't exist under that member's actual target. This section of the script is already documented as agent-CLI-specific ("resume is shown only as a recovery path for a *dead* window and is agent-CLI-specific"), so baking a Claude-Code-specific flag directly into both printed commands is consistent with what it already does, not a new precedent.

### Exact change to `bin/crew-resume`

The **unattended** bulk-recovery path, and the more consequential of the two remaining sites: `bin/crew-resume` relaunches a `died` member itself, with nobody choosing to run it in the moment — including via `bin/crew-resume --all-died`, the one action `CLAUDE.md`'s own standing instruction pre-authorizes to run "immediately, without asking the pilot first" the moment an `outage-cleared` fire names outage-tagged deaths (`docs/fleet-resilience.md`, `docs/runbooks/incidents.md`). A single tmux or host crash can route every currently-`died` crew member through this path at once.

`bin/crew-resume` already sources `bin/lib/common.sh` (so `wm_claude_md_excludes()` and `quote()` are already in scope) and already restores the member's original cwd before exec'ing (`bin/crew-resume:185-186, 210`) — for a repo-scope wingman member, that cwd *is* `$WM_REPO`, the exact launch-time ancestor-walk shape that is this issue's original confirmed leak. Add one line alongside the existing `--add-dir` lines in the generated resume script (`bin/crew-resume:253-254`):

```bash
    printf ' --add-dir %s' "$(quote "$WM_HOME")"
    printf ' --add-dir %s' "$(quote "$_repo")"
    printf ' --settings %s' "$(quote "$(wm_claude_md_excludes)")"
```

Applied unconditionally, matching the other two sites — the payload is a no-op for a resumed member whose repo has nothing at the excluded paths.

### Exact change to `playbooks/_delivery.md`

One clause added to the existing global-scope guidance (line 37):

```markdown
If `$WINGMAN_WORKTREE` is unset (a global-scope session), pick a path yourself and register it (see above) - if the target happens to be the wingman repo itself, name it `<repo-path>-<crew-id>` (the same convention repo scope uses) so it stays covered by wingman's own CLAUDE.md exclusion (`bin/spawn-crew`, issue #213).
```

This does not make the global-scope worktree case fully mechanical — see "A fifth leak shape" above for why that would need materially more machinery than this fix's scope warrants — but it upgrades the residual from an undocumented gap to an explicit, motivated convention, which is a meaningfully more reliable ask than the disclaimer it sits alongside.

## Implementation steps

1. Add `wm_claude_md_excludes()` to `bin/lib/common.sh`, exactly as above.
2. Change `bin/spawn-crew` to emit `--settings "$(wm_claude_md_excludes)"` in the generated launch script, and reword the `TARGET_IS_WM_REPO` disclaimer's opening clause (should-fix C, above) — its substance and gating stay exactly as they are.
3. Change `bin/crew-takeover`'s "no live window" branch to append `--settings "$(wm_claude_md_excludes)"` to **both** printed resume-command forms (line 38's placeholder and line 39's concrete example).
4. Change `bin/crew-resume`'s generated `.resume.sh` to add `--settings "$(wm_claude_md_excludes)"` alongside its existing `--add-dir` lines.
5. Add the one clause to `playbooks/_delivery.md:37`'s existing "pick a path yourself" guidance, naming the `<repo-path>-<crew-id>` worktree convention.
6. Add `tests/spawn-crew-claude-md-exclude.test.sh`, modeled directly on the existing `tests/spawn-wm-repo-note.test.sh` (same stub-agent/isolated-tmux harness, same `test_new_home`/`wm_write_config`/`wm_trust_repo` fixture pattern). Assert:
   - `--repo <this checkout>` (wingman itself): the generated `.launch.sh` contains `--settings` with `claudeMdExcludes` naming `<repo>/CLAUDE.md` **and** the worktree glob `<repo>-*/CLAUDE.md`.
   - `--repo <unrelated repo>`: the `.launch.sh` *also* contains the same `--settings` payload (unconditional application), even though the named paths don't exist under that target — this is the regression guard against re-introducing a `TARGET_IS_WM_REPO`-only gate.
   - `--scope global` (with wingman pinned into the discovered set, mirroring the existing note test's fixture): the `.launch.sh` contains the same `--settings` payload, worktree glob included.
   - A member with no live window (simulate the same way `tests/dead-lead-orphans.test.sh` does): `bin/crew-takeover <id>`'s printed output contains the exclusion payload in **both** printed forms — asserting only one form (round 2's mistake) would pass while the other stayed open.
7. Extend `tests/crew-resume.test.sh` (it already asserts the generated `.resume.sh`'s contents) with an assertion that the exclusion payload is present there too.
8. Run `bash tests/run.sh` and confirm the full suite passes, including the existing `spawn-wm-repo-note.test.sh` and both new/extended tests. `spawn-wm-repo-note.test.sh` does inspect the generated `.launch.sh` too (asserting the wingman repo appears among a global-scope spawn's `--add-dir`s), not only `.sysprompt.md` — but none of its assertions match against the new `--settings` payload, so it stays unaffected regardless.
9. Add the one-sentence notes to `docs/configuration.md` and `docs/guards.md` per the table above.
10. Run the live verification below.

## Testing strategy

- **Unit/E2E (automated, in-repo):** the new `tests/spawn-crew-claude-md-exclude.test.sh` plus the extended `tests/crew-resume.test.sh`, run via `bash tests/run.sh`. These are deterministic, no-`claude`-binary-needed static checks on the generated scripts and printed output — fast, and together they are the regression guard against a future edit to any of the three sites silently dropping or re-gating the exclusion.
- **Direct mechanism verification (already done by this analyst, reported above, and independently re-confirmed three times over across three review rounds):** disposable `claude -p` invocations against scratch fixtures — including a real git repo with a real `git worktree add`, and real `--session-id`/`--resume` cycles — confirming: the primary-cwd ancestor-walk leak and its fix; the on-demand subdirectory leak and its fix; that the worktree copy leaks under global scope but never loads at all under repo scope (so there is nothing for the glob to close there); that a resumed session without `--settings` reloads the root `CLAUDE.md` even when the original launch excluded it; and that a resumed session **with** `--settings` genuinely suppresses the reload (the remedy's own efficacy, not only the hole). Not repeated by the implementer; cited here as already-established grounding for the mechanism itself.
- **A note on how to phrase the live probe, learned the hard way.** An earlier draft of this verification asked the spawned member to check for the literal phrase "the pilot started `claude` from the wingman repo" — but that phrase was itself quoted in the objective handed to the member, so a truthful member reports it as "present" whether or not the file actually loaded, since it's reading its own instructions, not the leaked file. This self-contaminating shape was caught in peer review, reproduced there, and independently reproduced again by this analyst before revising: the fix is to never name the marker text in the objective, and ask a **content-free** question instead — the member has no way to answer it except by reporting what actually loaded. **Use the probe's exact wording, including "without reading any other file"** — a fourth-round review dropped that clause once while reproducing this plan's own steps, and the member simply opened `CLAUDE.md` with the `Read` tool and reported its contents, which reads as a leak but is not one: `claudeMdExcludes` gates the memory loader, never the `Read` tool (as stated above), so a member that opens the file on its own initiative will always find it, exclusion working or not.
- **Live crew-spawn verification (for whoever implements this to run, per the issue's own requirement for an actual spawn, not a reasoned assertion).** For each case, the objective must **not** quote or reference any distinctive `CLAUDE.md` phrase — ask only:

  > "Read `<file>`. Then, without reading any other file, report the exact contents of any project-instructions/CLAUDE.md memory block attached to your context. If there is no such block, reply exactly `NONE`."

  1. **Regression check, mirrors probe 3 (primary cwd = wingman repo root):** `bin/spawn-crew --type software-analyst --repo <path-to-wingman> --objective "<the content-free probe above, naming any small file in the repo, e.g. README.md>"`. Confirm the reply is `NONE` (before the fix, this was the confirmed-present case).
  2. **Regression check, the global-scope subdirectory case:** `bin/spawn-crew --type software-analyst --scope global --objective "<the content-free probe above, naming bin/spawn-crew inside the wingman repo>"`. Confirm `NONE` — this is the case that was wrongly believed safe before this plan.
  3. **Regression check, the worktree case — must be `--scope global`, not repo scope:** `bin/spawn-crew --type developer --scope global --objective "<work on some small wingman issue; once your worktree exists, run the content-free probe above naming a file inside the worktree, not the shared checkout>"`. Confirm `NONE`. This case must be global scope specifically — a repo-scope developer's worktree is a sibling of its primary cwd and the on-demand loader never reaches it at all, so a repo-scope version of this case would return `NONE` whether or not the glob is present and would prove nothing about the fix.
  4. **Regression check, the manual-takeover resume case — test both printed forms separately.** Spawn any crew member, confirm case 1 or 2's probe returns `NONE`, then kill its tmux window (simulating a `died` member) and run `bin/crew-takeover <id>`. It prints two resume commands (a `<your-agent-cli>` placeholder and a concrete `claude --resume` example) — run **each one**, as two separate resumed sessions, and send the content-free probe to both. Confirm `NONE` in both cases; testing only one, as an earlier draft of this plan did, would not catch a fix applied to only one of the two lines.
  5. **Regression check, the unattended bulk-recovery case (new, per review round 3's must-fix D):** repeat case 4's setup (a crew member with a killed window), but recover it via `bin/crew-resume <id>` (or `--all-died`) instead of `crew-takeover`'s printed command. Send the content-free probe to the relaunched session. Confirm `NONE` — before this fix, this unattended path (the one `CLAUDE.md`'s standing instruction pre-authorizes to run without confirmation after a fleet-wide outage clears) reloads the root `CLAUDE.md` exactly like the manual path did.
  6. **Orchestrator-unaffected check:** start (or attach to) the orchestrator session itself via `bin/wingman` (and separately, bare `claude` from the repo root) and confirm the persona is still present — e.g. via `/context`, checking `CLAUDE.md` is listed under "Memory files," or simply confirming the session still behaves as the orchestrator (announces delegation-first behavior, refuses heavy work itself, etc.).
  7. **Guard-hooks-unaffected smoke check:** from any of the crew spawns above, attempt an action one of the user-level guard hooks denies (e.g. a bare `gh pr merge` without `--allow-merge` should still be denied by `hooks/no-merge-guard.sh`). Confirm it is still denied exactly as before — this change touches only memory-file loading and should have zero effect on any hook, but given how central this machinery is, a direct smoke check costs little and rules out an unexpected interaction.

## Risks and open questions

- **Version dependence.** `claudeMdExcludes` is confirmed not only in the prose docs but directly in the installed 2.1.220 binary's own settings schema string: *"Glob patterns or absolute paths of CLAUDE.md files to exclude from loading. Patterns are matched against absolute file paths using picomatch. Only applies to User, Project, and Local memory types (Managed/policy files cannot be excluded)."* No `min-version` marker accompanies it in the docs, suggesting long-standing stability — but wingman does not pin or check the installed `claude` version anywhere today, and a future release could rename or remove the setting. `tests/spawn-crew-claude-md-exclude.test.sh` and the extended `tests/crew-resume.test.sh` only prove the flag is *emitted* correctly, not that the installed `claude` binary still honors it — the live verification steps above are what actually prove current-version behavior, and are worth re-running after any `claude` CLI upgrade that touches memory-loading behavior.
- **A corrected claim about the fallback if that ever happens.** An earlier draft of this plan asserted the prose disclaimer would remain a fallback if `claudeMdExcludes` ever regressed — caught on a third round of review as true for only one of the two hazardous spawn shapes. The disclaimer is injected only when `TARGET_IS_WM_REPO` is 1 (`bin/spawn-crew:167-168`: `--scope repo` and the target *is* wingman); a `--scope global` member — this plan's own newly-discovered hazard shape, and the routine one for wingman-focused work — never receives it. So a future regression of `claudeMdExcludes` would leave a repo-scope-targeting-wingman spawn with the disclaimer as backup, but a global-scope spawn with no defense at all, silently. Widening the disclaimer's gate to fire unconditionally (matching the exclusion's own unconditional scope) was considered as a follow-up: it is not the one-line change it first appears to be, because the disclaimer's current wording says "the file `CLAUDE.md` at **this repo's root**" — true when `TARGET_IS_WM_REPO`, but for a crew member whose own target is some other repo with its own legitimate `CLAUDE.md`, "this repo" would refer to *that* repo, and the sentence would wrongly describe an unrelated project's real instructions as the wingman orchestrator persona. Widening the gate correctly would need the wording re-anchored to name `$WM_REPO` specifically rather than "this repo" generically — a real but modest additional change, left as a named follow-up rather than folded into this plan.
- **Managed/policy CLAUDE.md is out of this fix's reach.** Per the same schema string, `claudeMdExcludes` "only applies to User, Project, and Local memory types" — a `claudeMd` value in a managed/policy settings file (`/etc/claude-code/CLAUDE.md` or the `claudeMd` key in `managed-settings.json`) cannot be excluded by this or any per-invocation mechanism. Not a current concern — wingman's orchestrator persona lives in an ordinary project-level `CLAUDE.md`, and nothing in this project uses managed/policy settings — but it is a real boundary on the guarantee this fix provides, worth knowing if that ever changes.
- **Scope of the exclusion list.** The eight excluded paths (four at the repo root, four repeated as a `$WM_REPO-*` glob for the worktree naming convention) cover every location the current schema recognizes as a memory/rules file, most of which don't exist in this repo today. This is deliberately defensive rather than minimal — a future contributor adding orchestrator-only content under `.claude/rules/`, in either location, would otherwise reopen exactly this hazard.
- **The `$WM_REPO-*` glob is a blunt instrument that could, in principle, swallow an unrelated repo's own legitimate `CLAUDE.md`.** The emitted pattern is `/home/greer/github/wingman-*/CLAUDE.md` — a genuine sibling repo named, say, `wingman-web` or `wingman-docs` would have its own project `CLAUDE.md` silently excluded for any crew member whose cwd sits above it, the same cost this plan uses to reject `--setting-sources` (above), reintroduced here in miniature. No such directory exists today (confirmed: `wingman` is the only match under its parent), and the `<repo-path>-<crew-id>` worktree convention makes an accidental collision unlikely — but the failure mode would be silent, exactly like the symlink risk above, not a loud error a developer would notice.
- **The global-scope worktree residual.** As detailed in "A fifth leak shape" under Grounding, a global-scope crew member that names its own worktree without following the `<repo-path>-<crew-id>` convention (now named explicitly in `playbooks/_delivery.md`, but not enforced) falls outside the glob. This is not a marginal corner: it is the entire worktree-leak story, since the worktree copy was never reachable under repo scope in the first place. Accepted deliberately — see that section for why pinning a path or enforcing the convention mechanically would need materially more machinery than this fix's scope — rather than left as an unstated gap.
- **`$WM_REPO` is a logical, not a physically-resolved, path.** `bin/lib/common.sh` derives it via `cd "$(dirname "${BASH_SOURCE[0]}")" && pwd` (no `-P`), which preserves a symlink component if one exists on the path from the filesystem root to this checkout. `claudeMdExcludes` patterns are "matched against absolute file paths using picomatch" — a literal string comparison, with no symlink resolution of its own. If the wingman checkout were ever reached through a symlinked path, the emitted patterns would silently match nothing, and the fix would become a no-op with no visible failure — the automated test would still pass, since it only checks that a payload naming `$WM_REPO` was emitted, not that the path it names matches reality. Not the case in this installation (`/home/greer/github/wingman` is a real directory, confirmed), and `bin/spawn-crew` already normalizes `$REPO` with `pwd -P` elsewhere for the identical reason (a symlinked workspace-root component mismatching the trust-gate lookup), so applying the same `-P` to `$WM_REPO`'s own derivation in `bin/lib/common.sh` would close this defensively — worth doing alongside this fix if the implementer wants to, though it is a change to a value used throughout every `bin/` script, not only this one, so it is noted here as a recommendation rather than folded into the implementation steps above.

One design point is genuinely a judgment call rather than something this plan treats as settled:

```wingman-questions
{
  "questions": [
    {
      "id": "defense-in-depth-scope",
      "type": "choice",
      "question": "claudeMdExcludes plus the worktree glob is confirmed (by direct reproduction, twice over) to mechanically close the hazard for a repo-scope spawn (root and worktree alike - the worktree was never reachable there to begin with) and for the root copy under global scope; the one place it stays best-effort is a global-scope member's self-chosen worktree path, now backed by an explicit naming convention rather than silence. Is that combination sufficient, or should the orchestrator persona also be split out of root CLAUDE.md (candidate direction (a)) as a second, independent layer?",
      "options": [
        { "label": "claudeMdExcludes + the convention, as specified", "recommended": true,
          "detail": "Closes every case that can be closed mechanically, and turns the one residual (a global-scope member's freely-named worktree) into an explicit, motivated convention instead of an unstated gap. Splitting the persona would not close that residual either - a worktree checkout copies whatever is at the repo root, stub or not - so it buys no additional coverage there, only redundancy against a future claudeMdExcludes-specific regression - and even that fallback is partial: the disclaimer only covers a repo-scope spawn targeting wingman, not the global-scope shape this plan itself found newly-hazardous, so a regression under global scope would have no defense either way." },
        { "label": "Also split the persona out (direction a)",
          "detail": "Adds real refactor cost (relocating persona content, restructuring root CLAUDE.md as a stub or import) for redundancy against a future version regression in claudeMdExcludes specifically - a real but currently-hypothetical risk, not a gap in today's fix, and one a persona split would not itself close for the global-scope worktree residual." }
      ]
    }
  ]
}
```

## Files touched (summary)

- `bin/lib/common.sh` — new `wm_claude_md_excludes()` helper.
- `bin/spawn-crew` — one new `--settings "$(wm_claude_md_excludes)"` line in the launch-script generator; the `TARGET_IS_WM_REPO` disclaimer's opening clause reworded (substance and gating unchanged).
- `bin/crew-takeover` — **both** printed `--resume` command forms gain the same `--settings` payload.
- `bin/crew-resume` — the generated `.resume.sh`'s `exec` line gains the same `--settings` payload, alongside its existing `--add-dir` lines.
- `playbooks/_delivery.md` — one clause added to the existing global-scope worktree-path guidance.
- `tests/spawn-crew-claude-md-exclude.test.sh` — new.
- `tests/crew-resume.test.sh` — extended with an assertion on the exclusion payload.
- `docs/configuration.md`, `docs/guards.md` — one sentence each.
- `CLAUDE.md`, `bin/wingman` — unchanged.
