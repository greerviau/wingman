# Review: spec for new wingman-specific Claude Code skills (`/watch`, `/say`+`/ask`, `/prefs`)

- **Artifact reviewed:** `docs/plans/2026-07-13-wingman-skills-for-robust-operation.md`
- **Reviewer:** independent reviewer engagement, 2026-07-13
- **Verdict:** **request-changes** (blocking defects in the `/watch` design; `/say` + `/ask` are approvable as-is)

## Summary

The spec is well-researched and unusually honest about its own limits: it correctly states that a slash command is not a callback, it correctly separates the watcher-kill root cause into its own filed issue (#64) instead of pretending the skill fixes it, and it correctly identifies a real, verified permission-parity gap for `bin/crew-say` / `bin/crew-ask`.
The `/say` and `/ask` designs are sound and consistent with the existing convention.

The `/watch` design, however, rests on three factual premises about `bin/watch-fleet`'s output contract that do not hold against the code.
As written, the skill would **misclassify every genuine fire as a spurious kill**, silently swallow it, and report nothing to the requester - the exact inverse of its purpose - and can additionally drive an unbounded arm/wake loop.
These are mechanical, verifiable defects, not style disagreements, so the plan should not be implemented as specified.

The `/prefs` design has a separate blocking interaction with `hooks/pilot-preferences-guard.sh` that the spec does not mention at all.

---

## Must-fix findings

### F1 (blocking). The `/watch` exit classifier reads a stdout shape `watch-fleet` never produces

The spec's step 1 (plan line 73) classifies a wake by whether *"stdout begins with one of `blocked:`/`review:`/`done:`/`died:`/`stalled:`/`remote-control-dropped:`"*.

`bin/watch-fleet` always prints its arm line to **stdout** first:

- `bin/watch-fleet:312` - `wm_ok "watcher: armed pid=$$ (interval ${INTERVAL}s)"`
- `bin/lib/common.sh:58` - `wm_ok() { printf ... }` - **stdout**, not stderr (unlike `wm_warn`/`wm_err`, which are `>&2`).

So the background task's stdout is always:

```
✓ watcher: armed pid=12345 (interval 5s)
review: <crew-id> <note>
--
The lines above are state-change deltas, not the full picture.
...
```

**Failure:** stdout never *begins* with a reason prefix. Under the spec's literal rule, a genuine `review`/`blocked`/`died` fire falls into the "unrecognized exit" branch, which instructs the session to **report nothing to the pilot** and log the event as a spurious kill.
Every crew event would be silently swallowed while `watch-spurious.log` filled with what were actually real fires.
This turns the one skill aimed at supervision reliability into a supervision blackhole.

**Fix:** classify by scanning the captured lines for a reason-prefix match *anywhere* (the fire block is emitted after the arm line, and is terminated by the literal `--` separator at `watch-fleet:424`), not by the first line. The recognized-prefix list itself is correct and complete today: `wm_state group-attention` (`bin/lib/wm-state.py:925,941`) keeps its synthetic correlated rows under the existing `died`/`stalled` statuses, so mass-death and API-outage batches do not introduce a new prefix.

### F2 (blocking). "Just arm, a redundant arm is safe and free" is false in wake terms and can livelock

Step 2 (plan line 75) says *"`bin/watch-fleet`'s own singleton guard (`cycle_live`) makes a redundant arm safe and free, so there is no need to check `--status` first - just arm."*

Safe, yes: it will not start a rival loop. Free, no. When a cycle is already live, the arm **exits immediately** (`watch-fleet:301-305`) after printing:

```
✓ watcher: already armed and healthy - one cycle is live (pid N, beacon Ms ago). Nothing to do; this pid is the EXISTING watcher, never a target to stop or kill.
```

A harness-tracked background task that completes **re-invokes the session** - that is the entire wake mechanism. So a redundant arm produces an immediate wake carrying that line, which under the spec's classifier is an "unrecognized exit" → logged as a spurious kill → **arm again** → healthy → immediate exit → wake → ... a self-sustaining loop that burns a turn per iteration, pollutes `watch-spurious.log`, and never touches the real (perfectly healthy) cycle.

This also directly contradicts `CLAUDE.md`'s existing rule (*"Read the arm's status line as truth: `armed` ... `healthy` (a live cycle already exists - do not start another) ... Do not churn extra arms while one is `healthy`"*), which the spec silently reverses without saying it is doing so.

Given the spec's own framing - that the observed incident was a **stuck stop-hook loop** - shipping a skill that can manufacture a fresh wake loop is the wrong direction.

**Fix:** the classifier must recognize three arm-time outcomes explicitly, and the `healthy` outcome must mean *"a cycle is already live; do nothing and end the turn"*, never *"spurious kill, log and re-arm"*.

### F3 (blocking). The spurious-kill log has no `allowed-tools` grant - and the classification logic belongs in `bin/`, not in prose

The proposed frontmatter (plan lines 63-68) grants `Bash(bin/watch-fleet:*)`, `Bash(bin/crew-list:*)`, `Read(~/.wingman/wake)`.
Step 1 then instructs the session to append a line to `$WINGMAN_HOME/watch-spurious.log`. Nothing in the grant permits a write - not `Write`, not a `Bash(printf:*)`/`Bash(echo:*)` shape.

**Failure:** every spurious-kill recovery fires an interactive permission prompt - on the exact code path whose stated purpose is *silent* recovery, in a spec whose second recommendation exists precisely to eliminate permission-prompt friction.

There is a better fix than widening the grant. This repo's own convention is *logic in `bin/`, prose in the skill* - all seven existing skills are ~1:1 wrappers over one `bin/` verb, and `tests/` covers the `bin/` and `hooks/` layer (`tests/*.test.sh`), not skill prose. The classifier in F1/F2 is a state machine with three branches and a hard dependency on `watch-fleet`'s exact output contract; encoding it as a prose checklist in a markdown file makes it untestable and guarantees it drifts from `watch-fleet` (a risk the spec itself names at line 163, then accepts).

**Recommendation:** put the classification and the bookkeeping in a small `bin/` verb (e.g. `bin/watch-fleet --classify`, reading the prior cycle's captured output, or having `watch-fleet` record its own exit reason to a log on the way out), keep `/watch` a thin wrapper as the convention requires, and cover the branches in `tests/`.
The spec's claim that *"No changes to any `bin/` script are required"* (line 159) is the root of this problem, not a virtue of the design.

### F4 (blocking). `/prefs` is denied by the very guard it is meant to complement

`hooks/pilot-preferences-guard.sh` denies **every** tool call while a required preference is unanswered, with an allowlist of exactly: `AskUserQuestion`; `Read` of `$WM_HOME/wake`; and `Bash` whose every segment resolves to `wm-state.py prefs-list|pref-get`, `wm-state.py pref-set` (only after an `AskUserQuestion` has completed), `crew-list`, `watch-fleet`, or `crew-ask await` (guard lines 221-262).

A skill invoked by wingman itself is a **tool call** (`Skill`/`SlashCommand`), and it is not on that allowlist. So while preferences are unanswered - the only moment `/prefs` has any purpose - a self-invoked `/prefs` is **denied**.
Only a pilot *typing* `/prefs` (client-side prompt expansion, no `PreToolUse`) would work, which is not the use case the spec argues for (it argues for wingman invoking it proactively at session start, plan line 118).

The spec's testing strategy (line 149) has this backwards: it proposes confirming the skill *"does not regress the existing hard-deny behavior"*, when the actual interaction is that the hard-deny blocks the skill.

**This finding also lands on `/watch`.** The guard deliberately carves out `bin/watch-fleet`, `bin/crew-list`, `bin/crew-ask await`, and reading `$WM_HOME/wake` **as bare Bash commands**, so that fleet supervision keeps working while the preferences gate pends - the behavior `docs/analysis/2026-07-13-unattended-boot-launch-behavior.md` documents and relies on. If `CLAUDE.md`'s wake-loop section is rewritten to say *"run `/watch`"* in place of the raw command (plan line 58), then during a pending gate the skill is denied and the documented fallback is gone.

**Fix:** either extend the guard's allowlist to accept the specific `Skill`/`SlashCommand` invocations that are safe during the gate (`watch`, `status`, `prefs`), or keep the raw `bin/watch-fleet` command documented in `CLAUDE.md` as the gate-time path. Either way the spec must state which, because today it silently breaks a deliberately-engineered exemption.

### F5 (blocking). The explicit `timeout: 600000` is not "free" - it may *create* the failure class it claims to guard against

Step 2 (plan line 75) instructs arming with an explicit `timeout` of 600000ms, calling it *"a defensive floor... there is no reason to leave an idle-Bash-tool timeout artifact as an open question when specifying the max is free."*

The spec's own experiment (line 28) is the argument against this: a backgrounded `sleep 300` with **no** `timeout` parameter ran to completion, past the documented 120s default. That is evidence the Bash timeout does not govern backgrounded tasks the way it governs foreground ones. Two possibilities follow, and both argue against setting it:

- the parameter is ignored for background tasks → setting it is a no-op, and the "open question" is not actually closed; or
- the parameter *is* honored → a quiet fleet, which routinely blocks far longer than 10 minutes, gets its watcher **killed every 600 seconds**, manufacturing exactly the spurious-death class the skill is built to absorb, on a 10-minute cadence, forever. Combined with F1/F2, that is a permanent churn loop.

The spec explicitly declined to run the 11-minute test that would settle this (line 28).

**Fix:** do not set the timeout without that empirical test. If the intent is genuinely defensive, the test is cheap relative to the risk of converting an unbounded watcher into a self-killing one.

---

## Should-fix findings

### F6. `/ask` overstates that the inline answer always suffices

Plan line 108 states that `crew-ask await`'s fire *"already embeds the distilled answer directly in its stdout reason line... no separate roster read... is needed."*
That holds only when the delegate answered inline. When the delegate used `--answer-file`, `bin/crew-ask:147` prints `answered: <req> <ans> (detail: <file>)`, and the fire's own directive (`crew-ask:132`) says to read `$WM_HOME/ask/<req>.json` for the full answer.
`/ask`'s body should include that read, and its `allowed-tools` needs a matching `Read(~/.wingman/ask/*)` grant, or the detail path prompts.

### F7. `Read(~/.wingman/wake)` hardcodes a path that is configurable and owner-keyed

`WM_HOME` is `${WINGMAN_HOME:-$HOME/.wingman}` and the wake file is owner-keyed (`wake-<owner>` for a lead; bare `wake` only for owner `""`). The grant is correct for wingman's own session in the default install and wrong everywhere else. Acceptable if the skill is explicitly scoped to wingman's own top-level session - but say so, since `/watch`'s `argument-hint` advertises `[--owner <lead-id>]`, which implies lead use and would read the wrong file.

### F8. The stuck-stop-hook-loop incident is never root-caused

The spec's headline justification is an incident where the orchestrator *"forgot to re-arm the watcher once (causing a stuck stop-hook loop)"*, but it never explains why the loop got **stuck**. `hooks/stop-guard.sh` is explicitly designed not to loop (it respects `stop_hook_active`, blocks once, and pass 2 marks the captured scratch set handled and allows the stop). A loop that nonetheless got stuck means one of those mechanisms did not behave as designed - and that is a bug in the guard or in the ack/handled interplay, not something a naming convention fixes.
Given F2, one plausible mechanism is already visible: a re-arm that returns `healthy` immediately, wakes the session, and re-enters the same handling path.
**Recommend** the stuck-loop incident get its own root-cause pass (a sibling to issue #64) before `/watch` is credited with addressing it.

### F9. The watcher-kill hypothesis set is incomplete, and #64 does not cover the observed shape

The investigation is good and the separation is right (see "Answers", Q3). Two gaps worth recording:

- A `PreToolUse` guard (issue #64) can only deny a kill **issued as a tool call by the session it guards**. If the observed kill originated outside the session - a harness-side reap of background tasks across a `/clear` or a context compaction, the systemd `--user` timer path, an OOM kill, a stray signal (the codebase already carries scar tissue for this: `watch-fleet:73`'s unconditional `trap '' URG`, added because a stray SIGURG terminated the loop with exit 144) - then #64 changes nothing, and the spec's claim that it is *"a prerequisite for `/watch`'s design to be complete"* (line 164) does not hold.
- **Harness-side reaping across compaction/`/clear` is not in the hypothesis set at all**, and it fits the observed shape better than a self-inflicted kill does: it kills only the background child, leaves the parent session alive and able to notice, and wingman sessions compact frequently. It is also cheap to test.

The forensic capture the spec proposes is the right instinct; note that a SIGKILL leaves `$WM_HOME/watch.pid` behind (the `INT TERM` trap at `watch-fleet:311` does not run), while a SIGTERM removes it and exits 0 - so pidfile presence at wake time is itself a usable signal for distinguishing kill classes. Capture that in `bin/`, per F3.

### F10. The `/prefs` `allowed-tools` command shape is wrong, and is verified against the wrong matcher

Two separate problems in plan lines 126 and 137:

- The pattern uses a **relative** path (`bin/lib/wm-state.py`), but `$WINGMAN_STATE` expands to an **absolute** one (`uv run --no-project --quiet /home/agents/github/wingman/bin/lib/wm-state.py`). A prefix-matched grant against the relative form will not match the command actually run.
- The spec says to verify the shape against *"what `hooks/lib/cmd_match.py`-based tooling expects."* That is a category error: `allowed-tools` is matched by Claude Code's own permission engine; `cmd_match.py` is wingman's *hook-side* resolver. Both matter here, but they are different matchers with different rules, and conflating them is how a grant ends up passing one and failing the other.

Also: `/prefs`'s body calls `AskUserQuestion`, which is not in its `allowed-tools`. Whether slash-command `allowed-tools` is an additive grant or a restrictive whitelist decides whether that is harmless or fatal; the spec should establish which before shipping, and list `AskUserQuestion` either way.

### F11. Testing strategy misses the cases that would have caught F1/F2

The `/watch` test plan (line 147) proposes a natural fire and a manual `kill`. Add: (a) assert on the **actual captured stdout of a real fire** (this is the test that catches F1); (b) `SIGKILL` and `SIGTERM` separately - they produce different exits and different pidfile residue; (c) an arm while a cycle is already live, asserting the skill ends the turn without re-arming (catches F2).

---

## What the spec gets right

Worth stating explicitly, since the findings above are all critical:

- The verified permission-parity gap for `bin/crew-say` / `bin/crew-ask` is **real and correctly diagnosed**. Confirmed independently: `.claude/settings.json` allows only `Bash(bin/crew-standdown:*)`, `.claude/settings.local.json` only `bin/crew-list`, no `.claude/commands/*.md` names either verb, and `bin/wingman` execs `claude` with no bypass permission mode - so wingman's own session genuinely prompts on every `crew-say`. `blocked.md` really does promise a relay it has no grant for.
- The `/say` and `/ask` designs are consistent with the existing convention (thin wrapper, narrow `allowed-tools`, fixed reporting shape) and carry no new failure modes.
- The honesty about `/prefs` being marginal, and about a skill not being a callback, is the right register for a spec.
- The refusal to let the skill stand in for the mechanical fix (issue #64) is correct and should be preserved through any rework.

---

## Answers to the four questions posed

**Q1. Is the priority ranking sound?** The *rationale* is sound (highest-impact observed failure first), but the ranking should be **inverted in practice**: `/say` + `/ask` is the only candidate that is verified, low-risk, and introduces no new failure modes - it can be built today. `/watch` as specified would regress supervision (F1) and can livelock (F2); it is not ready to be built first. Build `/say`+`/ask` while `/watch`'s design is reworked. `/prefs` last, unchanged - and blocked on F4 regardless.

**Q2. Does `/watch` make arm-report-rearm structurally reliable, or is it a prose checklist restated as a skill?** As specified, it is closer to the latter, and the spec is admirably candid about the reason (a slash command is not a callback; nothing enforces its invocation). The genuine structural enforcement already exists and is not the skill: `hooks/stop-guard.sh` blocks a stop with crew in flight and no live watcher, and blocks once per unhandled event. What `/watch` legitimately adds is (a) collapsing four remembered steps into one, and (b) exit classification with silent auto-recovery - which is real value, but *only* if the classification is correct, and today it is not (F1, F2). Moving that classification into `bin/` where it can be tested (F3) is what would make it structural rather than aspirational.

**Q3. Does it correctly address the externally-killed watcher, or at least flag it as a separate root-cause bug?** **Yes - this is the strongest part of the spec.** It investigates empirically, rules out the naive timeout theory with an actual test, finds a precedented mechanism, files issue #64 (confirmed OPEN) for the mechanical fix, and states plainly that the skill mitigates rather than fixes. It does not silently assume the skill closes it. The caveats are F9 (the hypothesis set is incomplete - harness-side reaping across compaction is unexamined and fits the observed shape better; and #64 cannot cover a kill that did not originate as a tool call in the guarded session) and F5 (the "free" timeout may itself become a kill source).

**Q4. Are `/say`, `/ask`, and `/prefs` scoped consistently with the existing skills?** `/say` and `/ask`: yes - thin wrappers, narrow grants, matching the `standdown`/`takeover` shape (with F6's small correction to `/ask`). `/prefs`: not consistently, and not viably - it is the only proposed skill whose primary tool is `AskUserQuestion` rather than a `bin/` verb, its grant shape is wrong (F10), and it is denied by the preferences guard at the only moment it matters (F4). `/watch` is the real outlier: it is the first skill with branching logic, a wake boundary, and a file write, which is exactly why its logic belongs in `bin/`.

---

## Recommended disposition

1. **Build `/say` and `/ask` now** (with F6 applied). They are correct, verified, and independent of everything else here.
2. **Rework `/watch` before building it**: fix the classifier against `watch-fleet`'s real output contract (F1), handle the `healthy` arm outcome (F2), move the classification and logging into `bin/` with test coverage (F3), resolve the guard interaction (F4), and either test or drop the explicit timeout (F5).
3. **Root-cause the stuck stop-hook loop separately** (F8) - it is the incident actually cited as justification, and it remains unexplained.
4. **Defer `/prefs`** until F4 is resolved; as specified it cannot run.
</content>
