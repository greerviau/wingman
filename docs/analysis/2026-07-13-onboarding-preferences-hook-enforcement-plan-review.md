# Review: onboarding-preferences hook enforcement plan

**Artifact reviewed:** `docs/plans/2026-07-13-onboarding-preferences-hook-enforcement.md`
**Verdict:** The approach is sound and the right mechanism was chosen, but the plan has two enforcement bypasses, one deadlock path, and one environment gap that must be resolved before implementation.

The recommendation to record publish facts via a `PostToolUse` marker and gate on it via `PreToolUse`, rather than scraping the transcript JSONL, is well argued and correct.
The generalization of the pilot-location cache into a per-run preference store is clean, and the single shared key list (`hooks/lib/pilot-prefs.sh`) keeps growth cheap.
The findings below are ordered by severity.

## Must fix

### 1. The section 6 guard is bypassed by the status contract's own "only pass the flags that changed" convention

`hooks/artifact-link-guard.sh` fires only on a `crew-set` command containing both `--status review` and `--artifact <path>` (plan, section 6).
But `playbooks/_status-contract.md:28` instructs every crew member: "Only pass the flags that changed."
Two legitimate, contract-following call shapes therefore never hit the guard:

- A member that recorded `--artifact` on an earlier call (e.g. while still `working`) and later flips with a bare `crew-set --status review`.
- A member that re-enters `review` after revising the deliverable: the path did not change, so the re-entry call is `crew-set --status review --silent --summary ...` with no `--artifact` flag.

The second case is exactly the staleness scenario the plan's sha256 machinery exists to catch (a revised deliverable that was never republished), and it is the *normal* re-entry shape, not an edge case.
As specified, the stale-revision guarantee holds only when the member redundantly re-passes `--artifact`, which the contract tells it not to do.

**Fix:** fire on any `crew-set` whose segment contains `--status review`; resolve the artifact path from the command's `--artifact` when present, otherwise from the member's current `$WINGMAN_HOME/crew/<id>.json` `artifact` field (readable on disk, and non-markdown/absent values fall through to allow).
The test list in section 6 should gain both call shapes.

### 2. The command allowlist tokenizer must handle the real `$WINGMAN_STATE` invocation shape, or the onboarding gate cannot be satisfied at all

`$WINGMAN_STATE` is `uv run --no-project --quiet <abs-path>/wm-state.py` (`bin/spawn-crew:176`, `bin/lib/common.sh`'s `WM_UV`).
The tokenizer the plan reuses (`no-direct-edit-guard.sh:150`) handles `uv` only as `tokens[1] == "run"` then recurses on `tokens[2:]`, which lands on `--no-project`, not the script, and fails to match.
If `hooks/lib/cmd_match.py` inherits that behavior verbatim, the guard's allowlist denies the exact `pref-set`/`prefs-list` invocation `CLAUDE.md` mandates, and the deny reason instructs the session to run a command the same guard then denies.
The session is wedged on its own happy path.

The testing strategy says "relative-path, absolute-path, and `uv run` forms" but does not name the flag-bearing form, so the test as written can pass while the real invocation fails.

**Fix:** cmd_match.py must skip option tokens (`--*` and their values where applicable) after `uv run` before matching the script basename, and the guard test must exercise the literal `$WINGMAN_STATE` string spawn-crew exports, flags included.

### 3. A failed or refused `Artifact` publish deadlocks the section 6 gate with no named escape

When the scan passes (no `scan-failed` marker) but the `Artifact` tool call itself errors, is refused by the tool's built-in refusal categories, or fails transiently (network, CSP), no `published` marker is written either.
The guard then denies `crew-set --status review --artifact` indefinitely, and its deny reason names exactly two resolutions (publish, or scan-fail) - neither achievable.
The member can still escape by reporting `blocked` (the guard matches only `--status review`), but nothing tells it so, and the plan's open question covers only the "success signal is ambiguous" risk, not persistent publish failure.

**Fix:** have `artifact-publish-tracker.sh` record a `publish-failed` marker on an unsuccessful `Artifact` call, and have the guard treat it like `scan-failed` (allow the local-only report, with the failure noted), or at minimum extend the deny reason with the third resolution: report `blocked`/local-only after a recorded failed attempt.
This also makes the open-question fallback ("record published optimistically") unnecessary.

### 4. `bin/crew-resume` drops `WINGMAN_RUN_ID`, silently disabling the crew-side enforcement after any resume

The resume launch script (`bin/crew-resume:147-151`) exports `WINGMAN_HOME`, `WINGMAN_CREW_ID`, `WINGMAN_STATE`, `WINGMAN_BIN`, and `WINGMAN_WORKTREE` - but not `WINGMAN_RUN_ID`.
A resumed member therefore cannot satisfy `pref-get --run-id ... --key artifact_linking`, so `artifact-link-guard.sh` takes its "preference isn't `artifact`" skip and the section 6 gate is off for every resumed member; condition B's publish behavior also silently degrades to local-only.
The plan's files-touched list asserts "No changes to `bin/wingman`, `bin/spawn-crew` - `WINGMAN_RUN_ID` stamping/export is already correct" - true for those two files, but `crew-resume` re-creates the environment and was not audited.

Related, pre-existing but adjacent: `crew-resume` also omits `WINGMAN_CREW_TYPE`, so a resumed *lead* loses the delegation guard's lead activation (`no-direct-edit-guard.sh:60`).
Worth fixing in the same touch since the plan is already in this territory.

Secondary note in the same area: markers are keyed by `session_id`, and a resumed session's hook-input `session_id` may differ from the pre-crash one, so `published` markers can be lost across a resume.
That degrades safely (a deny prompting one republish), but is worth a sentence in the plan so the implementer does not treat it as a bug.

**Fix:** add `bin/crew-resume` to files touched, exporting `WINGMAN_RUN_ID` (and `WINGMAN_CREW_TYPE`) in the resume launch script, and extend `tests/crew-resume.test.sh`.

## Should fix

### 5. The onboarding gate can be satisfied without ever asking the pilot

While the gate is unsatisfied, `pref-set` is on the unconditional Bash allowlist (section 2).
A session under deny pressure can therefore self-answer all three preferences with plausible defaults and proceed - no `AskUserQuestion` ever fires.
"The values must come from the pilot's answers" is back to being prose, which is the precise failure class this plan exists to close, and "resolve the blocked call with the minimal unblocking action" is a realistic agent behavior, not a hypothetical.

The plan already designs the machinery that closes this: a `PostToolUse` marker (section 6's pattern) recording that `AskUserQuestion` completed this session, with the guard allowing `pref-set` only after that marker exists.
If instead the flexibility is *intended* (e.g. the pilot volunteers all three answers in their first message and a re-ask would be annoying), the plan should state that residual risk and the acceptance explicitly rather than leaving it implicit.

### 6. The interaction between the onboarding gate, an in-flight fleet, and `stop-guard.sh` is unexamined

"Survival & reconciliation" is a supported flow: wingman restarts mid-effort with crew in flight, and a restart mints a fresh `WINGMAN_RUN_ID`, so all preferences are unanswered again.
Until the pilot answers, the guard denies `bin/watch-fleet` arming, `crew-list`, and every `ack`/`mark-handled` call - so live crew run unwatched, and `hooks/stop-guard.sh` blocks wingman's stop while directing it to run exactly the Bash commands the preferences guard denies.
The turn does terminate (the stop-guard's two-pass design plus a pending `AskUserQuestion` end it), but the plan should name this interaction and decide deliberately: either accept the supervision gap while the ask is pending (consistent with the hard-gate philosophy, but say so), or add the watcher/attention commands to the allowlist.
The existing open question covers only fully-unattended launches, which is a different case from "restarted mid-run and the pilot is momentarily away."

### 7. Section 5 is internally inconsistent about the unset `artifact_linking` case

The plan says to treat `local`, unset, or unreadable as "local path only" (the conservative default), and in the next sentence keeps the contract's fallback-ask paragraph "updated to reference `artifact_linking`."
These pull in opposite directions: if unset conservatively means local-only, the crew-side fallback `AskUserQuestion` is dead code; if the fallback ask stays, unset means "ask," not "local."
Either is defensible; the spec must pick one, or the implementer will pick arbitrarily.
Note the guard is consistent with either choice (it skips unless the value is `artifact`), so this is a contract-text decision, not a hook-logic one.

## Minor

### 8. `hooks/lib/cmd_match.py` is described as "extracted from `no-direct-edit-guard.sh` ... shared rather than duplicated," but the files-touched list omits the donor

If the embedded Python is genuinely extracted, `hooks/no-direct-edit-guard.sh` (and `tests/no-direct-edit-guard.test.sh`) are modified files and belong in the list; if it is a copy, the plan should say "duplicated from" and accept the drift risk explicitly.
As written the diff scope is understated either way.

### 9. `bin/lib/install-user-hook.py` needs more than `--event` on the CLI

`is_registered()` (`install-user-hook.py:39-49`) hardcodes the `PreToolUse` key, so the `--event` addition must also generalize the idempotency check to the given event, or re-runs of `bin/doctor` will duplicate `SessionStart`/`PostToolUse` entries.
The plan's test extension ("register under a non-default `--event` and assert it lands under that key") should also assert re-registration is a no-op under that key.

## What holds up well

- The rejection of transcript scanning in favor of the `PostToolUse` marker is correct and well reasoned; every listed fragility (success pairing, path normalization, write-ordering) is real.
- `WINGMAN_RUN_ID` export to freshly spawned crew is confirmed correct (`bin/spawn-crew:169`), so the crew-side `pref-get` works without spawn changes, exactly as the plan claims - the gap is confined to `crew-resume` (finding 4).
- The activation predicates reuse proven patterns (`wm_is_wingman_repo_session`, `WINGMAN_CREW_ID` for crew scope) and correctly keep the onboarding gate off for leads and unrelated sessions.
- Scoping verbosity to storage-plus-one-consumption-point, with the full propagation audit deferred, is the right call for a reviewable diff.
- The open-questions section is honest about the unverified `tool_response` shape and the unattended-launch hard-stall; findings 3 and 6 sharpen rather than contradict those risks.
