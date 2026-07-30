# Code review: PR #215 - mechanically exclude wingman's own CLAUDE.md from crew sessions

**Artifact reviewed:** [PR #215](https://github.com/greerviau/wingman/pull/215), head `37027c5`, base `origin/main` (`7f40b87`).
**Plan implemented:** `docs/plans/2026-07-30-mechanical-claude-md-crew-exclusion.md` (issue [#213](https://github.com/greerviau/wingman/issues/213)).
**Verdict: approve.** No must-fix items. Four nice-to-have items are recorded below; none of them block merge.

This is a code review of the actual diff, not a plan review. Every claim below is grounded either on the branch's own content (read via `git show origin/fix/mechanical-claude-md-crew-exclusion:<path>` after a fresh `git fetch`, so nothing here depends on a possibly-stale working tree) or on a live experiment this reviewer ran directly and reports in full.

---

## Summary

The change does what it claims. The exclusion payload is computed in exactly one place, consumed by exactly the three command-construction sites the plan identifies, and the orchestrator's own launch path is byte-identical to `main`. Most importantly, the fix is *empirically* effective: this reviewer independently reproduced all four leak shapes against the real repository with the real emitted payload, and confirmed each one is closed. The change also does not disturb the settings layers wingman's guard hooks depend on - verified directly rather than assumed.

One detail deserves stating up front, because it is the strongest available evidence that the bug being fixed is real and current: **this reviewer's own session is a live reproduction of it.** This is a global-scope session whose launch script predates the fix; the moment it read a file inside the wingman subtree, `/home/greer/github/wingman/CLAUDE.md` - the orchestrator's first-person operating manual - was auto-loaded into its context in full, exactly as the plan's "fourth case" describes.

---

## 1. All three sites share one mechanism

Confirmed. The payload is computed once and consumed three times; there is no per-site reimplementation.

| Site | Line | Call |
| --- | --- | --- |
| Definition | `bin/lib/common.sh:196` | `wm_claude_md_excludes()` |
| Initial spawn | `bin/spawn-crew:426` | `printf ' --settings %s' "$(quote "$(wm_claude_md_excludes)")"` |
| Manual takeover resume | `bin/crew-takeover:39` | same expression, inlined into the printed command |
| Unattended bulk recovery | `bin/crew-resume:255` | same expression, in the generated `.resume.sh` |

A repo-wide grep for `claudeMdExcludes` and for `wm_claude_md_excludes` finds no fourth construction site and no second literal copy of the JSON anywhere outside the helper, the plan, and the two doc files. All three consumers already source `bin/lib/common.sh`, so the helper needed no new wiring.

The helper is placed immediately after `quote()` in `bin/lib/common.sh`, which is where the plan put it and the natural neighbourhood - `quote()` is the other shared primitive every launch-line builder uses. Naming (`wm_` prefix), the bash-3.2-safe `printf` style, and the comment density all match the surrounding file.

**A deviation from the plan worth recording, which I judge to be an improvement rather than a defect.** Plan step 3 says both of `bin/crew-takeover`'s printed resume forms should gain the payload. The implementation instead collapsed the second form (the concrete `claude --resume $SID` example) into a plain caveat sentence with no command of its own, leaving exactly one printed command. This satisfies the plan's stated *intent* - "neither is the unpatched one a human might paste" - more robustly than the literal instruction did, because it removes the possibility of a second pasteable form existing at all. `tests/spawn-crew-claude-md-exclude.test.sh:99-100` pins this by asserting exactly one `--resume` is printed, so a future edit cannot quietly reintroduce an unpatched second form. The PR body discloses the change. Approved as-is.

I rendered the resulting output with real values and checked it end to end: it parses as valid shell (`bash -n`), and the `--settings` argument, after shell unquoting, parses as valid JSON. It is genuinely copy-pasteable, which is the whole point of that branch.

## 2. `bin/wingman` is untouched

Confirmed mechanically, not by inspection: `diff <(git show origin/main:bin/wingman) <(git show origin/fix/...:bin/wingman)` reports the files identical. `bin/wingman:45` still reads `exec claude $adddirs "$@"` with no `--settings`. The orchestrator keeps loading its own persona exactly as before.

## 3. The disclaimer is still present and its wording is accurate

Confirmed. `bin/spawn-crew:334` still injects the disclaimer, still gated on `TARGET_IS_WM_REPO`, with its substance unchanged; only the opening clause was reworded, from

> "the file `CLAUDE.md` at this repo's root, **which your harness just loaded automatically as project context**, is written entirely in first person..."

to

> "the file `CLAUDE.md` at this repo's root - **if it is anywhere in your context, whether your harness loaded it automatically or you opened it yourself** - is written entirely in first person..."

The rewording was necessary, not cosmetic: the old clause asserts as fact something the fix makes false in the normal case, which would have left the disclaimer stating a falsehood precisely when the mechanical protection was working. The new wording is true in all three reachable states - exclusion working (the premise simply does not fire), exclusion regressed (the harness did load it), and a deliberate `Read` by the member (`claudeMdExcludes` gates the memory loader, never the `Read` tool). `tests/spawn-wm-repo-note.test.sh` still passes unchanged (10 assertions, 0 failures).

## 4. Live verification - run by this reviewer, not taken on trust

I did not rely on the developer's summary. I extracted the payload the branch's helper actually emits for the real checkout, confirmed it is valid JSON, and ran paired control/treatment probes with the installed CLI (Claude Code 2.1.220) against the real repository. Each probe is content-free - it never names any marker text, so it cannot be answered from the objective itself - and asks only for the absolute paths of the CLAUDE.md memory blocks attached to context.

| Leak shape | Setup | Without the payload (control) | With the payload |
| --- | --- | --- | --- |
| Repo scope (launch-time ancestor walk) | cwd = `/home/greer/github/wingman`, no file read | **`/home/greer/github/wingman/CLAUDE.md` loaded** | absent |
| Global scope (on-demand subtree load) | cwd = `/home/greer/github`, read `wingman/bin/spawn-crew` | **`/home/greer/github/wingman/CLAUDE.md` loaded** | absent |
| Global-scope worktree copy | cwd = `/home/greer/github`, read a file inside the real sibling worktree `wingman-issue-213-developer` | **`/home/greer/github/wingman-issue-213-developer/CLAUDE.md` loaded** | absent - the `<repo>-*` glob closes it |
| Resume (the `crew-takeover` / `crew-resume` hole) | clean `--session-id` session, then `--resume` | **root `CLAUDE.md` reloaded on resume** | absent |

All four leak shapes reproduce on demand, and all four are closed by the emitted payload. The exclusion is correctly narrow in every case: the user-level `~/.claude/CLAUDE.md` and the per-project memory file remain attached throughout, so this is not a blunt suppression of all memory loading.

The resume row is worth emphasizing because it is the one an automated path depends on. The control run makes the pre-fix hole concrete: a session that answered cleanly at launch reloaded the orchestrator persona the instant it was resumed without the flag - which is exactly what `bin/crew-resume --all-died` did, unattended, to every dead member after any fleet-wide outage.

## 5. Regressions

**No regressions found.**

- **Test suite.** I ran the full suite on a clean clone of the PR branch and, separately, on a clean clone of `origin/main`, in the same environment. Both produce an **identical** failure set: the same six assertions across the same three suites. Nothing this PR touches changes the result.
- **CI is green** on the PR head (`shellcheck`, `test`, `ci` all `SUCCESS`), so the six local failures are environment-specific and do not reproduce on the runner.
- **New and extended tests pass:** `tests/spawn-crew-claude-md-exclude.test.sh` 21/21, `tests/crew-resume.test.sh` 47/47.
- **Launch-line construction is otherwise unchanged.** The new line is a single `printf` inserted between the existing `--add-dir "$WM_REPO"` and the global-scope `--add-dir` loop; the `--add-dir` behaviour, the global-scope loop, `--append-system-prompt`, and every other flag are untouched. Quoting uses the same `quote()` helper as every neighbouring flag, and I verified the composition round-trips: the emitted argument, after shell unquoting, is valid JSON.
- **Settings blast radius - checked directly, since this is the change's one real risk.** `--settings` must *add* a layer rather than replace the project settings source; if it replaced it, every crew guard hook would silently stop firing. I tested this against a purpose-built fixture with a project-level `PreToolUse` hook: the hook fires identically with and without the fix's `--settings` argument. `--settings` merges. This is a stronger check than the developer's reported smoke test, and it confirms the plan's central reason for preferring `claudeMdExcludes` over `--setting-sources`.

**One correction to the PR body's testing note.** It states "the only failures are three pre-existing, timing-sensitive `watch-fleet` tests." Locally the count is six failing assertions across three suites, and one of them is not timing-sensitive: `tests/wm-state-review-gate.test.sh:191` ("review-sign with no `WM_REVIEW_TOKEN`/`--token` must fail, not succeed") fails because the assertion at that line runs `wm_state review-sign` without clearing `WM_REVIEW_TOKEN` from the ambient environment, so it inherits a real token whenever the suite is run from inside a reviewer crew session - which is exactly what happens when a reviewer verifies a PR. Re-running that suite with `env -u WM_REVIEW_TOKEN` gives 65/65. This is a pre-existing test-isolation defect, reproduces identically on `origin/main`, is invisible in CI, and is **not** caused by this PR - but it is a real defect that will bite the next reviewer, and is worth a follow-up issue. It does not affect this verdict.

## 6. Code quality

The helper is well placed, well named, and consistent with the file's conventions. No dead code, no leftover debug artifacts, no commented-out iteration residue anywhere in the diff. The three commits are cleanly separated (fix / tests / docs). The doc additions in `docs/configuration.md` and `docs/guards.md` are accurate against the shipped behaviour, and the `playbooks/_delivery.md` clause correctly names the `<repo-path>-<crew-id>` convention that keeps a global-scope member's self-chosen worktree inside the glob.

The helper's comment block is long, but it is load-bearing rather than padding: it records why this mechanism was chosen over `--bare`/`--safe-mode`/`--setting-sources`, and explicitly names `bin/wingman` as the one site that must never call it. That is the right thing to write down at the definition site.

---

## Nice-to-have findings

None of these block merge. They are ordered by how much they matter.

### NTH-1: the "`bin/wingman` must NOT carry this" invariant has no regression guard

`bin/lib/common.sh:189` states the invariant explicitly - "`bin/wingman`'s own launch is the one site that must NOT call this" - but nothing enforces it. No test asserts that `bin/wingman` is free of `--settings`/`wm_claude_md_excludes`.

This is the single most damaging way the change could be silently undone. A future refactor that "helpfully" applies the exclusion everywhere a `claude` command is built would strip the orchestrator's own persona, and the entire suite would stay green while wingman quietly stopped being wingman. The invariant is currently protected only by a comment.

A two-line assertion in `tests/spawn-crew-claude-md-exclude.test.sh` closes it - assert `bin/wingman` contains neither `wm_claude_md_excludes` nor `claudeMdExcludes`. Cheap, and it turns the most consequential invariant in this change from prose into machinery, which is precisely the discipline this PR exists to apply.

### NTH-2: the tests assert substrings, never that the emitted payload is valid JSON

`tests/spawn-crew-claude-md-exclude.test.sh:37-48` and the `tests/crew-resume.test.sh` additions all use `assert_contains` against path fragments. A future quoting regression - in `quote()`, in the `printf`, or in how the launch script is written - could produce a payload that satisfies every one of those greps while being malformed JSON, in which case `claude` rejects `--settings` and **every crew spawn dies at startup** with a green suite.

I verified by hand that the current composition is correct (the `--settings` argument, extracted after shell unquoting, parses cleanly via `json.load`), which is exactly the property worth asserting rather than re-deriving. Extracting the `--settings` argument from the generated `.launch.sh` and piping it through `python3 -c 'import json,sys; json.load(sys.stdin)'` would make the test prove the payload *works* rather than that it *looks right*.

### NTH-3: `$WM_REPO` is interpolated into JSON, and into a glob, with no escaping

`bin/lib/common.sh:196-199` builds the payload by direct `printf` interpolation. Two silent-failure modes follow, both remote for the current path but both worth knowing:

- A checkout path containing `"` or `\` produces **malformed JSON**, and every spawn fails at launch. Loud, at least.
- A checkout path containing a picomatch metacharacter (`[`, `]`, `{`, `}`, `(`, `)`, `!`, `*`, `?`, `+`, `@`) produces a pattern that **silently matches nothing**, making the entire fix a no-op with no visible failure and a still-green test suite.

The second is the nastier one, and it is the same silent-no-op class as the symlink risk the plan already documents under "Risks and open questions" (where `pwd -P` was raised as an optional hardening the implementation did not take - reasonably, since it changes a value used across every `bin/` script). Neither applies to `/home/greer/github/wingman`. Worth a note at the helper, or a follow-up that hardens `$WM_REPO`'s derivation once for all consumers.

### NTH-4: the `<repo>-*` glob's collateral risk is in the plan but not in the shipped docs

The plan records that `/home/greer/github/wingman-*/CLAUDE.md` would silently swallow a genuine sibling repo's own legitimate `CLAUDE.md` (`wingman-web`, `wingman-docs`) for any crew member whose cwd sits above it. `docs/configuration.md` and `docs/guards.md` both describe the glob without that caveat, and plan files are not where someone debugging a mysteriously-missing project `CLAUDE.md` will look. One clause in `docs/guards.md` would close the gap. No such directory exists today.

---

## Follow-ups suggested (out of scope for this PR)

1. The `tests/wm-state-review-gate.test.sh:191` environment-inheritance defect described in section 5. Pre-existing, reproduces on `main`, invisible in CI, hits any reviewer running the suite from a crew session.
2. Widening the disclaimer's `TARGET_IS_WM_REPO` gate, with its wording re-anchored to name `$WM_REPO` rather than "this repo" - already named as a follow-up in the plan, and still the right call to keep out of this change.
