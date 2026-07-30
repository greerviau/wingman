# Plan review, round 2: mechanically exclude wingman's root CLAUDE.md from every crew session

Second-round review of `docs/plans/2026-07-30-mechanical-claude-md-crew-exclusion.md` against
[issue #213](https://github.com/greerviau/wingman/issues/213), and against round 1's findings in
`docs/analysis/2026-07-30-review-mechanical-claude-md-crew-exclusion-plan.md`.

**Verdict: changes needed.** Two must-fix items, one should-fix, two nits.

The recommended fix is still the right one, and the revision fixed round 1's cleanest defect. But
the revision's *new* material — the worktree section, which is the heart of round 1's must-fix 1 —
rests on a mechanism claim that does not reproduce. The remedy it prescribes (the `$WM_REPO-*`
glob) is correct and necessary; the reasoning about *which spawn shape needs it* is inverted, and
that inversion propagates into the plan's stated guarantee, its residual, its embedded open
question, and one of its live verification steps, which as written cannot exercise the case it
claims to cover. Separately, the exclusion is silently lost on session resume — the documented
recovery path for a dead crew member.

Every finding below was reproduced against the installed Claude Code 2.1.220 in disposable
fixtures, including a real `git worktree add`, not reasoned from documentation.

---

## Round 1's findings: re-verified independently

### Must-fix 1 — worktree copy of `CLAUDE.md`: remedy present, mechanism wrong

**The glob is in the plan** (`$WM_REPO-*/CLAUDE.md` and its three siblings, plan line 133), and it
is genuinely necessary. But the plan's account of *why* — that the leak "reaches both spawn
shapes, not just one" via an unanchored string-prefix test (plan lines 54, 63) — does not
reproduce. See must-fix A below; this is the finding, restated there in full rather than split
across two sections.

The underlying facts round 1 asserted and this round confirms: `bin/spawn-crew:302` computes
`WORKTREE="$(dirname "$REPO")/$(basename "$REPO")-$ID"`, `playbooks/_delivery.md:33` has the member
`git worktree add "$WINGMAN_WORKTREE"`, and `git worktree add` does check out a byte-identical
`CLAUDE.md` into that sibling directory (verified directly on a real worktree). The hazard is real.
Its reach is not what the plan says.

### Must-fix 2 — self-contaminating live probe: **fixed**

The revised probe (plan line 163) names no marker text:

> "Read `<file>`. Then, without reading any other file, report the exact contents of any
> project-instructions/CLAUDE.md memory block attached to your context. If there is no such block,
> reply exactly `NONE`."

This is genuinely content-free, and it is not merely plausible — it is the exact wording this
reviewer used for all nine live probes reported in this document. It discriminated cleanly every
time, distinguishing not just present/absent but *which* of two same-shaped `CLAUDE.md` files had
loaded (by returning the file's own text, which the probe never supplies). It also survives the
`TARGET_IS_WM_REPO` case: the #69 disclaimer that `bin/spawn-crew:333-335` injects into that
spawn's objective mentions `CLAUDE.md` but quotes none of its content, so it cannot manufacture a
false "present". Finding closed.

Plan line 160's account of how the defect was found and fixed is accurate and worth keeping.

One consequence of must-fix A below lands on this section: **live verification case 3 (plan line
167) cannot exercise the worktree path as written.** It spawns a `developer` "against wingman" —
repo scope — where the worktree copy never loads at all (measured below), so that case returns
`NONE` whether or not the glob is present. It is not a test of the glob. It must be a
**`--scope global`** spawn to exercise anything.

### Should-fix 3 — `--setting-sources` rationale: **fixed**

The revised section (plan lines 75–79) now states that `--setting-sources user,local` *does*
suppress `CLAUDE.md` loading and rejects it on blast radius alone. Both halves check out:

- **Effectiveness, reproduced.** `claude -p --setting-sources user,local` in a fixture whose
  baseline leaks the marker returned `NONE`. The corrected claim is right.
- **Blast radius, verified against the repo.** `.claude/settings.json` does register project-level
  hooks — `hooks/stop-guard.sh` (Stop), `hooks/pilot-preferences-guard.sh` (PreToolUse),
  `hooks/pilot-preferences-nudge.sh` (SessionStart), `hooks/pilot-preferences-ask-tracker.sh`
  (PostToolUse) — so dropping the `project` source would drop those. And suppressing every target
  repo's own legitimate `CLAUDE.md` is the more general cost, correctly identified as the decisive
  one.
- **The contrast with `--settings` holds.** `claude --help` documents `--settings <file-or-json>`
  as "load **additional** settings from" — it adds a layer rather than replacing one, so a JSON
  payload carrying only `claudeMdExcludes` genuinely touches nothing else. The plan's "touches
  only the files named here" is accurate.

Finding closed.

### Round 1 nice-to-haves 4, 5, 6: all addressed

- **4** — implementation step 2 now cites `tests/spawn-wm-repo-note.test.sh` correctly (plan line 148).
- **5** — the deliberate-read affordance is stated (plan line 89), and it is correct:
  `claudeMdExcludes` gates the memory loader only, never the `Read` tool.
- **6** — the risk section now cites the shipped 2.1.220 settings schema rather than only the prose
  docs, and names the managed/policy boundary (plan lines 173–174).

---

## Must-fix

### A. The worktree leak is a global-scope-only phenomenon, and the plan says the opposite

The plan asserts (lines 54, 63) that because 2.1.220's nested-directory walk is a raw string-prefix
test, `/home/greer/github/wingman-<id>` counts as nested under **both** a repo-scope cwd of
`/home/greer/github/wingman` and a global-scope cwd of `/home/greer/github`, so "the worktree leak
reaches both spawn shapes, not just one."

It does not reach repo scope. Measured, on a real git repo with a real `git worktree add`, with the
root and worktree copies carrying **distinct** markers so the two are distinguishable, and with the
session doing what a developer actually does (`cd` into the worktree, list it, read files inside
it):

| cwd (spawn shape) | exclusion | which `CLAUDE.md` loaded |
| --- | --- | --- |
| `fx/repo` (**repo scope**) | none | **ROOT only** |
| `fx/repo` (**repo scope**) | root patterns only | **none** |
| `fx/repo` (**repo scope**) | root + `repo-*` glob | none |
| `fx` (**global scope**) | none | **WORKTREE** |
| `fx` (**global scope**) | root patterns only | **WORKTREE — leak stands** |
| `fx` (**global scope**) | root + `repo-*` glob | **none — glob closes it** |

The same pattern reproduced on a non-git fixture first, so it is not an artifact of worktree
plumbing. In the repo-scope shape the sibling worktree copy is never loaded at all — the only thing
that loads is the root `CLAUDE.md`, via the launch-time ancestor walk, which the four root patterns
already handled in the plan's original draft.

**Why this matters beyond a corrected sentence.** Three of the plan's conclusions invert:

1. **The guarantee (line 65).** The plan claims it is "complete for repo scope (both the root and
   the worktree), and best-effort for a global-scope member's self-chosen worktree path
   specifically." Measured, the worktree exposure exists *only* in the global-scope shape — the one
   shape where `bin/spawn-crew:302` gates `WORKTREE` on `[ "$SCOPE" = repo ]`, leaves
   `$WINGMAN_WORKTREE` unset, and `playbooks/_delivery.md:37` tells the member to "pick a path
   yourself." So worktree coverage is best-effort **wherever it is needed at all**. That is the
   honest statement, and it is a materially weaker guarantee than the one the plan offers.
2. **The residual (line 65, line 176).** The plan frames the global-scope residual as a narrow
   corner left over after a complete repo-scope fix. It is the entire worktree story. Whether to
   accept it is the requester's call, but it must be put to them accurately — and the plan's
   rejection of pinning a worktree path for global scope ("wingman cannot know which repo it will
   need a worktree for") should be re-examined now that this is the *only* thing standing between
   the plan and a mechanical guarantee, not a marginal extra.
3. **The embedded open question (line 186).** It asserts the fix is "confirmed (by direct
   reproduction, not just docs) to mechanically close the hazard for the repo root, the on-demand
   subdirectory case, **and the crew's own worktree checkout**." The third clause is not confirmed;
   for the shape where the worktree hazard exists, closure is convention-dependent. This is the
   text the human answers the question from, so it has to be right.

**No code change is implied.** The `$WM_REPO-*` patterns at plan line 133 are correct, necessary,
and should stay — they are what closed the global-scope case in the table above. What needs
rewriting is the mechanism paragraph (lines 54, 63), the residual assessment (line 65), the open
question's premise (line 186), and live verification case 3 (line 167, which must become a
`--scope global` spawn to test anything).

### B. The exclusion is silently lost on `--resume`, the documented recovery path

`--settings` is a per-invocation flag, and the plan applies it only in the generated `.launch.sh`.
`bin/crew-takeover:38` hands the human a resume command built from scratch:

```
cd <repo> && <your-agent-cli> --resume <session-id>
```

with no `--settings`. Reproduced end to end in the git fixture: an initial `claude -p` launched
with the exclusion returned `NONE`; resuming that same session id with no `--settings` reloaded the
root `CLAUDE.md` and the session volunteered *"My previous answer was wrong — there is such a
block,"* quoting the marker.

This matters because takeover is not only a human-attaches-to-watch path. `CLAUDE.md`'s own
survival section documents it as the recovery path for a member whose window `died`
(`bin/crew-list` shows `died`; `bin/crew-takeover <id>` prints the command), and that member then
goes on working autonomously with the persona reattached. The mechanical guarantee has a hole
exactly where the fix is most needed — a long-running developer session that got restarted.

The plan's proposed test greps `.launch.sh` only, so it would not catch this either.

Remedy is the author's call; the obvious shapes are to have `bin/crew-takeover` emit the same
`--settings` payload in the command it prints (it can recompute it from `$WM_REPO`, or read it back
out of the recorded `.launch.sh`), and to cover it in the new test. Whatever is chosen, the plan
should state explicitly whether resumed sessions are in or out of the guarantee rather than leaving
it unaddressed.

---

## Should-fix

### C. The preserved disclaimer asserts something that becomes false once the fix lands

`bin/spawn-crew:334` opens with: "the file `CLAUDE.md` at this repo's root, **which your harness
just loaded automatically as project context**, is written entirely in first person for the wingman
orchestrator role."

After this fix, in the normal working case, the harness did *not* just load it. The plan
acknowledges this (line 87) and argues the wording "remains accurate for that fallback case" — i.e.
accurate only when the mechanism has failed. That inverts the usual standard: the durable text is
now wrong in the common case and right only in the rare one, and a crew member reading a confident
false statement about its own context is precisely the confusion the disclaimer exists to prevent.

The requester's constraint is that the disclaimer stay in place, not that its wording be frozen —
rewording is not removing. A clause that holds in both states ("if you see this repo's root
`CLAUDE.md` in your context, or open it yourself…") costs one line and keeps the defense-in-depth
role intact. Flagging as should-fix rather than must-fix because it degrades to a confusing
sentence, not to a leak.

---

## Nits

1. **Wrong citation for the project-level hooks.** Plan line 79 cites `docs/guards.md:49-56` for
   `hooks/pilot-preferences-guard.sh` and `hooks/stop-guard.sh`. Lines 49–56 of that file are the
   "Hooks that need user-level settings" list (`no-direct-edit-guard.sh`, the Artifact pair, the
   outage/usage-limit guards, the merge pair) — a different set, registered a different way.
   `pilot-preferences-guard.sh` is documented at `docs/guards.md:17` and `:37`; `stop-guard.sh` is
   not named in `docs/guards.md` at all. The *substance* is correct — both are registered in the
   checked-in `.claude/settings.json`, verified directly — so cite that file instead. (Round 1
   introduced this citation; it is inherited, not authored.)

2. **`$WM_REPO` is a logical path, and the match is a literal string comparison.**
   `bin/lib/common.sh:6-12` derives it via `cd … && pwd`, which preserves symlinks, while
   `claudeMdExcludes` "patterns are matched against absolute file paths using picomatch." If the
   repo were ever reached through a symlinked path, the patterns would silently match nothing and
   the fix would become a no-op with no visible failure. Not the case in this install
   (`/home/greer/github/wingman` is a real directory), and the emitted-string test would not detect
   it. Worth one sentence in the risk section, or `pwd -P`.

---

## Re-confirming the three standing constraints

- **The orchestrator's launch path is untouched.** `bin/wingman:45` execs `claude $adddirs "$@"`
  with no `--settings`, and the change writes only into the generated crew `.launch.sh`. Bare
  `claude` from the repo root is likewise unaffected. Confirmed again this round.
- **The prose disclaimer stays.** Present and unchanged at `bin/spawn-crew:333-335`, still
  `TARGET_IS_WM_REPO`-gated, explicitly preserved by the plan. (Its wording is finding C, not its
  existence.)
- **Blast radius is no larger than necessary.** One behavioural file, one new test, two doc
  sentences; `CLAUDE.md` and `bin/wingman` explicitly unchanged. `--settings` adds a settings layer
  rather than replacing one, and the payload carries a single key, so nothing outside memory-file
  loading is affected. No existing `--settings` flag is emitted in the launch command, so there is
  no conflict. `quote()` (`bin/lib/common.sh:171-173`) wraps in single quotes and the JSON payload
  contains none, so the embedding is safe. Applying it unconditionally rather than gating on
  `TARGET_IS_WM_REPO` remains the right call and costs nothing for an unrelated target.

## Summary of what to change

| # | Severity | Change |
| --- | --- | --- |
| A | must-fix | Correct the worktree mechanism (repo scope does **not** reach the sibling worktree); restate the guarantee and residual as best-effort wherever the worktree hazard exists; fix the open question's premise; make live case 3 a `--scope global` spawn. Keep the glob — it is correct. |
| B | must-fix | Address the exclusion being lost on `claude --resume` (`bin/crew-takeover:38`), or state explicitly that resumed sessions are outside the guarantee. |
| C | should-fix | Reword the #69 disclaimer's "which your harness just loaded automatically" so it is true in both states. Rewording is not removing. |
| 1 | nit | Cite `.claude/settings.json` for the project-level hooks, not `docs/guards.md:49-56`. |
| 2 | nit | Note the logical-vs-resolved path assumption in `$WM_REPO`. |

Everything else in the plan — the mechanism choice, the rejections of directions (a) and (b), the
corrected `--setting-sources` rationale, the unconditional application, the automated test design,
the scope — holds up under a second, independent check.
