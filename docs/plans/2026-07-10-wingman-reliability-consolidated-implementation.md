# Consolidated plan: wingman reliability - lead test at intake, complete wake handling, silent-stall detection, prompt-freeze hardening

**Date:** 2026-07-10
**Type:** Implementation plan (build-ready). One developer implements this as one coordinated change in the `wingman` repo.
**Area:** `bin/watch-fleet`, `bin/lib/wm-state.py`, `bin/lib/common.sh`, `hooks/stop-guard.sh`, `CLAUDE.md`, `playbook/_status-contract.md`, `tests/`.

## 1. Problem

Four reliability defects, each documented separately, all rooted in the same intake/watcher/wake machinery:

1. **Lead-suggestion miss at intake** (approved report: `docs/analysis/2026-07-10-wingman-lead-suggestion-miss.md`).
   The lead heuristic exists only as prose buried in a Scope sub-bullet; the command vocabulary short-circuits past it, its literal threshold contradicts the documented analyst→developer default, cost rhetoric biases against suggesting, and nothing re-evaluates when scope grows mid-flight.
2. **Short-circuited wake handling** (approved report: `docs/analysis/2026-07-10-short-circuited-wake-handling.md`).
   On a watcher fire, the stdout reason line (`<status>: <id> <note>`) looks self-sufficient, the wake file duplicates it byte-for-byte, and the Stop hook is pre-disarmed by the fire-time ack - so wingman relays the single event and skips the prescribed full-roster report.
3. **Silent crew stall invisible** (existing plan: `docs/plans/2026-07-10-detect-silent-crew-stall.md`).
   A crew member whose agent errors and goes idle keeps status `working` forever: no self-reported transition, window still alive, pane backstop matches only permission prompts.
4. **Prompt-freeze detector false positive** (approved report: `docs/analysis/2026-07-10-prompt-freeze-false-positive.md`; scope added mid-build 2026-07-10).
   The permission-prompt backstop greps the entire visible pane for generic case-insensitive substrings, so a healthy session whose transcript merely *mentions* a prompt phrase (a diff, a plan, a test fixture, or an investigation of the detector itself) is flipped to `blocked` and its true status overwritten.
   It misfired twice on 2026-07-10, both times on wingman-repo crew working on this very plan.

This plan supersedes the "Concrete changes" sections of the four inputs where they touch the same code; the analyses remain the record of the root causes.

## 2. Design overview and overlap resolution

The fixes share machinery, so they are built as one branch/PR with a deliberate internal order: state layer → watcher → hook → instructions/docs.
Mechanism lands before prose so the documentation pass describes finished reality once.

The overlap decisions, resolved here so the pieces compose:

- **The working-crew pane backstop in `bin/watch-fleet` is touched by fixes 3 and 4.** It is rewritten once: the permission check becomes the hardened `prompt_freeze_check` (§4.1), keeps its priority as the more specific diagnosis (it `continue`s past the stall check on a flip), and the stall check follows in the same loop body.
- **`fire()` in `bin/watch-fleet` is touched by fixes 2 and 3.** It is rewritten once (§4.2): the wake file becomes *deltas + the full owner-scoped roster*, and stdout becomes *reason lines + an explicit directive block*. New `stalled` events (fix 3) then flow through this same path with no special casing - the directive text simply enumerates `stalled` among the states to report.
- **Stall detection is two-stage: staleness gates plus a positive execution probe.** A pure time threshold cannot be made safe at any value: a healthy member parked between harness wakes (a `working` lead waiting on its armed `watch-fleet`, the normal state of a lead supervising active crew) emits no pane output and no status updates for arbitrarily long, so it out-waits any threshold. This was measured live on the target host (§3.2). The two staleness signals therefore only *nominate* a candidate; the flag additionally requires a probe of the pane's process tree that finds **no** positive evidence of execution or of an armed wake source. The threshold consequently stops being a correctness knob and becomes pure detection latency.
- **State vocabulary changes go through the existing constants, not inline tuples.** The stall plan's code sketches write `LIVE_STATES = ("working", "blocked", "stalled")` and an inline `needs-attention` filter; applied literally, both would **drop `review`** from the live and attention sets - a regression to the deliverable lifecycle. The consolidated change is: append `"stalled"` to the existing `LIVE_STATES` and `ATTENTION_STATES` tuples in `wm-state.py` (lines 39 and 47), touching nothing else in them.
- **Timestamp parsing already exists.** The stall plan proposes a `_parse_iso` helper; `wm-state.py` already has `_parse_updated` (line 344) doing exactly this, tolerant of missing fractional seconds. `stall-check` reuses it; no new helper.
- **The Stop hook gets the safe half of fix 2's change 3 only.** The block-reason text is strengthened to demand the roster report (no risk), but relocating the fire-time ack into the hook is **deferred**: it reintroduces a re-fire race that needs a separate `handled` dedupe marker design (see §8). With the wake file now carrying the roster and the stdout carrying the directive, the hook is a backstop, not the primary fix.
- **`CLAUDE.md` is edited by all three fixes in one pass** (§6): the intake lead test (fix 1), the wake-loop section rewritten to match the new mechanism (fix 2), and the `stalled` state in the Supervise vocabulary (fix 3). One pass avoids self-conflicting edits and keeps the doc describing one consistent reality.
- **The threshold statement for the lead test appears once.** The current text states the heuristic in two places (Scope bullet, "Appointing a lead") with a third trigger-phrase entry in the vocabulary; the miss analysis shows duplicated prose drifts. The new test is stated in full at Intake, and the other sites reference it.

What is *not* in this change (deferred, with reasons, in §9): the Stop-hook ack relocation, the `bin/spawn-crew` mechanical nudge, stall auto-recovery, and the error-banner fast path.

## 3. Stage 1 - state layer (`bin/lib/wm-state.py`, `bin/lib/common.sh`)

### 3.1 `stalled` joins the state vocabulary

In `wm-state.py`:

```python
LIVE_STATES = ("working", "blocked", "review", "stalled")
...
ATTENTION_STATES = ("blocked", "review", "done", "died", "stalled")
```

Consequences that fall out for free and are relied on later:
the board renders a stalled member under **Active** (an unresolved problem, not closed);
`reconcile` escalates a stalled member to `died` if its window later dies (it is in `LIVE_STATES`);
`needs-attention` surfaces it once per `(id, updated)` via the existing ack dedupe;
and the watcher's `crew-list --status working` scan skips an already-stalled member, so it is never re-processed.

Update the comments on both constants to name `stalled`: externally observed, supervisor-flagged, "the member shows no sign of life while claiming `working`; remedy is takeover or stand-down".

### 3.2 New `stall-check` subcommand: staleness gates plus an execution probe

#### Why staleness alone is insufficient (measured on the target host, 2026-07-10, tmux 3.7b, macOS)

The stall plan's original predicate - flag when pane output **and** status file are both stale past a threshold - was validated against the live fleet before build, and it fails on a class the source plan did not consider: **healthy members parked between harness wakes.**
The measurements that ground the revised design:

- **Idle claude panes emit zero output.** Sampled twice 159s apart, every idle crew pane's `#{window_activity}` age grew by exactly the elapsed time (68s→227s, 156s→315s, 173s→332s), while the actively-working session's age stayed 0s. The pane-idle signal is clean on this stack: a session repaints continuously while thinking or running a tool, and goes byte-silent the moment it parks at the prompt.
- **A healthy parked lead trips both staleness gates.** At sample time, a live lead supervising active crew read status `working` with a 312s-old status file and a 227s-old pane - past the 180s threshold on both signals, and it would stay past them for however long its crew take. Parking between wakes is the *designed* steady state for a lead (and for any member awaiting a background watcher), so no threshold fixes this; raising it only lengthens the coin-flip.
- **The pane root *is* the agent process.** `spawn-crew` execs the agent CLI as the pane command, so tmux `#{pane_pid}` is the `claude` process itself; `ps` can walk its descendants directly.
- **Mere child-process presence proves nothing.** Idle sessions retain long-lived children: MCP stdio servers, and - for parked members - the armed background watchers themselves (`watch-fleet` with its `sleep 5`, `pr-watch` with its `sleep 30`). "Has descendants" is true for every healthy *and* every stalled claude session.
- **"New pids appeared" also proves nothing.** An idle parked member's armed watcher spawns transient `uv run` processes every poll; even fully idle trees showed `new_pids=1` across a 12s window.
- **Cumulative CPU time separates idle from executing.** Summed CPU-time delta over the pane's process tree (pids present in both samples), across a 12s window: idle parked trees 0.030s / 0.080s / 0.130s (0.25-1.1% of one core, the residue of watcher wakeups); the actively-working session 1.220s (~10%). An epsilon of ~0.5s per 10s window sits well clear of both sides. Instantaneous `%cpu` corroborates (idle claude 0.0-0.3%, active 15.7%) but is a decaying average on macOS, so the delta of cumulative `TIME` is the signal to use.
- **Descendant start times separate baseline children from armed work.** MCP servers start with the agent (same second, at launch); armed background watchers and foreground tool shells start minutes to tens of minutes later (measured: agent 15:48:23 → its `watch-fleet` child 15:56:11; agent 15:16:57 → `watch-fleet` 16:01:15). "A descendant started more than a grace period after the pane root" is therefore reliable evidence of either in-flight tool work (a build's shell) or an armed wake source (a watcher that will exit and re-invoke the session) - and it is observable portably via `ps -o etime=`.

#### The revised predicate

A `working` member with a live window is flagged `stalled` iff **all four** hold:

```
status_idle >= WM_STALL_IDLE                     (gate: no self-reported progress)
pane_idle   >= WM_STALL_IDLE                     (gate: no pane output)
no descendant of the pane root started more      (probe: no in-flight tool work and
  than WM_STALL_ROOT_GRACE secs after the root    no armed wake source)
tree cputime delta over WM_STALL_PROBE_GAP       (probe: not computing)
  secs < WM_STALL_CPU_EPS
```

The two cheap staleness gates run every poll and nominate candidates; the probe runs only for a nominated candidate (rare), so its cost - one extra `ps` pass plus a `WM_STALL_PROBE_GAP` pause inside the watcher process - is paid almost never and blocks nothing but the watcher's own loop.

How each legitimate quiet shape escapes the flag:

- **Long build / test run / long foreground tool call:** on the current harness the pane keeps repainting (elapsed-seconds timer), so it is never nominated; even if the repaint were lost, the tool's shell is a late-started descendant and usually burns CPU - two independent escapes.
- **Parked lead / member awaiting a background watcher:** the armed `watch-fleet`/`pr-watch` is a late-started descendant → never flagged, at any parking duration.
- **Model inference / streaming:** pane repaints (not nominated); the agent process itself accumulates CPU (probe escape) - covers a pane frozen by tmux copy-mode during real work.
- **Non-repainting harness doing quiet in-process work:** CPU delta escape, plus the status-refresh cadence the contract already asks for.
- **The target failure (agent errored, idle at prompt):** status stale, pane silent, only launch-time children (MCP servers), tree CPU ≈ 0 → flagged.

One asymmetry is deliberate: a member that errored *while a background watcher was still armed* is not flagged, because the armed watcher is indistinguishable from healthy parking - and it is also the self-healing path: that watcher's eventual exit re-invokes the session. The residual blind spot (errored member whose armed watcher never fires because the watched condition never occurs) is accepted and documented in §8.

#### Implementation sketch

`stall-check` keeps all policy, timestamp math, and `ps` parsing in Python; the watcher supplies the two inputs Python cannot see as cheaply - the pane-idle age and the pane root pid.

```python
def _ps_tree(root_pid):
    """{pid: (cputime_secs, elapsed_secs)} for root_pid and its descendants, from one
    `ps -ax -o pid=,ppid=,time=,etime=` pass. Parses both time formats: BSD/macOS
    'MM:SS.cc' and procps/Linux '[[DD-]HH:]MM:SS'. Empty dict if the root is gone."""

def _probe_execution(root_pid, root_grace, gap, eps):
    """True if the pane's process tree shows positive evidence of execution or an
    armed wake source: (a) any descendant whose start lags the root's by more than
    root_grace seconds (in-flight tool shell, or an armed background watcher that
    will exit and wake the session; launch-time children like MCP servers start
    with the root and do not count), else (b) summed cputime delta over pids
    present in two samples `gap` seconds apart >= eps. If the tree cannot be read
    at all, returns False (fall back to the staleness verdict; window liveness is
    reconcile's job)."""

def cmd_stall_check(args):
    """Flag a WORKING crew member as 'stalled' iff it shows no external sign of life:
    BOTH staleness gates (pane_idle from the watcher, status_idle computed here) at
    or past --threshold, AND the execution probe over --pane-pid finds no evidence.

    Prints 'stalled' if it flipped the member, nothing otherwise. Idempotent and safe
    to call every poll: gates fail fast, the probe runs only for nominated candidates,
    and once flipped, status != 'working' so subsequent calls skip."""
    ensure_home()
    live = read_json(status_path(args.id), None)
    if not isinstance(live, dict) or live.get("status") != "working":
        return
    updated = _parse_updated(live.get("updated"))
    if updated is None:
        return
    status_idle = (datetime.datetime.now(datetime.timezone.utc) - updated).total_seconds()
    if args.pane_idle < args.threshold or status_idle < args.threshold:
        return
    if _probe_execution(args.pane_pid, args.root_grace, args.probe_gap, args.cpu_eps):
        return

    prior = (live.get("summary") or "").split("\n")[0][:80]
    reason = ("no pane output, status update, running child process, or CPU activity "
              "for >%ds while status was 'working'; the agent likely errored or went "
              "idle. Inspect with `bin/crew-takeover %s` or stand down with "
              "`bin/crew-standdown %s`." % (int(args.threshold), args.id, args.id))
    if prior:
        reason += " (last summary: %s)" % prior

    live["status"] = "stalled"
    live["summary"] = reason
    live["updated"] = now()
    write_json(status_path(args.id), live)

    # Mirror into the roster, as crew-set does, so a later loss of the status
    # file still tells the truth.
    roster = load_roster()
    for r in roster:
        if r.get("id") == args.id:
            r["status"] = "stalled"
            r["updated"] = live["updated"]
    write_json(crew_json_path(), roster)
    render_board()
    print("stalled")
```

Parser registration in `build_parser()`:

```python
a = sub.add_parser("stall-check")
a.add_argument("--id", required=True)
a.add_argument("--pane-idle", type=int, required=True, dest="pane_idle")
a.add_argument("--pane-pid", type=int, required=True, dest="pane_pid")
a.add_argument("--threshold", type=int, default=180)
a.add_argument("--root-grace", type=int, default=30, dest="root_grace")
a.add_argument("--probe-gap", type=int, default=10, dest="probe_gap")
a.add_argument("--cpu-eps", type=float, default=0.5, dest="cpu_eps")
a.set_defaults(fn=cmd_stall_check)
```

Design points: gates before probe keeps the per-poll cost of the common case at one early-returning Python invocation;
the probe's two `ps` samples use cumulative `TIME` deltas over the pid intersection, which is immune to the transient processes idle watchers spawn (§ measurements above) and to `%cpu`'s platform-dependent averaging;
the late-descendant test uses `etime` arithmetic (`root_elapsed - descendant_elapsed > root_grace`), not wall-clock parsing, so it is locale-safe;
the prior summary is preserved inline in the reason so no information is lost;
the direct file write (rather than shelling to `crew-set`) composes the reason atomically, matching the `reconcile` pattern.

The `needs-attention` note for a stalled member resolves through the existing fallback chain (`blocker or delivery or artifact or summary`) to the stall reason, so the fire line reads `stalled: <id> no pane output or status update for ...` with the remedy embedded - no change needed there.

### 3.3 tmux helpers in `common.sh`

Two helpers, added next to `wm_tmux_pane_text`.
The pane root pid feeds the execution probe (`spawn-crew` execs the agent as the pane command, so this is the agent process; if a human has split the window, the first pane is still the agent's):

```sh
# Pid of the root process of a window's first pane (the agent CLI itself - spawn-crew
# execs it as the pane command). Empty if the window is unknown.
wm_tmux_pane_pid() {
  wm_tmux list-panes -t "$WM_TMUX_SESSION:$1" -F '#{pane_pid}' 2>/dev/null | head -1
}
```

```sh
# Seconds since the last output in a window's pane, from tmux's own
# #{window_activity} (epoch secs), which advances on any pane repaint and is
# independent of the monitor-activity option. Prints a large number if the window
# is unknown, so callers treat "can't tell" as "not stale enough to suppress a
# real flag" - the AND with status-idle guards the flag itself.
# Harness-neutral: any TUI that repaints while working keeps this fresh.
wm_tmux_window_activity_age() {
  _win="$1"
  _act="$(wm_tmux list-windows -t "$WM_TMUX_SESSION" \
            -F '#{window_name} #{window_activity}' 2>/dev/null \
          | awk -v w="$_win" '$1==w {print $2; exit}')"
  [ -n "$_act" ] || { echo 999999; return; }
  echo $(( $(date +%s) - _act ))
}
```

Single `list-windows` call parsed with `awk`; bash-3.2-safe (no associative arrays, no `mapfile`).

**Precondition status:** the `#{window_activity}` assumption is **verified on the target host** (tmux 3.7b, macOS, no `monitor-activity`): idle panes' activity ages grow by exactly the elapsed wall-clock time and an active session's stays at 0 (§3.2 measurements).
Re-verify on any other deployment host (§7.1 gives the recipe); if a tmux configuration is found where it does not hold, fall back to a double-capture comparison (capture pane text twice, `WM_STALL_SETTLE` apart, compare for byte-identity) as the pane-idle signal; the rest of the design is unchanged.

## 4. Stage 2 - watcher (`bin/watch-fleet`)

### 4.1 Harden the prompt-freeze detector (fix 4)

The single `grep -qiE "$WM_PERM_PROMPT_RE"` over the whole pane is replaced by a `prompt_freeze_check <id> <window>` helper enforcing three cumulative conditions, per the report's recommendation; each alone stops the transcript-content false positive, and together they make the check anchored to what a real frozen dialog looks like rather than to what its text says:

1. **Prompt UI shape at the bottom of the screen, with adjacency and a line-start anchor.** Only the last `WM_PERM_TAIL` (default 25) lines of the capture are searched; the question phrase must render as its own line (`WM_PERM_LEAD_RE`: only non-alphanumeric characters and optionally an option-row prefix `N. ` may precede it, so the trust/Bypass acceptance rows still match); and a numbered-options line (`WM_PERM_OPTION_RE`, default `^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]`) must appear within `WM_PERM_ADJ` (default 3) lines *after* the phrase line - the one-block layout a real dialog renders. Transcript diffs mid-screen stop matching entirely; a quoted phrase in prose stops matching regardless of nearby lists, because prose and diff prefixes contain alphanumerics (PR-review finding 1 and its round-2 residual: stability cannot discriminate on a *parked* pane, and adjacency alone admits a quote with a list starting within the window). The accepted residual is a verbatim full-dialog quote at column zero.
2. **Pane stability across consecutive polls.** The capture's `cksum` is kept per member in `$WM_HOME/pane-<id>.hash` (the pidfile pattern; a stale file is harmless) and the flip requires byte-identity with the previous poll's capture. A mid-turn working pane is never identical across polls (the status-line timer ticks every second), while a frozen dialog is static. Costs one extra `INTERVAL` (~5s) of latency on a real freeze.
3. **Case-sensitive question prefix.** `WM_PERM_PROMPT_RE` defaults to the case-sensitive `Do you want to ` prefix (covering every per-tool phrasing: proceed, make-this-edit, create-file) plus the trust-dialog and Bypass-acceptance option rows, still overridable for another harness. The precision is carried by conditions 1 and 2, not by phrase pinning (PR-review finding 4: pinning to `proceed?` dropped the most common non-bypass gates).

The anchor and adjacency were verified against live captured dialogs (Claude Code v2.1.206, per the §7.1 recipe): the per-tool proceed dialog renders the question as its own line with options immediately below; the workspace-trust dialog's question prose varies by CLI version and sits ~8 lines above its options, so it is matched by its stable `Yes, I trust this folder` option row (with its sibling row satisfying adjacency) - which is why the phrase list names option rows, not the trust question.

The helper writes the hash file on every poll (match or not) so a dialog appearing later is confirmed on its second sighting.
When the shape matches but stability is not yet confirmed (first sighting, no prior hash), the loop holds the stall check off that member for the poll - otherwise a dialog frozen longer than `WM_STALL_IDLE` before the watcher's first look would be flipped `stalled` on poll one and, having left the working scan, never re-diagnosed `blocked` (PR-review finding 2).
Symmetrically, `stall-check` re-reads the live status file after its probe gap and bails unless status and `updated` are unchanged, so a member self-reporting during the gap is never clobbered by the pre-gap snapshot (PR-review finding 3).
The report's follow-ups (status-file freshness veto, spinner veto) are deferred: the stability condition captures the same liveness signal generically, and the spinner match is fragile against harness UI changes.

### 4.2 Rewrite `fire()`: distinct roles for the two channels

Today both channels carry the same `(id, status, note)` delta.
After this change: **stdout = terse trigger + directive; wake file = deltas + the full roster to report from.**

```sh
fire() {
  _attention="$1"
  {
    echo "# Crew need your attention"
    echo
    echo "## New events"
    echo
    printf '%s\n' "$_attention" | while IFS=$'\t' read -r id st upd note; do
      [ -n "$id" ] && printf -- '- **%s** [%s] %s\n' "$id" "$st" "$note"
    done
    echo
    echo "## Full roster (this owner's scope)"
    echo
    wm_state crew-list --owner "$OWNER" 2>/dev/null
  } > "$WAKEFILE"
  printf '%s\n' "$_attention" | while IFS=$'\t' read -r id st upd note; do
    [ -n "$id" ] && printf '%s: %s %s\n' "$st" "$id" "$note"
  done
  printf -- '--\n'
  printf 'The lines above are state-change deltas, not the full picture.\n'
  printf 'Read %s for the full roster (or run bin/crew-list), then report a compact\n' "$WAKEFILE"
  printf 'roster status to the pilot: who is on what, what is blocked, what is stalled,\n'
  printf 'what is ready for review. Then arm one fresh watch-fleet cycle before you stop.\n'
  # Firing IS the delivery, so ack each surfaced (id, updated). (Unchanged.)
  printf '%s\n' "$_attention" | while IFS=$'\t' read -r id st upd note; do
    [ -n "$id" ] && wm_state ack --id "$id" --updated "$upd" >/dev/null 2>&1
  done
  rm -f "$PIDFILE"
  exit 0
}
```

Notes:

- The directive prints the **actual `$WAKEFILE` path**, not a hardcoded `~/.wingman/wake` - a lead's cycle is keyed `wake-<key>`, and the owner scoping risk in the wake-handling report is exactly that a lead would otherwise read or render the wrong scope.
  The roster render uses the same `--owner "$OWNER"` the cycle was armed with, for the same reason.
- `crew-list`'s default view (hides only `stood-down`) is the right roster slice: it includes `died` members, which are themselves frequently the event being surfaced.
- The roster snapshot is written at fire time, immediately after the loop's own `reconcile` and stall pass, so it is current; `bin/crew-list` remains the live fallback and the directive names it.
- The fire-time ack stays exactly where it is.
  Removing it is the deferred change (§9.1); with the directive now in the wake signal itself, the ack's pre-disarming of the Stop hook no longer removes the only pointer to complete handling.

### 4.3 Wire the stall detector into the existing working-crew loop

Add the tunables next to `INTERVAL`/`GRACE`:

```sh
# Silent-stall detection. STALL_IDLE seconds of BOTH pane-output silence AND
# status-file staleness nominates a 'working' member; it is flagged stalled only if
# the execution probe (see wm-state stall-check) then finds no late-started
# descendant process and no CPU activity in its pane's process tree.
STALL_IDLE="${WM_STALL_IDLE:-180}"
STALL_ROOT_GRACE="${WM_STALL_ROOT_GRACE:-30}"
STALL_PROBE_GAP="${WM_STALL_PROBE_GAP:-10}"
STALL_CPU_EPS="${WM_STALL_CPU_EPS:-0.5}"
```

Extend the loop body that already iterates every `working` member with a live window (do **not** add a second `crew-list` pass).
The permission branch gains a `continue` - a permission freeze is the more specific diagnosis and must not also be stall-flagged - then the stall check runs:

```sh
      if prompt_freeze_check "$_id" "$_win"; then
        wm_state crew-set --id "$_id" --status blocked \
          --blocker "frozen on a permission/trust prompt with no one at its terminal; approve it via bin/crew-takeover $_id, or relaunch the crew with bypass" \
          >/dev/null 2>&1
        continue
      fi

      # Silent-stall backstop: no pane repaint AND no status update for STALL_IDLE
      # seconds nominates the member; stall-check probes its process tree and flags
      # it stalled only if nothing there is executing or armed to wake it.
      _idle="$(wm_tmux_window_activity_age "$_win")"
      _pid="$(wm_tmux_pane_pid "$_win")"
      [ -n "$_pid" ] && wm_state stall-check --id "$_id" \
        --pane-idle "$_idle" --pane-pid "$_pid" --threshold "$STALL_IDLE" \
        --root-grace "$STALL_ROOT_GRACE" --probe-gap "$STALL_PROBE_GAP" \
        --cpu-eps "$STALL_CPU_EPS" >/dev/null 2>&1
```

`stall-check` fails fast on the gates, so calling it every poll is safe and idempotent; the probe (and its `STALL_PROBE_GAP` pause inside the watcher) runs only for a nominated candidate, which the parked-member escape makes rare.
When it flips, the next top-of-loop `needs-attention` picks up the `stalled` row and `fire()` surfaces it through the rewritten path above; `ack` makes it fire exactly once.
Detection latency ≈ `WM_STALL_IDLE` plus the probe gap plus up to one `WM_WATCH_INTERVAL` (5s) poll.
The per-poll cost is one extra `uv run` per working member, alongside the `crew-list` and pane captures the loop already pays; acceptable at fleet sizes wingman runs.

### 4.4 Header comment

Update the `watch-fleet` header to current reality: a cycle exits when a member flips to any attention state (`blocked`, `review`, `done`, `died`, `stalled`) or freezes on a prompt; the pane backstop now covers both the permission freeze and the silent stall; the wake file carries deltas plus the full owner-scoped roster.

## 5. Stage 3 - Stop hook (`hooks/stop-guard.sh`)

Strengthen the block reason (lines 70-72) so the one enforcement message asks for the same complete handling the wake signal now directs:

```sh
  reason="Crew need your attention before you go idle:
$list
Read $WM_HOME/wake and run bin/crew-list, surface each blocker/PR to the pilot (or
answer via bin/crew-say), and give the pilot a compact roster status (who is on what,
what is blocked, what is stalled, what is ready), then you may stop."
```

The hook's ack behavior, liveness check, and no-watcher branch are unchanged.
Moving the fire-time ack into this hook (so a fired event blocks the stop once and enforces the roster report) is deferred - see §9.1 for the race it must first solve.

## 6. Stage 4 - instructions and docs (one pass, after the mechanism lands)

Per the repo's doc guidelines: present tense, describing the current state, no change narrative.

### 6.1 `CLAUDE.md` - the lead test at intake (fix 1)

Four coordinated edits; the threshold is stated in full **once**, at Intake:

1. **Intake step: add "the lead test" to the grounding checklist** (alongside artifact resolution and never-invent-history), as a mandatory binary question answered for every directive before scoping:

   > - **Run the lead test.** Does the effort need a **third role beyond the standard analyst→developer pair** (a reviewer or architect in the same sequence), or **more than one developer/delivery**, or does it **span multiple repos**? If yes, include the verdict in the one-line restatement and offer the choice: "this crosses the lead threshold - want me to appoint a lead, or run it as direct spawns?". Suggesting a lead costs nothing; only spawning is expensive - when the test passes, always say so; the pilot decides. Re-run the test whenever the pilot expands an in-flight effort with another role or deliverable, counting everything already spawned for that effort; if it now passes, suggest promoting the effort to a lead.

   The threshold is deliberately restated so the plain analyst→developer handoff (two roles, two deliverables) no longer passes it - the current "more than one role in sequence *and* more than one deliverable" wording captures wingman's documented default path and therefore cannot be applied literally.
2. **Scope step:** rewrite the "Assess whether the effort warrants a lead" sub-bullet to a one-line pointer: the assessment already happened at intake as the lead test; scope acts on its verdict.
   Remove the trailing "don't reach for it by default" from this bullet (the anti-suggestion bias the analysis identified); the cost caution lives where it belongs, on *spawning*, in Cost discipline.
3. **Command vocabulary:** prefix the entries that can absorb large directives - "Implement feature X" and "Investigate issue Y" - with "apply the lead test first (see Intake)".
   The lead's own entry keeps its explicit-trigger behavior and adds the same cross-reference for implied cases.
4. **"Appointing a lead" section:** replace the duplicated heuristic sentence with a reference to the intake lead test (keeping "(Heuristic tunable here.)" pointing at the Intake statement), and keep the direct-appointment rule for explicit "take the lead" phrasing.

### 6.2 `CLAUDE.md` - wake loop and supervise (fixes 2 and 3)

- **"Supervise" bullet:** the watcher also detects a member that has gone silently idle or errored while its status stays `working`, and flips it to `stalled`; the remedy to surface is `bin/crew-takeover <id>` or `bin/crew-standdown <id>`.
- **"The wake loop" section, "On each wake":** rewrite to match the mechanism - the fire's stdout names the wake file and the required roster report; the wake file contains the new events plus the full roster for the cycle's owner scope; wingman reads it (or runs `bin/crew-list`), reports a compact roster status (who is on what, what is blocked, what is stalled, what is ready), then arms exactly one fresh cycle.
- **Command vocabulary / lifecycle:** add `stalled` where states are enumerated (a stalled member is left running like `blocked`/`review`; the pilot decides takeover vs stand-down).

### 6.3 `playbook/_status-contract.md`

Document that the supervisor may externally flip a member to `stalled` when it shows no sign of life on any channel - no pane output, no status update, no running child process, no CPU activity - for an extended period (default 180s), that the flip preserves the last summary inside the stall reason, and that the remedy is takeover or stand-down.
Note explicitly that parking on an armed harness-tracked watcher is recognized (the watcher is a live descendant process) and is never flagged, so the contract's wake-loop pattern needs no defensive status refreshes.
Reinforce the existing guidance to refresh the status summary on meaningful progress regardless - on a harness with no live repaint and no child processes, that refresh is the remaining escape hatch.

### 6.4 Comments enumerating states

Sweep `wm-state.py` and `bin/watch-fleet` for comments that enumerate the state vocabulary and add `stalled` (the `LIVE_STATES`/`ATTENTION_STATES` comment blocks, the `fire()` and header comments, `board.md` render needs no change - `stalled` flows through Active automatically).

## 7. Testing strategy

The repo has a bash E2E suite (`tests/*.test.sh`, shared `tests/lib.sh`, runner `tests/run.sh`) with per-test isolated `WINGMAN_HOME` and a nonexistent tmux session name; new tests follow those conventions.
Existing `watch-fleet.test.sh` assertions use `assert_contains` on the reason lines and wake file, so the appended directive block and roster section do not break them; run the full suite to confirm.

### 7.1 Verify the platform assumptions first (manual, before coding)

The tmux `#{window_activity}` behavior is already verified on this host (§3.2); on any other deployment host, re-check with:

```sh
tmux new-window -t wingman -n wm-stalltest 'sh -c "echo hi; sleep 600"'
tmux list-windows -t wingman -F '#{window_name} #{window_activity}'   # poll a few times
```

Also verify the `ps` invocation the probe depends on parses on the host: `ps -ax -o pid=,ppid=,time=,etime=` (BSD and procps both accept it; `time` is `MM:SS.cc` on macOS, `[[DD-]HH:]MM:SS` on Linux, and `_ps_tree` must parse both).

### 7.2 Unit-level, no tmux (`tests/stall-check.test.sh`, driving `wm-state.py` directly)

The probe operates on real process trees, so the tests build tiny synthetic ones (the harness's isolated `WINGMAN_HOME` needs no tmux for any of this); `--probe-gap 2 --root-grace 2` keeps them fast.

Gate behavior:

- Fresh working member: `stall-check --pane-idle 0 ...` prints nothing; status stays `working`; the probe is never reached (verify by passing a bogus `--pane-pid`, which must not matter).
- Old status but fresh pane (`--pane-idle 5`), and fresh status but stale pane: nothing (AND fails).
- `stall-check` on a `blocked`/`review`/`done` member is a no-op regardless of ages.
- `review` members still appear in `needs-attention` and on the board's Active list (guards the constant-append against the inline-tuple regression named in §2).

Probe behavior (both gates stale in each case, `updated` hand-written 10 min old):

- **Truly idle tree → flagged:** `--pane-pid` of a bare `sleep 600` process (its only child, if any, started at launch) → prints `stalled`; status file **and** roster read `stalled`; the prior summary appears inside the reason; a second identical call prints nothing.
- **Late-started descendant → not flagged:** a root that spawns a sleeping child after the grace has elapsed (e.g. `sh -c 'sleep 5; sleep 600 & wait'` with `--root-grace 2`, probed after the child exists) - models a parked member with an armed watcher.
- **Launch-time child only → still flagged:** a root that spawned its sleeping child immediately (`sh -c 'sleep 600 & wait'`) - models the MCP-server baseline; the child is within the grace, so it is not evidence.
- **CPU activity → not flagged:** `--pane-pid` of a busy-loop process (`sh -c 'while :; do :; done'`) with no late children - the cputime delta over the probe gap exceeds the epsilon.
- **Vanished root → flagged:** a pid that no longer exists falls back to the staleness verdict (window liveness is reconcile's concern, and the gates already tripped).
- `needs-attention` surfaces the stalled member once; after `ack --id --updated <stamp>` it is suppressed; a later status change re-surfaces.

### 7.3 Watcher E2E (`tests/watch-fleet.test.sh` extensions)

- **Wake file carries the full picture:** with two members on the roster (one flipping to `review`, one staying `working`), a fire's wake file contains a "New events" section naming the flipped member **and** a roster section naming both; stdout contains the `review: <id> <artifact>` line **and** the directive block (assert on "not the full picture" and the wake-file path).
- **Owner scoping:** arm with `--owner lead-x` where the roster holds both a top-level member and a `parent: lead-x` member; the wake file (`wake-lead-x`) roster section contains only the lead's report.
- **Stall fires end-to-end (tmux integration):** spawn a dummy window running a bare sleep (an errored/idle agent - no output, no late children, no CPU), register a matching `working` record with an old `updated`, run one cycle with `WM_STALL_IDLE=10 WM_STALL_PROBE_GAP=2 WM_WATCH_INTERVAL=2`; the cycle exits with a `stalled: <id>` reason and the wake file names it.
- **No false positive on a busy window:** a dummy window printing every second with the same old `updated` is not flagged (pane fresh, never nominated).
- **No false positive on a parked member (the §3.2 finding):** a dummy window whose root is silent but holds a late-started sleeping child (armed-watcher analog) with the same old `updated` is not flagged - the probe sees the descendant.
- **Permission regression:** a window rendering a real frozen dialog (question phrase plus numbered options, static pane) is flagged `blocked` (not `stalled`) on its second sighting, and the `continue` means it is never double-processed.
- **No false positive on quoted prompt text (the fix-4 incident shape):** a static window whose transcript quotes the full question phrase but shows no options list is never flagged - the UI-shape anchor refuses it.
- **No false positive on a live prompt-shaped pane:** a window showing both phrase and options but still emitting output (a working session's ticking status line) is never flagged - the stability condition refuses it.

### 7.4 Stop hook (`tests/` addition or extension)

Pipe a synthetic hook input with unacked attention present; assert the block reason contains the roster-status wording and the wake-file/crew-list references; assert `stop_hook_active: true` still allows the stop.

### 7.5 Instruction-level verification (fix 1, manual)

Replay the incident's directive shapes against the revised `CLAUDE.md` in a scratch session:
"review this analysis and fix it" followed by "I want an analyst plan handed to a developer plus review" must produce the lead-test verdict at intake of the second message;
a plain "implement feature X" must still take the direct analyst path with no lead suggestion.

### 7.6 Guardrails

Full `tests/run.sh` green; `wm-state.py` stays dependency-free (PEP 723 header unchanged); all shell stays bash-3.2-safe (no associative arrays, no `mapfile`, no `${x,,}`).

## 8. Risks and tradeoffs

- **Stall false positives.** The measured false-positive class (a healthy parked member, §3.2) is eliminated structurally by the late-descendant probe, not by threshold tuning; long builds and tool calls have two independent escapes (pane repaint, late-started shell + CPU); the residual exposure is a harness that neither repaints, nor spawns child processes, nor burns measurable CPU during legitimate quiet work - there the status-refresh cadence the contract asks for is the escape hatch, and `WM_STALL_IDLE` can be raised as a last resort.
- **Stall false negatives (the deliberate asymmetry).** A member that errored while a background watcher was still armed is not flagged; the armed watcher is also the self-healing path (its exit re-invokes the session). The blind spot - an errored member whose armed watcher never fires because the watched condition never occurs - is accepted: in that scenario the watched subtree itself is quiet and surfaces through its own states. An MCP server restarted mid-session would likewise read as a late descendant and suppress a real stall; rare, and it heals on the next real event.
- **Probe epsilon drift.** `WM_STALL_CPU_EPS` (0.5s per 10s window) sits ~4x above the measured idle-tree residue (0.03-0.13s per 12s, from armed watchers waking) and ~10x below measured active work (1.2s per 12s); if future harness versions get chattier at idle, the margin narrows from below - the epsilon is an env knob precisely for this.
- **`window_activity` semantics.** Verified on this host (§3.2); re-verify per deployment host per §7.1, with the double-capture fallback named in §3.3.
- **`ps` portability.** The probe's single invocation (`ps -ax -o pid=,ppid=,time=,etime=`) is accepted by both BSD ps (macOS) and procps (Linux), but the `time`/`etime` formats differ and `_ps_tree` must parse both; only macOS is empirically verified today (§10).
- **Wake-file roster staleness.** The snapshot is written at fire time; crew state can change before wingman reads it. Accepted: the directive also names `bin/crew-list` as the live fallback, and the snapshot is still strictly more complete than today's delta-only file.
- **Directive verbosity on every fire.** A few lines per wake, negligible against wingman's context, and deliberately placed in the one channel that cannot be skipped.
- **Summary overwrite on stall flip.** The stall reason replaces the live summary; the prior summary is preserved inline, so nothing is lost.
- **Human takeover during a stall.** Typing in the pane refreshes `window_activity` but status stays `stalled` until someone calls `crew-set`; acceptable, since the human is already engaged. Auto-recovery is deferred to avoid flapping.
- **Prompt-freeze detection now depends on the harness's dialog shape.** The UI-shape anchor assumes a question phrase plus a numbered-options list at the bottom of the pane (Claude Code's rendering); a harness that renders gates differently needs `WM_PERM_PROMPT_RE`/`WM_PERM_OPTION_RE`/`WM_PERM_TAIL` overridden - the same knob story as `WM_AGENT`. A real freeze is detected one `INTERVAL` later than before (the stability confirmation); acceptable for a one-time-per-repo gate.
- **Prose fixes remain prose.** Fix 1 is an instruction-text change to an LLM orchestrator; it cannot be deterministically guaranteed. The visible-verdict requirement is what converts a future miss from silent to immediately observable, and the spawn-crew nudge (§9.2) is the mechanical backstop if misses persist.

## 9. Deferred follow-ups (explicitly out of scope)

1. **Stop-hook ack relocation** (wake report, change 3b): removing the fire-time ack so the hook blocks once per fired event would enforce the roster report, but it reintroduces a re-fire race - a fresh cycle armed before the hook acks re-fires the still-unacked event. Requires a separate `handled` marker keyed by `(id, updated)` that both `fire()` and `needs-attention` respect, distinct from `ack`. Design that first; do not ship it here.
2. **Mechanical lead-test backstop in `bin/spawn-crew`** (lead-miss report): print a heuristic warning when a top-level spawn would put three or more active top-level members in flight, or when a `reviewer`/`architect` spawns at top level. A nudge, not a block.
3. **Stall auto-recovery** (flip `stalled` back to `working` on sustained fresh pane activity) - deferred to avoid state flapping.
4. **Error-banner fast path** (`WM_STALL_BANNER_RE`) - harness/version-specific pane text, against the harness-agnostic grain, and Claude Code auto-retries transient errors so matching the banner would false-alarm during normal recovery.
5. **Per-type stall thresholds** if some crew types prove legitimately quieter.
6. **Retire the session-memory mitigation** (`suggest-lead-at-intake.md` in the requester's memory directory) once the repo encoding lands, so behavior does not depend on one machine's memory files. This is a machine-local step for the requester, not a repo change.

## 10. Open questions

- **Stall threshold default:** with the execution probe gating the flag, `WM_STALL_IDLE` no longer bounds false positives - it is pure detection latency plus a rate limit on probing. Recommended: ship 180s. Raising it buys nothing except slower detection; lowering it below ~120s starts probing sessions that merely paused between turns.
- **Probe defaults (`WM_STALL_ROOT_GRACE=30`, `WM_STALL_PROBE_GAP=10`, `WM_STALL_CPU_EPS=0.5`):** grounded in the §3.2 measurements on one host; treat as initial calibration and adjust from observation. The grace must stay above the agent's launch-time child spawn window (MCP servers: ~1s observed) and below the shortest plausible gap between launch and first armed watcher (minutes observed).
- **Linux verification:** the probe's `ps` output formats are handled by design but only macOS is measured; verify `_ps_tree` parsing and the idle/active CPU separation on a Linux host before relying on the detector there.
- **§7.1 outcome on other hosts:** if `window_activity` does not behave as assumed, switch the pane-idle signal to the double-capture fallback before proceeding; everything downstream of the signal is unchanged.

## 11. Files touched

| File | Change |
|---|---|
| `bin/lib/wm-state.py` | append `stalled` to `LIVE_STATES` and `ATTENTION_STATES`; add `cmd_stall_check` with the execution probe (`_ps_tree`, `_probe_execution`) + parser entry (reusing `_parse_updated`); update state-vocabulary comments |
| `bin/lib/common.sh` | add `wm_tmux_window_activity_age` and `wm_tmux_pane_pid` |
| `bin/watch-fleet` | rewrite `fire()` (wake file = deltas + owner-scoped roster; stdout = reason lines + directive block with the real `$WAKEFILE` path); add the `STALL_*` tunables; replace the pane grep with `prompt_freeze_check` (UI-shape anchor + pane-stability hash + tightened case-sensitive phrases, `WM_PERM_OPTION_RE`/`WM_PERM_TAIL` knobs); `continue` after the permission flip; call `stall-check` with pane idle + pane pid per working member; header comment |
| `hooks/stop-guard.sh` | strengthen the block reason to require the roster report |
| `CLAUDE.md` | intake lead test (threshold stated once, verdict visible, re-evaluation rule); Scope/vocabulary/"Appointing a lead" cross-references; wake-loop section matches the new mechanism; `stalled` in the supervise vocabulary |
| `playbook/_status-contract.md` | document supervisor-flagged `stalled` and the status-refresh escape hatch |
| `tests/stall-check.test.sh` (new) | unit coverage per §7.2 |
| `tests/watch-fleet.test.sh` | wake-file/directive/owner-scope/stall E2E per §7.3 |
| `tests/` stop-hook coverage | reason-text assertions per §7.4 |

## 12. Suggested build order (one branch, one PR)

1. Stage 1 (state layer) + §7.2 unit tests - green.
2. §7.1 platform verification (tmux `window_activity` where not already measured, and the probe's `ps` parsing) on the build host.
3. Stage 2 (watcher) + §7.3 E2E tests - green, including existing suite.
4. Stage 3 (stop hook) + §7.4.
5. Stage 4 (CLAUDE.md + playbook docs) in one pass, then §7.5 scratch-session replay.
6. Full `tests/run.sh`, lint, PR referencing this plan and the three source documents.
