# Plan review, round 3 (final): mechanically exclude wingman's root CLAUDE.md from every crew session

Third and final round of review on `docs/plans/2026-07-30-mechanical-claude-md-crew-exclusion.md` against
[issue #213](https://github.com/greerviau/wingman/issues/213), round 1
(`docs/analysis/2026-07-30-review-mechanical-claude-md-crew-exclusion-plan.md`) and round 2
(`docs/analysis/2026-07-30-review-round2-mechanical-claude-md-crew-exclusion-plan.md`).

**Verdict: changes needed.** Two must-fix, one should-fix, two nits.

Round 2's three findings (A, B, C) are all genuinely resolved, and I confirmed each by
re-reproducing the underlying behaviour myself rather than reading the revision. The recommended
mechanism is right, the corrected worktree account is right, and — a claim the plan asserts but
never demonstrated — I verified that the `--resume` remedy actually works, not just that the hole
exists.

What is left is the *same defect class* as round 2's must-fix B, swept incompletely. B was framed as
"the exclusion is lost on `--resume`" and remedied at the one resume site round 2 happened to name.
There are three sites where a crew session's agent command line is constructed, and the plan covers
two of them. The third (`bin/crew-resume`) is the *automated, unattended* one and is absent from the
plan entirely; the second (`bin/crew-takeover`) is patched in one of the two commands it prints.

Everything below was reproduced against the installed Claude Code 2.1.220 in a disposable fixture
with a real `git init` and a real `git worktree add`, and every line citation was checked against a
checkout confirmed byte-identical to `origin/main` for all files named.

---

## Round 2's findings: independently re-verified

### Must-fix A — the worktree leak is global-scope-only: **fixed, and the mechanism is correct**

I rebuilt the fixture from scratch (real git repo `fx/repo`, real `git worktree add fx/repo-wt1`,
**distinct** markers in the two copies so they are unambiguously distinguishable), and had the
session read a file *inside the worktree* in each case:

| cwd (spawn shape) | exclusion | which `CLAUDE.md` loaded |
| --- | --- | --- |
| `fx/repo` (**repo scope**) | none | **root only** — the session volunteered "No CLAUDE.md block for the `repo-wt1` worktree directory was attached, even though the file I read lives there" |
| `fx` (**global scope**) | none | **worktree** |
| `fx` (**global scope**) | the plan's exact eight-pattern payload | **NONE** |

This is precisely what the revision now says. Checking the four places round 2 said the inversion
had propagated:

- **Mechanism (plan lines 54–70).** Correct, and the "primary cwd is what actually matters"
  framing is the right explanation.
- **The guarantee (line 76).** Correct and honestly weaker: "best-effort ... for a global-scope
  member's self-chosen worktree path specifically, which is the one place this plan cannot make the
  guarantee airtight."
- **The residual (line 233).** Correct — "it is the entire worktree-leak story, since the worktree
  copy was never reachable under repo scope in the first place."
- **The embedded open question (line 244).** Premise corrected; it no longer claims the worktree
  case is confirmed closed under both scopes. (One clause in its *option B* detail is now the
  weakest link — see should-fix F.)
- **Live verification case 3 (line 223).** Now `--scope global`, with the rationale stated inline
  ("a repo-scope version of this case would return `NONE` whether or not the glob is present and
  would prove nothing about the fix"). Correct.

I also confirmed the payload survives `quote()` embedding into the generated launch script: single
quotes prevent the shell expanding `wingman-*` before the agent sees it, and the argv the agent
receives is the intact JSON. Finding closed.

### Must-fix B — exclusion lost on `--resume`: **the named site is fixed, and the remedy is now proven to work**

The plan's proposed `bin/crew-takeover` diff matches the real code exactly (`bin/crew-takeover:36–38`
is verbatim what the plan quotes), and it genuinely adds `--settings` to the printed `--resume`
command rather than merely defining a helper — I checked the diff, not just the helper's existence.
`bin/crew-takeover` sources `bin/lib/common.sh` at line 13, so `$WM_REPO` and `quote()` are both in
scope for the call.

The plan demonstrated only that resuming *without* `--settings` reloads the file. It never showed
that resuming *with* it suppresses the load — the actual efficacy of its own remedy. I ran that:

| step | result |
| --- | --- |
| `claude -p --session-id <sid> --settings '<payload>'` | `NONE` |
| `claude -p --resume <sid> --settings '<payload>'` | `NONE` — **the remedy works** |
| `claude -p --resume <sid>` (no `--settings`, control) | leak returns; the session volunteered *"My earlier two answers of NONE were wrong — there is such a block"*, quoting the marker |

So `--settings` is honoured on a resume, and the plan's approach is sound. What is not sound is its
coverage — see must-fix D and E.

### Should-fix C — disclaimer wording: **fixed**

The current text (`bin/spawn-crew:334`) opens "which your harness just loaded automatically as
project context". The replacement (plan line 110) reads:

> "the file `CLAUDE.md` at this repo's root — if it is anywhere in your context, whether your
> harness loaded it automatically or you opened it yourself — is written entirely in first person
> for the **wingman orchestrator** role..."

This holds in all three states: exclusion working (premise simply doesn't fire), exclusion failed
(harness did load it), deliberate `Read` (member opened it). The substance and the
`TARGET_IS_WM_REPO` gating are untouched, so the requester's "keep the disclaimer" constraint is
honoured — rewording is not removing. Finding closed.

### Round 2's nits: both addressed

- **Nit 1** — plan line 100 now cites "all registered in the checked-in `.claude/settings.json`"
  rather than `docs/guards.md:49-56`. Correct.
- **Nit 2** — plan line 234 documents the logical-vs-resolved `$WM_REPO` path, correctly notes the
  failure would be silent and the automated test would still pass, and recommends `pwd -P` without
  folding a repo-wide change into this plan's steps. Well judged.

---

## Must-fix

### D. `bin/crew-resume` — the *automated* resume path — is missing from the plan entirely

There are three places a crew session's agent command line is built. The plan names two:

| site | what it does | in the plan? |
| --- | --- | --- |
| `bin/spawn-crew:402–430` | writes `<id>.launch.sh`, `exec claude ...` | yes |
| `bin/crew-takeover:38` | *prints* a resume command for a human to run | yes (partially — see E) |
| **`bin/crew-resume:206–259`** | **writes `<id>.resume.sh` and `exec`s `claude --resume` unattended** | **no** |

`bin/crew-resume` generates its own launch script that `cd`s to the member's original cwd
(`bin/crew-resume:210`) and then, at lines 249–257, builds:

```
exec claude --resume <sid> [--permission-mode ...] --add-dir <WM_HOME> --add-dir <repo> [--model ...] [--effort ...]
```

with no `--settings` anywhere. Because it restores the original cwd, a repo-scope wingman member
resumes with its primary cwd set to the wingman checkout — the exact launch-time ancestor-walk
shape that is issue #213's original confirmed leak (plan line 19, probe 3). My T4 control above is
that scenario reproduced end to end: same session id, resumed without `--settings`, root
`CLAUDE.md` back in context and the session explicitly retracting its earlier clean answer.

This is a worse hole than the one round 2 found, for three reasons:

1. **It is unattended.** `bin/crew-takeover` prints a command a human chooses to run.
   `bin/crew-resume` relaunches sessions itself and flips them back to `working`
   (`bin/crew-resume:303–307`). Nobody is in the loop to notice.
2. **It is the documented default remedy for the most common mass failure.**
   `docs/fleet-resilience.md:13` calls it "the bulk recovery tool a mass-death bullet names as its
   default remedy"; `docs/runbooks/incidents.md:61–67` and `bin/watch-fleet:1167,1174` make
   `bin/crew-resume --all-died` **pre-authorized to run without a fresh confirmation** after an
   `outage-cleared` fire. A single tmux/host crash routes every crew member in the fleet through
   this path at once.
3. **The plan's own test would not catch it.** Step 5 asserts `.launch.sh` and `crew-takeover`'s
   printed output. `.resume.sh` is a third artifact, written by a third script.

The plan's line 84 states the reason B was hard to catch — "the vulnerable command lives in a
different script entirely" — and that reasoning applies once more, to a script it did not look at.
Note the precedent: `docs/plans/2026-07-13-onboarding-preferences-hook-enforcement.md:247–263` is
the identical class of miss in this same codebase (`bin/spawn-crew` exported the env a guard needed;
`bin/crew-resume` did not), found and fixed there. `bin/crew-resume` is a known blind spot when
changing what a crew session launches with.

**What to change:**

- Add `--settings "$(wm_claude_md_excludes)"` to `bin/crew-resume`'s generated resume script,
  alongside the existing `--add-dir` lines (around `bin/crew-resume:253–256`). `bin/crew-resume`
  already sources `common.sh`, so the shared helper is available with no further plumbing — this is
  exactly the drift the helper exists to prevent, so use it rather than a fourth copy of the JSON.
- Update the plan's narrative accordingly: line 86 ("used by both `bin/spawn-crew` and
  `bin/crew-takeover`"), line 106, the file-layout table (lines 118–128), the "Files touched"
  summary, and implementation steps 1–3, all of which currently enumerate two sites.
- Extend **`tests/crew-resume.test.sh`** (it already exists and already asserts the generated
  `.resume.sh`'s contents, so this is an added assertion, not a new harness) rather than putting
  everything in the new test file.
- Add a live-verification bullet: resume a `died` member via `bin/crew-resume <id>` — not only via
  the command `bin/crew-takeover` prints — and re-run the content-free probe.

### E. `bin/crew-takeover:39` still prints an exclusion-free resume command, and it is the more copyable one

The plan patches `bin/crew-takeover:38`, which prints:

```
    cd <repo> && <your-agent-cli> --resume <sid>
```

The very next line, in the same branch, prints a second command:

```
bin/crew-takeover:39:  echo "(e.g. with Claude Code: 'claude --resume $SID' - resume is refused if the session is still live.)"
```

The plan leaves this untouched. That is the only **concrete, runnable** form in the output — line
38's requires the human to substitute the `<your-agent-cli>` placeholder first, so line 39 is the
one that gets pasted. After the fix, `bin/crew-takeover` prints two resume commands: one that
carries the guarantee and one that silently drops it, with the unsafe one easier to use.

This also makes the plan's own live-verification case 4 ambiguous — line 224 says "run the exact
command `bin/crew-takeover <id>` prints", and there would be two. Worse, the failure mode is
asymmetric: the plan's automated assertion ("`bin/crew-takeover <id>`'s printed output contains the
same `--settings` payload", step 5) passes on line 38 alone while line 39 keeps the hole open, so
the regression guard would certify a partially-fixed script.

Given that the plan explicitly claims (line 106) "the guarantee holds across a crew member's full
lifecycle, not only its first process", this needs closing rather than disclosing.

**What to change:** either carry the payload in line 39's example too, or reduce line 39 to a note
that does not restate a full command (e.g. keep only the "resume is refused if the session is still
live" caveat and let line 38 be the single command). Assert *both* forms — or the absence of a
second bare `--resume` — in the test.

---

## Should-fix

### F. The "prose disclaimer remains the fallback" claim is false for global scope

Plan line 230, on version dependence:

> "If that ever happens, the existing prose disclaimer remains the fallback (not a silent regression
> to 'no defense at all')."

The disclaimer is injected only when `TARGET_IS_WM_REPO` is 1, and `bin/spawn-crew:167–168` sets
that to 1 only for `[ "$SCOPE" = repo ] && [ "$REPO" = "$WM_REPO" ]`. A `--scope global` member is
never given it — and a global-scope member doing wingman work is exactly the hazard this plan's own
Grounding section introduced as newly-discovered and "routine" (lines 21–23, 33), and is the shape
this very review crew was spawned in. If `claudeMdExcludes` is ever renamed or removed, that spawn
shape regresses to *no defense at all*, silently, which is the specific outcome the sentence denies.

The same clause props up the recommendation in the embedded open question (line 247): option B is
argued down partly on "for which the existing prose disclaimer already provides a fallback". That is
the text the human answers the question from, so it needs to be accurate — the fallback covers one
of the two hazardous spawn shapes, not both.

**What to change:** state the limit plainly in the risk bullet and in the open question's option
detail. Separately worth naming (not necessarily doing): widening the disclaimer's gate so it is
injected whenever wingman's tree is reachable — which, given `--add-dir "$WM_REPO"` is
unconditional at `bin/spawn-crew:425`, means always — is a one-condition change that would make the
claim true as written. That is an addition to a defense the issue asked to keep, not a removal, so
it stays inside the issue's constraints; it is the analyst's call whether to fold it in or leave it
as a named follow-up.

---

## Nits

1. **The `$WM_REPO-*` glob can swallow an unrelated repo's legitimate `CLAUDE.md`.** The emitted
   pattern is `/home/greer/github/wingman-*/CLAUDE.md`. A future sibling repo named `wingman-web`,
   `wingman-docs`, or similar would have its *own* legitimate project `CLAUDE.md` silently
   suppressed for every crew member whose cwd sits above it — which is the precise cost the plan
   uses to reject `--setting-sources` (line 100: "would suppress the **target** repo's own
   legitimate project `CLAUDE.md`"), reintroduced in miniature. No such directory exists today
   (`ls -d /home/greer/github/wingman*` returns only `wingman`), and the `<repo>-<crew-id>` worktree
   convention makes a collision unlikely — but the failure would be silent, the same silence mode
   the plan already documents for the symlink case at line 234. One sentence in the risk section.

2. **Implementation step 5's assertion list needs the third artifact.** Follows from must-fix D:
   the generated `.resume.sh` is a distinct file from `.launch.sh` and needs its own assertion, in
   `tests/crew-resume.test.sh`.

---

## Re-confirming the standing constraints (final check)

- **The orchestrator's own launch path is untouched.** `bin/wingman:45` is `exec claude $adddirs "$@"`
  — no `--settings`, and the plan changes only crew-facing scripts. Bare `claude` from the repo root
  (`README.md:31` documents both as equally supported) is likewise unaffected. Confirmed again.
- **The disclaimer is preserved.** Present at `bin/spawn-crew:334`, still `TARGET_IS_WM_REPO`-gated,
  explicitly retained; only its opening clause is reworded, which the requester's constraint allows.
- **Blast radius is minimal, and stays minimal with D and E folded in.** The additions are one line
  in `bin/crew-resume` and one string in `bin/crew-takeover` — same helper, same payload, no new
  mechanism. `--settings` is confirmed additive by the CLI's own help ("load **additional**
  settings"), and the payload carries a single key, so nothing outside memory-file loading moves.
  `CLAUDE.md` and `bin/wingman` stay unchanged.
- **The verification steps are content-free and executable.** The probe wording (plan line 219) is
  genuinely content-free — I used it verbatim for every live probe in this document, and it
  discriminated cleanly every time, including reporting *which* of two same-shaped `CLAUDE.md` files
  had loaded by returning text the probe never supplied. Cases 1, 2, 3, 5 and 6 are runnable as
  written. Case 4 needs the disambiguation from must-fix E (which of the two printed commands) and
  the added `bin/crew-resume` arm from must-fix D.
- **Every line citation in the plan checks out.** `bin/spawn-crew:167-168`, `:302`, `:334`, `:425`;
  `bin/crew-takeover:38`; `bin/lib/common.sh:171`; `playbooks/_delivery.md:33`, `:37`;
  `README.md:31`. The checkout was verified byte-identical to `origin/main` for every file named
  here before any of these claims were made.

## Summary of what to change

| # | Severity | Change |
| --- | --- | --- |
| D | must-fix | Add the same `--settings "$(wm_claude_md_excludes)"` to `bin/crew-resume`'s generated `.resume.sh` (the unattended bulk-recovery path, pre-authorized after an outage), update the plan's two-site narrative to three, and assert it in `tests/crew-resume.test.sh` plus a live-verification arm. |
| E | must-fix | Close `bin/crew-takeover:39`'s exclusion-free `claude --resume <sid>` example — the concrete, copy-pasteable form the plan leaves untouched — and assert both printed forms in the test. |
| F | should-fix | Correct the claim that the prose disclaimer is a fallback if `claudeMdExcludes` regresses: it is `TARGET_IS_WM_REPO`-gated, so a global-scope member gets no fallback at all. Fix it in the risk bullet and the open question's option-B detail. |
| 1 | nit | Note that the `$WM_REPO-*` glob would silently suppress a legitimately-named future sibling repo's own `CLAUDE.md`. |
| 2 | nit | Add the `.resume.sh` assertion to implementation step 5's list. |

Rounds 1 and 2 are fully closed, and the mechanism, the direction rejections, the unconditional
application, the corrected worktree account, the disclaimer rewording, the risk section and the test
design all hold up under a third independent check with fresh reproductions. D and E are a completion
of round 2's own finding rather than new territory: once all three command-construction sites carry
the payload, the lifecycle guarantee the plan claims is actually true.
