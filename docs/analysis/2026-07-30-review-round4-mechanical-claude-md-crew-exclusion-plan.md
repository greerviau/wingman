# Plan review, round 4 (final): mechanically exclude wingman's root CLAUDE.md from every crew session

Fourth and final round of review on `docs/plans/2026-07-30-mechanical-claude-md-crew-exclusion.md` against
[issue #213](https://github.com/greerviau/wingman/issues/213), following round 1
(`docs/analysis/2026-07-30-review-mechanical-claude-md-crew-exclusion-plan.md`), round 2
(`docs/analysis/2026-07-30-review-round2-mechanical-claude-md-crew-exclusion-plan.md`) and round 3
(`docs/analysis/2026-07-30-review-round3-mechanical-claude-md-crew-exclusion-plan.md`).

## Verdict: **APPROVE**

No must-fix items. No should-fix items. Round 3's two must-fix (D, E), one should-fix (F) and two
nits are all genuinely closed. The plan is ready to hand to a developer.

Four nits follow, all one-line corrections a developer can absorb while implementing. None of them
warrants another plan round, and none of them changes the fix, the tests, or the verification steps.

Everything below was verified by reproducing it against the installed Claude Code 2.1.220 and by
re-deriving the plan's central completeness claim from scratch, not by reading the revision.

---

## What I reproduced myself

Rather than accept the plan's (or the previous rounds') reported grounding, I re-ran the mechanism
end to end against the **real wingman checkout**, using the plan's own content-free probe verbatim
and the plan's own exact eight-pattern payload.

| # | Setup | Result |
| --- | --- | --- |
| 1 | cwd = `/home/greer/github/wingman`, no exclusion | **Leak.** The orchestrator persona loads verbatim — the reply opened with `# You are Wingman / You are running because the **pilot** started ...`. |
| 2 | Identical, plus `--settings '<the plan's exact 8-pattern payload>'` | **`NONE`.** The exclusion suppresses it. |
| 3 | Fresh session launched with the payload (`--session-id <sid> --settings ...`), then resumed with `--resume <sid>` and **no** `--settings` | **Leak returns.** The persona is back in the resumed process's context. This is the hole at sites 2 and 3 (`bin/crew-takeover`, `bin/crew-resume`), reproduced independently. |
| 4 | Same shape, resumed **with** `--settings '<payload>'` | **`NONE`.** The remedy genuinely works across a resume, not only on first launch. |

Two further checks on the machinery itself:

- **The payload survives the generated launch script intact.** I ran the plan's proposed
  `wm_claude_md_excludes()` through the real `quote()` (`bin/lib/common.sh:171-173`) into a generated
  script and printed the argv the agent actually receives: one `--settings` argument carrying valid
  JSON with all eight patterns, and the `wingman-*` globs unexpanded (the single-quoting stops the
  shell touching them before the agent sees them).
- **`--settings` is additive, per the installed CLI's own help**: *"Path to a settings JSON file or a
  JSON string to load additional settings from."* Neither launch line emits `--settings` today, and
  no settings file in scope (the user-level `settings.json` and its local override, plus the repo's
  own `.claude/settings.json`) carries a `claudeMdExcludes` key for the new one to collide with.
  `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` is unset in the environment and appears nowhere in
  the tree outside these review documents, so the `--add-dir` carve-out the plan relies on holds.

**A fifth data point, unprompted:** this review session is itself a `--scope global` spawn grounded at
the workspace root, and wingman's root `CLAUDE.md` arrived in its context automatically — under a
`# claudeMd` system-reminder naming the file — as soon as it began reading files inside the wingman
subdirectory. That is the plan's Grounding §"fourth, previously-uncaught case" reproducing live, in
this reviewer's own transcript, without any deliberate probe. The hazard the plan describes is real
and is firing on the crew doing this very effort.

---

## Round 3's findings: all closed

### Must-fix D — `bin/crew-resume`, the unattended path — **closed**

The revision carries the third site through every place it needed to appear, not only the code change:

| where | present? |
| --- | --- |
| Its own "Exact change" subsection (plan lines 207-219), adding `--settings` alongside the existing `--add-dir` lines | yes |
| The three-site narrative (plan lines 80-98), with site 3 called out as the more serious of the two remaining and *why* (unattended; pre-authorized bulk remedy; a `.launch.sh`-only test would miss it) | yes |
| File-layout table row (line 137) and "Files touched" summary (line 300) | yes |
| Implementation step 4 (line 236) | yes |
| Test coverage in `tests/crew-resume.test.sh` rather than duplicated into the new file (table line 142, step 7) | yes |
| Live-verification case 5 (line 261) | yes |
| The `bin/crew-resume`-is-a-known-blind-spot precedent (`docs/plans/2026-07-13-onboarding-preferences-hook-enforcement.md`) | yes, line 96 |

I confirmed the mechanics the change depends on: `bin/crew-resume` sources `bin/lib/common.sh` at
line 57, so `wm_claude_md_excludes()` and `quote()` are in scope with no further plumbing; its
generated script's `--add-dir` lines are at `:253-254` exactly as the plan cites; and it restores the
member's original cwd (`:210`) before `exec`, which for a repo-scope wingman member is `$WM_REPO`
itself — the launch-time ancestor-walk shape my reproduction #1 above confirms leaks.

I also re-checked the pre-authorization claim the plan leans on for severity: `docs/runbooks/incidents.md:61`
does instruct `bin/crew-resume --all-died` to be run "immediately", and `bin/watch-fleet:1174` emits
"pre-authorized auto-recovery, run bin/crew-resume --all-died now" in its own `outage-cleared` wake
text. The plan's characterization is accurate, not rhetorical.

### Must-fix E — `bin/crew-takeover`'s second printed command — **closed**

Both printed forms now carry the payload (plan lines 195-203), and the fix is reflected everywhere it
needed to be: the file-layout table (line 136) names both lines explicitly; implementation step 3
(line 235) says "**both** printed resume-command forms"; the test bullet (line 242) asserts the
payload "in **both** printed forms" with the rationale that asserting one would certify a
partially-fixed script; and live-verification case 4 (line 260) now says to run **each one** as two
separate resumed sessions.

The current code is `bin/crew-takeover:38` (the `<your-agent-cli>` placeholder `printf`) and `:39`
(the concrete `claude --resume $SID` `echo`), exactly as the plan quotes, and `bin/crew-takeover`
sources `common.sh` at line 13. See nit 2 below for a cosmetic consequence of the chosen form.

### Should-fix F — the disclaimer-fallback claim — **closed**

Plan line 268 now states the limit plainly and correctly: the disclaimer is injected only when
`TARGET_IS_WM_REPO` is 1, so *"a future regression of `claudeMdExcludes` would leave a
repo-scope-targeting-wingman spawn with the disclaimer as backup, but a global-scope spawn with no
defense at all, silently."* I re-confirmed the gate at `bin/spawn-crew:167-168`
(`[ "$SCOPE" = repo ] && [ "$REPO" = "$WM_REPO" ]`) and the injection at `:333-334`.

The embedded open question is also fixed, which round 3 specifically called out because the human
answers from that text: the false "the existing prose disclaimer already provides a fallback" clause
is gone from option B, and option A's detail now carries the corrected statement — *"even that
fallback is partial: the disclaimer only covers a repo-scope spawn targeting wingman, not the
global-scope shape this plan itself found newly-hazardous."*

The "widen the disclaimer's gate" follow-up is named rather than folded in, with reasoning I checked
and agree with: the current wording says "the file `CLAUDE.md` at **this repo's root**", which for a
member targeting some unrelated repo would wrongly describe *that* project's legitimate instructions
as the wingman persona. Widening correctly means re-anchoring the wording to `$WM_REPO`, which is a
real (if modest) additional change. Leaving it as a follow-up is the right call.

### Round 3's nits — both closed

1. **The `$WM_REPO-*` glob can swallow a sibling repo's legitimate `CLAUDE.md`** — plan line 271,
   with the silent-failure mode named and the parallel to the `--setting-sources` rejection drawn
   explicitly. I verified the "no such directory exists today" claim myself: `/home/greer/github/wingman`
   is the only match under its parent, and it is a real directory, not a symlink.
2. **The `.resume.sh` assertion** — implementation step 7 and the file-layout table row for
   `tests/crew-resume.test.sh`. I confirmed that file already reads the generated `.resume.sh`
   (`tests/crew-resume.test.sh:38, :62`), so this is an added assertion to an existing harness, as
   the plan says.

---

## The exhaustive-sweep claim, re-derived from scratch

This is the finding class that grew for three consecutive rounds (`spawn-crew` → `crew-takeover` →
`crew-resume`), so I did not check the delta. I re-enumerated every site in the repository that
constructs or prints an agent launch or resume command line, from zero.

**Every `exec` of an agent binary, whole tree:**

```
$ grep -rn "^\s*exec \|printf 'exec\|echo \"exec\|'exec " bin/ hooks/
bin/crew-resume:250:    printf 'exec %s' "${WM_AGENT:-claude}"
bin/spawn-crew:402:    printf 'exec %s' "${WM_AGENT:-claude}"
bin/wingman:45:exec claude $adddirs "$@"
```

**Every launch-line flag, cross-checked independently** (`--permission-mode`, `--session-id`,
`--append-system-prompt`, `--add-dir`, `--resume`) across `bin/`, `bin/lib/`, `hooks/`, `playbooks/`,
`.claude/`, `docs/` and `README.md`: the only *emitting* occurrences are inside those same three
scripts, plus the two `echo`/`printf` lines at `bin/crew-takeover:38-39`. Everything else is prose or
a flag on an unrelated tool (`claude-gate-check.py --settings`, `install-user-hook.py --settings`).

**The complete site list, and its disposition:**

| # | Site | Kind | Disposition |
| --- | --- | --- | --- |
| 1 | `bin/spawn-crew:402` (payload lands after `:425`) | crew's first process, `exec` | covered |
| 2 | `bin/crew-takeover:38` | printed, `<your-agent-cli>` placeholder | covered |
| 3 | `bin/crew-takeover:39` | printed, concrete `claude --resume` | covered |
| 4 | `bin/crew-resume:250` (payload lands after `:254`) | unattended relaunch, `exec` | covered |
| — | `bin/wingman:45` | the orchestrator's own launch | **deliberately excluded — correct** |

**Places I checked that turn out not to be sites:**

- **`.claude/commands/*.md`** (the eleven slash commands, including `takeover.md` and `spawn.md`):
  every one delegates to a `bin/` script. None constructs or prints an agent command line itself.
  This was the most plausible candidate for a fourth site and it is clean.
- **`hooks/`**: no hook launches or prints an agent command line.
- **`docs/`** (`architecture.md`, `fleet-resilience.md`, `configuration.md`, `runbooks/incidents.md`,
  `README.md`): every `claude --resume` mention is prose describing what `bin/crew-resume` does, or a
  `bin/crew-takeover`/`bin/crew-resume` invocation. No copy-pasteable agent command line.
  `README.md:31` documents the two orchestrator launches (`bin/wingman`, bare `claude`), which are
  the deliberately-excluded case.
- **`playbooks/`**: no agent command line; recovery is always via `bin/crew-takeover`.
- **`tests/`**: assertions and stubs, not sites a real session launches from.

**Conclusion: the plan's "exactly three sites, one deliberate exclusion" is complete and correct.**
The set has stopped growing, and I have an independent derivation rather than a confirmation of the
plan's own.

One boundary case worth naming — see nit 1.

---

## Standing constraints, re-confirmed

- **The orchestrator's own launch is genuinely untouched.** `bin/wingman:45` is
  `exec claude $adddirs "$@"` — no `--settings`, and it is the one `exec` site the plan changes
  nothing about. The plan lists it as `**Unchanged**` in both the file-layout table (line 139) and
  the "Files touched" summary (line 305). The bare-`claude`-from-the-repo-root path
  (`README.md:31`) is likewise untouched, since the exclusion only ever enters a *crew* member's
  generated command. `CLAUDE.md` itself is unchanged.
- **The disclaimer is preserved and now accurately worded.** Present at `bin/spawn-crew:334`, still
  `TARGET_IS_WM_REPO`-gated, substance intact; only the opening clause changes, to a form that holds
  whether the exclusion worked, failed, or the member opened the file itself. I checked one thing the
  previous rounds did not: the existing regression test keys on
  `NOTE_MARKER="About this repo's CLAUDE.md"` (`tests/spawn-wm-repo-note.test.sh:18`), the bold label
  the reword leaves untouched — so the reword does not silently break that test.
- **Blast radius is minimal.** One new helper, one line each at three emitting sites, one clause in a
  playbook, two test additions, two doc sentences. `--settings` is additive by the CLI's own help,
  the payload carries a single key, and nothing outside memory-file loading moves. I also checked
  every existing assertion in the suite that reads a generated `.launch.sh` or `.resume.sh`
  (`tests/spawn-scope.test.sh`, `tests/config-file.test.sh`, `tests/crew-resume.test.sh`,
  `tests/spawn-wm-repo-note.test.sh`) — **none breaks** under the added `--settings` line, including
  the `assert_false`-style negative assertions, since the payload names only `$WM_REPO` paths. Step
  8's "the full suite passes" is a safe expectation.
- **The verification steps are content-free and executable.** The probe at plan line 255 is genuinely
  content-free; I used it verbatim for reproductions 1 and 2 above and it discriminated cleanly. Case
  4 is now unambiguous (both printed forms, run separately), case 5 covers the unattended path, case
  3 is correctly pinned to global scope, and cases 6 and 7 (orchestrator unaffected, guard hooks
  unaffected) are runnable as written. See nit 4 for one hygiene note about using the probe verbatim.
- **Every line citation in the plan checks out.** `bin/spawn-crew:167-168`, `:302`, `:333-335`,
  `:402`, `:425`; `bin/crew-takeover:38-39`; `bin/crew-resume:250`, `:253-254`;
  `bin/lib/common.sh:171-173`; `playbooks/_delivery.md:33`, `:37`; `docs/configuration.md:70`;
  `docs/runbooks/incidents.md`; `bin/wingman:45`. My checkout is one commit behind `origin/main`, and
  that commit adds four `docs/analysis/` post-mortems only — no file cited here differs from
  `origin/main`.

---

## Nits

None of these blocks the hand-off; all four are one-line corrections for whoever implements.

1. **The sweep's parenthetical is slightly broader than its own claim.** Plan line 80 says the grep
   covered "every `$WM_AGENT`/hardcoded-`claude` exec site **and every literal example command a
   human might copy-paste**." Strictly, one more literal `claude` a human is told to run exists:
   `bin/spawn-crew:236`'s refusal message, *"Run 'claude' there once, interactively, and accept the
   trust dialog."* It is correctly out of scope — that is the human's own interactive session in the
   *target* repo, and when the target is wingman it is exactly the orchestrator shape that **must**
   load `CLAUDE.md` — but naming it as considered-and-excluded, alongside `bin/wingman`, would make
   the completeness claim airtight on its face rather than requiring the reader to re-derive it. The
   narrower claim in the same sentence ("a crew session's agent command line is constructed or
   printed in three places") is exactly right.

2. **`bin/crew-takeover:39`'s rendered output collides with its own display quoting.** I rendered
   both proposed forms. Line 39 becomes:

   ```
   (e.g. with Claude Code: 'claude --resume <sid> --settings '{"claudeMdExcludes":[... ~390 chars ...]}'' - resume is refused if the session is still live.)
   ```

   The payload's closing `'` abuts the sentence's own display quote, so the line ends `}'' - resume`,
   and "the bit between the quotes" no longer has an unambiguous boundary. This is cosmetic, not a
   correctness hole: a human who mis-copies gets an unterminated-quote continuation prompt, a loud
   failure, not a silent leak — and the payload *is* present, which is what must-fix E required.
   Still, since line 39 exists precisely to be the copyable form, dropping its outer display quotes
   (or taking round 3's other suggestion — reduce line 39 to the "resume is refused if the session is
   still live" caveat and let line 38 be the single command) would leave exactly one unambiguous copy
   target. Line 38's form renders cleanly and needs nothing.

3. **Two small inaccuracies in the plan's own file references**, neither affecting the work:
   - Step 8 (line 244) says `tests/spawn-wm-repo-note.test.sh` is unaffected "*— it inspects
     `.sysprompt.md`, not `.launch.sh`*". It does also inspect `.launch.sh`, at `:75-77`. The
     conclusion is still right (the test is unaffected: none of its assertions match the new
     payload), just not for the stated reason. Worth knowing separately: that file's
     `grep -qF '$TEST_REPO' '$glaunch'` pin assertion is *already* tautological today, because
     `bin/spawn-crew:425` emits `--add-dir "$WM_REPO"` unconditionally — a pre-existing weakness this
     change neither causes nor worsens, but a candidate for tightening to match `--add-dir` if anyone
     is in that file anyway.
   - Step 9 / the table (line 144) place the `docs/guards.md` sentence "near the existing CLAUDE.md/persona
     discussion". There is no such discussion — `docs/guards.md` mentions `CLAUDE.md` once, in
     passing, at line 8. Take the plan's own alternative branch: a new short bullet under
     "## Mechanical guards".

4. **Use the live-verification probe verbatim, including the "without reading any other file"
   clause.** While reproducing, I once shortened the probe by dropping that clause — and the session
   answered by opening `CLAUDE.md` with the `Read` tool and reporting its contents, which reads as a
   leak but is not one. `claudeMdExcludes` is checked in the memory loader only, never in `Read`
   (the plan says exactly this at line 126), so a member that opens the file on its own initiative
   will always find it. The plan's wording already forbids this correctly; this is a note for
   whoever runs the probes, and it corroborates the plan's own "learned the hard way" paragraph about
   probe phrasing (line 252) rather than contradicting it.

---

## Summary

| # | Severity | Item |
| --- | --- | --- |
| D | closed | `bin/crew-resume` covered at the code, narrative, table, step, test and live-verification level. |
| E | closed | Both of `bin/crew-takeover`'s printed forms carry the payload; both asserted; both run in live verification. |
| F | closed | The disclaimer-fallback limit stated correctly in the risk bullet *and* in the open question the human answers from. |
| 1, 2 (round 3) | closed | Sibling-repo glob risk documented; `.resume.sh` assertion in the step list. |
| 1-4 (round 4) | nit | Name `bin/spawn-crew:236` as considered-and-excluded; line 39's display quoting; two file-reference corrections; use the probe verbatim. |

The recommended mechanism is right, the three-site coverage is now complete and independently
re-derived, the guarantee is stated honestly (including the one global-scope worktree residual it
cannot close mechanically), the orchestrator is untouched, the disclaimer is preserved and now
accurately worded, and the verification plan proves the thing the issue asked to be proven.

**Approved. Hand it to a developer.**
