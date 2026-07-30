# Plan review: mechanically exclude wingman's root CLAUDE.md from every crew session

Review of `docs/plans/2026-07-30-mechanical-claude-md-crew-exclusion.md` against
[issue #213](https://github.com/greerviau/wingman/issues/213).

**Verdict: changes needed.** Two must-fix items, one should-fix, three nice-to-haves.

The plan's core direction is right and its central mechanism is real. The recommended fix
(`claudeMdExcludes` via `--settings` on every spawn) is a genuine, verifiable, narrowly-scoped
mechanical control, and the plan is correct that the hazard is broader than the
`TARGET_IS_WM_REPO` gate assumes. But as written the exclusion list does not cover the place a
crew member doing wingman work actually spends its session — its own git worktree, which holds a
byte-identical copy of `CLAUDE.md` at a path none of the four proposed patterns match. And the
plan's live verification steps are constructed so that they return the same answer whether or not
the fix worked, so they could not have caught that.

All findings below were reproduced against the installed Claude Code 2.1.220 in a disposable
fixture, not reasoned from documentation.

---

## What was verified and holds

Recorded so the author does not re-litigate the parts that are sound.

**The fourth leak shape is real** — independently reproduced twice, not merely asserted.
Once accidentally, in this reviewer's own session: primary cwd was the workspace root
(`/home/greer/github`), and reading the plan file inside the `wingman/` subtree pulled the
entire root `CLAUDE.md` into context as a `# claudeMd` system-reminder, unprompted. Once in a
controlled fixture (case A2 below). The plan's claim stands on its own evidence and now on
independent evidence.

The mechanism is confirmed in the shipped binary, not just in prose docs. The 2.1.220 settings
schema carries:

> `claudeMdExcludes`: "Glob patterns or absolute paths of CLAUDE.md files to exclude from
> loading. Patterns are matched against absolute file paths using picomatch. Only applies to
> User, Project, and Local memory types (Managed/policy files cannot be excluded)."

and the memory loader's first guard is an exclusion test that returns an empty result — so an
excluded file contributes neither content nor followed imports. `claude --help` confirms
`--settings <file-or-json>` accepts an inline JSON string, so per-spawn injection works as the
plan describes.

The on-demand subtree loader resolves memory type `Project`/`Local`, both of which the exclusion
covers — so the fix genuinely closes the fourth leak shape, not only the primary-cwd case. This
was the sharpest open question in the review brief; it resolves in the plan's favour.

The `--add-dir` claim is correct: additional directories load `CLAUDE.md` only when
`CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` is set, which it is not. Probe 2's "absent" result
is explained and stays absent regardless of this fix.

**The orchestrator is genuinely untouched.** `bin/wingman:44-46` execs `claude $adddirs "$@"`
with no `--settings`, and the proposed change writes only into the generated crew `.launch.sh`.
Bare `claude` from the repo root is likewise unaffected. Constraint satisfied.

The prose disclaimer is preserved as specified, the rejections of candidate directions (a) and
(b) are well-argued, and the blast radius is appropriately tight — one behavioural file, one new
test, two doc sentences.

---

## Must-fix

### 1. The exclusion list misses the crew's own worktree copy of `CLAUDE.md`

This is the finding that prevents the plan from delivering its stated guarantee.

`bin/spawn-crew:302` computes `WORKTREE="$(dirname "$REPO")/$(basename "$REPO")-$ID"` — for a
wingman-targeted repo-scope spawn, `/home/greer/github/wingman-<crew-id>`. `playbooks/_delivery.md:33`
then has every software-development crew member `git worktree add "$WINGMAN_WORKTREE"` and do its
entire session's work inside it. That worktree contains a checked-out copy of `CLAUDE.md` — the
same orchestrator persona, verbatim — at an absolute path that none of the plan's four patterns
match, since all four are anchored to `$WM_REPO/...`.

The on-demand loader reaches it. In 2.1.220 the nested-directory walk is a raw string-prefix test
against the primary cwd, with no path-separator check:

```js
while (o !== cwd && o !== root) { if (o.startsWith(cwd)) n.push(o); o = dirname(o) }
```

So `/home/greer/github/wingman-<id>` counts as nested under a repo-scope cwd of
`/home/greer/github/wingman` (string prefix) *and* under a global-scope cwd of
`/home/greer/github` (true subdirectory). Both spawn shapes reach the worktree copy.

Reproduced directly. Fixture: `repo/CLAUDE.md` and sibling `repo-crewid/CLAUDE.md`, both
containing a marker phrase; cwd is their common parent.

| Case | Setup | Result |
| --- | --- | --- |
| A2 | no exclusion; read `repo/bin/tool.sh` | marker **loaded** (baseline leak) |
| B2 | exclude `<abs>/repo/CLAUDE.md`; read `repo/bin/tool.sh` | `NONE` (fix works) |
| **C** | **exclude `<abs>/repo/CLAUDE.md` only; read `repo-crewid/bin/tool.sh`** | **marker loaded — leak reopens** |
| D | add `<abs>/repo-*/CLAUDE.md`; read `repo-crewid/bin/tool.sh` | `NONE` (remedy works) |

Case C is the worktree scenario, and it is precisely the case issue #213 is about: a developer
crew fixing a wingman issue. As written, the plan leaves that crew with the prose disclaimer as
its only defence — the situation the issue rejected as insufficient.

Suggested remedy (case D confirms it works): extend the pattern set to the worktree naming
convention, e.g. `$WM_REPO-*/CLAUDE.md`, `$WM_REPO-*/CLAUDE.local.md`,
`$WM_REPO-*/.claude/CLAUDE.md`, `$WM_REPO-*/.claude/rules/**`. Patterns are picomatch globs
matched against absolute paths with `dot: true`, so this form is valid.

One residual the plan should name rather than leave implicit: `_delivery.md:37` tells a
**global-scope** member whose `$WINGMAN_WORKTREE` is unset to "pick a path yourself," so a
convention-based glob is best-effort in that case. Either accept and state that residual, or have
`bin/spawn-crew` pin a worktree path for global scope too so the glob is exhaustive. That is a
design call for the author, not something this review prescribes.

### 2. The live verification steps cannot distinguish a pass from a fail

Testing strategy steps 1 and 2 direct the spawned member to report whether the phrase
"the pilot started `claude` from the wingman repo" appears in its context — but the objective
carrying that instruction *is itself in the member's context*. A truthful member answers
"present" whether or not the leak was closed. The probe is self-contaminating and would report
failure against a working fix.

This is not hypothetical: this reviewer's first probe pair had exactly this defect and returned
`YES`/`YES` for a case that, retested cleanly, was `loaded`/`NONE`.

Suggested remedy: never name the marker in the objective. Ask a content-free question instead —
the wording that produced clean, unambiguous results here was:

> "Read `<file>`. Then, without reading any other file, report the exact contents of any
> project-instructions/CLAUDE.md memory block attached to your context. If there is no such
> block, reply exactly `NONE`."

A leaking session returns the file's text; a clean one returns `NONE`. Add a third live case
covering the worktree path from finding 1 — spawn a member, have it create its worktree per
`_delivery.md`, read a file inside it, then run the same probe.

---

## Should-fix

### 3. The stated reason for rejecting `--setting-sources` is factually wrong

The plan states: "There is no documented claim, and this analyst found no reproduction, that
`--setting-sources` affects `CLAUDE.md` loading at all."

It does affect it. In 2.1.220 both the launch-time ancestor walk and the on-demand subtree load
are gated on `pg("projectSettings")` — whether `projectSettings` is among the enabled setting
sources. Reproduced in the same fixture: `claude -p --setting-sources user,local` returns `NONE`
where the identical baseline run leaks the marker.

**The conclusion to reject it is still correct**, on the plan's own second argument: excluding the
`project` source would also drop wingman's project-level `.claude/settings.json` hooks
(`hooks/pilot-preferences-guard.sh`, `hooks/stop-guard.sh`), and would suppress the *target*
repo's own legitimate `CLAUDE.md` along with wingman's. That is a much larger blast radius for no
added benefit over `claudeMdExcludes`, which is scoped to exactly the files named.

But the rationale needs correcting, and the "a subagent got this wrong" framing should go with
it — the subagent's suggestion was mechanically effective, just wrong on blast radius. This
document is the durable record of why an alternative was rejected; a future contributor who tests
the claim will find it false and reasonably discount the rest of the analysis. Rewrite the section
to reject `--setting-sources` on blast radius alone, which is the argument that actually holds.

---

## Nice-to-have

4. **Wrong test filename.** Implementation step 2 cites `tests/spawn-crew-wm-repo-note.test.sh`;
   the file is `tests/spawn-wm-repo-note.test.sh` (step 3 names it correctly).

5. **State that the exclusion does not block a deliberate read.** `claudeMdExcludes` is checked
   only in the memory loader, never in the `Read` tool, so a crew member can still open
   `CLAUDE.md` on purpose. That preserves the disclaimer's "optional background reading"
   affordance and is a point in the approach's favour — worth one sentence, since it is an
   obvious reviewer question and the answer is good news.

6. **Two small grounding upgrades for the risk section.** The mechanism can now be cited from the
   shipped binary's own settings schema rather than only from the docs, which is stronger evidence
   for the version-stability argument. And that schema's "Managed/policy files cannot be excluded"
   clause is worth a line: if orchestrator content were ever placed in managed or policy settings'
   `claudeMd` field, this fix could not suppress it. Not a current concern — nothing uses it
   today — but it is a real boundary on the guarantee being claimed.

---

## Answers to the review brief's specific questions

1. **Does it deliver a mechanical guarantee across every spawn shape?** Not yet. It closes
   repo-scope-targeting-wingman, repo-scope-targeting-another-repo (already safe), and
   global-scope-touching-the-wingman-subtree. It does **not** close the worktree copy, which
   affects both repo and global scope (finding 1). With that pattern added, yes.
2. **Is the claimed mechanism real and verifiable?** Yes — confirmed independently against
   `claude --help`, the 2.1.220 settings schema, and direct reproduction. The fourth leak shape is
   grounded, and the fix demonstrably closes the on-demand case, not just the primary-cwd case.
3. **Are the other two directions correctly rejected?** (a) and (b): yes, well-argued.
   `--setting-sources`: right conclusion, wrong stated reason (finding 3).
4. **Is the orchestrator untouched?** Yes. Verified against `bin/wingman`'s launch path.
5. **Is the prose disclaimer preserved?** Yes, explicitly, and correctly framed as
   defence-in-depth.
6. **Is verification concrete and executable?** The automated test is well-specified. The live
   verification is not currently executable as a pass/fail check (finding 2).
7. **Is the scope appropriate?** Yes. One behavioural file, one new test, two doc sentences, with
   `CLAUDE.md` and `bin/wingman` explicitly unchanged. No unnecessary blast radius.

## On the plan's open question

The embedded `defense-in-depth-scope` question asks whether `claudeMdExcludes` alone suffices or
whether the persona should also be split out of root `CLAUDE.md`. The recommended answer
(`claudeMdExcludes` alone) is sound and this review does not dispute it — but note that finding 1
slightly changes its basis. The plan argues the exclusion is complete for both confirmed leak
shapes; it is complete only once the worktree pattern is added. The recommendation still holds
after that fix, since splitting the persona would not have covered the worktree case either — a
worktree checkout copies whatever is at the repo root, stub or not.
