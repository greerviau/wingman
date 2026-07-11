# Review findings: PR #6 (feat/reliability-consolidated) against the consolidated reliability plan

**Date:** 2026-07-10
**PR:** https://github.com/greerviau/wingman/pull/6 (head `d7dde15`)
**Plan:** `docs/plans/2026-07-10-wingman-reliability-consolidated-implementation.md`
**Source issues:** lead test at intake (`docs/analysis/2026-07-10-wingman-lead-suggestion-miss.md`), complete wake handling (`docs/analysis/2026-07-10-short-circuited-wake-handling.md`), silent-stall detection (plan §3-§4), prompt-freeze false positive (`docs/analysis/2026-07-10-prompt-freeze-false-positive.md`).
**Method:** full diff read against the plan and the four source analyses; branch checked out in a worktree; full test suite run; each claimed defect below reproduced live against the PR branch (repro commands inline).

## Verdict

**Final (head `f137a61`): merge-ready.** All five findings are fixed and verified by re-running the original reproductions; both approved additions (`WM_MODEL` default, communication-register norm) conform; the full suite is green (41 watch-fleet asserts, all suites passed).
Per the user's decision, the remaining anchoring refinement (verbatim full-dialog quotes on a parked pane) is accepted as a documented residual and deferred: the PR's Follow-ups section and issue #7 capture it in neutral language, with candidate refinements (selection-marker requirement, status-freshness veto) and the true-positive coverage constraints any refinement must preserve. Nothing functionally broken was found in the final pass.

History: the initial pass (head `d7dde15`) found the PR a faithful, well-tested implementation of the approved plan - every plan section maps to a matching change, the deferred items (Stop-hook ack relocation, spawn-crew nudge, auto-recovery) are correctly left out, and the constants-append avoids the `review` regression the plan warned about (guarded by tests).
Three defects were found and **reproduced live**, all in the watcher's pane backstop; none required a design change.
Findings 1 and 2 were must-fix before merge: finding 1 is the *same incident class* fix 4 exists to close, still reproducible through a different path; finding 2 broke the plan's own "more specific diagnosis wins" invariant.
Findings 2-5 were fixed at `a336b7d`; finding 1 required a second iteration (line-start anchoring) and closed at `f137a61` - see the Re-verification section.

## Finding 1 (must-fix): the prompt-freeze false positive is narrowed, not closed - a parked pane *discussing* prompts at the bottom of the screen still flips to `blocked`

**Where:** `bin/watch-fleet`, `prompt_freeze_check` (`WM_PERM_OPTION_RE` + the stability condition).

The review brief asks specifically whether the detector still substring-matches pane content that merely discusses prompts.
Mid-screen discussion no longer matches (the tail anchor works, and the shipped tests prove the incident's exact shape is refused).
But discussion in the **last 25 lines of a parked pane** still trips it, because the two remaining conditions both fail to discriminate there:

- The stability condition is ineffective for a parked member: an idle-at-prompt session's pane is **byte-static** - this is the plan's own §3.2 measurement ("idle claude panes emit zero output"). "A working Claude Code pane is never identical across polls" is only true mid-turn; parked-between-wakes is the designed steady state for `working` leads and members awaiting watchers.
- `WM_PERM_OPTION_RE` (`^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]`) matches **any markdown numbered list**, which is ubiquitous in the plans, analyses, and test fixtures wingman-repo crew display.

**Reproduced on the PR branch:** a window rendering a parked session whose transcript tail reads "…test fixture that echoes: Do you want to proceed?" followed by an unrelated three-item numbered list and an idle input box - no dialog anywhere - is flipped to `blocked` ("frozen on a permission/trust prompt…") on the watcher's second poll.
This is precisely the recursive hazard the incident report names (both 2026-07-10 misfires were on sessions working on the detector); those sessions park with this content on screen constantly.

**Suggested fix (small):** require adjacency - the numbered-options line(s) must appear within the ~3 lines immediately following the question-phrase line (a real dialog renders them together as one block).
A phrase in prose with an unrelated list elsewhere in the tail then stops matching.
Optionally also require ≥2 consecutive numbered lines (every real gate offers at least two options).
Add the parked-pane repro shape to `tests/watch-fleet.test.sh` alongside the existing z5/z6 cases.

## Finding 2 (must-fix): a real permission freeze older than `WM_STALL_IDLE` at first sighting is permanently misdiagnosed as `stalled`

**Where:** `bin/watch-fleet` loop body - ordering between `prompt_freeze_check` and `stall-check`.

`prompt_freeze_check` needs **two identical sightings** (no previous hash → returns false), but `stall-check` flips on the **first** poll if both staleness gates are already past.
A pane frozen on a real dialog for longer than `WM_STALL_IDLE` before the watcher's first-ever look at it (wingman restart, a fresh `WINGMAN_HOME`, a long fire-to-re-arm gap - any window with no prior `pane-<id>.hash`) therefore gets flagged `stalled` on poll one.
Once flipped, the member leaves the `--status working` scan, so the prompt check never gets its confirming second sighting: the misdiagnosis is **permanent**, and the operator is told "the agent likely errored" with a takeover/stand-down remedy instead of "approve the prompt".
This violates the plan's stated invariant (§2: the permission check "keeps its priority as the more specific diagnosis").

**Reproduced on the PR branch:** a window rendering a real frozen dialog (question + numbered options, static), status stamp 10 min old, pane parked past `WM_STALL_IDLE` before the watcher arms → the cycle fires `stalled: fz no pane output, status update…`, not `blocked:`.

The shipped z4 test passes only because its watcher arms within `WM_STALL_IDLE=3`s of window creation; on a slow host that test shares this race (flake risk).

**Suggested fix (small):** when the tail matches the prompt *shape* (phrase + options) but stability is not yet confirmed, `continue` past the stall check for that member this poll - a prompt-shaped pane is one `INTERVAL` away from a definitive diagnosis either way.
The fix also removes the z4 flake.

## Finding 3 (should-fix): `stall-check` clobbers a status the member self-reports during the probe gap

**Where:** `bin/lib/wm-state.py`, `cmd_stall_check`.

The live status file is read once at entry; the probe then sleeps `--probe-gap` (default 10s); the flip writes the **pre-gap snapshot** (mutated) back unconditionally.
A member that self-reports during the gap - e.g. flips to `review` with an artifact, or `blocked` with a real blocker - is overwritten back to `stalled`, and `needs-attention` announces the wrong event to the owner.

**Reproduced on the PR branch:** `crew-set --status review --artifact /tmp/plan.md` issued 2s into a 5s probe gap; final status file reads `stalled`.

The realistic window is narrow (a member waking *during* the gap usually burns enough CPU to escape via the probe), but the fix is one guard: after the probe returns false, re-read the status file and bail unless `status == "working"` and `updated` is unchanged.

## Finding 4 (should-fix, traces to the source report): the tightened `WM_PERM_PROMPT_RE` drops real Claude Code permission variants

**Where:** `bin/watch-fleet` default `WM_PERM_PROMPT_RE`; prescribed by the incident report's recommendation 3 and plan §4.1, so this is a plan-level gap the PR carries, not a developer deviation.

The old prefix `Do you want to ` matched every per-tool permission phrasing; the new list pins exactly `Do you want to proceed\?`.
Claude Code's file-edit and file-creation gates phrase differently ("Do you want to make this edit to <file>?", "Do you want to create <file>?"), so a non-bypass crew frozen on one of those no longer matches - despite the loop comment explicitly claiming the backstop "still catches freezes when bypass is disabled", where those variants are the *most common* gates.
Such a freeze now falls through to the stall path: detected ~`WM_STALL_IDLE` later with the generic errored-agent misdiagnosis, permanently (finding 2's shape).

**Suggested fix:** with the shape anchor, stability, and (per finding 1) adjacency carrying the precision, a case-sensitive `Do you want to ` prefix is safe to restore - or enumerate the known variants.
The phrase tightening was the weakest of the report's three conditions and the only one that costs recall.

## Finding 5 (should-fix): the PR description and one commit message use internal orchestration vocabulary in outward-facing text

Outward-facing artifacts (PR descriptions, commit messages, review reports) should read as normal engineering prose; the repo's own status contract states the internal term "pilot" must not appear in PRs or commit messages.
Two violations:

- **PR #6 description**, Changes section: "a re-run rule when the pilot expands an in-flight effort" → "when the user expands an in-flight effort".
- **Commit `d7dde15`** (`docs(wingman): lead test at intake, …`) body: "a standing instruction to re-run it when the pilot expands an in-flight effort" → same rewording; amend when the branch is next rebased/pushed.

In-repo code comments and wingman's operating docs (`CLAUDE.md`, `playbook/`, the watcher's directive text) legitimately use the project's own concepts - "pilot" appears there on `main` already and is the vocabulary those texts are written in; no change needed there.

## Minor notes (no action required to merge)

- **`hooks/stop-guard.sh` names `$WM_HOME/wake` unconditionally** in the new reason text. For a crew-with-reports running in the wingman repo (`WINGMAN_CREW_ID` set, `OWNER` non-empty) the wake file is `wake-<key>`. The same hook already checks the unkeyed `watch.pid`/`watch.beat` (pre-existing, from the owner-keying in PR #5), and the plan §5 prescribed this text verbatim - noted as an inherited inconsistency, and `fire()` gets it right by design.
- **`pane-<id>.hash` files are never cleaned up** on stand-down; the incident report suggested `crew-standdown` cleanup. Harmless accumulation in `~/.wingman`.
- The wake-file roster snapshot, owner-keyed wake naming, fire-time ack retention, and `LIVE_STATES`/`ATTENTION_STATES` appends all match the plan exactly; the `review`-regression guard the plan demanded is present in `tests/stall-check.test.sh`.

## Plan-conformance check (per source issue)

1. **Lead test at intake** - conforms. The threshold is stated in full exactly once (Intake), fixes the analyst→developer contradiction ("third role beyond the standard analyst→developer pair"), adds the visible verdict and the mid-flight re-run rule, removes the "don't reach for it by default" bias from Scope, and cross-references from the command vocabulary and "Appointing a lead". All five root causes in the analysis are addressed (the spawn-crew mechanical nudge is deferred, as the plan specifies).
2. **Complete wake handling** - conforms. `fire()` splits the channels (stdout = deltas + directive naming the actual `$WAKEFILE`; wake file = new events + owner-scoped roster), the Stop hook demands the roster report, CLAUDE.md's wake-loop section matches the mechanism, and the ack relocation is correctly deferred with the race documented.
3. **Silent-stall detection** - conforms. Two staleness gates nominate; the execution probe (late-started descendant, cumulative-CPU delta over the pid intersection) carries correctness; both `ps` time formats parsed; parked-member/busy/launch-time-child/vanished-root behaviors all match §3.2's measured design and are tested. Findings 2 and 3 above are the residual failure modes.
4. **Prompt-freeze hardening** - largely conforms (tail anchor, per-member `cksum` stability, case-sensitive phrases, all overridable, `continue` as the more specific diagnosis). Finding 1 is the residual false-positive class; finding 4 is the recall cost.

## Re-verification (head `a336b7d`, 2026-07-10)

Each original reproduction was re-run against the updated branch, and the two approved additions were reviewed.

- **Finding 2 - fixed and verified.** The pre-aged frozen dialog (older than `WM_STALL_IDLE` at first sighting) now diagnoses `blocked`: the `PFC_SHAPE` hold-off keeps the stall check off a prompt-shaped pane until stability confirms. The hold-off introduces no new blind spot (a changing prompt-shaped pane is repainting and thus never stall-nominated anyway), and the z8 regression test pins the behavior.
- **Finding 3 - fixed and verified.** A `review`+artifact self-report issued mid-probe-gap now survives; `stall-check` re-reads the live status after the gap and bails on any change. Verified by reproduction and by the new p6 test.
- **Finding 4 - fixed and verified.** The case-sensitive `Do you want to ` prefix is restored; the edit-gate phrasing ("Do you want to make this edit to foo.py?") is detected (z9 test), with precision explicitly reassigned to the shape/adjacency/stability conditions in the comment.
- **Finding 5 - fixed and verified.** The PR description and the amended commit (`a87be59`) both read "when the user expands an in-flight effort".
- **Finding 1 - NOT closed; reproduction still fires.** The adjacency gate (`WM_PERM_ADJ=3` lines after the phrase line) refuses a list placed *far* from the phrase, but the original documented reproduction has the natural transcript shape - a prose sentence quoting the phrase, followed two lines later by an introduced numbered list ("…three conditions: / 1. anchor… / 2. …") - which sits *inside* the adjacency window and still flips a parked member to `blocked`. The z7 regression test places the list four lines below the phrase, just outside the window, so it passes while the incident shape does not. Suggested next step: anchor the question-phrase match to the *start* of the line (allowing only whitespace or box-drawing prefix) - a real dialog renders the question as its own line, while transcript quotes are prefixed by prose/diff/quote markers; verify the anchor against one real captured dialog pane first (the §7.1 recipe), keep `Yes, I accept`/`Yes, and don.t ask` matching option-row-prefixed lines, and re-point z7 at the adjacent-list shape. A verbatim full-dialog quote at column zero remains an accepted, documented residual.

### Round 3 (head `f137a61`) - finding 1 closed and verified

- The question phrase must now render as its own line: `WM_PERM_LEAD_RE` (`^[^[:alnum:]]*([0-9]+\.[[:space:]])?`) permits only non-alphanumeric characters (whitespace, border glyphs) plus an optional option-row prefix before the phrase, so prose and diff prefixes stop matching while acceptance-row phrases ("Yes, I accept") still do. **The original reproduction no longer fires** (parked pane stays `working`, watcher keeps blocking), and the z7 test now encodes that exact adjacent-list shape. The pre-aged-freeze reproduction still lands `blocked` (the anchor did not cost recall on real dialogs).
- The live §7.1 verification surfaced a real staleness bug in the previous phrase list: the current CLI's trust dialog (v2.1.206) phrases its question differently ("Quick safety check: …") and renders it outside the adjacency window, so the old "Do you trust the files in this folder?" phrase would have missed it entirely. Detection now rides the version-stable "Yes, I trust this folder" option row, whose sibling row satisfies adjacency; the z10 test pins the captured layout.
- The status-contract contradiction is resolved: the older pilot-term sentence now defers to the communication-register section for the full rule.
- Documented residuals, accepted: a verbatim full-dialog quote at column zero, and its variant - a static numbered list whose item *begins* with a question phrase followed within the adjacency window by further numbered lines (the option-row allowance in `WM_PERM_LEAD_RE` admits it; it cannot be excluded without losing the acceptance rows). Both require quoting dialog rows essentially verbatim at line start, a far narrower surface than the incident class.

### Approved additions (both conform)

- **`WM_MODEL` default in `bin/spawn-crew`:** precedence is exactly as approved (`--model` wins, else `$WM_MODEL`, else no flag so the agent CLI's default applies); it sits beside the `WM_AGENT`/`WM_PERMISSION_MODE` harness-isolation knobs with a comment naming them; the usage header documents it and the `-h` sed range was widened to cover the grown header (verified by running `-h`); precedence is covered by three new `tests/spawn-scope.test.sh` asserts including an `unset WM_MODEL` guard against inherited environment.
- **Communication-register norm in `playbook/_status-contract.md`:** placed in the one document appended to every agent brief (correct - no per-playbook duplication), concise (intro + four bullets), and written in the register it prescribes. One consistency nit: the pre-existing paragraph directly above it still says the internal term "must not appear in the plans, reports, PRs, commit messages, **or code comments** you produce", while the new exception bullet permits those terms where wingman's existing code already uses them - contradictory instructions for an agent editing wingman's own code comments. Reconcile by scoping the older sentence to non-wingman work or folding it into the new section.

## Test suite

Full `tests/run.sh` executed in a clean worktree on the macOS deployment host, at both review heads: **all suites passed** at `d7dde15` (watch-fleet 34 asserts) and again at `a336b7d` (watch-fleet 40 asserts, including the new z7/z8/z9 detector regressions, the p6 mid-gap self-report case, and the three `WM_MODEL` precedence asserts in spawn-scope).
Note the suite being green at `a336b7d` coexists with finding 1 still reproducing: z7 encodes a non-adjacent list shape, not the incident's adjacent one - the replacement test should use the adjacent shape (list within `WM_PERM_ADJ` lines of the phrase).
