# Re-review: wingman-specific skills for robust operation (r2)

**Artifact reviewed:** `docs/plans/2026-07-13-wingman-skills-for-robust-operation.md` (revision r2)
**Prior review:** `docs/analysis/2026-07-13-review-wingman-skills-for-robust-operation-plan.md` (request-changes, 5 blocking items)
**Date:** 2026-07-13
**Verdict: request-changes**

## Summary

All five previously-blocking items were genuinely engaged with, not merely acknowledged. Four are correctly fixed (F1, F2, F5, and the `/prefs` half of F4). The revision's quality is materially higher than r1's: every line number it cites (`watch-fleet:73,302,311,312,424`, `wm-state.py:69`) is exact, and the F5 empirical test is the right way to have closed that question.

Two items are only nominally closed, because both rest on an unstated assumption about **how `bin/watch-fleet --classify` is actually invoked** - and that assumption is provably false against this repo's own guard. Separately, the fix for F2 closes the livelock on the `healthy` path but leaves the identical livelock open on the new `spurious` path.

The `/say` + `/ask` design (priority 1) remains sound and is unaffected by every finding below. It can proceed to implementation independently and immediately.

## Status of the five prior findings

| Prior finding | Status |
| --- | --- |
| F1 - classifier read stdout's first line, swallowing every real fire | **Fixed**, with one gap (finding 3) |
| F2 - redundant arm returns `healthy`, livelocks | **Fixed** on the `healthy` path; same defect reintroduced on the `spurious` path (finding 2) |
| F3 - no write grant for the log; logic untestable in prose | **Partially fixed**; the grant-sufficiency claim is false as specified (finding 1) |
| F4 - `/prefs` denied by the preferences guard | **Fixed** for `/prefs`; the `/watch` fallback claim is false as specified (finding 1) |
| F5 - explicit `600s` timeout may kill the watcher | **Fixed** |

### F1 - correctly fixed, one residual gap

Verified against the code. `wm_ok` writes to **stdout** (`bin/lib/common.sh:58`, unlike `wm_warn`/`wm_err` which redirect to stderr), and the arm line is printed at `watch-fleet:312` before the blocking loop begins, so r1's first-line classifier really would have misread every genuine fire. The revision's fix - scan every line up to the `--` separator (`watch-fleet:424`) for `^(blocked|review|done|died|stalled|remote-control-dropped):` - matches `fire()`'s real emitted shape (`watch-fleet:399-424`).

The prefix list is also complete, as the plan claims: `ATTENTION_STATES = ("blocked", "review", "done", "died", "stalled")` at `wm-state.py:69`, plus `remote-control-dropped` emitted directly. The plan's claim that `group-attention`'s synthetic correlated rows introduce no new prefix is correct - they reuse `died`/`stalled`.

The residual gap is finding 3 below.

### F2 - correctly fixed on the path it addresses

Verified. The singleton guard at `watch-fleet:302` emits exactly `watcher: already armed and healthy - one cycle is live (pid N, beacon Ms ago)...` and exits 0 immediately, so the substring match the classifier keys on is real, and the three-outcome design is right. Critically, the `healthy` branch does **not** re-arm, which is what actually breaks the cycle: a redundant arm produces one wasted wake and then terminates, rather than sustaining itself. The deliberate double-enforcement (classifier short-circuit plus `watch-fleet`'s own atomic claim-then-check) is sound.

### F5 - correctly fixed

The revision ran the test the prior review demanded (a `run_in_background` task with an explicit `timeout: 600000` surviving to 700s) and **dropped** the recommendation rather than keeping a rationale it now knows to be false. This is the right outcome and the right method. I cannot independently re-run their observation, but the resulting instruction - arm with no `timeout` parameter - is safe regardless of which way the test had gone, since it matches what `CLAUDE.md` already documents. Nothing blocking here.

Minor note, non-blocking: "the `timeout` parameter does not govern a background task's lifetime" is a conclusion drawn from a single observation. The *action* is safe either way, so this does not need re-testing; it would just be worth phrasing as an observation rather than a settled property of the harness.

### F4 - fixed for `/prefs`, not for `/watch`

The `/prefs` half is correct and verified. `hooks/pilot-preferences-guard.sh` branches on `tool_name` and allows only `AskUserQuestion`, a `Read` of exactly `$WM_HOME/wake`, and `Bash` commands whose every segment resolves to an allowlisted basename; there is no `Skill` branch, so a `Skill` call reaches the unconditional `deny()`. The proposed narrow fix (allow `tool_name == "Skill"` **and** skill name exactly `prefs`) is the right shape, and the plan is appropriately honest that the `tool_input` field naming the invoked skill must be confirmed against the harness before implementing rather than asserted.

The `/watch` half of F4 is where the plan goes wrong - see finding 1.

---

## Findings

### 1. (Must fix) The `--classify` invocation shape is unspecified, and the two shapes the plan implies are both denied by wingman's own preferences guard

This single defect undercuts the F3 grant claim and the F4 `/watch` fallback claim at once.

The plan specifies the classifier as reading "the just-completed cycle's full captured stdout **on stdin**", and the skill body says to "**pipe** its captured stdout into `bin/watch-fleet --classify`". But that captured stdout does not exist as a file - the harness delivers it as text into the session's context. So the session must materialize it back into a shell command, and the shape it picks is load-bearing for two of the plan's own claims:

- **F3's claim:** "Because the log write happens inside `bin/watch-fleet` (invoked via the already-required `Bash(bin/watch-fleet:*)` grant), the skill needs no additional tool grant." This holds only for a command that *begins with* `bin/watch-fleet`. A piped command begins with `printf`/`echo`/`cat`.
- **F4's claim:** during the pending-preferences window, "arm and process `bin/watch-fleet` via the raw `Bash` form directly (**already exempted by the guard**)." *Arming* is exempted. *Processing* is not.

`hooks/pilot-preferences-guard.sh` requires **every** segment of a Bash command to resolve to an allowlisted basename (`crew-list`, `watch-fleet`, `crew-ask await`, or the `wm-state.py` preference verbs), and `command_segments` (`hooks/lib/cmd_match.py:53`) splits on `|`, `;`, `&&`, `||` **and newlines**. Running the guard's own matcher over the candidate shapes:

| Shape | Segments | Guard verdict |
| --- | --- | --- |
| `printf '%s' "$OUT" \| bin/watch-fleet --classify` | 2 (`printf` unresolvable) | **DENY** |
| `bin/watch-fleet --classify <<'EOF' …fire block… EOF` | 5 (`review:`, `--`, `The` unresolvable) | **DENY** |
| `bin/watch-fleet --classify < <file>` | 1 | ALLOW |
| `bin/watch-fleet` (bare arm) | 1 | ALLOW |

The heredoc denial is the instructive one: because the guard splits on newlines, the *content* of the captured fire block is parsed as if each line were a command, and lines like `review: wm-abc plan ready` and `The lines above are state-change deltas…` fail to resolve. The output being classified is what trips the guard.

So during the pending-preferences window - the exact window F4 exists to protect, and the one `docs/analysis/2026-07-13-unattended-boot-launch-behavior.md` documents relying on for continued supervision - `/watch`'s classify step is denied in every shape the plan describes. The fallback the plan calls "already tested and working" covers arming only.

Independently of the guard: in normal operation (preferences answered, guard exits early), the skill's own `allowed-tools: Bash(bin/watch-fleet:*)` is a prefix grant, and a command starting with `printf … |` does not match that prefix. The likely result is an interactive permission prompt in wingman's own session - which is not in `bypassPermissions` mode, since it is the pilot's own interactive session - defeating the stated purpose of `allowed-tools` ("pre-authorizes exactly the command(s) the skill needs, so invoking it never triggers an interactive permission prompt"). No existing skill in `.claude/commands/` pipes into a `bin/` command, so there is no precedent to lean on and this shape is unverified against Claude Code's permission engine. This is the same class of error the prior review's F10 caught for `/prefs` (a grant that cannot match the command actually invoked); the revision fixed it there but reintroduced it here.

**Recommended fix - drop stdin entirely.** Have `bin/watch-fleet` record its own exit reason to a small file (e.g. `$WM_HOME/watch-last-exit`) at each of its exit points: the `healthy` early-exit (`watch-fleet:302`), and `fire()` (`watch-fleet:399-437`, which already writes `$WAKEFILE`). `--classify` then takes **no stdin at all** and reads that record itself: a `fire` record means a genuine event, a `healthy` record means a live cycle, and a missing/stale record means the process died without running its exit path - which is exactly the `spurious` case, and gives a *stronger* forensic signal than the pidfile hint alone (a SIGKILL cannot write the record any more than it can clear the pidfile). The command becomes a single bare `bin/watch-fleet --classify`, which passes the preferences guard and matches the `Bash(bin/watch-fleet:*)` prefix grant **by construction**, and it removes the dependency on the model faithfully round-tripping ANSI-coloured multi-line text back through a shell quoting layer.

If stdin is kept instead, the plan must name the exact command string the skill runs, and that string must be verified against both `hooks/pilot-preferences-guard.sh` and Claude Code's permission engine before implementation - not asserted.

### 2. (Must fix) The `spurious` branch re-arms unconditionally with no backoff, reintroducing F2's livelock for any persistent failure - silently

F2's fix stops a redundant arm from looping. But the new `spurious` branch re-arms unconditionally, and the plan explicitly instructs it to "**Report nothing to the pilot** (nothing about the fleet changed)". For a *transient* death (the SIGKILL case the plan tests) that is correct and desirable. For a *persistent* one it is a silent, self-sustaining wake loop - structurally identical to the defect F2 was blocked on.

Concrete reproduction: `watch-fleet:290` calls `wm_die "watcher: could not acquire the claim lock after 5s (a concurrent arm may be stuck)"`. `wm_die` routes through `wm_err`, which writes to **stderr** (`common.sh:60-61`) and exits 1 - leaving **stdout empty**. Empty stdout contains neither `already armed and healthy` nor a reason prefix, so the classifier falls through to rule 3 → `spurious` → log a line → re-arm → hit the same stuck claim lock → die again → empty stdout → `spurious` → re-arm. A tight loop of wakes, each consuming a turn, each reporting nothing to the pilot, while fleet supervision is entirely dead and nobody is told.

The plan's testing strategy only exercises a *single* SIGKILL/SIGTERM recovery, so this would not be caught. Note also the irony: the plan defers the stuck-stop-hook-loop incident to issue #67 as unexplained, while observing that "a re-arm that returns `healthy` immediately produces an instant wake" is one plausible mechanism. That mechanism is now closed - but this one, of the same shape, is opened in the same revision, and is at least as plausible a candidate for the original incident.

**Recommended fix:** give the `spurious` path a failure budget. `--classify` already owns the log file, so it can own the counter too: if N spurious classifications occur within a short window (e.g. 3 within 60s), have it emit a distinct fourth outcome - `spurious-repeated` - and have the skill *stop re-arming* and surface the situation to the pilot instead. A watcher that cannot stay up is a genuine attention event, not something to absorb silently. This also gives the `watch-spurious.log` forensics a natural trigger for being read.

### 3. (Should fix) A `remote-control-dropped` fire emits no `--` separator, so the "scan up to `--`" rule needs an explicit no-separator case - and no test covers it

The F1 fix is described as scanning "every line up to the literal `--` separator", and the example block in the plan shows the separator present. That is true for crew events, which go through `fire()`. It is **not** true for the `remote-control-dropped` prefix, which the plan itself lists in the regex: that path (`watch-fleet:451-460`) writes its own wake file, echoes the single reason line, and exits - it never calls `fire()` and never prints `--`.

Most natural implementations survive this (`sed -n '1,/^--$/p'` and `awk '$0=="--"{exit} {print}'` both scan to EOF when no separator is found), so this is not certain to bite. But the plan's testing strategy lists only "a genuine `fire` block (constructed from real `group-attention` output shapes)" and never the separator-less `remote-control-dropped` shape, so an implementation that keys on the separator's *presence* would ship undetected - and the failure mode is silent: wingman's own dropped Remote Control connection gets classified `spurious`, logged, and never reported, which is the precise class of silent swallowing F1 was raised to prevent.

**Recommended fix:** state the rule as "scan every line up to the `--` separator, **or the whole input if no separator is present**", and add the `remote-control-dropped` shape (no separator, single reason line) as an explicit `--classify` unit-test case.

## What is already right and should not be re-litigated

- **`/say` + `/ask` (priority 1).** Sound, verified, unblocked by every finding above. The `bin/crew-say`/`bin/crew-ask` allowlist gap is real (confirmed: neither appears in any `allowed-tools` nor in `.claude/settings*.json`), and `/blocked`'s body does promise a `bin/crew-say` relay its own `allowed-tools` does not grant. The F6 `--answer-file` follow-up read and its matching `Read(~/.wingman/ask/*.json)` grant are correct.
- **Moving the classifier into `bin/` (F3's core insight).** The right call, and the right justification - it restores the convention rather than making `/watch` the one skill with a state machine in prose, and it makes the logic unit-testable alongside every other `bin/` verb. Finding 1 is about the *invocation shape*, not this decision, which should stand.
- **The three-outcome classification and the pidfile forensic hint.** Correct, and the SIGKILL-cannot-run-the-trap reasoning (`watch-fleet:311`) is sound.
- **The honesty of the investigation section.** Issue #64 correctly downgraded from "prerequisite" to "necessary but not sufficient"; the compaction-reap hypothesis correctly recorded as untested rather than asserted; issue #67 correctly filed rather than letting `/watch` imply it fixed something it never fixed. This is the right standard and the revision meets it.

## Recommendation

**Request changes**, scoped narrowly:

1. Respecify `--classify`'s invocation so it passes both the preferences guard and the skill's own grant by construction - preferably by dropping stdin in favour of a `watch-fleet`-written exit record (finding 1).
2. Add a failure budget to the `spurious` branch so a persistently-failing watcher surfaces to the pilot instead of silently looping (finding 2).
3. Handle and test the separator-less `remote-control-dropped` fire shape (finding 3).

None of these touch `/say` + `/ask`, which is priority 1 in the plan's own order and should proceed to implementation now, in parallel with this revision. `/prefs` remains correctly blocked on the guard change and is otherwise ready.
