# Plan: Detect a silently-stalled crew member

**Date:** 2026-07-10
**Type:** Plan of action (spec). No build handoff has been authorized yet; this file is
the implementation spec a build crew member can execute from alone.
**Area:** `bin/watch-fleet`, `bin/lib/wm-state.py`, `bin/lib/common.sh`, playbooks.

---

## 1. Problem

A build crew member hit an API error inside its agent CLI and went **silently idle**.
From the supervisor's point of view nothing looked wrong:

- Its status file (`crew/<id>.json`) still read `working` - the crew never got a turn
  to update it, because a stalled/idle agent does not run any code to report in.
- Its tmux window was still **alive** - the agent process did not exit, it just stopped
  doing work - so `reconcile` never marked it `died`.
- `needs-attention` only surfaces `blocked` / `done` / `died`, so a member stuck at
  `working` is invisible to it.
- The pane-content backstop in `watch-fleet` only matches an interactive
  permission/trust prompt (`WM_PERM_PROMPT_RE`); an API-error banner or a returned-to-idle
  prompt does not match, so it never fired.

Net effect: the requester saw a **phantom worker** - a crew member reported `working`
indefinitely while it was actually dead in the water.

## 2. Root cause

The supervisor has **no external liveness signal** for a member whose status stays
`working`. Every existing detector keys off either a *self-reported* status transition
(which a stalled agent cannot emit) or a *coarse* signal (window death) that a
hung-but-alive process does not trip. The one external signal we do read - pane text -
is matched only against permission prompts.

A self-reported heartbeat cannot fix this: the failure mode is precisely that the agent
is not executing, so any heartbeat *it* must send is exactly the thing that stops. The
supervisor must **observe the member from the outside**, the same way the permission
backstop already reads the pane, and infer the stall.

## 3. Approach (recommended)

Add an **externally-observed stall detector** to the watcher, built on two independent
staleness signals that must *both* be stale before a member is flagged, and surface the
result as a new distinct state, `stalled`.

### 3.1 The two signals

1. **Pane-output idle age** - harness-agnostic, from tmux itself.
   tmux tracks `#{window_activity}` (epoch seconds of the last output in a window) for
   every window, independent of the `monitor-activity` option. A healthy Claude Code
   session renders a live working indicator (spinner + elapsed/token counters) that
   repaints the pane roughly every second, so `window_activity` keeps advancing the
   whole time it is thinking *or* running a tool. When the agent errors out and returns
   to an idle prompt - or freezes - the repaint stops and `window_activity` goes stale.
   Verified on this host (tmux 3.7b): active windows report `window_activity == now`;
   idle ones lag by minutes.

2. **Status-file idle age** - `now - crew/<id>.json:updated`.
   A stalled agent stops calling `crew-set`, so its `updated` stamp stops advancing.

### 3.2 The decision

A `working` member with a live window is flagged **`stalled`** iff:

```
pane_idle_secs   >= WM_STALL_IDLE   AND
status_idle_secs >= WM_STALL_IDLE
```

Requiring **both** is what keeps false positives low and makes the detector degrade
gracefully across harnesses:

- The errored/idle agent trips both (no pane repaint, no status update) → flagged.
- A genuinely busy Claude Code member never trips signal (1): its spinner keeps the
  pane changing, so `pane_idle` stays small. It is safe even during a long silent tool
  call, because the CLI's "running…" indicator keeps repainting.
- A harness that has *no* live repaint indicator would let `pane_idle` grow during
  normal model inference, but such a member can still keep signal (2) fresh by
  refreshing its status summary on the cadence the contract already asks for - so the
  AND prevents a false flag. This is the escape hatch for long, quiet, legitimate work.

`WM_STALL_IDLE` defaults to **180s** (3 minutes) - long enough that a healthy Claude Code
member (repainting every ~1s) is never within an order of magnitude of it, short enough
that a real stall surfaces within a few minutes. Detection latency ≈ `WM_STALL_IDLE`
plus up to one `WM_WATCH_INTERVAL` (5s) poll.

### 3.3 Why a new `stalled` state (not `blocked`)

`blocked` means "the member is healthy and is *asking* the pilot for a decision/input" -
a considered request the crew itself made. A stall is the opposite: the member is **not**
healthy and did **not** ask for anything. Overloading `blocked` would (a) mislead the
board, and (b) make wingman look for a "decision to relay" that does not exist. A distinct
`stalled` state lets wingman surface a different, correct recommended action: *inspect via
`bin/crew-takeover <id>` or `bin/crew-standdown <id>`*.

### 3.4 Why this respects harness-agnosticism (CLAUDE.md)

- The primary signal (`window_activity`) is a **tmux** feature, not a Claude Code
  feature - it lives in the harness-neutral crew-coordination layer.
- The `stalled` state, `needs-attention`, and the fire/ack plumbing are all in the
  neutral state layer.
- The only harness-specific pane knowledge (the permission regex) is untouched, and the
  optional error-banner regex is deliberately deferred (see Follow-ups) precisely because
  banner text is harness- and version-specific.

## 4. Concrete changes

### 4.1 `bin/lib/common.sh` - a tmux helper for pane-activity age

Add, next to the other tmux helpers (after `wm_tmux_pane_text`):

```sh
# Seconds since the last output in a window's pane, from tmux's own
# #{window_activity} (epoch secs), which advances on any pane repaint and is
# independent of the monitor-activity option. Prints a large number if the window
# is unknown, so callers treat "can't tell" as "not stale enough to flag".
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

Notes:
- Single `list-windows` call, parsed with `awk` - bash-3.2-safe, no associative arrays.
- Missing/unknown window → `999999`. The caller must *not* flag on this alone; the AND
  with status-idle already guards against it, but the large sentinel keeps the helper
  from ever *suppressing* a real flag either.

### 4.2 `bin/lib/wm-state.py` - the `stalled` state + a `stall-check` command

**(a) State tables (top of file).** Add `stalled` as a live-ish, attention-worthy state:

```python
LIVE_STATES = ("working", "blocked", "stalled")
```

`stalled` joins `LIVE_STATES` so that: the board renders it under **Active** (it is an
unresolved problem, not a closed member); `reconcile` still escalates a stalled member
to `died` if its window later dies; and the watcher's `crew-list --status working` scan
naturally skips a member already marked `stalled` (no re-processing).

**(b) `needs-attention` filter.** Include `stalled` so it wakes wingman exactly like the
other actionable states (the `ack` dedupe by `(id, updated)` already makes it fire once):

```python
if r.get("status") in ("blocked", "done", "died", "stalled"):
```

**(c) New `stall-check` subcommand.** This encapsulates the *policy* and the timestamp
math in Python (where ISO-8601 parsing is correct and unit-testable), while the watcher
supplies the one thing Python cannot see - the pane-idle age. It is a no-op unless the
member is genuinely `working` and both ages exceed the threshold:

```python
def _parse_iso(s):
    # 'updated' is UTC ISO-8601 with a trailing Z (see now()).
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def cmd_stall_check(args):
    """Flag a WORKING crew member as 'stalled' iff it has shown no external sign of
    life for >= threshold seconds on BOTH channels: pane output (pane_idle, supplied
    by the watcher from tmux) and its own status file (status_idle, computed here).

    Prints 'stalled' if it flipped the member, nothing otherwise. Idempotent and safe
    to call every poll: once flipped, status != 'working' so subsequent calls skip."""
    ensure_home()
    live = read_json(status_path(args.id), None)
    if not isinstance(live, dict) or live.get("status") != "working":
        return
    updated = _parse_iso(live.get("updated"))
    if updated is None:
        return
    now_dt = datetime.datetime.now(datetime.timezone.utc)
    status_idle = (now_dt - updated).total_seconds()
    if args.pane_idle < args.threshold or status_idle < args.threshold:
        return

    prior = (live.get("summary") or "").split("\n")[0][:80]
    reason = ("no pane output or status update for >%ds while status was 'working'; "
              "the agent may have errored or gone idle. Inspect with "
              "`bin/crew-takeover %s` or stand down with `bin/crew-standdown %s`."
              % (int(args.threshold), args.id, args.id))
    if prior:
        reason += " (last summary: %s)" % prior

    live["status"] = "stalled"
    live["summary"] = reason
    live["updated"] = now()
    write_json(status_path(args.id), live)

    # Mirror status into the roster, exactly as crew-set does, so a later loss of the
    # status file still tells the truth.
    roster = load_roster()
    for r in roster:
        if r.get("id") == args.id:
            r["status"] = "stalled"
            r["updated"] = live["updated"]
    write_json(crew_json_path(), roster)
    render_board()
    print("stalled")
```

Register it in `build_parser()`:

```python
a = sub.add_parser("stall-check")
a.add_argument("--id", required=True)
a.add_argument("--pane-idle", type=int, required=True, dest="pane_idle")
a.add_argument("--threshold", type=int, default=180)
a.set_defaults(fn=cmd_stall_check)
```

Design points:
- Policy lives in one testable place; the watcher stays a thin shell caller.
- The prior summary is preserved inside the reason string (Python already has it in
  hand), so no information is lost when the member is flagged.
- Reads/writes the status file directly (same pattern as `reconcile`), rather than
  shelling back out to `crew-set`, so the reason string is composed atomically.

### 4.3 `bin/watch-fleet` - wire the detector into the existing working-crew loop

The loop that runs the permission backstop already iterates every `working` member with a
live window and captures its pane. Extend **that same loop body** (do not add a second
`crew-list`). Introduce the threshold near the other tunables:

```sh
# Seconds of BOTH pane-output silence AND status-file staleness before a 'working'
# member is judged stalled (errored / idle / hung with status stuck at 'working').
STALL_IDLE="${WM_STALL_IDLE:-180}"
```

Inside the `for _id in ...working...` loop, after the permission-prompt check, make the
permission branch `continue` (a permission freeze is the more specific diagnosis and
should not also be stall-flagged), then evaluate the stall:

```sh
      if wm_tmux_pane_text "$WM_TMUX_SESSION:$_win" | grep -qiE "$WM_PERM_PROMPT_RE"; then
        wm_state crew-set --id "$_id" --status blocked \
          --blocker "frozen on a permission/trust prompt with no one at its terminal; approve it via bin/crew-takeover $_id, or relaunch the crew with bypass" \
          >/dev/null 2>&1
        continue
      fi

      # Silent-stall backstop: no pane repaint AND no status update for STALL_IDLE
      # seconds => the agent errored/idle while status is stuck at 'working'.
      _idle="$(wm_tmux_window_activity_age "$_win")"
      wm_state stall-check --id "$_id" --pane-idle "$_idle" --threshold "$STALL_IDLE" >/dev/null 2>&1
```

`stall-check` only flips the member when *both* thresholds are exceeded, so calling it
every poll is safe. When it flips, the next `needs-attention` at the top of the loop picks
up the new `stalled` row and `fire()`s it - and `ack` makes it fire exactly once.

### 4.4 Documentation to update alongside the code

Keep docs describing current reality (per the repo guidelines), present tense:

- **`CLAUDE.md`** ("Supervise" bullet and "The wake loop"): the watcher also detects a
  member that has **gone silently idle/errored while status stays `working`** and flips it
  to `stalled`. Add `stalled` to the vocabulary of states wingman surfaces.
- **`playbook/_status-contract.md`**: document that the supervisor may externally flip a
  member to `stalled` if it shows no pane output and no status update for an extended
  period, and that the remedy is takeover or stand-down. Reinforce the existing guidance
  to refresh the status summary on progress (that refresh is what keeps a legitimately
  long, quiet task from being mistaken for a stall).
- **`bin/watch-fleet`** header comment: add `stalled` to the list of events a cycle exits
  on, and note the new pane-activity + status-staleness backstop beside the permission one.
- Any board/state-vocabulary comment in **`wm-state.py`** that enumerates states.

## 5. Testing strategy

### 5.1 Verify the core tmux assumption first
Before writing code, confirm on the target host that `#{window_activity}` advances on
pane output **without** `monitor-activity` enabled, and freezes when a window goes quiet:

```sh
tmux new-window -t wingman -n wm-stalltest 'sh -c "echo hi; sleep 600"'
# poll a few times; activity age should climb steadily after the initial echo:
for i in 1 2 3; do bin/... wm_tmux_window_activity_age wm-stalltest; sleep 20; done
```

(Confirmed at plan time that active vs idle windows already differ in `window_activity`.)

### 5.2 Unit-level, no tmux (drive `wm-state.py` directly)
Point `WINGMAN_HOME` at a temp dir and:
- **Fresh working member is not flagged:** `crew-add` a member, then
  `stall-check --pane-idle 0 --threshold 180` → prints nothing; status stays `working`.
- **Old status but active pane is not flagged:** hand-write `updated` 10 min old, call
  `stall-check --pane-idle 5 --threshold 180` → nothing (pane is fresh → AND fails).
- **Both stale → flagged once:** `updated` 10 min old, `stall-check --pane-idle 600` →
  prints `stalled`; status file and roster both read `stalled`; prior summary preserved
  in the reason; a second identical call prints nothing (already `stalled`).
- **`needs-attention` surfaces it once:** after the flip it appears in
  `needs-attention`; after `ack --id --updated <that stamp>` it is suppressed;
  changing status again re-surfaces.
- **Non-working states are untouched:** `stall-check` on a `blocked`/`done` member is a
  no-op regardless of ages.

### 5.3 tmux integration (end-to-end, closest to the real failure)
- Spawn a dummy window that prints once then sleeps silently (simulates an errored/idle
  agent), and register a matching `working` crew record with an old `updated`. Run one
  `watch-fleet` cycle with a small `WM_STALL_IDLE` (e.g. `WM_STALL_IDLE=10`,
  `WM_WATCH_INTERVAL=2`) and confirm the cycle **exits** with a `stalled: <id>` reason and
  the wake file names it.
- **No false positive on a busy window:** a dummy window that prints every second
  (simulates the live spinner) with the same old `updated` must **not** be flagged - its
  `window_activity` stays fresh, so the AND fails.
- **Regression:** a window sitting on a permission-prompt string is still flagged
  `blocked` (not `stalled`), and healthy members refreshing their status stay `working`.

### 5.4 Guardrails
Run any existing shell/pyflakes lint the repo uses; keep `wm-state.py` dependency-free and
`common.sh` bash-3.2-safe (no associative arrays, no `mapfile`).

## 6. Risks & tradeoffs

- **False positive - a genuinely long, silent, non-repainting operation.** Mitigated by
  the AND of two signals and the 3-min threshold. For the current Claude Code harness the
  live indicator repaints every ~1s, so a busy member cannot be within range of the pane
  threshold; the residual risk is only a harness with no repaint indicator, and there the
  status-summary refresh is the escape hatch.
- **Threshold tuning.** `WM_STALL_IDLE` is a single env knob; 180s is conservative. If a
  workload legitimately goes quiet for longer, raise it rather than disabling the check.
- **`window_activity` semantics.** The design assumes tmux updates it on pane repaint
  regardless of `monitor-activity`. This is why §5.1 verifies it explicitly before build.
- **Summary overwrite.** Flagging replaces the live summary with the stall reason; the
  prior summary is preserved inline, so no information is lost.
- **Human takeover during a stall.** If the pilot attaches and types, `window_activity`
  goes fresh again but the status stays `stalled` until the member (or the human driving
  it) calls `crew-set`. That is acceptable: the pilot is already engaged, which is the
  intended remedy. Auto-recovery is deferred (see below) to avoid state flapping.

## 7. Follow-ups (not in this change)

- **Auto-recovery from `stalled`.** Optionally let the watcher flip a `stalled` member
  back to `working` once its pane activity is fresh again for a sustained window, to
  self-heal a false positive without pilot action. Deferred to avoid flapping; the AND
  detector makes false positives rare enough that manual takeover/stand-down suffices.
- **Optional error-banner fast path.** An off-by-default, overridable regex
  (`WM_STALL_BANNER_RE`) over the pane to catch a *terminal* API-error banner faster than
  the idle threshold. Deferred because banner text is harness/version-specific (against
  the harness-agnostic grain) and because Claude Code auto-retries transient errors -
  matching the transient banner would false-alarm during normal recovery, whereas the
  idle detector fires only once the agent has actually stopped.
- **Per-type thresholds.** If some crew types are legitimately quieter than others, allow
  a per-playbook `WM_STALL_IDLE` override.

## 8. Files touched (summary)

| File | Change |
|---|---|
| `bin/lib/common.sh` | add `wm_tmux_window_activity_age` helper |
| `bin/lib/wm-state.py` | add `stalled` to `LIVE_STATES`; include `stalled` in `needs-attention`; add `stall-check` command + `_parse_iso` helper |
| `bin/watch-fleet` | add `STALL_IDLE` tunable; `continue` after permission flip; call `stall-check` per working member in the existing loop |
| `CLAUDE.md` | document the stall detector and the `stalled` state |
| `playbook/_status-contract.md` | document that the supervisor may flip a member to `stalled`; reinforce status-refresh cadence |

## 9. Open questions

- **Default threshold.** Is 180s the right default for this fleet's typical workloads, or
  should it be higher (e.g. 300s) given some build tasks run long silent test suites?
  Recommended: ship 180s and adjust from observation; it is one env var.
- **`monitor-activity` dependency.** §5.1 must confirm `window_activity` advances without
  it; if a tmux configuration is found where it does not, fall back to the double-capture
  method (capture pane text twice `WM_STALL_SETTLE` apart and compare for byte-identity)
  as the pane-idle signal.
