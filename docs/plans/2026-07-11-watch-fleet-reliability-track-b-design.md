# Design: watch-fleet reliability - Track B (#12, #22, #23)

Author: architect crew member `design-the-implementation-for-is-architect`.
Date: 2026-07-11.
Status: draft, awaiting lead approval.
Input: `docs/plans/2026-07-11-four-reliability-issues-decomposition.md` ("Track B" section), GitHub issues #12, #22, #23.

## 1. Scope

This document is the detailed technical design for the three watch-fleet reliability issues assigned to Track B:

- **#12** - idempotent watcher arming: guarantee exactly one live watcher, and make the arm/health report unambiguous so it can never again be misread as "kill this pid."
- **#22** - detect a mass crew-death event (tmux/host crash) distinctly from a routine single `died`, and provide a bulk-resume path that relaunches each affected session with `claude --resume <session-id>`, preserving conversation and the parent/owner tree.
- **#23** - recognize API/connectivity-error text in a crew pane, give it a distinct stall reason instead of the generic silent-stall bucket, detect a correlated fleet-wide occurrence, and prefer an automatic nudge over a manual pilot diagnosis.

It does not cover Track A (#17, the mechanical delegation guard), which touches disjoint files (`hooks/`, `.claude/settings.json`) and has no dependency on this work.

### Ground-truth note: PR #26 has merged

The decomposition document's "no-touch zones" were written against PR #26 while it was still open.
It has since merged (`cfb1f0f`, "Categorized playbook library").
The constraint is now moot rather than violated: this design does not touch `wm_crew_types`, `wm_resolve_playbook`, `wm_glob_escape`, or the playbook-resolution block in `bin/spawn-crew`, and none of the `CLAUDE.md` prose it edits overlaps the playbook-path/`software-analyst` paragraphs PR #26 introduced.
File and line references below are against the current `main` (post-#26): playbooks live under `playbooks/<category>/<role>.md`, and the shared partial is `playbooks/_status-contract.md`.
All three source files this design touches - `bin/watch-fleet`, `bin/lib/wm-state.py`, `bin/lib/common.sh` (the tmux helpers, not the playbook-resolution helpers) - were outside PR #26's scope and are unchanged by it.

## 2. Prior art this builds on

`docs/plans/2026-07-10-wingman-reliability-consolidated-implementation.md` (merged) already added, and this design does not re-derive:

- The `stalled` state in `LIVE_STATES`/`ATTENTION_STATES` (`bin/lib/wm-state.py`).
- `wm-state.py stall-check`, with the two staleness gates (pane idle, status idle) plus the `_ps_tree`/`_probe_execution` execution probe (no late-started descendant, no CPU delta) that turns a threshold breach into a confirmed stall.
- `bin/watch-fleet`'s pane backstop loop over every `working` member, `prompt_freeze_check` (permission/trust-dialog detection via UI-shape + adjacency + stability), and the wake-file-carries-full-roster `fire()` mechanism.
- The `handled`/`ack` dedupe split between the watcher and the Stop hook.

Everything below is additive to that machinery, not a rewrite of it.

## 3. Shared foundation

Both the issue bodies and the decomposition explicitly ask whether #22 and #23 should share a "fleet-wide correlated event" code path.
**They do, but only at the display layer - not in detection, and not in recovery.**

### 3.1 Why detection stays separate but display is shared

#22's signal (many `died` in one reconcile pass) and #23's signal (many `stalled` members whose reason is pane-recognized as an API error) are produced by two different, unrelated code paths (`cmd_reconcile` vs. `cmd_stall_check`) that already run independently once per poll.
Forcing them through one detector function would require passing kind-specific context (window lists for one, pane text for the other) through a shared abstraction that buys nothing - each detector already knows exactly what it's looking at.

But the *reporting* problem is identical in shape for both: "N members show the same abnormal status in the same batch; collapse that into one bullet instead of N, so the report reads as one event instead of N pilot interventions."
That collapsing needs no knowledge of *why* the members are correlated, only that several rows in the current attention batch share a recognizable status/reason pattern.
So the shared primitive lives exactly there: a new `wm_state group-attention` filter that reads `needs-attention`'s existing TSV output and, for each of two recognized patterns (`status == died`, and `status == stalled` with a reason starting `api-error:`), collapses a group at or above threshold into one synthetic row.
Below threshold, every row passes through unchanged - a single ordinary `died` or `stalled` member is never touched.

This is a **pure, stateless display filter**: it recomputes its threshold check fresh from the current roster on every call, stores nothing between calls, and never mutates any status file.
It sits strictly between `needs-attention` and `bin/watch-fleet`'s `fire()` - the one consumer that renders the "New events" section and the stdout reason lines pilots/wingman actually read.
Both the Stop hook and `crew-list`/board rendering are unaffected and keep showing every member individually (see §3.3 for why the hook is deliberately left ungrouped).

Recovery is where the two issues genuinely diverge, per the issues' own framing, and stays separate: #22's remedy is relaunching a dead window (`bin/crew-resume`); #23's remedy is nudging a still-alive pane, falling back to the same resume tool only if the session is truly gone.
No shared "recover" abstraction is introduced.

### 3.2 `wm_state group-attention` (new subcommand, `bin/lib/wm-state.py`)

```python
def cmd_group_attention(args):
    """Read needs-attention's TSV from stdin (id, status, updated, note) and
    collapse fleet-wide correlated batches into one synthetic row each, passing
    every other row through unchanged. Two recognized patterns, both meaning
    "many crew show the same abnormal signal in one pass":
      - status == "died"                                   -> key "mass-death"
      - status == "stalled" and note startswith "api-error:" -> key "api-outage"
    A group collapses only at or above --mass-min-count AND --mass-min-ratio
    (of the relevant live population - see below); below threshold its rows
    pass through individually, so one routine died/stalled member is untouched.

    Pure filter: recomputes the roster snapshot fresh on every call and writes
    nothing. The synthetic row's id ("correlated:mass-death"/"correlated:api-
    outage") is not a real crew id - callers must ack/mark-handled from the
    ORIGINAL ungrouped needs-attention output, never from this filtered one.
    --owner scopes the ratio's denominator to the same cohort needs-attention
    was called with ("" = top level, matching a lead's own scope), so a lead's
    cycle judges "N of M" against its own team, not the whole fleet.
    """
```

Grouping and ratio-denominator details:

- `mass-death`: numerator = rows with `status == "died"` in the input. Because a `died` member has just left `LIVE_STATES`, the ratio denominator is `(current count of this owner's members in LIVE_STATES) + (number of died rows in this group)` - i.e. "how many were live a moment before this pass," not the post-death count (which would undercount and make ratios look inflated).
- `api-outage`: numerator = rows with `status == "stalled"` and `note.startswith("api-error:")`. `stalled` is still a `LIVE_STATES` member, so the denominator is simply the current live count for that owner scope - no adjustment needed.
- Defaults: `--mass-min-count 2` (a lone death/stall is always routine, never a "batch" of one), `--mass-min-ratio 0.5` (at least half the relevant cohort), both overridable via `WM_MASS_MIN_COUNT`/`WM_MASS_MIN_RATIO` in `bin/watch-fleet`, following the existing `WM_STALL_*` tunable convention.
- The synthetic row's `note` names every affected id and the concrete remedy command (`bin/crew-resume --all-died` for mass-death; "already nudged; escalate with `bin/crew-resume <id>` if it does not recover" for api-outage), so the collapsed bullet is still actionable without expanding it.

### 3.3 `fire()` is the only consumer; the Stop hook stays ungrouped

`bin/watch-fleet`'s `fire()` gains one line: `_grouped="$(printf '%s\n' "$_attention" | wm_state group-attention --owner "$OWNER" --mass-min-count "$MASS_MIN_COUNT" --mass-min-ratio "$MASS_MIN_RATIO")"`.
Its two existing display loops (the wake-file "New events" section, and the stdout reason lines) switch from iterating `$_attention` to iterating `$_grouped`.
Its ack loop is untouched and keeps iterating the original `$_attention` - acking the real ids with their real `updated` stamps is what suppresses re-firing; acking a synthetic `correlated:*` pseudo-id would ack nothing real and the raw events would re-fire on the next arm.

`hooks/stop-guard.sh` is **not** changed to group.
This follows the precedent the prior (merged) design already established for this exact hook: it is "a backstop, not the primary fix" - its job is "you have unhandled events, go read the wake file," not to fully reproduce the wake file's content.
Leaving it listing raw rows is a few extra lines in a rare mass-event, not a correctness gap, and it keeps this change's footprint smaller and lower-risk (no changes to the hook's `mark-handled` scratch-set logic, which must keep operating on real ids regardless).

### 3.4 Shared pane snapshot (`bin/lib/common.sh`, `bin/watch-fleet`)

#23 needs a second pane-text inspection (API-error signature matching) alongside the existing `prompt_freeze_check`.
Both need the same two things per poll: the pane's current text, and whether it is byte-identical to the previous poll's capture (the stability signal that rules out matching mid-scroll transcript content).
Today `prompt_freeze_check` captures and hashes the pane inline.
This design factors that into one shared helper so the pane is captured and hashed once per member per poll, not twice:

```sh
# common.sh - captures a window's pane text once per poll and compares it to
# the previous poll's capture (per id, via the existing pane-<id>.hash file),
# setting PANE_TEXT and PANE_STABLE for every caller in this poll to share.
wm_pane_snapshot() {
  _id="$1"; _win="$2"
  PANE_TEXT="$(wm_tmux_pane_text "$WM_TMUX_SESSION:$_win")"
  _hashfile="$WM_HOME/pane-$(printf '%s' "$_id" | tr -c 'A-Za-z0-9._-' '_').hash"
  _hash="$(printf '%s' "$PANE_TEXT" | cksum)"
  _prev="$(cat "$_hashfile" 2>/dev/null)"
  printf '%s\n' "$_hash" > "$_hashfile"
  if [ -n "$_prev" ] && [ "$_hash" = "$_prev" ]; then PANE_STABLE=1; else PANE_STABLE=0; fi
}
```

`prompt_freeze_check` in `bin/watch-fleet` is refactored to consume `$PANE_TEXT`/`$PANE_STABLE` instead of capturing/hashing inline; its own logic (the UI-shape/adjacency scan, `PFC_SHAPE`) is unchanged - only where it gets the text and the stability boolean changes.
This is a behavior-preserving refactor: existing `watch-fleet.test.sh` permission-freeze assertions must stay green unmodified, and the reviewer should specifically re-run them to confirm no regression, since this is the one place in the design that edits already-tested, working code rather than adding new code.

## 4. #12 - idempotent watcher arming

### 4.1 What is and isn't actually broken

Re-reading `bin/watch-fleet`'s current singleton guard: `cycle_live()` already makes a fresh arm a true no-op when a cycle is live - it never kills, never starts a second blocking loop from that branch, and prints `wm_ok "watcher: healthy pid=..."` then exits 0.
So the incident described in the issue (the live watcher was killed) was not this code choosing to kill anything - watch-fleet has no code path that ever calls `kill` on a watcher pid.
It was a **human/agent misreading the reported pid as something to act on** and running a manual `kill` outside the tool entirely.
The issue is explicit that this is the root cause ("a fresh arm that reports `healthy pid=N`... is easy to mistake... and kill the wrong process"), and its own proposed direction is about making state unambiguous, not about fixing a bug in the no-op branch (there isn't one).

There is, however, a second, real gap the issue's "Problem" section also names and the code confirms: **the check-then-claim sequence is not atomic.** Today:

```sh
if cycle_live; then ...; exit 0; fi
echo $$ > "$PIDFILE"
```

Two `bin/watch-fleet` invocations racing in the same instant (both observe no live cycle, both write `$PIDFILE`) produce two competing blocking loops, the second's write silently clobbering the first's pidfile - the exact "nothing enforces the exactly-one-live-watcher invariant" gap the issue names.
This is latent (arms are infrequent and normally sequential - wingman/a lead arms once per turn) but is a genuine correctness bug, not a hypothetical, and is cheap to close.

The design therefore has two independent parts: close the race (mechanical), and make the no-op report impossible to misread as a kill target (mechanical + doc).

### 4.2 Atomic claim via a `mkdir` lock

`mkdir` is atomic on every POSIX filesystem and needs no new dependency (no `flock(1)`, which macOS does not ship).
Wrap the check-then-claim section in a short-lived lock directory, scoped by the same owner key as the pidfile:

```sh
CLAIMLOCK="$PIDFILE.lock"
_claim_tries=0
while ! mkdir "$CLAIMLOCK" 2>/dev/null; do
  _claim_tries=$((_claim_tries+1))
  [ "$_claim_tries" -ge 50 ] && wm_die "watcher: could not acquire the claim lock after 5s (a concurrent arm may be stuck) - see $CLAIMLOCK"
  sleep 0.1
done
trap 'rmdir "$CLAIMLOCK" 2>/dev/null' EXIT

if cycle_live; then
  wm_ok "watcher: already armed - one cycle is live (pid $(cat "$PIDFILE"), beacon $(beat_age)s ago). Nothing to do; this pid is the EXISTING watcher, never a target to stop or kill."
  rmdir "$CLAIMLOCK" 2>/dev/null
  exit 0
fi

echo $$ > "$PIDFILE"
: > "$BEATFILE" || true
rmdir "$CLAIMLOCK" 2>/dev/null
trap 'rm -f "$PIDFILE"; exit 0' INT TERM
wm_ok "watcher: armed pid=$$ (interval ${INTERVAL}s)"
```

The lock is held only across the check+claim (microseconds), never across the blocking loop itself, so it adds no contention for the common case (one arm at a time) and bounds the pathological case (a stuck concurrent arm) at 5s rather than hanging forever.
A stale lock directory left by a killed process is self-healing: the next arm's `mkdir` will still fail until removed, but the 50-try/5s bound surfaces that loudly (`wm_die`) instead of hanging silently - an operator sees a clear, diagnosable error rather than a wedged arm.

### 4.3 Making the no-op report structurally hard to misread

Two changes, deliberately redundant with each other (defense in depth, since the CLAUDE.md prose describing "healthy" already existed before the incident and did not prevent it):

1. **Reword the no-op line itself** (shown above): leads with "already armed" (mirroring what the caller just attempted, not just "healthy," which describes the watcher's condition but not the caller's situation), states in the same line that the pid is "the EXISTING watcher, never a target to stop or kill," and keeps the `watcher: healthy` token prefix unchanged so `CLAUDE.md`'s documented parsing contract ("Read the arm's status line as truth: armed, healthy, or a `blocked:/review:/done:/died:/stalled:` reason") still holds for any code or memory keyed on that prefix.
2. **`--status` becomes the single scriptable liveness check.** Today `--status` always exits 0 regardless of whether a cycle is live, so nothing can script off it without parsing text. Change it to exit 0 when live, 1 when not - `bin/watch-fleet --status >/dev/null 2>&1` is now the documented, scriptable "is a watcher live right now?" the issue asks for, usable from a hook, a test, or another script without grepping colored text.

### 4.4 `CLAUDE.md` wording (small, targeted)

In "The wake loop" section, strengthen the existing singleton bullet with an explicit, unmissable rule (not a new fact, just closing the gap that let the incident happen despite the existing "do not start another" prose):

> Never `kill` a watch-fleet process for any reason during normal operation - the pid shown in a `healthy`/`armed` line is informational, never an instruction. The only legitimate way to stop a cycle is `bin/watch-fleet --stop`, and that is a manual/testing action, not part of the normal arm-supervise-fire loop.

## 5. #22 - mass crew-death detection + bulk resume

### 5.1 Detection: piggyback on the existing death-flip pass, no new pass

`cmd_reconcile`'s existing per-member loop already computes `changed` (the ids flipped to `died` in this call).
No new scan is needed to know "how many died together" - that's just `len(changed)`.
What's missing is a *denominator* and a *decision*, both of which now live in `group-attention` (§3.2) rather than in `cmd_reconcile` itself: reconcile keeps doing exactly what it does today (flip each dead-windowed live member, unconditionally, regardless of which owner's cycle called it - this is deliberately unchanged, since the death-flip loop already isn't owner-scoped and a crash's blast radius doesn't respect ownership boundaries anyway).

This is a meaningfully simpler design than tagging each `died` record at flip time with a shared batch id: no cross-record rewrite inside `cmd_reconcile`, no new field on the roster schema, no risk of a batch tag going stale if the composition of "who died together" is judged differently by two different observers.
The correlation is entirely a property of *what's currently sitting in the attention batch*, recomputed fresh every time `group-attention` runs - exactly the reasoning in §3.1.

### 5.2 `bin/crew-resume` (new script)

A new top-level tool, mirroring `bin/crew-takeover`'s and `bin/crew-standdown`'s shape (read the roster record via `wm_state crew-get`, act via tmux + `wm_state`, no new Python subcommand needed beyond the existing `crew-set`).

```
Usage:
  bin/crew-resume <id> [<id2> ...]     resume the named died member(s)
  bin/crew-resume --all-died [--owner <id>]   resume every currently-died member
                                        (optionally scoped to one owner's team)
```

Per-id logic:

1. `wm_state crew-get --id <id>` for `repo`, `session_id`, `window`, `worktree`, `parent`, `type`, `status`.
2. **Idempotency guard 1:** if `status != died`, skip with "not died, nothing to resume" - running `--all-died` twice is then naturally a no-op the second time, since the first run already moved every resumed member off `died` (see step 6).
3. **Idempotency guard 2:** if a tmux window named `wm-<id>` already exists, skip with "window already exists, not relaunching" - closes the residual race window between two concurrent `crew-resume` invocations (or a retry) that guard 1 alone wouldn't catch if they read the roster in the same instant.
4. Build a resume launch script at `$WM_HOME/crew/<id>.resume.sh`, mirroring `bin/spawn-crew`'s launch-script generation but replacing the exec line:
   ```sh
   cd <worktree if non-empty, else repo> || exit 1
   export WINGMAN_HOME=<home>
   export WINGMAN_CREW_ID=<id>
   export WINGMAN_STATE=<uv invocation>
   export WINGMAN_BIN=<bin dir>
   [ -n "<worktree>" ] && export WINGMAN_WORKTREE=<worktree>
   exec <agent:-claude> --resume <session_id> --permission-mode <perm-mode> \
     --add-dir <home> --add-dir <repo> [--model ...] [--effort ...]
   ```
   `cd`'ing into the **worktree** (not the bare repo) when one is recorded matters: `--resume` restarts a fresh process whose Bash tool cwd starts at the new process's own launch directory, not wherever the crashed process's shell had `cd`'d to - the crew member's actual branch/work lives in its worktree, and the original spawn only `cd`'d to the bare repo because the member itself creates the worktree as its own first turn's action (per the developer playbook), which `--resume` will not replay.
   No `--session-id` (reusing the existing one is the point), no `--append-system-prompt` (already part of the resumed conversation's history), no new `crew-add` (the roster record is reused as-is, so `parent` never changes - this is what "preserves the tree" for free: standing up the same id in a new window under the same parent needs no tree surgery at all).
5. `wm_tmux new-window -d -t "$WM_TMUX_SESSION:" -n "wm-$ID" "bash $(quote "$RESUME_LAUNCH")"`, then a nudge message via the existing `wm_tmux_send_message`: `--resume` reopens the conversation but, in this unattended setup, does not itself decide to keep working - it needs the same kind of opening nudge a fresh spawn gets, e.g. "Your previous window was interrupted (likely a tmux/host crash); this is a resumed session continuing your prior work. Check `bin/crew-list`/your own last status, re-arm any watcher you had running, and continue."
6. **Verify the resume actually took**, rather than optimistically declaring success: poll briefly (bounded, `WM_RESUME_VERIFY_TRIES` x `WM_RESUME_VERIFY_POLL`, a few seconds total) for whether the window is still present. tmux destroys a window when its pane's process exits (no `remain-on-exit`), so a `--resume` that fails fast (a stale/invalid session id) manifests as the just-created window vanishing again almost immediately - a real, observable signal, not a guess.
   - Window still there → `wm_state crew-set --id <id> --status working --summary "resumed after an interruption (was died); continuing prior session"`. Reusing `crew-set` (not a direct file write) keeps this on the same well-tested code path every other status transition uses.
   - Window gone → **leave status as `died`** and print a message pointing at the existing manual path (`bin/crew-takeover <id>` for the resume command text, or `bin/crew-standdown <id>` to discard). This is exactly "falls back to today's manual path only when `--resume` genuinely fails," and it requires no new state or plumbing - `died` already flows through `needs-attention` normally.
7. `--all-died [--owner <id>]`: iterate `wm_state crew-list --status died [--owner <id>] --json`, run steps 1-6 for each, sequentially (a shared tmux server makes true concurrency unnecessary and riskier - no benefit to parallelizing a handful of window creations, and sequential avoids any tmux-side race), print a one-line summary (`N resumed, M skipped: <reasons>`).

### 5.3 Why resume is a tool wingman invokes, not something the watcher auto-fires

A nudge (§6) is cheap and reversible - worst case, an already-healthy pane gets an unnecessary message.
A bulk resume is not: it spawns real sessions that will make real API calls and burn real compute, which is precisely the "spawning is the expensive act" cost-discipline guardrail `CLAUDE.md` already states.
Auto-firing it from `bin/watch-fleet` (a non-agentic bash loop with no judgment and no visibility into whether the pilot even wants this batch of work resumed right now) would bypass that guardrail entirely.

So the design keeps the mechanism and the decision separate, matching how `bin/crew-takeover`/`bin/crew-standdown` already work today (the watcher never calls either automatically): `group-attention`'s collapsed bullet surfaces the event and names the exact remedy command; wingman relays it and runs `bin/crew-resume --all-died` on the pilot's behalf once they've said go, or immediately if the pilot has pre-authorized auto-recovery for a given effort.
`CLAUDE.md`'s command vocabulary gets one new short entry documenting this (see §8).

## 6. #23 - API/connectivity-error stall detection

### 6.1 Pane-text signature (`bin/watch-fleet`)

```sh
WM_APIERR_RE="${WM_APIERR_RE:-rate.limit|rate_limit|\\b429\\b|\\b5[0-9]{2}\\b [Ee]rror|overloaded_error|Internal Server Error|ECONNRESET|ETIMEDOUT|ENOTFOUND|[Nn]etwork error|[Cc]onnection error|Connection refused|fetch failed|socket hang up|Service Unavailable|Bad Gateway|Gateway Timeout}"
WM_APIERR_TAIL="${WM_APIERR_TAIL:-15}"

api_error_check() {
  printf '%s\n' "$PANE_TEXT" | tail -n "$WM_APIERR_TAIL" | grep -qE "$WM_APIERR_RE"
}
```

This is deliberately **not** given `prompt_freeze_check`'s full UI-shape/adjacency precision machinery (there is no equivalent stable "shape" for an error banner the way a numbered-options dialog has one), but it does not need to be: its role is narrower than that check's.
`prompt_freeze_check`'s match, by itself, *mutates state* (flips to `blocked`) - false positives there directly caused the incident fix 4 of the prior plan had to correct.
`api_error_check`'s match never mutates state by itself; it only (a) decides whether to attempt a nudge (§6.3, cheap and reversible even if wrong) and (b) picks which reason string `stall-check` uses *if and only if* `stall-check`'s own existing, independently-gated flip to `stalled` was going to happen anyway (§6.2).
A transcript that merely mentions "ECONNRESET" while the member is actively working never reaches either check: both are only evaluated once the member has already failed the same staleness gates (`pane_idle >= STALL_IDLE`) that gate `stall-check` itself, so an actively-producing pane is never even examined.
The one place precision still matters directly is the nudge (see §6.3's stability requirement).

### 6.2 `stall-check` gets a reason flavor, not a new status

`cmd_stall_check` (`bin/lib/wm-state.py`) gains one boolean flag, `--api-error {0,1}`, changing only which template it writes once it has already decided (via its existing, unmodified gates and probe) that the member is genuinely stalled:

```python
a.add_argument("--api-error", type=int, default=0, dest="api_error")
```

```python
if getattr(args, "api_error", 0):
    reason = ("api-error: the pane shows an API/connectivity-error signature (rate "
              "limit, connection error, 5xx, overloaded_error, or similar) and then "
              "went quiet for >%ds while status was 'working' - the CLI's own retry/"
              "backoff appears exhausted. Likely a local network blip or an Anthropic-"
              "side outage, not a broken agent. Already nudged once; if it does not "
              "recover, resume it with `bin/crew-resume %s`."
              % (int(args.threshold), args.id))
else:
    reason = ("no pane output, status update, running child process, or CPU activity "
              # ...unchanged...
```

No new status value: the issue's own example (`stalled: api-error`) is exactly what `fire()`'s existing stdout line already renders once the reason starts with `api-error:` - `"%s: %s %s" % (status, id, note)` reads `stalled: <id> api-error: ...` verbatim.
This is the smallest change that satisfies the requirement: `stall-check`'s staleness gates and execution probe - already proven and tested - are completely unmodified; only the text differs.

### 6.3 Automatic nudge (`bin/watch-fleet`, no new tool)

A nudge is just a message into a still-alive pane - exactly what `wm_tmux_send_message` (already in `common.sh`, already used by `bin/crew-say`) does.
No new script is needed.
Extend the per-member loop:

```sh
_idle="$(wm_tmux_window_activity_age "$_win")"
_pid="$(wm_tmux_pane_pid "$_win")"

_api=0
if [ "$_idle" -ge "$STALL_IDLE" ] && api_error_check; then
  _api=1
  if [ "$PANE_STABLE" = 1 ]; then
    _nudgefile="$WM_HOME/apierr-$(printf '%s' "$_id" | tr -c 'A-Za-z0-9._-' '_').nudged"
    _nudge_age=$(( $(date +%s) - $(wm_py -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$_nudgefile" 2>/dev/null || echo 0) ))
    if [ ! -f "$_nudgefile" ] || [ "$_nudge_age" -ge "$APIERR_NUDGE_COOLDOWN" ]; then
      wm_tmux_send_message "$WM_TMUX_SESSION:$_win" \
        "An API/connectivity error appears to have interrupted your last turn (rate limit, network blip, or a brief Anthropic-side outage). This is usually transient - please retry your last action."
      : > "$_nudgefile"
    fi
  else
    continue   # first sighting or still changing; one more poll before acting
  fi
fi

[ -n "$_pid" ] && wm_state stall-check --id "$_id" \
  --pane-idle "$_idle" --pane-pid "$_pid" --threshold "$STALL_IDLE" \
  --root-grace "$STALL_ROOT_GRACE" --probe-gap "$STALL_PROBE_GAP" \
  --cpu-eps "$STALL_CPU_EPS" --api-error "$_api" >/dev/null 2>&1
```

New tunable: `WM_APIERR_NUDGE_COOLDOWN` (default 180s, matching `WM_STALL_IDLE`'s default - tunable independently since an operator may want the nudge to retry more or less eagerly than the stall flip fires) - a per-id mtime marker file, the same pattern as `BEATFILE`/the pane-hash file, so a persistent error is nudged at most once per cooldown window rather than every 5s poll.

Note the two actions - nudge and `stall-check` - are not mutually exclusive within one poll: if the probe already independently confirms nothing is executing, the member can be both nudged and flagged `stalled` in the same cycle (correct - the nudge is a parallel self-heal attempt, not a gate on ever being flagged).
If the nudge works, `pane_idle` resets well before the next probe, so neither repeats.
If it doesn't, the signature persists, staleness keeps growing, and `stall-check`'s own existing, unmodified gates eventually confirm and flip to `stalled` with the `api-error:` reason - a real, visible escalation past a failed self-heal attempt, not a silent retry loop.

### 6.4 Correlated fleet-wide outage

Handled entirely by `group-attention` (§3.2's `api-outage` key) - no additional code in `stall-check` or the watcher loop.
When several members are simultaneously `stalled` with an `api-error:` reason, `fire()`'s next call collapses them into one bullet naming every affected id and the fact that they've already been nudged.
No batch-id plumbing, no retroactive rewriting of already-flagged members' summaries - the grouping is recomputed fresh from whatever's currently in the attention batch each time `fire()` runs, exactly as designed in §3.1.

## 7. Files touched

| File | Change |
|---|---|
| `bin/lib/wm-state.py` | new `cmd_group_attention` (+parser entry, `--owner`/`--mass-min-count`/`--mass-min-ratio`); `cmd_stall_check` gains `--api-error` (reason-template branch only, gates/probe untouched) |
| `bin/lib/common.sh` | new `wm_pane_snapshot` (factored out of `prompt_freeze_check`'s inline hash logic) |
| `bin/watch-fleet` | atomic `mkdir`-lock claim + reworded no-op report (#12); `--status` exit code reflects liveness (#12); `prompt_freeze_check` refactored onto `wm_pane_snapshot` (no behavior change); new `api_error_check`; per-member loop gains the nudge branch and passes `--api-error` to `stall-check`; `fire()` gains the `group-attention` pipe for its two display loops only (ack loop unchanged); new tunables `WM_MASS_MIN_COUNT`, `WM_MASS_MIN_RATIO`, `WM_APIERR_RE`, `WM_APIERR_TAIL`, `WM_APIERR_NUDGE_COOLDOWN`; header comment updated |
| `bin/crew-resume` (new) | bulk/single resume of `died` members via `claude --resume`, per §5.2 |
| `CLAUDE.md` | one new sentence in "The wake loop" (never kill a watch-fleet pid, §4.4); command-vocabulary entry for mass-death/outage events pointing at `bin/crew-resume` (§8) |
| `tests/watch-fleet.test.sh` (extended) | permission-freeze assertions re-run unmodified against the refactored `prompt_freeze_check`; new coverage per §9 |
| `tests/group-attention.test.sh` (new) | unit coverage for the grouping filter |
| `tests/crew-resume.test.sh` (new) | idempotency + tree-preservation coverage |
| `tests/stall-check.test.sh` (extended) | `--api-error` reason-template coverage |

## 8. `CLAUDE.md` command vocabulary addition

One new entry, alongside the existing "Crew stalled" / "Deliverable ready" entries:

> - **Mass death or correlated outage detected** (a `fire()` bullet naming several ids at once) → relay the event and the suggested command plainly ("N crew members died/hit API errors together around \<time\>, looks like \<a crash / an outage\>"). The default remedy is `bin/crew-resume --all-died` (mass-death) or letting the automatic nudge play out (outage) - confirm with the pilot before running `crew-resume` (spawning/resuming sessions is the same costly act as any other spawn) unless the pilot has pre-authorized auto-recovery for this effort.

## 9. Testing strategy

Follows the existing bash E2E conventions (`tests/lib.sh`, isolated `WINGMAN_HOME`, nonexistent tmux session names, `wm_timeout` around any foreground `watch-fleet` call).

**`group-attention` (new, no tmux):**
- A single `died` row passes through unchanged (below `--mass-min-count`).
- N ≥ min-count, N/total ≥ min-ratio `died` rows collapse to one `correlated:mass-death` row naming every id; a row with an unrelated status in the same input is untouched.
- Same for `stalled` rows with an `api-error:`-prefixed note vs. a plain stall reason (which must never be swept into the group).
- `--owner` scopes the ratio denominator correctly (mirrors `owner-scope.test.sh`'s existing pattern).
- Piping the filter's output back through the same per-line shape `fire()` expects (`id\tstatus\tupdated\tnote`) parses cleanly.

**`bin/crew-resume` (new, tmux-integration):**
- A `died` member with a live `session_id` resumes: window `wm-<id>` exists afterward, status is `working`, `parent` is unchanged.
- Running `--all-died` twice: second run resumes zero (idempotency guard 1).
- A pre-existing window with the target name is left alone, not duplicated (idempotency guard 2) - simulate by creating `wm-<id>` before invoking resume.
- A lead + its sub-crew, both `died`, both individually resumed: `parent` relationships in the roster are identical before and after (tree preservation), with no `crew-add`/re-parent calls needed.
- A `--resume` that exits immediately (stub `$WM_AGENT` that exits nonzero right away) leaves status `died`, not `working` (fallback-to-manual path).

**`stall-check --api-error` (extended):**
- `--api-error 1` on an otherwise-qualifying stall writes a reason starting `api-error:`; `--api-error 0` (default) is byte-identical to today's existing reason text (regression guard).
- The gates/probe are exercised exactly as today's `stall-check.test.sh` already covers - no new gate behavior to test, only the reason-text branch.

**`bin/watch-fleet` E2E (extended `watch-fleet.test.sh`):**
- Existing permission-freeze assertions re-run against the `wm_pane_snapshot`-refactored `prompt_freeze_check` with no changes to the assertions themselves (regression guard for §3.4's refactor).
- A dummy window whose pane tail matches `WM_APIERR_RE`, stable across two polls, with an old `updated`: `wm_tmux_send_message` is invoked once (mock/spy on `send-keys`, or assert the nudge marker file appears) and not again within the cooldown window on a second poll.
- The same window, after the cooldown/probe window elapses without recovering: cycle exits with `stalled: <id> api-error: ...` - assert on stdout and the wake file.
- Fire with several members simultaneously `died` (â‰¥ threshold): stdout/wake file show one collapsed bullet naming all of them, not N separate `died:` lines; a single unrelated `died` member elsewhere in the same batch stays a separate, individual line.
- `bin/watch-fleet` arming test: two near-simultaneous foreground arms (backgrounded, raced with `&`) result in exactly one live pidfile pointing at exactly one live process (closes the TOCTOU gap from §4.2) - assert via `ps` that only one `bin/watch-fleet` blocking-loop process exists after both return.
- `bin/watch-fleet --status`: exit code 0 with a cycle live, 1 with none (regression/contract test for §4.3).

**Guardrails:** full `tests/run.sh` green; `wm-state.py` stays dependency-free (stdlib only, PEP 723 header unchanged); all shell stays bash-3.2-safe (no associative arrays, no `mapfile`, no `${x,,}`).

## 10. PR shape and build order

**One PR**, not a stack, structured as ordered commits.
Reasoning:

- One developer implements all three per the decomposition's own sequencing (not three separate developers), and one reviewer reviews the whole thing in one pass ("concurrent process management, tmux window lifecycle, idempotency" - explicitly one review scope per the decomposition) - a multi-PR stack buys isolation that nothing downstream actually needs.
- #22 and #23 share `group-attention` directly (§3). Splitting them across two PRs means whichever ships first adds the filter supporting only its own one pattern, and the second PR's "diff" is really "extend a function the first PR just added" - reviewed once, this reads as one coherent piece of infrastructure; reviewed twice, as two partial views of the same thing.
- All three land in the same ~450-line `bin/watch-fleet` loop body. A 3-PR stack means 3 rounds of merging into the same hunk region sequentially - more rebase/integration overhead than 3 commits reviewed together in one PR, for no isolation benefit (nothing here is optional or independently revertible in a way that matters - #12's fix is not going to ship without #22/#23 anyway, per the decomposition's own single-developer sequencing).

Suggested commit order (each green on its own before the next, mirroring the prior merged plan's staged-build pattern):

1. `wm_pane_snapshot` refactor in `common.sh` + `prompt_freeze_check` updated to use it - pure refactor, existing tests must stay green unmodified.
2. #12: the `mkdir` claim lock, reworded no-op report, `--status` exit code, `CLAUDE.md` sentence.
3. `group-attention` (new subcommand) + its unit tests - built once, used by both remaining commits.
4. #22: `bin/crew-resume` + its tests, `fire()`'s `group-attention` pipe wired in, `CLAUDE.md` vocabulary entry.
5. #23: `api_error_check`, `stall-check --api-error`, the nudge branch, and their tests.
6. Full `tests/run.sh`, lint.

A 3-PR stack (commit 2 as PR1, commits 3-4 as PR2, commit 5 as PR3) remains a reasonable fallback if the reviewer prefers smaller review chunks once implementation is under way - noted here as a follow-up option, not the recommendation.

## 11. Risks and open questions

- **`group-attention` threshold defaults (`WM_MASS_MIN_COUNT=2`, `WM_MASS_MIN_RATIO=0.5`) are a first calibration**, not empirically measured against a real crash (unlike the stall probe's constants, which were measured live). Treat as a starting point; adjust from observation the same way the prior plan flagged its own probe constants.
- **The nudge message assumes the CLI returns to an interactive prompt after an API error** rather than exiting the process. This matches the issue's own description ("the sessions and their windows are still alive") but is unverified against a live captured incident the way the permission-dialog shape was (§7.1 of the prior plan). If a future Claude Code version instead exits on a persistent API error, the window disappears and this becomes a `died` case `bin/crew-resume` already handles - not a silent gap, but worth a manual check per the prior plan's own "verify platform assumptions first" discipline.
- **`WM_APIERR_RE` is a first pass at the signature list**, not exhaustive; false negatives (an error phrasing not on the list) degrade gracefully to the existing generic stall path, not to a missed detection - a member showing unrecognized error text is still eventually flagged `stalled`, just without the `api-error:` flavor or the nudge attempt.
- **`bin/crew-resume`'s window-vanished check has a bounded polling window** (`WM_RESUME_VERIFY_TRIES` x `WM_RESUME_VERIFY_POLL`); a `--resume` that succeeds but takes longer than that window to stabilize could be misread as failed. Mirrors the existing `wm_tmux_pane_ready` bounded-wait pattern already accepted elsewhere in this codebase for the same reason (a pane that never settles still proceeds rather than hanging).
- **A host crash that also kills wingman's own process** is out of scope, as it is for the existing merged design: detection requires *something* to survive and reconcile. The issue's own incident narrative (wingman correctly flagged every death) confirms this is the assumed operating case, not a gap this design introduces.
