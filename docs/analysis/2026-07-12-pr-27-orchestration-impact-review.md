# Review: PR #27 - orchestration-impact assessment

Reviewer: crew `review-pr-27-https-github-com-gr-reviewer`.
Date: 2026-07-12.
Scope: `github.com/greerviau/wingman` PR #27 (`hooks/no-direct-edit-guard.sh` + `bin/spawn-crew` + `.claude/settings.json` + `tests/no-direct-edit-guard.test.sh`), assessed specifically for whether it could degrade wingman's own orchestration abilities: context protection, delegation discipline, the crew supervision loop, and playbook contracts.

This is a narrower, orchestration-focused pass.
A prior general correctness review of this PR already exists at `docs/analysis/2026-07-11-pr-27-pretooluse-delegation-guard-review.md` (approved, after the developer fixed a Bash test-runner substring-matching bug in commit `27ebe4c`).
That fix is present in the current diff (`gh pr diff 27`); this review does not re-litigate it and focuses on the orchestration-specific angle instead.

## Verdict: approve, with one significant gap that should be documented or closed before this is treated as "issue #17 solved for leads"

The guard is a net addition, not a regression: for the case it actually covers (wingman's own top-level session, and any `lead` operating inside the wingman repo itself), it mechanically enforces delegation discipline exactly as designed, without interfering with the existing `Stop` hook, the crew supervision/wake loop, or any playbook contract.
No finding here shows the PR making current orchestration behavior *worse*.

However, one finding (below) shows the guard silently does **not** fire for the majority of real `lead` deployments - any lead spawned with `--repo <other-repo>` or `--scope global`, which is precisely the scenario CLAUDE.md describes as a lead's main job (a large, cross-repo, or repo-unclear effort).
That gap doesn't make orchestration worse than today's prompt-only baseline, but it does mean the PR's own stated scope ("active... when `WINGMAN_CREW_TYPE=lead`") overstates the protection actually delivered, and nothing in the test suite can catch this because the tests invoke the hook script directly, bypassing the settings-loading question entirely.

## Findings

### 1. [High, confirmed] The guard never loads for a `lead` spawned outside the wingman repo - the common case, not the edge case

**Files:** `.claude/settings.json` (where the hook is wired), `bin/spawn-crew` (how a lead's working directory and `--add-dir`s are set).

Claude Code loads project-level `.claude/settings.json` hooks only from the directory Claude was launched in (the project root at session start) - not from any directory added later via `--add-dir`.
This is documented behavior (Claude Code hooks/settings docs: project-level settings are single-project-scoped to the launch location; `--add-dir` only expands file-access permissions).

`bin/spawn-crew`'s launch script does `cd "$REPO"` before exec'ing `claude`, and separately does `--add-dir "$WM_REPO"` (the wingman repo) so a member grounded elsewhere can still reach wingman's `bin/` tools by absolute path.
For a `lead` spawned with `--repo <some-other-project>` or `--scope global` (workspace root, not the wingman checkout), `$REPO` is that other project or the workspace root - **not** the wingman repo - so:

- The session's project root is `<other-project>` or the workspace root.
- Wingman's `.claude/settings.json` (which carries the new `PreToolUse` hook entry) lives only in the wingman checkout, which is merely an `--add-dir` for this session.
- Per the settings-scope rule above, that hook is never loaded. `hooks/no-direct-edit-guard.sh` never runs for this lead at all, regardless of `WINGMAN_CREW_TYPE`.

The only case where a `lead`'s guard actually fires is a lead spawned with `--repo wingman` itself (i.e., a lead managing changes to wingman's own codebase - which does happen in this repo's current work, but is explicitly *not* the primary scenario CLAUDE.md describes for leads: "Spawn it with the full objective at repo or global scope as the effort demands," aimed at arbitrary target projects or cross-repo efforts).

**Failure scenario:** The pilot says "take the lead on the checkout redesign" for the team's actual product repo. Wingman appoints a lead via `bin/spawn-crew --type lead --repo checkout-service --objective "..."`. That lead session never has this guard wired at all - it can `Edit`/`Write` files or run the test suite directly with nothing but the prompt-level CLAUDE.md instruction to stop it, exactly the gap issue #17 was opened to close mechanically. The PR's own description and the hook's header comment both claim leads are covered ("stays inactive for every worker crew type... a lead... is a conductor... the same role wingman plays one layer up"); in this deployment shape that claim doesn't hold.

**Why the test suite doesn't catch it:** `tests/no-direct-edit-guard.test.sh` invokes `hooks/no-direct-edit-guard.sh` directly (`bash "$HOOK"` with a synthetic `PreToolUse` payload piped in) and asserts on the script's own stdout. That's a correct and thorough test of the script's internal branching logic, but it never goes through Claude Code's actual settings/hook-loading machinery, so "43/43 (now 54/54) pass" is evidence the logic is right *if the hook runs* - it is not evidence the hook runs for a lead in a non-wingman repo. There is no coverage anywhere in this PR of the loading/wiring question.

**Suggested direction (for the developer to design, not prescribed here):** the two real fixes are (a) stop relying on project-level scoping and wire this guard at **user scope** (`~/.claude/settings.json`) keyed purely off `WINGMAN_CREW_TYPE`/`WINGMAN_CREW_ID`, since a user-level hook fires regardless of which repo a session's cwd is in - this is the only option that actually matches the stated "any lead, anywhere" intent; or (b) if project-scoping is intentionally kept, have `bin/spawn-crew` provision the hook into the target repo/worktree for `lead` spawns (e.g., write a minimal generated `.claude/settings.json` + copy of the hook script into a repo-scoped lead's working directory) and explicitly narrow the PR's claims to say so. Given this project's stated bar ("prefer quality, correctness, robustness... over dev cost"), (a) is the more correct fix rather than special-casing per-repo provisioning. At minimum, before merge, the hook's header comment and the PR description should stop asserting blanket lead coverage and state the actual (repo-scoped) limitation, so nobody relies on a guarantee that isn't there.

### 2. [Low, note] Every top-level/lead Bash call now pays a subprocess round-trip, including the hottest orchestration paths

**File:** `hooks/no-direct-edit-guard.sh` (matcher includes `Bash`, unconditionally).

Where the guard is active, it now intercepts *every* `Bash` tool call - not just Edit/Write/NotebookEdit - and shells out to `uv run --no-project --quiet python -c ...` to decide pass-through. This includes purely read-only orchestration commands central to the supervision loop: `bin/crew-list`, `git status`, arming `bin/watch-fleet` as a background task, `bin/crew-say`, etc. Behavior is unaffected (all of these are correctly allowed), but it adds a process-spawn's worth of latency to literally every Bash call at the orchestrator layer, which cuts slightly against the "stay a lightweight orchestrator" design goal. Not a correctness issue and likely negligible in absolute terms, but worth being aware of if wingman's Bash-call volume ever grows.

### 3. [Low, note - pre-existing convention, not a new regression] Silent fail-open if `WINGMAN_CREW_TYPE` is ever missing for an actual lead

If `WINGMAN_CREW_ID` is set but `WINGMAN_CREW_TYPE` is empty or wrong (a future refactor bug, a hand-started session, or - as directly observed in this very reviewer session, which was spawned by the pre-PR-#27 `bin/spawn-crew` and has `WINGMAN_CREW_ID` set but no `WINGMAN_CREW_TYPE` at all), the guard's condition (`WINGMAN_CREW_TYPE != "lead"`) treats it as a worker and exits without guarding. This matches the repo's existing fail-open convention (`stop-guard.sh`, JSON-parse failures) and is the correct transition behavior for already-running pre-PR sessions, so it is not a new inconsistency - but it does mean the entire mechanical guarantee rests on `bin/spawn-crew` always propagating the type correctly, with no independent signal if that ever drifts.

## What was verified as correct (no degradation found)

- **Crew supervision loop:** no Bash pattern used by the wake loop, `bin/watch-fleet`, `bin/crew-list`, `bin/crew-say`, `bin/crew-ask`, or `bin/spawn-crew` itself matches the test-runner detection (confirmed by inspection of the fixed tokenized matcher and by the existing generic-Bash test coverage). The supervise/report/escalate cycle is unaffected wherever the guard is active.
- **Playbook contracts:** `playbooks/common/lead.md` and CLAUDE.md's "you never edit playbooks yourself" rule are already fully consistent with an unconditional `Edit`/`Write`/`NotebookEdit` block at orchestrator scope - neither wingman nor a lead has any sanctioned path that requires direct file edits (state changes go through `bin/` scripts via Bash), so where the guard is active it clips no legitimate capability.
- **No interference with `stop-guard.sh`/the existing `Stop` hook:** the two hooks are independent entries in `.claude/settings.json` with no shared state; full suite passes with both present.
- **Worker-type inactivity is correct by construction:** the `!= "lead"` exclusion (rather than an enumerated denylist) means every current and future worker playbook type is unguarded without needing a hook update - confirmed against `developer`, `architect`, `reviewer`, `software-analyst`, `research`.
- **The Bash test-runner false-positive bug** flagged in the prior general review (commit `9124892`) is fixed in the current diff (`27ebe4c`): matching now walks tokenized command segments rather than raw substrings, so orchestration commands like `cat tests/run.sh` or `git log --grep="go test"` are correctly allowed while actual test-runner invocations (including wrapped/chained ones) are still denied.

## Recommendation

Land the top-level-wingman protection (it works and is a clean improvement), but do not let the PR ship the claim that leads are covered without qualification. Either narrow the documentation/hook comments to state the actual repo-scoped limitation, or - preferably, given this project's stated preference for correctness over dev cost - move the guard to user-level (`~/.claude/settings.json`) scope so it actually follows `WINGMAN_CREW_TYPE`/`WINGMAN_CREW_ID` regardless of which repo a lead is grounded in.
