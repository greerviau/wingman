# Plan: make the pilot-location ask eager instead of reactive

## Problem

`playbooks/_status-contract.md`'s "Publishing a deliverable as a hosted Artifact" section (condition B) is currently the *only* place that asks "is the pilot genuinely remote right now" and caches the answer in `$WM_HOME/pilot-location.json`, keyed to `WINGMAN_RUN_ID`.
The check fires reactively, at the moment a crew member is about to report a `review`-state markdown `--artifact` - a single clause buried roughly 130 lines into a long contract document that a session consults for many other reasons (status states, escalation, communication register) without necessarily reaching the one paragraph that matters here.

In practice this has already been skipped: an orchestrating session went through a full deliverable-reporting cycle without ever running the check, so the pilot was never asked and no session had a cached answer to reuse.
The mechanism itself (`wm-state.py`'s `pilot-location-get`/`pilot-location-set`, keyed by `WINGMAN_RUN_ID`) is sound and already covered by `tests/pilot-location.test.sh`; the defect is entirely one of *placement* - a reliability property ("ask once, early, for the whole run") implemented as an optional step deep inside an unrelated contract, dependent on a session happening to reach and remember that clause during unrelated work.

## Constraint that shapes the fix

`bin/wingman` is a bash launcher; it stamps and exports `WINGMAN_RUN_ID`, registers `$WM_HOME/self-pane`, then `exec`s `claude`.
It cannot itself call `AskUserQuestion` - that tool only exists inside a running Claude Code turn.
So "ask right when `bin/wingman` registers its own pane" is not literally implementable in the shell script; the earliest point a question can actually be asked is the first turn of the Claude Code session `bin/wingman` boots, i.e. wingman reading its own `CLAUDE.md` for the first time in a run.
That collapses the two candidate locations named in the brief (CLAUDE.md's First run sequence, and the pane-registration point in `bin/wingman`) into one real answer: **a new, unconditional step in `CLAUDE.md`, run at the true start of every wingman session.**

## Recommended approach

Add a new top-level section to `CLAUDE.md`, positioned right after "First run (onboarding)" and before "The operating loop," that runs unconditionally at the start of every wingman session - not nested inside the "First run" checklist itself.

That placement is deliberate, not incidental: "First run (onboarding)" is explicitly conditional ("on the first launch, or any time something looks missing") and describes one-time environment setup (`bin/doctor`, `bin/discover-projects`, arming the supervisor).
The pilot-location cache is keyed to `WINGMAN_RUN_ID`, which is fresh on *every* `bin/wingman` launch - so this check needs to run every session, unconditionally, not just when something "looks missing."
Folding it into the conditional checklist would reintroduce the same failure mode this plan exists to fix: a step that reads as skippable on routine runs.
A dedicated, always-run section makes the ask impossible to miss without also making it a second, competing question later (it reuses the exact same cache, so a session that already answered it this run never asks again).

### New CLAUDE.md section (content, not final prose)

```
## Confirm the pilot's location (once per run)

Some of your own behavior, and every crew member's, depends on whether the
pilot is watching this session locally or over Remote Control right now -
there is no reliable signal for this (see
docs/analysis/2026-07-13-remote-control-transport-detectability.md), so it
must be asked. Do this now, as the first thing you do in a fresh run -
before "First run (onboarding)" and before touching the pilot's directive -
not deferred until the moment an Artifact-publish decision happens to need
it.

1. Run `$WINGMAN_STATE pilot-location-get --run-id "$WINGMAN_RUN_ID"`.
   Exit 0 means this run already has an answer (e.g. you are continuing
   after a `/clear` or context compaction, not a fresh process) - nothing
   to do.
2. On a nonzero exit, and only if `$WINGMAN_RUN_ID` is set: ask once via
   `AskUserQuestion` ("Are you viewing this session via Remote Control
   right now, or are you local at this machine?"), then cache it:
   `$WINGMAN_STATE pilot-location-set --run-id "$WINGMAN_RUN_ID" --remote <true|false>`.
3. If `$WINGMAN_RUN_ID` is unset, skip silently - this session was not
   launched via `bin/wingman` (e.g. `claude` started directly in this
   repo); every downstream consumer already treats a missing run id as
   "not remote" by design.

This is the only place this question is asked for your own session. Every
crew member you spawn afterward inherits the same `WINGMAN_RUN_ID` and
reads this cached answer (`playbooks/_status-contract.md`'s
Artifact-publish gate, condition B) rather than asking again.
```

### Crew members: no eager ask of their own

The brief asks explicitly whether an eager onboarding ask is appropriate for crew members too.
It is not, and the existing design already explains why: crew members have no session-start moment analogous to wingman's - they are spawned mid-run for one objective, and asking eagerly at each one's own start would reintroduce exactly the anti-pattern the original design rejected ("once per software-analyst, once per architect, once per research report").
By construction, wingman's new eager step runs and completes (`AskUserQuestion` blocks for an answer) before wingman does anything else in that run, including spawning any crew - so by the time a crew member exists, the cache for that `WINGMAN_RUN_ID` is already populated in the overwhelming majority of cases.

No functional change is needed to `playbooks/_status-contract.md`'s condition B: it already reads the cache first and only asks itself as a fallback.
That fallback stays, unchanged, as defensive coverage for the one remaining edge case - `WINGMAN_RUN_ID` unset or the cache file unreadable when a crew member checks - but add one clarifying sentence noting that hitting it is now the unusual case, not the routine one, since the primary ask has moved upstream to wingman's own session start.

## Files touched

- `CLAUDE.md` - add the new "Confirm the pilot's location (once per run)" section described above.
- `playbooks/_status-contract.md` - one clarifying sentence in condition B's intro, noting the primary ask now happens eagerly at wingman's own session start (`CLAUDE.md`) and that this fallback path firing is the exception, not the rule.
- No changes to `bin/wingman`, `bin/lib/wm-state.py`, or `bin/spawn-crew` - `WINGMAN_RUN_ID` stamping/export, `self-pane` registration, and the `pilot-location-get`/`-set` subcommands are already correct; this plan only relocates *when* the ask fires, not the mechanism.

## Testing strategy

This is a documentation/behavioral change with no new code path, so there is no new unit-test surface; `tests/pilot-location.test.sh` already covers the state layer (`pilot-location-get`/`-set`, run-id scoping) and needs no changes.
Validate by a fresh `bin/wingman` sit-down: confirm the location question fires once, immediately, before any directive is acted on; confirm a second directive in the same session does not ask again; confirm a crew member spawned afterward reports a cached answer (via its own condition-B check) without prompting.

## Open questions / risks

- **Unattended launches would hang.** If wingman's own session is ever started without a human present to answer (today's docs describe every wingman launch as pilot-initiated via `bin/wingman`, so this is not a documented use case, but it is worth stating plainly), an eager, blocking `AskUserQuestion` at session start would stall the entire session waiting for an answer that never comes - a strictly worse failure mode than today's reactive version, which only blocks if a deliverable-publish decision is actually reached. Flag this explicitly to whoever approves the plan; if wingman is ever launched unattended (e.g. via a scheduled routine), this design needs an unattended-safe default before that path exists.
- **Follow-up (not in scope):** an env var (e.g. `WM_PILOT_LOCATION=remote|false`) that lets the pilot pre-answer once (in shell profile, or per-invocation) to skip the prompt entirely, for anyone who finds the once-per-sit-down question unwanted. Low cost, but not needed to fix the reliability defect this plan targets, so left as a follow-up rather than folded in.
- **Trade-off worth naming, not a defect:** this moves from "sometimes asked, sometimes silently skipped" to "asked once, unconditionally, every sit-down" - a small, bounded, guaranteed cost in exchange for eliminating the reliability gap. That is the correct trade for this problem, not a compromise.
